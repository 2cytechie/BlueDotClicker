import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/blueprint.dart';
import '../models/key_names.dart';
import '../platform/platform_automation.dart';
import '../platform/recording.dart' show replayActions;
import '../services/file_saver.dart';
import '../services/ocr_target.dart';
import '../services/recognition.dart';
import '../services/windows_recognition.dart' show loadTemplateFile;
import 'variables.dart';

/// 执行引擎回调集合
class EngineHooks {
  final void Function(String message) log;
  final void Function(String? nodeId) onNodeChange;

  /// 按 id 加载录制（「执行录制」节点用），找不到返回 null
  final Future<Recording?> Function(String id) loadRecording;
  const EngineHooks({
    required this.log,
    required this.onNodeChange,
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

  /// 最近一次截图（screenshot/ocr/imageMatch 节点共享）
  RawImage? _lastImage;

  /// 图像左上角对应的屏幕坐标（虚拟桌面坐标，副屏在主屏左侧时可为负）。
  /// 截图与裁剪都会登记，区域坐标换算与识别结果回算都以此为准。
  final Expando<(int, int)> _imageOrigin = Expando<(int, int)>('imageOrigin');

  /// 输出数据端口缓存（本次运行内有效）
  final Map<PortRef, Object?> _portValues = {};

  /// 模板文件缓存
  final Map<String, RawImage> _templateCache = {};

  /// 数据保存节点落盘服务（overrideDir 静态注入便于测试）
  final SaveFileService _saver = SaveFileService();

  /// 本次运行已提示过警告的节点 id（变量缺失等，避免循环内刷屏）
  final Set<String> _warnedNodes = {};

  /// 组合键执行中尚未抬起的按键：停止或异常结束时统一释放，避免卡住用户桌面
  final Set<int> _pressedKeys = {};

  bool get isRunning => _running;

  void stop() => _stopped = true;

  Future<void> run(BlueprintScript script, {Map<String, Object>? initialVars}) async {
    if (_running) throw StateError('引擎已在运行中');
    _running = true;
    _stopped = false;
    vars = VariableTable(initialVars ?? script.variables);
    _lastImage = null;
    _portValues.clear();
    _warnedNodes.clear();
    _pressedKeys.clear();
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
        _lastImage = null;
        await _exec(script, start, 'enter');
      }
      hooks.log(_stopped ? '■ 已停止' : '✓ 执行完成');
    } on UnsupportedError catch (e) {
      hooks.log('✗ 平台不支持：${e.message}');
    } catch (e) {
      hooks.log('✗ 执行异常：$e');
    } finally {
      await _releaseHeldInputs();
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

      case 'mouse':
        await _executeMouse(script, n);
        return 'out';

      case 'keyboard':
        await _executeKeyboard(n);
        return 'out';

      case 'playRecording':
        {
          _writeOut(n, 'success', false);
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
          if (_stopped) {
            hooks.log('执行录制中止');
            return 'out';
          }
          _writeOut(n, 'success', true);
          hooks.log('录制「${rec.name}」执行完成');
          return 'out';
        }

      case 'screenshot':
        {
          final region = await _resolveRegion(script, n);
          if (region.enabled && !region.valid) {
            hooks.log('截图失败：区域无效（宽或高为 0）');
            _lastImage = null;
            _writeOut(n, 'imageOut', null);
            return 'out';
          }
          // 区域坐标支持负值（副屏在主屏左侧/上方时为负）
          _lastImage = await _captureNow(region: region.rect);
          _portValues[PortRef(nodeId: n.id, port: 'imageOut')] = _lastImage;
          final ok = _lastImage != null;
          hooks.log(
              '截图 ${ok ? '${_lastImage!.width}×${_lastImage!.height}' : '失败'}');
          return 'out';
        }

      case 'ocr':
        {
          final region = await _resolveRegion(script, n);
          if (region.enabled && !region.valid) {
            hooks.log('OCR 失败：区域无效（宽或高为 0）');
            _writeOcrFailure(n);
            return 'out';
          }
          final img = await _acquireImage(script, n, region: region.rect);
          if (img == null) {
            hooks.log('OCR 失败：无可用图像');
            _writeOcrFailure(n);
            return 'out';
          }
          final res = await recognition.recognizeText(img);
          final target =
              ((await _resolveInput(script, n, 'targetText', 'targetText')) ?? '')
                  .toString();
          // 坐标输出：目标文本为空 = 识别区域中心（旧语义）；
          // 目标非空 = 命中文字包围盒中心，未命中为 -1。
          final (imgX, imgY) = _imageOrigin[img] ?? (0, 0);
          var found = res.text.isNotEmpty;
          var cx = region.rect != null
              ? region.rect!.x + region.rect!.w ~/ 2
              : imgX + img.width ~/ 2;
          var cy = region.rect != null
              ? region.rect!.y + region.rect!.h ~/ 2
              : imgY + img.height ~/ 2;
          if (target.trim().isNotEmpty) {
            final hit = findOcrTarget(res.words, target);
            if (hit != null) {
              found = true;
              cx = imgX + hit.x;
              cy = imgY + hit.y;
              hooks.log('OCR 命中「$target」→ ($cx, $cy)');
            } else if (res.words.isEmpty &&
                normalizeOcrText(res.text).contains(normalizeOcrText(target))) {
              // 引擎未返回词框：只能判断命中，坐标回退区域中心
              found = true;
              hooks.log('OCR 命中「$target」（无词框，坐标回退区域中心）');
            } else {
              found = false;
              cx = -1;
              cy = -1;
              hooks.log('OCR 未找到目标文本「$target」');
            }
          }
          _writeOut(n, 'text', res.text);
          _writeOut(n, 'found', found);
          _writeOut(n, 'x', cx);
          _writeOut(n, 'y', cy);
          hooks.log('OCR: "${_brief(res.text)}"');
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
          final RawImage tpl;
          try {
            tpl = await _getTemplate(tplPath);
          } catch (_) {
            // 模板加载失败按节点失败处理，执行流继续
            _setFound(n, false);
            return 'out';
          }
          final threshold = (n.params['threshold'] as num?)?.toDouble() ?? 0.8;
          final region = await _resolveRegion(script, n);
          if (region.enabled && !region.valid) {
            hooks.log('图像识别失败：区域无效（宽或高为 0）');
            _setFound(n, false);
            return 'out';
          }
          final img = await _acquireImage(script, n, region: region.rect);
          if (img == null) {
            hooks.log('图像识别失败：无可用图像');
            _setFound(n, false);
            return 'out';
          }
          final r = await recognition.matchTemplate(img, tpl, threshold: threshold);
          final (imgX, imgY) = _imageOrigin[img] ?? (0, 0);
          final fullX = imgX + r.x;
          final fullY = imgY + r.y;
          _setFound(n, r.found, x: fullX, y: fullY, score: r.score);
          hooks.log(
              '图像识别: ${r.found ? "命中" : "未命中"} score=${r.score.toStringAsFixed(3)} pos=($fullX,$fullY)');
          return 'out';
        }

      case 'condition':
        {
          final left = await _resolveInput(script, n, 'left', 'leftConst');
          final right = await _resolveInput(script, n, 'right', 'rightConst');
          final op = (n.params['op'] as String?) ?? '==';
          final ok = compareValues(left, right, op);
          hooks.log('条件: ${_brief(left)} $op ${_brief(right)} → ${ok ? '真' : '假'}');
          return ok ? 'true' : 'false';
        }

      case 'loop':
        return await _executeLoop(script, n);

      case 'delay':
        {
          final ms = (n.params['ms'] as num?)?.toInt() ?? 0;
          hooks.log('延时 ${ms}ms');
          await _sleep(ms.clamp(0, 3600000));
          return 'out';
        }

      case 'setVar':
        {
          final name = ((n.params['name'] as String?) ?? '').trim();
          if (name.isEmpty) {
            hooks.log('设置变量失败：变量名为空');
            return 'out';
          }
          final value = await _resolveInput(script, n, 'value', 'const');
          vars[name] = value is String ? VariableTable.parseLiteral(value) : (value ?? '');
          _writeOut(n, 'valueOut', vars[name]);
          hooks.log('变量 $name = ${_brief(vars[name])}');
          return 'out';
        }

      case 'add':
      case 'subtract':
        {
          final isAdd = n.type == 'add';
          final a = await _resolveNumber(script, n, 'a', 'a');
          final b = await _resolveNumber(script, n, 'b', 'b');
          if (a == null || b == null) {
            hooks.log('${isAdd ? '加法' : '减法'}失败：${a == null ? 'A' : 'B'} 不是数字');
            _writeOut(n, 'result', 0);
            return 'out';
          }
          final value = isAdd ? a + b : a - b;
          final result = value is double && value == value.roundToDouble()
              ? value.toInt()
              : value;
          _writeOut(n, 'result', result);
          hooks.log(
              '${isAdd ? '加法' : '减法'}: ${_brief(a)} ${isAdd ? '+' : '−'} ${_brief(b)} = ${_brief(result)}');
          return 'out';
        }

      case 'saveData':
        {
          // 透传输出（与保存成败解耦：数据继续流给下游使用）
          final imgEdge = script.inEdges(n.id, 'image', kind: EdgeKind.data);
          final imgValue = imgEdge.isNotEmpty
              ? await _readDataPort(script, imgEdge.first.from)
              : null;
          if (imgValue is RawImage) _writeOut(n, 'imageOut', imgValue);
          final textEdge = script.inEdges(n.id, 'text', kind: EdgeKind.data);
          final textValue = textEdge.isNotEmpty
              ? await _readDataPort(script, textEdge.first.from)
              : null;
          final hasText = textEdge.isNotEmpty && textValue != null;
          if (hasText) _writeOut(n, 'textOut', textValue);

          final raw = ((n.params['fileName'] as String?) ?? '').trim();
          if (raw.isEmpty) {
            hooks.log('数据保存失败：文件名为空');
            return 'out';
          }
          var saved = false;
          if (imgValue is RawImage) {
            final p = await _saver.savePng(raw, imgValue);
            saved = true;
            hooks.log('已保存图像 → $p');
          }
          if (hasText) {
            final p = await _saver.saveText(raw, '$textValue');
            saved = true;
            hooks.log('已保存文本 → $p');
          }
          if (!saved) {
            hooks.log('数据保存：未连接文本/图像输入，未保存文件');
            return 'out';
          }
          return 'out';
        }

      default:
        // 用不存在的端口名让执行流在此中断：旧脚本里该节点之后的操作
        // 语义已不可知，继续执行可能造成比停下更危险的结果。
        hooks.log('✗ 节点类型已移除或未知：${n.type}（执行流已中断）');
        return '__halt__';
    }
  }

