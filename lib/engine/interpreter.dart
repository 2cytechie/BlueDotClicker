import 'dart:async';
import 'dart:math' as math;

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

  /// 协作让出钩子：等待下一帧（UI 层实现，自带超时）后完成。
  /// 纯 Dart 单元测试不注入（null），引擎回退为真实定时器让步。
  final Future<void> Function()? yieldToFrame;

  const EngineHooks({
    required this.log,
    required this.onNodeChange,
    this.loadRecording = _defaultLoadRecording,
    this.yieldToFrame,
  });

  static Future<Recording?> _defaultLoadRecording(String id) async => null;
}

/// 调试探针快照：从开始节点运行到目标节点「之前」时，目标节点的运行时输入。
/// 供属性面板「节点测试」复现真实执行路径（会真实执行前置节点）。
class ProbeSnapshot {
  /// 是否真的运行到了目标节点（没有连线/不可达时为 false）
  final bool reached;

  /// 已连接的输入图像（未连接时为 null）
  final RawImage? image;

  /// 输入图像的左上角屏幕坐标（虚拟桌面坐标，可为负）
  final (int, int) imageOrigin;

  /// 需要现场截屏的区域；连接了输入图像时为 disabled（图像优先）
  final RegionParse region;

  /// 已解析的数据输入（目前含 targetText）
  final Map<String, Object?> inputs;

  /// 前置执行经过的节点数
  final int steps;

  const ProbeSnapshot({
    required this.reached,
    required this.image,
    required this.imageOrigin,
    required this.region,
    required this.inputs,
    required this.steps,
  });

  const ProbeSnapshot.miss({this.steps = 0})
      : reached = false,
        image = null,
        imageOrigin = (0, 0),
        region = const RegionParse.disabled(),
        inputs = const {};
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

  /// 图像左上角对应的屏幕坐标（虚拟桌面坐标，副屏在主屏左侧时可为负）。
  /// 截图时按实际采集原点登记，识别结果回算屏幕坐标以此为准。
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

  /// 正在执行的循环节点 id：循环体若经执行流连回同一循环节点，
  /// 视为本轮循环体结束（避免递归嵌套与「假」出口重复执行）。
  final Set<String> _activeLoops = {};

  /// 最近一次通知 UI 的高亮节点：同一节点连续执行不重复通知
  String? _notifiedNodeId;

  /// 单次协作让步至少等待的真实定时器时长。必须 > 0：零时长定时器会让
  /// 定时器堆始终有到期任务，端口的消息（帧回调、F10 轮询）永远排不上队，
  /// 这是「无限循环时界面冻结」的根因。
  static const int kMinCoopDelayMs = 1;

  /// 两次「等待帧」之间允许的最大墙钟间隔（约一帧）。间隔内只做定时器让步，
  /// 这样纯计算的循环不会被压到 60 轮/秒，而界面仍能按帧刷新。
  static const int kFrameYieldIntervalMs = 16;

  /// `_exec` 长链每执行多少步让步一次（覆盖循环体外部的长链/自环）。
  static const int kStepsPerYield = 256;

  /// 距上次等待帧的时间：用于把快速空转的循环压到约每帧一轮
  final Stopwatch _frameWatch = Stopwatch()..start();

  /// 调试探针目标节点：运行到它之前停下（null = 正常执行）
  String? _probeNodeId;
  bool _probeHit = false;
  int _probeSteps = 0;
  ProbeSnapshot? _probeSnapshot;

  bool get isRunning => _running;

  /// 调试探针：从「开始」节点沿执行流运行到 [nodeId] **之前**停下，
  /// 返回该节点此刻的运行时输入（已连接的图像 / 区域 / 数据输入）。
  /// 前置节点会真实执行（会操作鼠标键盘），可用 [stop] 中止。
  Future<ProbeSnapshot> probeBefore(BlueprintScript script, String nodeId) async {
    _probeNodeId = nodeId;
    _probeHit = false;
    _probeSteps = 0;
    _probeSnapshot = null;
    await run(script);
    return _probeSnapshot ?? ProbeSnapshot.miss(steps: _probeSteps);
  }

