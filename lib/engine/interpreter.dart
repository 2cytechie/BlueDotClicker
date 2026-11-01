import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/blueprint.dart';
import '../platform/platform_automation.dart';
import '../platform/recording.dart' show replayActions;
import '../services/recognition.dart';
import '../services/script_storage.dart' show DataStore;
import '../services/windows_recognition.dart' show loadTemplateFile;
import 'variables.dart';

/// 执行引擎回调集合
class EngineHooks {
  final void Function(String message) log;
  final void Function(String? nodeId) onNodeChange;
  final Future<BlueprintScript?> Function(String name) loadScript;

  /// 按 id 加载录制（「执行录制」节点用），找不到返回 null
  final Future<Recording?> Function(String id) loadRecording;
  const EngineHooks({
    required this.log,
    required this.onNodeChange,
    required this.loadScript,
    this.loadRecording = _defaultLoadRecording,
  });

  static Future<Recording?> _defaultLoadRecording(String id) async => null;
}

/// 蓝图解释执行引擎：从开始节点沿执行流遍历，数据端口沿数据边取值。
/// 单实例对应一次运行（或复用时需先 reset）。
class BlueprintInterpreter {
  BlueprintInterpreter({
    required this.automation,
    required this.recognition,
    required this.hooks,
  });

  final PlatformAutomation automation;
  final RecognitionService recognition;
  final EngineHooks hooks;

  VariableTable vars = VariableTable();
  bool _stopped = false;
  bool _running = false;
  int _depth = 0;

  /// 最近一次截图（screenshot/ocr/imageMatch 节点共享）
  RawImage? _lastImage;

  /// 输出数据端口缓存（本次运行内有效）
  final Map<PortRef, Object?> _portValues = {};

  /// 模板文件缓存
  final Map<String, RawImage> _templateCache = {};

  /// 循环节点剩余计数（-1 = 无限）
  final Map<String, int> _loopRemaining = {};

  bool get isRunning => _running;

  void stop() => _stopped = true;

  Future<void> run(BlueprintScript script, {Map<String, Object>? initialVars}) async {
    if (_running) throw StateError('引擎已在运行中');
    _running = true;
    _stopped = false;
    vars = VariableTable(initialVars ?? script.variables);
    _lastImage = null;
    _portValues.clear();
    _loopRemaining.clear();
    try {
      final start = script.findStart();
      if (start == null) {
        hooks.log('错误：蓝图中没有「开始」节点');
        return;
      }
      // 开始节点执行次数：0/负 = 一直执行（运行中按 F10 停止）
      final count = (start.params['count'] as num?)?.toInt() ?? 1;
      final forever = count <= 0;
      final suffix = forever ? '（一直执行，F10 停止）' : (count > 1 ? '（共 $count 次）' : '');
      hooks.log('▶ 开始执行：${script.name}$suffix');
      var round = 0;
      while (!_stopped && (forever || round < count)) {
        round++;
        if (!forever && count > 1) hooks.log('—— 第 $round/$count 次 ——');
        // 每轮清空端口与截图缓存（变量表跨轮保留，可作累计器）
        _portValues.clear();
        _loopRemaining.clear();
        _lastImage = null;
        await _exec(script, start, 'enter');
      }
      hooks.log(_stopped ? '■ 已停止' : '✓ 执行完成');
    } on UnsupportedError catch (e) {
      hooks.log('✗ 平台不支持：${e.message}');
    } catch (e) {
      hooks.log('✗ 执行异常：$e');
    } finally {
      hooks.onNodeChange(null);
      _running = false;
    }
  }

  /// 执行从 [node] 开始的链（[viaPort] 为进入端口 key）
  Future<void> _exec(BlueprintScript script, BPNode node, String viaPort) async {
    BPNode? current = node;
    String currentPort = viaPort;
    var steps = 0;
    while (current != null && !_stopped) {
      if (++steps > 100000) {
        hooks.log('✗ 执行步数超限，疑似死循环，已终止');
        return;
      }
      final n = current;
      final inPort = currentPort;
      hooks.onNodeChange(n.id);
      final outKey = await _execute(script, n, inPort);
      if (_stopped) return;
      // 找到下一个执行节点
      final edges = script.outEdges(n.id, outKey, kind: EdgeKind.exec);
      if (edges.isEmpty) {
        hooks.onNodeChange(null);
        return;
      }
      final e = edges.first;
      current = script.nodes[e.to.nodeId];
      currentPort = e.to.port;
    }
  }