  /// 循环节点：条件成立时自动重复执行「真」出口后的节点链，
  /// 直到条件不成立；不成立走「假」出口（由外层线性遍历继续，仅一次）。
  /// 循环体无需连回本节点——「真」出口后的链走到死路即视为一轮结束。
  Future<String> _executeLoop(BlueprintScript script, BPNode n) async {
    final maxIterations = (n.params['maxIterations'] as num?)?.toInt() ?? 0;
    final op = (n.params['op'] as String?) ?? '==';
    var iterations = 0;
    while (!_stopped) {
      iterations++;
      if (maxIterations > 0 && iterations > maxIterations) {
        hooks.log('循环达到最大次数 $maxIterations，强制结束');
        break;
      }
      hooks.onNodeChange(n.id);
      final left = await _resolveInput(script, n, 'left', 'leftConst');
      final right = await _resolveInput(script, n, 'right', 'rightConst');
      final ok = compareValues(left, right, op);
      hooks.log(
          '循环: ${_brief(left)} ${_compareOpLabel(op)} ${_brief(right)} → ${ok ? '真' : '假'}');
      if (!ok) break;
      final edges = script.outEdges(n.id, 'true', kind: EdgeKind.exec);
      if (edges.isEmpty) {
        hooks.log('循环条件成立但「真」出口未连接，结束循环');
        break;
      }
      final bodyStart = script.nodes[edges.first.to.nodeId];
      if (bodyStart == null) break;
      // 一轮循环体 = 从真出口目标开始的一次线性链式执行（走到死路为止）
      await _exec(script, bodyStart, edges.first.to.port);
    }
    return 'false';
  }

