import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:pp_ocr/pp_ocr.dart';

import 'recognition.dart';

/// PP-OCRv6 模型文件路径（解压到可写目录后的绝对路径）
class PpOcrModelPaths {
  final String det;
  final String rec;
  final String dict;
  const PpOcrModelPaths(this.det, this.rec, this.dict);
}

const String _assetDir = 'assets/ocr/ppocr_v6';
const List<String> _modelFiles = ['det.onnx', 'rec.onnx', 'ppocr_v6_dict.txt'];

/// 确保模型文件存在于应用支持目录，返回其绝对路径。
///
/// `pp_ocr.initialize` 只接受文件路径，Flutter 资源无法直接作为路径使用，
/// 因此首次使用时把三个资源文件复制到 [getApplicationSupportDirectory]。
Future<PpOcrModelPaths> ensurePpOcrModels() async {
  final support = await getApplicationSupportDirectory();
  final sep = Platform.pathSeparator;
  final dir = Directory('${support.path}${sep}ocr${sep}ppocr_v6');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  for (final name in _modelFiles) {
    final file = File('${dir.path}$sep$name');
    final ready = await file.exists() && await file.length() > 0;
    if (ready) continue;
    final data = await rootBundle.load('$_assetDir/$name');
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await file.writeAsBytes(bytes, flush: true);
  }
  return PpOcrModelPaths(
    '${dir.path}${sep}det.onnx',
    '${dir.path}${sep}rec.onnx',
    '${dir.path}${sep}ppocr_v6_dict.txt',
  );
}