  /// 执行单个节点动作，返回继续执行的输出端口 key
  Future<String> _execute(BlueprintScript script, BPNode n, String inPort) async {
    switch (n.type) {
      case 'start':
        return 'out';

      case 'click':
        final x = _paramInt(n, 'x', 'x');
        final y = _paramInt(n, 'y', 'y');
        final button = _mouseButton(n.params['button']);
        await automation.click(x, y, button: button);
        hooks.log('点击 ($x, $y)${_buttonLabel(button)}');
        return 'out';

      case 'doubleClick':
        final x = _paramInt(n, 'x', 'x');
        final y = _paramInt(n, 'y', 'y');
        final button = _mouseButton(n.params['button']);
        await automation.click(x, y, button: button, count: 2);
        hooks.log('双击 ($x, $y)${_buttonLabel(button)}');
        return 'out';

      case 'swipe':
        final (x1, y1) = _swipeStart(n);
        final (x2, y2) = _swipeEnd(n);
        final dur = (n.params['durationMs'] as num?)?.toInt() ?? 300;
        await automation.swipe(x1, y1, x2, y2, durationMs: dur);
        hooks.log('滑动 ($x1,$y1) → ($x2,$y2) ${dur}ms');
        return 'out';

      case 'longPress':
        final x = (n.params['x'] as num?)?.toInt() ?? 0;
        final y = (n.params['y'] as num?)?.toInt() ?? 0;
        final dur = (n.params['durationMs'] as num?)?.toInt() ?? 800;
        await automation.longPress(x, y, durationMs: dur);
        hooks.log('长按 ($x, $y) ${dur}ms');
        return 'out';

      case 'playRecording':
        {
          final id = ((n.params['recordingId'] as String?) ?? '').trim();
          if (id.isEmpty) {
            hooks.log('执行录制失败：未选择录制');
            return 'out';
          }
          final rec = await hooks.loadRecording(id);
          if (rec == null) {
            hooks.log('执行录制失败：找不到录制 "$id"（可能已删除）');
            return 'out';
          }
          hooks.log('执行录制「${rec.name}」共 ${rec.actions.length} 个动作');
          await replayActions(automation, rec.actions,
              cancelled: () => _stopped, log: hooks.log);
          hooks.log(_stopped ? '执行录制中止' : '录制「${rec.name}」执行完成');
          return 'out';
        }

      case 'screenshot':
        _lastImage = await _captureNow();
        _portValues[PortRef(nodeId: n.id, port: 'imageOut')] = _lastImage;
        hooks.log('截图 ${_lastImage != null ? '${_lastImage!.width}×${_lastImage!.height}' : '失败'}');
        return 'out';

      case 'ocr':
        {
          final region = _region(n);
          final img = await _acquireImage(script, n, region: region);
          if (img == null) {
            hooks.log('OCR 失败：无可用图像');
            _writeOut(n, 'text', '');
            return 'out';
          }
          final res = await recognition.recognizeText(img);
          final fullX = (region?.x ?? 0) + res.x;
          final fullY = (region?.y ?? 0) + res.y;
          final varName = (n.params['resultVar'] as String?)?.trim() ?? '';
          if (varName.isNotEmpty) vars[varName] = res.text;
          _writeOut(n, 'text', res.text);
          _writeOut(n, 'x', fullX);
          _writeOut(n, 'y', fullY);
          hooks.log('OCR: "${_brief(res.text)}" → ${varName.isEmpty ? '(未存变量)' : varName}');
          return 'out';
        }

      case 'imageMatch':
        {
          final tplPath = (n.params['templatePath'] as String?)?.trim() ?? '';
          if (tplPath.isEmpty) {
            hooks.log('图像识别失败：未选择模板图片');
            _setFound(n, false);
            return 'out';
          }
          final tpl = await _getTemplate(tplPath);
          final threshold = (n.params['threshold'] as num?)?.toDouble() ?? 0.8;
          final region = _region(n);
          final img = await _acquireImage(script, n, region: region);
          if (img == null) {
            hooks.log('图像识别失败：无可用图像');
            _setFound(n, false);
            return 'out';
          }
          final r = await recognition.matchTemplate(img, tpl, threshold: threshold);
          final fullX = (region?.x ?? 0) + r.x;
          final fullY = (region?.y ?? 0) + r.y;
          final foundVar = (n.params['foundVar'] as String?)?.trim() ?? '';
          final xVar = (n.params['posXVar'] as String?)?.trim() ?? '';
          final yVar = (n.params['posYVar'] as String?)?.trim() ?? '';
          if (foundVar.isNotEmpty) vars[foundVar] = r.found;
          if (xVar.isNotEmpty) vars[xVar] = fullX;
          if (yVar.isNotEmpty) vars[yVar] = fullY;
          _setFound(n, r.found, x: fullX, y: fullY, score: r.score);
          hooks.log(
              '图像识别: ${r.found ? "命中" : "未命中"} score=${r.score.toStringAsFixed(3)} pos=($fullX,$fullY)');
          return 'out';
        }

      case 'condition':
        {
          final left = await _resolveInput(script, n, 'left', 'leftVar', 'leftConst');
          final right = await _resolveInput(script, n, 'right', 'rightVar', 'rightConst');
          final op = (n.params['op'] as String?) ?? '==';
          final ok = compareValues(left, right, op);
          hooks.log('条件: ${_brief(left)} $op ${_brief(right)} → ${ok ? '真' : '假'}');
          return ok ? 'true' : 'false';
        }

      case 'loop':
        {
          final count = (n.params['count'] as num?)?.toInt() ?? 0;
          final isInfinite = count <= 0;
          if (inPort == 'enter' && !_loopRemaining.containsKey(n.id)) {
            _loopRemaining[n.id] = isInfinite ? -1 : count;
          }
          final remaining = _loopRemaining[n.id] ?? 0;
          if (isInfinite && remaining == -1 || remaining > 0) {
            if (!isInfinite) _loopRemaining[n.id] = remaining - 1;
            hooks.log(isInfinite ? '循环(无限) → body' : '循环 → body (剩 ${_loopRemaining[n.id]})');
            return 'body';
          }
          _loopRemaining.remove(n.id);
          hooks.log('循环完成');
          return 'done';
        }

      case 'delay':
        {
          final ms = (n.params['ms'] as num?)?.toInt() ?? 0;
          hooks.log('延时 ${ms}ms');
          var left = ms.clamp(0, 3600000);
          while (left > 0 && !_stopped) {
            final step = math.min(left, 50);
            await Future<void>.delayed(Duration(milliseconds: step));
            left -= step;
          }
          return 'out';
        }

      case 'setVar':
        {
          final name = ((n.params['name'] as String?) ?? '').trim();
          if (name.isEmpty) {
            hooks.log('设置变量失败：变量名为空');
            return 'out';
          }
          final value = await _resolveInput(script, n, 'value', null, 'const');
          vars[name] = value is String ? VariableTable.parseLiteral(value) : (value ?? '');
          _writeOut(n, 'valueOut', vars[name]);
          hooks.log('变量 $name = ${_brief(vars[name])}');
          return 'out';
        }

      case 'storage':
        {
          final key = ((n.params['key'] as String?) ?? '').trim();
          final name = ((n.params['name'] as String?) ?? '').trim();
          final action = (n.params['action'] as String?) ?? 'save';
          if (key.isEmpty || name.isEmpty) {
            hooks.log('数据存取失败：键/变量名为空');
            return 'out';
          }
          if (action == 'save') {
            final value = await _resolveInput(script, n, 'value', 'name', null) ?? vars[name] ?? '';
            await DataStore.set(key, value);
            hooks.log('存储: $key ← ${_brief(value)}');
          } else {
            final v = await DataStore.get(key);
            if (v != null) vars[name] = v;
            _writeOut(n, 'valueOut', v);
            hooks.log('读取: $key → $name = ${_brief(v)}');
          }
          return 'out';
        }

      case 'subScript':
        {
          final name = ((n.params['scriptName'] as String?) ?? '').trim();
          if (name.isEmpty) {
            hooks.log('子脚本调用失败：未指定脚本');
            return 'out';
          }
          if (_depth >= 8) {
            hooks.log('子脚本调用失败：递归深度超限');
            return 'out';
          }
          final sub = await hooks.loadScript(name);
          if (sub == null) {
            hooks.log('子脚本调用失败：找不到脚本 "$name"');
            return 'out';
          }
          hooks.log('调用子脚本: $name');
          _depth++;
          try {
            final subInterp = BlueprintInterpreter(
              automation: automation,
              recognition: recognition,
              hooks: hooks,
            )
              .._depth = _depth;
            await subInterp.run(sub);
            if (subInterp._stopped) _stopped = true;
          } finally {
            _depth--;
          }
          return 'out';
        }
      default:
        hooks.log('未知节点类型: ${n.type}');
        return 'out';
    }
  }