  // ---- 鼠标 / 键盘动作 ----

  Future<void> _executeMouse(BlueprintScript script, BPNode n) async {
    final action = (n.params['action'] as String?) ?? 'click';
    final button = _mouseButton(n.params['button']);
    switch (action) {
      case 'click':
        {
          final x = await _mouseCoord(script, n, 'x');
          final y = await _mouseCoord(script, n, 'y');
          await automation.click(x, y, button: button);
          hooks.log('单击 ($x, $y)${_buttonLabel(button)}');
        }
      case 'doubleClick':
        {
          final x = await _mouseCoord(script, n, 'x');
          final y = await _mouseCoord(script, n, 'y');
          await automation.click(x, y, button: button, count: 2);
          hooks.log('双击 ($x, $y)${_buttonLabel(button)}');
        }
      case 'swipe':
        {
          // 拖拽起点复用 x/y 数据输入（与单击等动作共享同一组坐标）
          final x1 = await _mouseCoord(script, n, 'x');
          final y1 = await _mouseCoord(script, n, 'y');
          final (x2, y2) = await _swipeEnd(script, n, x1, y1);
          final dur = (n.params['durationMs'] as num?)?.toInt() ?? 300;
          await automation.swipe(
            x1,
            y1,
            x2,
            y2,
            durationMs: dur,
            button: button,
            cancelled: () => _stopped,
          );
          hooks.log('拖拽 ($x1,$y1) → ($x2,$y2) ${dur}ms${_buttonLabel(button)}');
        }
      case 'longPress':
        {
          final x = await _mouseCoord(script, n, 'x');
          final y = await _mouseCoord(script, n, 'y');
          final hold = (n.params['holdMs'] as num?)?.toInt() ?? 800;
          await automation.longPress(x, y, durationMs: hold, button: button);
          hooks.log('长按 ($x, $y) ${hold}ms ${_buttonName(button)}');
        }
      case 'scroll':
        {
          final x = await _mouseCoord(script, n, 'x');
          final y = await _mouseCoord(script, n, 'y');
          final dx = _paramInt(n, 'dx');
          final dy = _paramInt(n, 'dy');
          await automation.scrollWheel(x, y, dy: dy, dx: dx);
          hooks.log('滚轮 ($x, $y) dx=$dx dy=$dy');
        }
      case 'move':
        {
          final x = await _mouseCoord(script, n, 'x');
          final y = await _mouseCoord(script, n, 'y');
          final dur = _paramInt(n, 'moveDurationMs');
          await automation.moveMouse(
            x,
            y,
            durationMs: dur,
            cancelled: () => _stopped,
          );
          hooks.log('移动鼠标 ($x, $y)${dur > 0 ? ' ${dur}ms' : ''}');
        }
      default:
        hooks.log('鼠标操作失败：未知动作 "$action"');
    }
  }