/// 把 pp_ocr 的四角框映射为轴对齐词框，并按 上→下、同高 左→右 排序。
///
/// 入参每项为 `[text, x0, y0, x1, y1, x2, y2, x3, y3]`（共 9 项）。
/// 纯函数，便于单元测试。
List<OcrWordBox> mapPpOcrQuadsToWordBoxes(List<List<Object?>> raw) {
  final boxes = <OcrWordBox>[];
  for (final item in raw) {
    if (item.length < 9) continue;
    final text = (item[0] as String? ?? '').trim();
    if (text.isEmpty) continue;

    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    var valid = true;
    for (var i = 1; i + 1 < item.length && i < 9; i += 2) {
      final x = item[i];
      final y = item[i + 1];
      if (x is! num || y is! num) {
        valid = false;
        break;
      }
      final dx = x.toDouble();
      final dy = y.toDouble();
      if (dx < minX) minX = dx;
      if (dx > maxX) maxX = dx;
      if (dy < minY) minY = dy;
      if (dy > maxY) maxY = dy;
    }
    if (!valid || minX == double.infinity) continue;

    final left = minX.round();
    final top = minY.round();
    final w = math.max(1, maxX.round() - left);
    final h = math.max(1, maxY.round() - top);
    boxes.add(OcrWordBox(text, left, top, w, h));
  }
  boxes.sort((a, b) => a.y != b.y ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
  return boxes;
}

/// 后台 OCR worker：长生命周期 isolate，串行处理请求。
///
/// `pp_ocr.recognizeImageBytes` 内部是同步 FFI 调用，放在 UI isolate 会阻塞
/// 帧渲染；这里把引擎创建、模型加载和每次识别都搬到独立 isolate。
/// 任何失败（DLL/模型缺失、初始化失败、超时、异常退出）只发生一次：之后
/// 永久标记不可用，[tryRecognize] 返回 null，由调用方按「未识别到文本」处理。
class IsolatePaddleOcr {
  IsolatePaddleOcr({
    this.initTimeout = const Duration(seconds: 60),
    this.requestTimeout = const Duration(seconds: 20),
    this.onDisabled,
  });

  /// 等待 worker 完成模型加载与引擎初始化的最长时间
  final Duration initTimeout;

  /// 单次识别的最长等待
  final Duration requestTimeout;

  /// 后台 OCR 被禁用时回调一次原因
  final void Function(String reason)? onDisabled;

  Isolate? _isolate;
  ReceivePort? _recv;
  SendPort? _send;
  Completer<List<Object?>>? _pending;
  Future<void>? _spawning;
  Future<void> _tail = Future<void>.value();
  bool _disabled = false;
  bool _disposed = false;

  bool get disabled => _disabled;

  /// 识别 PNG 字节。后台不可用、超时或失败时返回 null。
  Future<List<List<Object?>>?> tryRecognize(
    PpOcrModelPaths paths,
    Uint8List png,
  ) {
    if (_disabled || _disposed || png.isEmpty) {
      return Future<List<List<Object?>>?>.value(null);
    }
    // 串行排队：同一时刻只有一个请求在飞，避免请求/响应错配。
    final result = _tail.then((_) => _recognize(paths, png));
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// 释放 worker（幂等）。Provider 销毁 / 应用退出时调用。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _killWorker();
  }

  Future<List<List<Object?>>?> _recognize(
    PpOcrModelPaths paths,
    Uint8List png,
  ) async {
    if (_disabled || _disposed) return null;

    if (_send == null) {
      final spawning = _spawning ??= _spawn(paths);
      try {
        await spawning;
      } catch (e) {
        _disable('OCR 后台 isolate 启动失败：$e');
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
      send.send(TransferableTypedData.fromList([png]));
    } catch (e) {
      _pending = null;
      _disable('OCR 请求发送失败：$e');
      return null;
    }

    List<Object?> reply;
    try {
      reply = await completer.future.timeout(requestTimeout);
    } on TimeoutException {
      _disable('OCR 识别超时（${requestTimeout.inMilliseconds}ms）');
      return null;
    } catch (e) {
      _disable('OCR 后台 isolate 异常：$e');
      return null;
    } finally {
      _pending = null;
    }

    if (reply.isNotEmpty && reply[0] == 'error') {
      _disable('OCR 识别失败：${reply.length > 1 ? reply[1] : ''}');
      return null;
    }
    final results = <List<Object?>>[];
    for (final item in reply) {
      if (item is List) results.add(item.cast<Object?>());
    }
    return results;
  }

  Future<void> _spawn(PpOcrModelPaths paths) async {
    final recv = ReceivePort();
    final ready = Completer<SendPort>();
    recv.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (!ready.isCompleted) {
        final detail = message is List && message.length > 1
            ? message[1]
            : message;
        ready.completeError(StateError('worker 初始化失败：$detail'));
        return;
      }
      final pending = _pending;
      if (message is List) {
        if (pending != null && !pending.isCompleted) {
          pending.complete(message.cast<Object?>());
        }
        return;
      }
      // onError / onExit：worker 已失效
      if (_disposed) return;
      if (pending != null && !pending.isCompleted) {
        pending.completeError(StateError('worker 已退出：$message'));
      }
      _disable('OCR isolate 意外退出：$message');
    });
    _recv = recv;
    try {
      _isolate = await Isolate.spawn<List<Object?>>(
        _paddleOcrWorker,
        <Object?>[recv.sendPort, paths.det, paths.rec, paths.dict],
        onError: recv.sendPort,
        onExit: recv.sendPort,
        debugName: 'bpc-paddle-ocr',
      );
      _send = await ready.future.timeout(initTimeout);
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

/// worker 入口：加载模型 → 握手 → 循环处理 PNG 识别请求。
Future<void> _paddleOcrWorker(List<Object?> args) async {
  final toMain = args[0] as SendPort;
  final detPath = args[1] as String;
  final recPath = args[2] as String;
  final dictPath = args[3] as String;

  final ocr = PaddleOcr();
  try {
    final ok = await ocr.initialize(
      detModelPath: detPath,
      recModelPath: recPath,
      dictPath: dictPath,
    );
    if (!ok) {
      toMain.send(<Object?>['error', 'pp_ocr 初始化失败（模型或原生库不可用）']);
      return;
    }
  } catch (e) {
    toMain.send(<Object?>['error', 'pp_ocr 初始化异常：$e']);
    try {
      ocr.dispose();
    } catch (_) {}
    return;
  }

  final recv = ReceivePort();
  toMain.send(recv.sendPort); // 握手：初始化完成后才交出 worker 端口
  await for (final message in recv) {
    if (message == null) break;
    if (message is! TransferableTypedData) continue;
    try {
      final bytes = message.materialize().asUint8List();
      final results = await ocr.recognizeImageBytes(bytes);
      final out = <Object?>[];
      for (final r in results) {
        final item = <Object?>[r.text];
        for (final p in r.box) {
          item.add(p.dx);
          item.add(p.dy);
        }
        out.add(item);
      }
      toMain.send(out);
    } catch (e) {
      toMain.send(<Object?>['error', '$e']);
    }
  }
  try {
    ocr.dispose();
  } catch (_) {}
  recv.close();
}