  // ---- 参数/数据解析辅助 ----

  void _writeOut(BPNode n, String port, Object? value) =>
      _portValues[PortRef(nodeId: n.id, port: port)] = value;

  void _setFound(BPNode n, bool found, {int? x, int? y, double? score}) {
    _writeOut(n, 'found', found);
    if (x != null) _writeOut(n, 'x', x);
    if (y != null) _writeOut(n, 'y', y);
    if (score != null) _writeOut(n, 'score', score);
  }

  int _paramInt(BPNode n, String key, String varKey) {
    final v = n.params[key];
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  /// 解析节点参数中的鼠标键（'left'/'right'/'middle'，默认左键）
  MouseButton _mouseButton(Object? v) => switch (v) {
        'right' => MouseButton.right,
        'middle' => MouseButton.middle,
        _ => MouseButton.left,
      };

  String _buttonLabel(MouseButton b) => switch (b) {
        MouseButton.right => ' 右键',
        MouseButton.middle => ' 中键',
        _ => '',
      };

  (int, int) _swipeStart(BPNode n) =>
      ((n.params['startX'] as num?)?.toInt() ?? 0, (n.params['startY'] as num?)?.toInt() ?? 0);

  (int, int) _swipeEnd(BPNode n) {
    final mode = (n.params['mode'] as String?) ?? 'coords';
    if (mode == 'direction') {
      final angleDeg = (n.params['angle'] as num?)?.toDouble() ?? 0;
      final dist = (n.params['distance'] as num?)?.toInt() ?? 200;
      final rad = -angleDeg * math.pi / 180; // 屏幕Y向下，角度逆时针为正
      final sx = (n.params['startX'] as num?)?.toInt() ?? 0;
      final sy = (n.params['startY'] as num?)?.toInt() ?? 0;
      return (sx + (dist * math.cos(rad)).round(), sy + (dist * math.sin(rad)).round());
    }
    return ((n.params['endX'] as num?)?.toInt() ?? 0, (n.params['endY'] as num?)?.toInt() ?? 0);
  }

  RectPx? _region(BPNode n) {
    if (n.params['useRegion'] != true) return null;
    final x = (n.params['rx'] as num?)?.toInt() ?? 0;
    final y = (n.params['ry'] as num?)?.toInt() ?? 0;
    final w = (n.params['rw'] as num?)?.toInt() ?? 400;
    final h = (n.params['rh'] as num?)?.toInt() ?? 300;
    return RectPx(x, y, w, h);
  }

  /// 获取节点输入图像：数据边 > 上次截图 > 现场截屏
  Future<RawImage?> _acquireImage(BlueprintScript script, BPNode n, {RectPx? region}) async {
    RawImage? img;
    final dataEdges = script.inEdges(n.id, 'image', kind: EdgeKind.data);
    if (dataEdges.isNotEmpty) {
      final v = _portValues[dataEdges.first.from];
      if (v is RawImage) img = v;
    }
    img ??= _lastImage;
    img ??= await _captureNow();
    if (img == null) return null;
    if (region != null) return _cropImage(img, region);
    return img;
  }

  Future<RawImage?> _captureNow() async {
    try {
      final cap = await automation.capture();
      return RawImage(cap.width, cap.height, cap.bgra);
    } on UnsupportedError {
      return null;
    }
  }

  RawImage _cropImage(RawImage img, RectPx r) => cropImage(img, r);

  /// 裁剪图像区域。越界参数先钳制到图像内（直接 clamp 宽高会在起点越界时抛
  /// ArgumentError，导致整个脚本中止），越界部分视为被图像边缘截断。
  @visibleForTesting
  static RawImage cropImage(RawImage img, RectPx r) {
    final x = r.x.clamp(0, img.width - 1);
    final y = r.y.clamp(0, img.height - 1);
    final w = r.w.clamp(1, img.width - x);
    final h = r.h.clamp(1, img.height - y);
    final result = Uint8List(w * h * 4);
    for (var row = 0; row < h; row++) {
      final srcStart = ((y + row) * img.width + x) * 4;
      result.setRange(row * w * 4, (row + 1) * w * 4, img.bgra, srcStart);
    }
    return RawImage(w, h, result);
  }

  /// 获取模板（带缓存与错误日志）
  Future<RawImage> _getTemplate(String path) async {
    final cached = _templateCache[path];
    if (cached != null) return cached;
    try {
      final tpl = await loadTemplateFile(path);
      _templateCache[path] = tpl;
      return tpl;
    } catch (e) {
      hooks.log('模板加载失败：$e');
      rethrow;
    }
  }

  /// 解析输入端口值：数据边 > 变量名 > 常量参数
  Future<Object?> _resolveInput(
      BlueprintScript script, BPNode n, String port, String? varKey, String? constKey) async {
    final edges = script.inEdges(n.id, port, kind: EdgeKind.data);
    if (edges.isNotEmpty) {
      final v = _portValues[edges.first.from];
      if (v != null) return v;
    }
    if (varKey != null) {
      final name = ((n.params[varKey] as String?) ?? '').trim();
      if (name.isNotEmpty && vars.contains(name)) return vars[name];
    }
    if (constKey != null) {
      return (n.params[constKey] as String?) ?? '';
    }
    return '';
  }

  String _brief(Object? v) {
    final s = '$v';
    return s.length > 32 ? '${s.substring(0, 32)}…' : s;
  }
}