  void stop() => _stopped = true;

  Future<void> run(BlueprintScript script, {Map<String, Object>? initialVars}) async {
    if (_running) throw StateError('引擎已在运行中');
    _running = true;
    _stopped = false;
    vars = VariableTable(initialVars ?? script.variables);
    _portValues.clear();
    _warnedNodes.clear();
    _pressedKeys.clear();
    _activeLoops.clear();
    _notifiedNodeId = null;
    _frameWatch.reset();
    _probeHit = false;
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
        // 每轮清空端口缓存（变量表跨轮保留，可作累计器）
        _portValues.clear();
        await _exec(script, start, 'enter');
        // 还有下一轮时才需要让出：多轮执行（含 count=0 一直执行）之间若不让出，
        // 「开始→短链」会以微任务/零时长定时器连续空转，饿死帧回调与 F10 轮询。
        if (!_stopped && (forever || round < count)) await _cooperate();
      }
      if (_probeHit) {
        hooks.log('⏸ 调试：已运行到目标节点之前（前置节点 $_probeSteps 个）');
      } else {
        hooks.log(_stopped ? '■ 已停止' : '✓ 执行完成');
      }
    } on UnsupportedError catch (e) {
      hooks.log('✗ 平台不支持：${e.message}');
    } catch (e) {
      hooks.log('✗ 执行异常：$e');
    } finally {
      await _releaseHeldInputs();
      _notifyNode(null);
      _activeLoops.clear();
      _probeNodeId = null;
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
      // 长链（尤其是循环体内的自环/回边）也要周期性让出，不能只依赖循环节点：
      // 纯同步节点的 await 只会排微任务，10 万步上限兜底前界面早已冻住。
      if (steps % kStepsPerYield == 0) await _cooperate();
      final n = current;
      final inPort = currentPort;
      // 循环体经执行流连回了同一循环节点：视为本轮循环体结束，
      // 交回 _executeLoop 重新判定条件（避免递归嵌套与假出口重复执行）
      if (_activeLoops.contains(n.id)) return;
      // 调试探针：到达目标节点前停下，快照它此刻的运行时输入，不执行它本身
      if (n.id == _probeNodeId) {
        await _takeProbe(script, n);
        _probeHit = true;
        _stopped = true;
        return;
      }
      if (_probeNodeId != null) _probeSteps++;
      _notifyNode(n.id);
      final outKey = await _execute(script, n, inPort);
      if (_stopped) return;
      // 找到下一个执行节点
      final edges = script.outEdges(n.id, outKey, kind: EdgeKind.exec);
      if (edges.isEmpty) {
        // 循环体内走到死路是每轮的常态：此时清空高亮会让 UI 在
        // 「循环节点 ↔ 无」之间每轮翻转一次，白白触发重建。
        // 运行结束（run 的 finally）会统一清空。
        if (_activeLoops.isEmpty) _notifyNode(null);
        return;
      }
      final e = edges.first;
      current = script.nodes[e.to.nodeId];
      currentPort = e.to.port;
    }
  }

  /// 执行单个节点动作，返回继续执行的输出端口 key
  Future<String> _execute(BlueprintScript script, BPNode n, String inPort) async {
    final watch = Stopwatch()..start();
    try {
      return await _executeNode(script, n, inPort);
    } finally {
      // 媒体节点同步占用界面线程较久时提示一次，便于定位卡顿来源
      if (watch.elapsedMilliseconds >= 300 &&
          (n.type == 'screenshot' ||
              n.type == 'ocr' ||
              n.type == 'imageMatch')) {
        _warnOnce(
          'slow:${n.id}',
          '慢节点：${n.title} 本次同步占用界面线程 ${watch.elapsedMilliseconds}ms',
        );
      }
    }
  }

  Future<String> _executeNode(BlueprintScript script, BPNode n, String inPort) async {
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
            _writeOut(n, 'imageOut', null);
            return 'out';
          }
          // 区域坐标支持负值（副屏在主屏左侧/上方时为负）
          final shot = await _captureNow(region: region.rect);
          _portValues[PortRef(nodeId: n.id, port: 'imageOut')] = shot;
          final ok = shot != null;
          hooks.log('截图 ${ok ? '${shot.width}×${shot.height}' : '失败'}');
          return 'out';
        }

      case 'ocr':
        {
          final region = await _resolveMediaRegion(script, n);
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
          // 以图像自身原点换算中心：区域被屏幕边界钳制、或直接使用上游图像时
          // 都不会像「请求区域 + 宽/2」那样产生偏移。
          var cx = imgX + img.width ~/ 2;
          var cy = imgY + img.height ~/ 2;
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
          final region = await _resolveMediaRegion(script, n);
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
          // 模板比识别区域大时匹配器会直接判「未命中」：不打日志的话，
          // 用户只会看到循环一直跑而不知道永远不可能命中。
          if (tpl.width > img.width || tpl.height > img.height) {
            _warnOnce(
              'tplsize:${n.id}',
              '图像识别：模板 ${tpl.width}×${tpl.height} 大于识别区域 '
              '${img.width}×${img.height}，永远无法命中（请缩小模板或扩大区域）',
            );
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
  /// 循环体无需连回本节点——「真」出口后的链走到死路即视为一轮结束；
  /// 连回本节点也按「一轮结束」处理（兼容旧写法，不递归）。
  Future<String> _executeLoop(BlueprintScript script, BPNode n) async {
    final maxIterations = (n.params['maxIterations'] as num?)?.toInt() ?? 0;
    final op = (n.params['op'] as String?) ?? '==';
    var iterations = 0;
    // 数据边连续多轮读不到值时告警：首轮兜底常量是正常语义，
    // 只有数据源一直不产出（连线断开/上游不在执行链上）时才提示。
    final missing = <String, int>{};
    _activeLoops.add(n.id);
    try {
      while (!_stopped) {
        iterations++;
        if (maxIterations > 0 && iterations > maxIterations) {
          hooks.log('循环达到最大次数 $maxIterations，强制结束');
          break;
        }
        _notifyNode(n.id);
        final left = await _loopOperand(script, n, 'left', 'leftConst', missing);
        final right = await _loopOperand(script, n, 'right', 'rightConst', missing);
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
        if (bodyStart.id == n.id) {
          hooks.log('循环体指向自身，结束循环');
          break;
        }
        // 一轮循环体 = 从真出口目标开始的一次线性链式执行（走到死路为止）
        await _exec(script, bodyStart, edges.first.to.port);
        // 每轮结束必须真实让出事件循环：即使本轮没有经过任何延时节点
        // （例如延时只挂在「条件为真」分支），也要给帧回调与 F10 轮询
        // （Timer）执行机会，否则循环会以满速空转把界面彻底冻住。
        await _cooperate();
      }
    } finally {
      _activeLoops.remove(n.id);
    }
    return 'false';
  }

  /// 循环条件取值：数据边优先；数据边存在但上游尚未产出值时给出一次性告警
  /// （常见于循环体链路断开、条件数据源永远不执行），再回退常量参数。
  Future<Object?> _loopOperand(
    BlueprintScript script,
    BPNode n,
    String port,
    String constKey,
    Map<String, int> missing,
  ) async {
    final edges = script.inEdges(n.id, port, kind: EdgeKind.data);
    if (edges.isNotEmpty) {
      final v = await _readDataPort(script, edges.first.from);
      if (v != null) {
        missing[port] = 0;
        return v;
      }
      final miss = (missing[port] ?? 0) + 1;
      missing[port] = miss;
      final src = script.nodes[edges.first.from.nodeId];
      if (miss >= 3 && src != null) {
        _warnOnce(
          '${n.id}:$port',
          '循环的「$port」数据源一直未产出（上游「${src.title}」未执行或连线断开），已回退常量参数',
        );
      }
    }
    return (n.params[constKey] as String?) ?? '';
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

  /// 协作让出事件循环：所有循环/空转路径的统一出口。
  /// 至少等待一个**真实**定时器（[kMinCoopDelayMs]）；距上次等待帧超过
  /// [kFrameYieldIntervalMs] 时再等一帧，把快速空转压到约每帧一轮。
  /// 用了零时长定时器或只在微任务里 `await` 都不会让帧回调与 F10 轮询有机会执行。
  Future<void> _cooperate() async {
    final yieldFrame = hooks.yieldToFrame;
    if (yieldFrame != null &&
        _frameWatch.elapsedMilliseconds >= kFrameYieldIntervalMs) {
      _frameWatch.reset();
      await yieldFrame();
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: kMinCoopDelayMs));
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

  /// 通知 UI 当前执行节点；同一节点连续执行不重复通知，避免频繁重建编辑器
  void _notifyNode(String? id) {
    if (id == _notifiedNodeId) return;
    _notifiedNodeId = id;
    hooks.onNodeChange(id);
  }

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
    // 「仅指定区域」未勾选时通常截全屏；但只要任一区域坐标接了数据边，
    // 就视为按区域截取（属性面板会把开关显示为开并锁定），避免连线被静默忽略。
    final cornerDriven = const ['left', 'top', 'right', 'bottom']
        .any((p) => script.inEdges(n.id, p, kind: EdgeKind.data).isNotEmpty);
    if (n.params['useRegion'] != true && !cornerDriven) {
      return const RegionParse.disabled();
    }
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
  /// 获取识别节点的输入图像：**图像优先**。
  /// - 连接了「输入图像」数据边 → 直接使用该图像整体（区域设置不生效，面板中锁定）；
  /// - 未连接 → 按区域现场截屏（区域为空则截取整个虚拟桌面）。
  /// 不再隐式复用「上次截图」：区域与旧图不匹配时会被静默裁到边界，
  /// 导致识别的不是指定区域、输出坐标还整体偏移。
  Future<RawImage?> _acquireImage(BlueprintScript script, BPNode n, {RectPx? region}) async {
    final dataEdges = script.inEdges(n.id, 'image', kind: EdgeKind.data);
    if (dataEdges.isNotEmpty) {
      final v = await _readDataPort(script, dataEdges.first.from);
      if (v is RawImage) return v;
      // 数据边存在但上游未产出图像（上游截图失败等）：回退现场截屏，避免整段识别中断
    }
    return _captureNow(region: region);
  }

  /// 识别节点的有效区域：连接了输入图像时区域不生效（图像优先）。
  Future<RegionParse> _resolveMediaRegion(
    BlueprintScript script,
    BPNode n,
  ) async {
    if (script.inEdges(n.id, 'image', kind: EdgeKind.data).isNotEmpty) {
      return const RegionParse.disabled();
    }
    return _resolveRegion(script, n);
  }

  /// 采集调试探针快照：目标节点此刻的输入图像 / 区域 / 数据输入。
  Future<void> _takeProbe(BlueprintScript script, BPNode n) async {
    RawImage? image;
    final imageEdges = script.inEdges(n.id, 'image', kind: EdgeKind.data);
    if (imageEdges.isNotEmpty) {
      final v = await _readDataPort(script, imageEdges.first.from);
      if (v is RawImage) image = v;
    }
    final region = image != null
        ? const RegionParse.disabled()
        : await _resolveRegion(script, n);
    final inputs = <String, Object?>{};
    if (script.inEdges(n.id, 'targetText', kind: EdgeKind.data).isNotEmpty) {
      inputs['targetText'] =
          await _resolveInput(script, n, 'targetText', 'targetText');
    }
    _probeSnapshot = ProbeSnapshot(
      reached: true,
      image: image,
      imageOrigin: image == null ? (0, 0) : (_imageOrigin[image] ?? (0, 0)),
      region: region,
      inputs: inputs,
      steps: _probeSteps,
    );
  }

  Future<RawImage?> _captureNow({RectPx? region}) async {
    try {
      final cap = await automation.capture(region: region);
      final img = RawImage(cap.width, cap.height, cap.bgra);
      // 钳制后的实际采集原点：坐标换算必须以它为准
      _imageOrigin[img] = (cap.x, cap.y);
      return img;
    } on UnsupportedError {
      return null;
    }
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