  Future<void> _executeKeyboard(BPNode n) async {
    final action = (n.params['action'] as String?) ?? 'tap';
    final duration = ((n.params['durationMs'] as num?)?.toInt() ?? 60).clamp(0, 60000);
    switch (action) {
      case 'tap':
        {
          final vk = _vkCode(n);
          if (vk == 0) {
            hooks.log('键盘操作失败：未设置按键');
            break;
          }
          await automation.keyTap(vk, durationMs: duration, extended: isExtendedKey(vk));
          hooks.log('按键 ${keyLabel(vk)}');
        }
      case 'combo':
        {
          final keys = parseKeyList(n.params['comboKeys']);
          if (keys.isEmpty) {
            hooks.log('键盘操作失败：未设置组合键');
            break;
          }
          for (final vk in keys) {
            if (_stopped) break;
            await automation.keyDown(vk, extended: isExtendedKey(vk));
            _pressedKeys.add(vk);
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          await _sleep(duration);
          for (final vk in keys.reversed) {
            await automation.keyUp(vk, extended: isExtendedKey(vk));
            _pressedKeys.remove(vk);
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          hooks.log('组合键 ${formatKeyList(keys)}');
        }
      default:
        hooks.log('键盘操作失败：未知动作 "$action"');
    }
  }

  /// 释放脚本遗留的按下状态（停止/异常/结束都走这里；组合键执行中断兜底）
  Future<void> _releaseHeldInputs() async {
    if (_pressedKeys.isNotEmpty) {
      for (final vk in _pressedKeys.toList()) {
        try {
          await automation.keyUp(vk, extended: isExtendedKey(vk));
        } catch (_) {}
      }
      _pressedKeys.clear();
      hooks.log('已释放未抬起的按键');
    }
  }

  /// 可中止的等待（每 50ms 检查一次停止标志）
  Future<void> _sleep(int ms) async {
    var left = ms;
    while (left > 0 && !_stopped) {
      final step = math.min(left, 50);
      await Future<void>.delayed(Duration(milliseconds: step));
      left -= step;
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

  int _paramInt(BPNode n, String key) {
    final v = n.params[key];
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  /// 鼠标坐标：数据输入有连接且上游可解析为数值时以输入为准
  /// （属性面板对应参数此时为锁定只读），否则回退节点参数值。
  /// 输入值非数字（如误连布尔/文本）时也回退参数，避免把光标移到 (0,0)。
  Future<int> _mouseCoord(
    BlueprintScript script,
    BPNode n,
    String key,
  ) async {
    final edges = script.inEdges(n.id, key, kind: EdgeKind.data);
    if (edges.isNotEmpty) {
      final v = await _readDataPort(script, edges.first.from);
      if (v is num) return v.toInt();
      final parsed = int.tryParse('${v ?? ''}'.trim());
      if (parsed != null) return parsed;
    }
    return _paramInt(n, key);
  }

  /// 读取数据边源端口值：端口缓存优先；纯数据节点（getVar）按需读取变量。
  /// 返回 null 表示上游没有可用值（非纯数据节点且未执行过）。
  Future<Object?> _readDataPort(BlueprintScript script, PortRef ref) async {
    if (_portValues.containsKey(ref)) return _portValues[ref];
    final upstream = script.nodes[ref.nodeId];
    if (upstream != null && upstream.type == 'getVar') {
      final name = ((upstream.params['name'] as String?) ?? '').trim();
      if (name.isEmpty) {
        _warnOnce(upstream.id, '获取变量：变量名为空（按空值处理）');
        return '';
      }
      if (!vars.contains(name)) {
        _warnOnce(upstream.id, '获取变量：变量 "$name" 不存在（按空值处理）');
        return '';
      }
      return vars[name];
    }
    return null;
  }

  /// 纯数据读取的警告每个节点每次运行只提示一次，避免循环内刷屏
  void _warnOnce(String nodeId, String message) {
    if (_warnedNodes.add(nodeId)) hooks.log(message);
  }

  int _vkCode(BPNode n) {
    final v = n.params['vkCode'];
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

  String _buttonName(MouseButton b) => switch (b) {
        MouseButton.right => '右键',
        MouseButton.middle => '中键',
        _ => '左键',
      };

  /// 媒体节点区域：useRegion=false 时忽略四个角点（含已连接数据边）；
  /// 四个角点支持数据边驱动，输入非数字时回退参数；两点顺序颠倒按 min/max。
  Future<RegionParse> _resolveRegion(
    BlueprintScript script,
    BPNode n,
  ) async {
    if (n.params['useRegion'] != true) return const RegionParse.disabled();
    final l = await _mouseCoord(script, n, 'left');
    final t = await _mouseCoord(script, n, 'top');
    final r = await _mouseCoord(script, n, 'right');
    final b = await _mouseCoord(script, n, 'bottom');
    final left = l < r ? l : r;
    final top = t < b ? t : b;
    final right = l < r ? r : l;
    final bottom = t < b ? b : t;
    if (l > r || t > b) {
      hooks.log('区域坐标顺序已自动纠正：按左上/右下组成矩形');
    }
    if (right - left <= 0 || bottom - top <= 0) {
      return const RegionParse.invalid();
    }
    return RegionParse.valid(RectPx(left, top, right - left, bottom - top));
  }

  /// 拖拽终点：方向距离模式由起点 + 角度/距离计算（忽略终点输入），
  /// 起点终点模式读取终点数据边，非数字回退参数。
  Future<(int, int)> _swipeEnd(
    BlueprintScript script,
    BPNode n,
    int sx,
    int sy,
  ) async {
    final mode = (n.params['mode'] as String?) ?? 'coords';
    if (mode == 'direction') {
      final angleDeg = (n.params['angle'] as num?)?.toDouble() ?? 0;
      final dist = _paramInt(n, 'distance');
      final rad = -angleDeg * math.pi / 180; // 屏幕Y向下，角度逆时针为正
      return (
        sx + (dist * math.cos(rad)).round(),
        sy + (dist * math.sin(rad)).round(),
      );
    }
    return (
      await _mouseCoord(script, n, 'endX'),
      await _mouseCoord(script, n, 'endY'),
    );
  }

  /// 获取节点输入图像：数据边 > 上次截图 > 现场截屏。
  /// 区域裁剪按图像自身的屏幕原点换算，负坐标区域（副屏）同样有效。
  Future<RawImage?> _acquireImage(BlueprintScript script, BPNode n, {RectPx? region}) async {
    RawImage? img;
    final dataEdges = script.inEdges(n.id, 'image', kind: EdgeKind.data);
    if (dataEdges.isNotEmpty) {
      final v = await _readDataPort(script, dataEdges.first.from);
      if (v is RawImage) img = v;
    }
    img ??= _lastImage;
    img ??= await _captureNow();
    if (img == null) return null;
    if (region == null) return img;
    final (ox, oy) = _imageOrigin[img] ?? (0, 0);
    final cropped = cropImage(img, region, originX: ox, originY: oy);
    _imageOrigin[cropped] = (region.x, region.y);
    return cropped;
  }

  Future<RawImage?> _captureNow({RectPx? region}) async {
    try {
      final cap = await automation.capture(region: region);
      final img = RawImage(cap.width, cap.height, cap.bgra);
      _imageOrigin[img] = (cap.x, cap.y);
      return img;
    } on UnsupportedError {
      return null;
    }
  }

  /// 裁剪图像区域。屏幕坐标先减去图像原点换算为图像内偏移，越界部分按
  /// 图像边缘截断；负原点（副屏在主屏左侧）不会被折回图像左上角。
  @visibleForTesting
  static RawImage cropImage(
    RawImage img,
    RectPx r, {
    int originX = 0,
    int originY = 0,
  }) {
    final left = (r.x - originX).clamp(0, img.width - 1);
    final top = (r.y - originY).clamp(0, img.height - 1);
    final right = (r.x - originX + r.w).clamp(left + 1, img.width);
    final bottom = (r.y - originY + r.h).clamp(top + 1, img.height);
    final w = right - left;
    final h = bottom - top;
    final result = Uint8List(w * h * 4);
    for (var row = 0; row < h; row++) {
      final srcStart = ((top + row) * img.width + left) * 4;
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

  /// 解析输入端口值：数据边 > 常量参数（数据边可读取纯数据节点）
  Future<Object?> _resolveInput(
    BlueprintScript script,
    BPNode n,
    String port,
    String? constKey,
  ) async {
    final edges = script.inEdges(n.id, port, kind: EdgeKind.data);
    if (edges.isNotEmpty) {
      final v = await _readDataPort(script, edges.first.from);
      if (v != null) return v;
    }
    if (constKey != null) {
      return (n.params[constKey] as String?) ?? '';
    }
    return '';
  }

  /// 数值操作数：数据边优先（连接后不回退参数）；非数字返回 null。
  Future<num?> _resolveNumber(
    BlueprintScript script,
    BPNode n,
    String port,
    String paramKey,
  ) async {
    final edges = script.inEdges(n.id, port, kind: EdgeKind.data);
    if (edges.isNotEmpty) {
      final v = await _readDataPort(script, edges.first.from);
      if (v is num) return v;
      return num.tryParse('${v ?? ''}'.trim());
    }
    final p = n.params[paramKey];
    if (p is num) return p;
    return num.tryParse('${p ?? ''}'.trim());
  }

  /// OCR 失败时统一写空输出
  void _writeOcrFailure(BPNode n) {
    _writeOut(n, 'text', '');
    _writeOut(n, 'found', false);
    _writeOut(n, 'x', -1);
    _writeOut(n, 'y', -1);
  }

  String _compareOpLabel(String op) => switch (op) {
        '==' => '等于',
        '!=' => '不等于',
        '>' => '大于',
        '<' => '小于',
        '>=' => '大于等于',
        '<=' => '小于等于',
        'contains' => '包含',
        'notContains' => '不包含',
        _ => op,
      };

  String _brief(Object? v) {
    final s = '$v';
    return s.length > 32 ? '${s.substring(0, 32)}…' : s;
  }
}
