import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'opencv_matcher.dart';
import 'recognition.dart';
import 'template_match_dart.dart';

/// 后台模板匹配 worker：长生命周期 isolate，串行处理请求。
///
/// 模板匹配是循环轮询里最耗 CPU 的一步（OpenCV 原生调用 / 纯 Dart NCC），
/// 放在 UI isolate 上会和帧回调抢同一个线程，表现为界面卡顿。这里把它搬到
/// 独立 isolate，结果通过 SendPort 回传。
///
/// 任何失败（isolate 启动失败、超时、worker 异常退出）都只发生一次：
/// 之后永久标记不可用，[tryMatch] 返回 null，调用方回退到主线程内联匹配。
class IsolateTemplateMatcher {
  IsolateTemplateMatcher({
    this.timeout = const Duration(seconds: 5),
    this.spawnTimeout = const Duration(seconds: 3),
    this.preferOpenCv = true,
    this.onDisabled,
  });

  /// 单次匹配的最长等待；超时视为 worker 失效
  final Duration timeout;

  /// 等待 worker 握手（返回 SendPort）的最长时间
  final Duration spawnTimeout;

  /// worker 内优先 OpenCV；失败再回退纯 Dart（与主线程语义一致）
  final bool preferOpenCv;

  /// 后台能力被禁用时回调一次原因（便于在日志里说明「已回退主线程」）
  final void Function(String reason)? onDisabled;

  Isolate? _isolate;
  ReceivePort? _recv;
  SendPort? _send;
  Completer<List<Object?>>? _pending;
  Future<void>? _spawning;
  bool _disabled = false;
  bool _disposed = false;

  bool get disabled => _disabled;

  /// 后台匹配；后台不可用或调用并发时返回 null，由调用方回退内联匹配。
  /// 匹配「未命中」是正常结果（[MatchResult.found] == false），不会返回 null。
  Future<MatchResult?> tryMatch(
    RawImage image,
    RawImage template, {
    double threshold = 0.8,
  }) async {
    if (_disabled || _disposed) return null;
    if (image.bgra.isEmpty || template.bgra.isEmpty) return null;
    // 引擎本身是串行的；只有属性面板的「测试」按钮可能并发，
    // 这种情况直接走内联，避免破坏请求/响应配对。
    if (_pending != null) return null;

    if (_send == null) {
      final spawning = _spawning ??= _spawn();
      try {
        await spawning;
      } catch (e) {
        _disable('识别后台 isolate 启动失败：$e');
        return null;
      } finally {
        if (identical(_spawning, spawning)) _spawning = null;
      }
    }
    final send = _send;
    if (send == null) return null;

    final completer = Completer<List<Object?>>();
    _pending = completer;
    try {
      send.send(<Object?>[
        image.width,
        image.height,
        // 先复制再转移：RawImage.bgra 可能被引擎复用（_lastImage/模板缓存），
        // 不能把原缓冲区交给 TransferableTypedData。
        TransferableTypedData.fromList([Uint8List.fromList(image.bgra)]),
        template.width,
        template.height,
        TransferableTypedData.fromList([Uint8List.fromList(template.bgra)]),
        threshold,
      ]);
    } catch (e) {
      _pending = null;
      _disable('识别请求发送失败：$e');
      return null;
    }

    final List<Object?> reply;
    try {
      reply = await completer.future.timeout(timeout);
    } on TimeoutException {
      _disable('识别后台 isolate 超时（${timeout.inMilliseconds}ms）');
      return null;
    } catch (e) {
      _disable('识别后台 isolate 异常：$e');
      return null;
    } finally {
      _pending = null;
    }

    if (reply.length != 4 || reply[0] is! bool) {
      _disable('识别后台 isolate 返回异常：$reply');
      return null;
    }
    return MatchResult(
      reply[0] as bool,
      reply[1] as int,
      reply[2] as int,
      (reply[3] as num).toDouble(),
    );
  }

  /// 释放 worker（幂等）。Provider 销毁 / 应用退出时调用。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _killWorker();
  }

  Future<void> _spawn() async {
    final recv = ReceivePort();
    final ready = Completer<SendPort>();
    recv.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (!ready.isCompleted) {
        ready.completeError(StateError('worker 提前退出：$message'));
        return;
      }
      final pending = _pending;
      if (message is List && message.length == 4 && message[0] is bool) {
        if (pending != null && !pending.isCompleted) pending.complete(message);
        return;
      }
      if (message is List && message.isNotEmpty && message[0] == 'error') {
        if (pending != null && !pending.isCompleted) pending.complete(message);
        return;
      }
      // onError / onExit：worker 已失效
      if (_disposed) return;
      if (pending != null && !pending.isCompleted) {
        pending.completeError(StateError('worker 已退出：$message'));
      }
      _disable('识别 isolate 意外退出：$message');
    });
    _recv = recv;
    try {
      _isolate = await Isolate.spawn<List<Object?>>(
        _templateMatchWorker,
        <Object?>[recv.sendPort, preferOpenCv],
        onError: recv.sendPort,
        onExit: recv.sendPort,
        debugName: 'bpc-template-match',
      );
      _send = await ready.future.timeout(spawnTimeout);
    } catch (_) {
      recv.close();
      _recv = null;
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      rethrow;
    }
  }

  void _disable(String reason) {
    if (_disabled) return;
    _disabled = true;
    onDisabled?.call(reason);
    _killWorker();
  }

  void _killWorker() {
    _send?.send(null); // 通知 worker 主动退出
    _send = null;
    _recv?.close();
    _recv = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

/// worker 入口：握手 → 循环处理匹配请求。
Future<void> _templateMatchWorker(List<Object?> args) async {
  final toMain = args[0] as SendPort;
  final preferOpenCv = args[1] as bool;
  final recv = ReceivePort();
  toMain.send(recv.sendPort); // 握手：把 worker 的 SendPort 交给主 isolate
  await for (final message in recv) {
    if (message == null) break; // 关闭信号
    if (message is! List || message.length != 7) continue;
    try {
      final image = RawImage(
        message[0] as int,
        message[1] as int,
        (message[2] as TransferableTypedData).materialize().asUint8List(),
      );
      final template = RawImage(
        message[3] as int,
        message[4] as int,
        (message[5] as TransferableTypedData).materialize().asUint8List(),
      );
      final threshold = (message[6] as num).toDouble();
      MatchResult r;
      if (preferOpenCv) {
        try {
          r = const OpenCvMatcher().match(image, template, threshold: threshold);
        } catch (_) {
          // 原生库在 worker 内不可用：与主线程一致地回退纯 Dart
          r = const DartTemplateMatcher()
              .match(image, template, threshold: threshold);
        }
      } else {
        r = const DartTemplateMatcher()
            .match(image, template, threshold: threshold);
      }
      toMain.send(<Object?>[r.found, r.x, r.y, r.score]);
    } catch (e) {
      toMain.send(<Object?>['error', '$e']);
    }
  }
  recv.close();
}
