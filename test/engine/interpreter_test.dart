import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluedot_clicker/engine/interpreter.dart';
import 'package:bluedot_clicker/engine/variables.dart';
import 'package:bluedot_clicker/models/blueprint.dart';
import 'package:bluedot_clicker/platform/platform_automation.dart';
import 'package:bluedot_clicker/services/file_saver.dart';
import 'package:bluedot_clicker/services/recognition.dart';
import 'package:flutter_test/flutter_test.dart';

// ---- 测试替身 ----

class MockAutomation implements PlatformAutomation {
  final List<String> calls = [];
  bool supported = true;

  /// 全屏采集时图像左上角的屏幕坐标（模拟副屏在主屏左侧时可为负）
  int captureX = 0;
  int captureY = 0;

  /// 最近一次采集请求的区域（验证截图节点是否传入区域参数）
  RectPx? lastRegion;

  /// 全部采集请求的区域（验证多次截图的区域变化）
  final List<RectPx?> regions = [];

  @override
  bool get isSupported => supported;
  @override
  String? get unsupportedReason => supported ? null : 'mock 不支持';

  @override
  (int, int) get screenSize => (1920, 1080);

  void _check() {
    if (!supported) throw UnsupportedError('mock 不支持');
  }

  @override
  Future<void> moveMouse(
    int x,
    int y, {
    int durationMs = 0,
    bool Function()? cancelled,
  }) async {
    _check();
    calls.add(durationMs > 0 ? 'move($x,$y,$durationMs)' : 'move($x,$y)');
  }

  @override
  Future<void> click(int x, int y, {MouseButton button = MouseButton.left, int count = 1}) async {
    _check();
    calls.add('click($x,$y,count:$count,${button.name})');
  }

  @override
  Future<void> swipe(
    int x1,
    int y1,
    int x2,
    int y2, {
    int durationMs = 300,
    MouseButton button = MouseButton.left,
    bool Function()? cancelled,
  }) async {
    _check();
    calls.add(
      'swipe($x1,$y1->$x2,$y2${button == MouseButton.left ? '' : ',${button.name}'})',
    );
  }

  @override
  Future<void> longPress(int x, int y, {int durationMs = 800, MouseButton button = MouseButton.left}) async {
    _check();
    calls.add('longPress($x,$y,$durationMs,${button.name})');
  }

  @override
  Future<void> scrollWheel(int x, int y, {int dy = 0, int dx = 0}) async {
    _check();
    calls.add('scrollWheel($x,$y,dy:$dy,dx:$dx)');
  }

  @override
  Future<void> keyTap(int vkCode, {int durationMs = 60, bool extended = false}) async {
    _check();
    calls.add('keyTap($vkCode,$durationMs,ext:$extended)');
  }

  @override
  Future<void> keyDown(int vkCode, {bool extended = false}) async {
    _check();
    calls.add('keyDown($vkCode,ext:$extended)');
  }

  @override
  Future<void> keyUp(int vkCode, {bool extended = false}) async {
    _check();
    calls.add('keyUp($vkCode,ext:$extended)');
  }

  @override
  Future<ScreenCapture> capture({RectPx? region}) async {
    _check();
    calls.add('capture');
    lastRegion = region;
    regions.add(region);
    final w = region?.w ?? 100;
    final h = region?.h ?? 100;
    return ScreenCapture(
      w,
      h,
      Uint8List(w * h * 4),
      x: region?.x ?? captureX,
      y: region?.y ?? captureY,
    );
  }

  @override
  (int, int) cursorPos() => (0, 0);
  @override
  (bool, bool, bool) buttonsDown() => (false, false, false);
  @override
  bool isKeyDown(int vkCode) => false;
}

class MockRecognition implements RecognitionService {
  String ocrText = '测试文本';
  List<OcrWordBox> words = const [];

  /// recognizeText 收到的图像（验证「图像优先」时识别的是哪张图）
  final List<RawImage> ocrCalls = [];

  /// matchTemplate 收到的图像
  final List<RawImage> matchCalls = [];

  @override
  bool get isAvailable => true;
  @override
  Future<OcrResult> recognizeText(RawImage image, {int? regionX, int? regionY, int? regionW, int? regionH}) async {
    ocrCalls.add(image);
    return OcrResult(ocrText, words: words);
  }

  @override
  Future<MatchResult> matchTemplate(RawImage image, RawImage template, {double threshold = 0.8}) async {
    matchCalls.add(image);
    return const MatchResult(true, 50, 60, 0.95);
  }
}

/// 测试钩子集合：捕获日志/节点高亮，支持注入录制与「等待帧」钩子
class Hooks {
  Hooks({this.yieldToFrame});

  final List<String> logs = [];
  final List<String?> nodeChanges = [];
  Recording? recording;
  final Future<void> Function()? yieldToFrame;

  late final EngineHooks engineHooks = EngineHooks(
    log: logs.add,
    onNodeChange: nodeChanges.add,
    loadRecording: (id) async => id == recording?.id ? recording : null,
    yieldToFrame: yieldToFrame,
  );
}

BlueprintScript _build(List<BPNode> nodes, List<BPEdge> edges, {String name = 't'}) {
  final s = BlueprintScript(name: name);
  for (final n in nodes) {
    s.nodes[n.id] = n;
  }
  for (final e in edges) {
    s.edges[e.id] = e;
  }
  return s;
}

BPNode _node(String id, String type, [Map<String, dynamic>? params]) =>
    BPNode(id: id, type: type, x: 0, y: 0, params: params);

BPEdge _edge(String id, String from, String fromPort, String to, String toPort, {EdgeKind kind = EdgeKind.exec}) =>
    BPEdge(id: id, from: PortRef(nodeId: from, port: fromPort), to: PortRef(nodeId: to, port: toPort), kind: kind);

/// 鼠标操作节点（默认动作 click）
BPNode _mouse(String id, String action, [Map<String, dynamic>? extra]) => BPNode(
      id: id,
      type: 'mouse',
      x: 0,
      y: 0,
      params: {'action': action, ...?extra},
    );

BPNode _keyboard(String id, String action, [Map<String, dynamic>? extra]) => BPNode(
      id: id,
      type: 'keyboard',
      x: 0,
      y: 0,
      params: {'action': action, ...?extra},
    );

Future<VariableTable> _run(BlueprintScript s, {MockAutomation? auto, Hooks? hooks}) async {
  final automation = auto ?? MockAutomation();
  final h = hooks ?? Hooks();
  final engine = BlueprintInterpreter(
    automation: automation,
    recognition: MockRecognition(),
    hooks: h.engineHooks,
  );
  await engine.run(s);
  return engine.vars;
}

void main() {
  group('变量与比较', () {
    test('parseLiteral 类型推断', () {
      expect(VariableTable.parseLiteral('42'), 42);
      expect(VariableTable.parseLiteral('3.5'), 3.5);
      expect(VariableTable.parseLiteral('true'), true);
      expect(VariableTable.parseLiteral('hello'), 'hello');
    });
    test('compareValues 数值/字符串/包含', () {
      expect(compareValues(5, 3, '>'), isTrue);
      expect(compareValues('abc', 'b', 'contains'), isTrue);
      expect(compareValues('abc', 'b', 'notContains'), isFalse);
      expect(compareValues('abc', 'z', 'notContains'), isTrue);
      expect(compareValues(1, 1.0, '=='), isTrue);
      expect(compareValues(true, 1, '=='), isTrue);
      expect(compareValues('a', 'b', '<'), isTrue);
    });
  });

  group('执行引擎', () {
    test('顺序执行：开始→延时→单击', () async {
      final s = _build([
        _node('a', 'start'),
        _node('b', 'delay', {'ms': 1}),
        _mouse('c', 'click', {'x': 10, 'y': 20, 'button': 'left'}),
      ], [
        _edge('e1', 'a', 'out', 'b', 'in'),
        _edge('e2', 'b', 'out', 'c', 'in'),
      ]);
      final auto = MockAutomation();
      final vars = await _run(s, auto: auto);
      expect(auto.calls, contains('click(10,20,count:1,left)'));
      expect(vars.snapshot(), isEmpty);
    });

    test('开始节点执行次数：整条链重复执行', () async {
      final s = _build([
        _node('a', 'start', {'count': 3}),
        _mouse('c', 'click', {'x': 1, 'y': 2, 'button': 'left'}),
      ], [
        _edge('e1', 'a', 'out', 'c', 'in'),
      ]);
      final auto = MockAutomation();
      await _run(s, auto: auto);
      expect(auto.calls.where((c) => c == 'click(1,2,count:1,left)').length, 3);
    });

    test('鼠标坐标由 X/Y 数据输入决定（覆盖参数值）', () async {
      final s = _build([
        _node('a', 'start'),
        _node('sx', 'setVar', {'name': 'px', 'const': '777'}),
        _node('sy', 'setVar', {'name': 'py', 'const': '888'}),
        _mouse('m', 'click', {'x': 10, 'y': 20}),
      ], [
        _edge('e1', 'a', 'out', 'sx', 'in'),
        _edge('e2', 'sx', 'out', 'sy', 'in'),
        _edge('e3', 'sy', 'out', 'm', 'in'),
        _edge('d1', 'sx', 'valueOut', 'm', 'x', kind: EdgeKind.data),
        _edge('d2', 'sy', 'valueOut', 'm', 'y', kind: EdgeKind.data),
      ]);
      final auto = MockAutomation();
      await _run(s, auto: auto);
      expect(
        auto.calls,
        contains('click(777,888,count:1,left)'),
        reason: 'X/Y 输入已连接时以输入值为准，参数坐标被忽略',
      );
    });

    test('X/Y 输入未连接时仍使用参数坐标', () async {
      final s = _build([
        _node('a', 'start'),
        _mouse('m', 'click', {'x': 10, 'y': 20}),
      ], [
        _edge('e1', 'a', 'out', 'm', 'in'),
      ]);
      final auto = MockAutomation();
      await _run(s, auto: auto);
      expect(auto.calls, contains('click(10,20,count:1,left)'));
    });

    test('鼠标动作：双击/滚轮/移动/长按', () async {
      final s = _build([
        _node('a', 'start'),
        _mouse('d', 'doubleClick', {'x': 5, 'y': 6, 'button': 'middle'}),
        _mouse('sc', 'scroll', {'x': 7, 'y': 8, 'dx': 0, 'dy': 240}),
        _mouse('mv', 'move', {'x': 9, 'y': 10}),
        _mouse('lp', 'longPress', {'x': 13, 'y': 14, 'holdMs': 1, 'button': 'middle'}),
      ], [
        _edge('e1', 'a', 'out', 'd', 'in'),
        _edge('e2', 'd', 'out', 'sc', 'in'),
        _edge('e3', 'sc', 'out', 'mv', 'in'),
        _edge('e4', 'mv', 'out', 'lp', 'in'),
      ]);
      final auto = MockAutomation();
      await _run(s, auto: auto);
      expect(auto.calls, contains('click(5,6,count:2,middle)'));
      expect(auto.calls, contains('scrollWheel(7,8,dy:240,dx:0)'));
      expect(auto.calls, contains('move(9,10)'));
      expect(auto.calls, contains('longPress(13,14,1,middle)'));
    });

    test('键盘动作：按键/组合键', () async {
      final s = _build([
        _node('a', 'start'),
        _keyboard('t', 'tap', {'vkCode': 0x41}), // A
        _keyboard('cb', 'combo', {'comboKeys': [0x11, 0x43], 'durationMs': 1}), // Ctrl+C
      ], [
        _edge('e1', 'a', 'out', 't', 'in'),
        _edge('e2', 't', 'out', 'cb', 'in'),
      ]);
      final auto = MockAutomation();
      await _run(s, auto: auto);
      expect(auto.calls, contains('keyTap(65,60,ext:false)'));
      // 组合键：顺序按下、逆序抬起
      final comboDown = auto.calls.indexOf('keyDown(17,ext:false)');
      final comboCDown = auto.calls.indexOf('keyDown(67,ext:false)');
      final cUp = auto.calls.indexOf('keyUp(67,ext:false)');
      final ctrlUp = auto.calls.indexOf('keyUp(17,ext:false)');
      expect(comboDown, greaterThanOrEqualTo(0));
      expect(comboCDown, greaterThan(comboDown));
      expect(cUp, greaterThan(comboCDown));
      expect(ctrlUp, greaterThan(cUp));
    });

    test('键盘动作未设置按键时记日志并跳过，不抛异常', () async {
      final s = _build([
        _node('a', 'start'),
        _keyboard('k', 'tap', {'vkCode': 0}),
        _keyboard('c', 'combo', {'comboKeys': <int>[]}),
      ], [
        _edge('e1', 'a', 'out', 'k', 'in'),
        _edge('e2', 'k', 'out', 'c', 'in'),
      ]);
      final hooks = Hooks();
      await _run(s, hooks: hooks);
      final logs = hooks.logs.join('\n');
      expect(logs, contains('未设置按键'));
      expect(logs, contains('未设置组合键'));
    });

    test('停止时已按下的组合键被释放，不残留按键', () async {
      final s = _build([
        _node('a', 'start'),
        // 组合键按住期间（durationMs 内）被 stop，已按下的键必须被释放
        _keyboard('cb', 'combo', {'comboKeys': [0x41, 0x42], 'durationMs': 5000}),
        _node('d', 'delay', {'ms': 5000}),
      ], [
        _edge('e1', 'a', 'out', 'cb', 'in'),
        _edge('e2', 'cb', 'out', 'd', 'in'),
      ]);
      final auto = MockAutomation();
      final hooks = Hooks();
      final engine = BlueprintInterpreter(
        automation: auto,
        recognition: MockRecognition(),
        hooks: hooks.engineHooks,
      );
      Future<void>.delayed(const Duration(milliseconds: 80), engine.stop);
      await engine.run(s);
      expect(auto.calls, contains('keyUp(65,ext:false)'));
      expect(auto.calls, contains('keyUp(66,ext:false)'));
    });

    test('条件分支走向 true/false 出口', () async {
      // found == true → 单击；否则长按
      final s = BlueprintScript(name: 'cond')..variables['found'] = true;
      s.nodes['a'] = _node('a', 'start');
      s.nodes['gv'] = _node('gv', 'getVar', {'name': 'found'});
      s.nodes['cond'] = _node('cond', 'condition', {'op': '==', 'rightConst': 'true'});
      s.nodes['yes'] = _mouse('yes', 'click', {'x': 1, 'y': 1, 'button': 'left'});
      s.nodes['no'] = _mouse('no', 'longPress', {'x': 2, 'y': 2, 'holdMs': 1});
      s.edges['e1'] = _edge('e1', 'a', 'out', 'cond', 'in');
      s.edges['e2'] = _edge('e2', 'cond', 'true', 'yes', 'in');
      s.edges['e3'] = _edge('e3', 'cond', 'false', 'no', 'in');
      s.edges['d1'] = _edge('d1', 'gv', 'value', 'cond', 'left', kind: EdgeKind.data);

      final auto = MockAutomation();
      await _run(s, auto: auto);
      expect(auto.calls, contains('click(1,1,count:1,left)'));
      expect(auto.calls.any((c) => c.startsWith('longPress')), isFalse);

      // 改变量为 false 走另一分支
      s.variables['found'] = false;
      final auto2 = MockAutomation();
      await _run(s, auto: auto2);
      expect(auto2.calls.any((c) => c.startsWith('longPress')), isTrue);
    });

    test('条件循环：真进入循环体，达到安全阀后强制走假', () async {
      final s = _build([
        _node('a', 'start'),
        _node('loop', 'loop', {
          'op': '==',
          'leftConst': '1',
          'rightConst': '1',
          'maxIterations': 2,
        }),
        _mouse('body', 'click', {'x': 1, 'y': 1}),
        _mouse('done', 'longPress', {'x': 2, 'y': 2, 'holdMs': 1}),
      ], [
        _edge('e1', 'a', 'out', 'loop', 'in'),
        _edge('e2', 'loop', 'true', 'body', 'in'),
        _edge('e4', 'loop', 'false', 'done', 'in'),
      ]);
      final auto = MockAutomation();
      final hooks = Hooks();
      await _run(s, auto: auto, hooks: hooks);
      expect(
        auto.calls.where((c) => c.startsWith('click')).length,
        2,
        reason: 'maxIterations=2 时循环体执行两次',
      );
      expect(auto.calls.any((c) => c.startsWith('longPress')), isTrue,
          reason: '达到安全阀后走假出口');
      expect(hooks.logs.join(), contains('达到最大次数 2，强制结束'));
    });

    test('条件循环：首轮常量兜底，数据边更新后正确退出', () async {
      final s = _build([
        _node('a', 'start'),
        _node('set1', 'setVar', {'name': 'count', 'const': '0'}),
        _node('loop', 'loop', {
          'op': '<',
          'leftConst': '0',
          'rightConst': '3',
          'maxIterations': 10,
        }),
        _node('get', 'getVar', {'name': 'count'}),
        _node('add', 'add', {'a': 0, 'b': 1}),
        _node('set2', 'setVar', {'name': 'count', 'const': ''}),
        _mouse('done', 'click', {'x': 3, 'y': 3}),
      ], [
        _edge('e1', 'a', 'out', 'set1', 'in'),
        _edge('e2', 'set1', 'out', 'loop', 'in'),
        _edge('e3', 'loop', 'true', 'add', 'in'),
        _edge('e4', 'add', 'out', 'set2', 'in'),
        _edge('e6', 'loop', 'false', 'done', 'in'),
        _edge('d1', 'get', 'value', 'add', 'a', kind: EdgeKind.data),
        _edge('d2', 'add', 'result', 'set2', 'value', kind: EdgeKind.data),
        _edge('d3', 'set2', 'valueOut', 'loop', 'left', kind: EdgeKind.data),
      ]);
      final auto = MockAutomation();
      final vars = await _run(s, auto: auto);
      expect(vars['count'], 3, reason: '首轮用常量 0，之后读数据边，累计到 3');
      expect(auto.calls, contains('click(3,3,count:1,left)'), reason: '条件为假后走假出口');
    });

    test('循环自动重复执行真出口链（循环体无需连回 in）', () async {
      final s = _build([
        _node('a', 'start'),
        _node('set1', 'setVar', {'name': 'count', 'const': '0'}),
        _node('loop', 'loop', {
          'op': '<',
          'leftConst': '0',
          'rightConst': '3',
          'maxIterations': 10,
        }),
        _node('get', 'getVar', {'name': 'count'}),
        _node('add', 'add', {'a': 0, 'b': 1}),
        _node('set2', 'setVar', {'name': 'count', 'const': ''}),
        _node('done', 'setVar', {'name': 'done', 'const': '完成'}),
      ], [
        _edge('e1', 'a', 'out', 'set1', 'in'),
        _edge('e2', 'set1', 'out', 'loop', 'in'),
        _edge('e3', 'loop', 'true', 'add', 'in'),
        _edge('e4', 'add', 'out', 'set2', 'in'),
        // 循环体链尾为死路（set2 无出边），循环应自动重判条件继续下一轮
        _edge('e6', 'loop', 'false', 'done', 'in'),
        _edge('d1', 'get', 'value', 'add', 'a', kind: EdgeKind.data),
        _edge('d2', 'add', 'result', 'set2', 'value', kind: EdgeKind.data),
        _edge('d3', 'set2', 'valueOut', 'loop', 'left', kind: EdgeKind.data),
      ]);
      final hooks = Hooks();
      final vars = await _run(s, hooks: hooks);
      expect(vars['count'], 3, reason: '真出口链自动循环 3 轮');
      expect(vars['done'], '完成', reason: '条件为假后走假出口执行一次');
      final loopLogs =
          hooks.logs.where((l) => l.startsWith('[循环]')).toList();
      expect(loopLogs.length, 4,
          reason: '每轮条件值不同（0/1/2/3），按「值变化时记录」全部保留');
      expect(loopLogs.first, contains('真'));
      expect(loopLogs.last, contains('假'));
    });

    test('条件成立但真出口未连接：打日志并走假出口，不空转', () async {
      final s = _build([
        _node('a', 'start'),
        _node('loop', 'loop', {
          'op': '==',
          'leftConst': '1',
          'rightConst': '1',
          'maxIterations': 0,
        }),
        _mouse('done', 'click', {'x': 3, 'y': 3}),
      ], [
        _edge('e1', 'a', 'out', 'loop', 'in'),
        _edge('e4', 'loop', 'false', 'done', 'in'),
      ]);
      final auto = MockAutomation();
      final hooks = Hooks();
      await _run(s, auto: auto, hooks: hooks);
      expect(hooks.logs.join(), contains('「真」出口未连接'));
      expect(
        auto.calls.where((c) => c.startsWith('click')).length,
        1,
        reason: '假出口只执行一次，运行正常结束',
      );
    });

    test('设置变量并在条件中使用', () async {
      final s = _build([
        _node('a', 'start'),
        _node('set', 'setVar', {'name': 'score', 'const': '88'}),
        _node('cond', 'condition', {'op': '>', 'rightConst': '60'}),
        _mouse('ok', 'click', {'x': 9, 'y': 9, 'button': 'left'}),
      ], [
        _edge('e1', 'a', 'out', 'set', 'in'),
        _edge('e2', 'set', 'out', 'cond', 'in'),
        _edge('e3', 'cond', 'true', 'ok', 'in'),
        _edge('d1', 'set', 'valueOut', 'cond', 'left', kind: EdgeKind.data),
      ]);
      final vars = await _run(s);
      expect(vars['score'], 88);
    });

    test('OCR 不再写变量：识别文本只从 text 输出消费', () async {
      final s = _build([
        _node('a', 'start'),
        _node('ocr', 'ocr', {'useRegion': false}),
        _node('copy', 'setVar', {'name': 'copyOf', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'ocr', 'in'),
        _edge('e2', 'ocr', 'out', 'copy', 'in'),
        _edge('d1', 'ocr', 'text', 'copy', 'value', kind: EdgeKind.data),
      ]);
      s.variables['ocrText'] = 'keep';
      final vars = await _run(s);
      expect(vars['ocrText'], 'keep', reason: 'OCR 不再修改同名变量');
      expect(vars['copyOf'], '测试文本');
    });

    test('获取变量：纯数据节点，无执行流也能读取当前值', () async {
      final s = _build([
        _node('a', 'start'),
        _node('set', 'setVar', {'name': 'count', 'const': '7'}),
        _node('get', 'getVar', {'name': 'count'}),
        _node('copy', 'setVar', {'name': 'copyOf', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'set', 'in'),
        _edge('e2', 'set', 'out', 'copy', 'in'),
        _edge('d1', 'get', 'value', 'copy', 'value', kind: EdgeKind.data),
      ]);
      final vars = await _run(s);
      expect(vars['copyOf'], 7, reason: 'getVar 未接入执行流，消费时惰性读取变量');
    });

    test('获取变量：变量未初始化时输出空字符串并只警告一次', () async {
      final s = _build([
        _node('a', 'start'),
        _node('get', 'getVar', {'name': 'neverSet'}),
        _node('copy', 'setVar', {'name': 'copyOf', 'const': ''}),
        _node('copy2', 'setVar', {'name': 'copyOf2', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'copy', 'in'),
        _edge('e2', 'copy', 'out', 'copy2', 'in'),
        _edge('d1', 'get', 'value', 'copy', 'value', kind: EdgeKind.data),
        _edge('d2', 'get', 'value', 'copy2', 'value', kind: EdgeKind.data),
      ]);
      final hooks = Hooks();
      final vars = await _run(s, hooks: hooks);
      expect(vars['copyOf'], '');
      expect(vars['copyOf2'], '');
      expect(
        hooks.logs.where((l) => l.contains('不存在')).length,
        1,
        reason: '同一节点每次运行只警告一次',
      );
    });

    test('数据保存：文本输入保存为 .txt（含识别文本）并透传文本输出', () async {
      final tmp = await Directory.systemTemp.createTemp('bpc_save_test');
      addTearDown(() async {
        SaveFileService.overrideDir(Directory.systemTemp.parent);
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      SaveFileService.overrideDir(tmp);
      final s = _build([
        _node('a', 'start'),
        _node('o', 'ocr', {'useRegion': false}),
        _node('save', 'saveData', {'fileName': 'note'}),
        _node('copy', 'setVar', {'name': 'savedText', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'o', 'in'),
        _edge('e2', 'o', 'out', 'save', 'in'),
        _edge('e3', 'save', 'out', 'copy', 'in'),
        _edge('d1', 'o', 'text', 'save', 'text', kind: EdgeKind.data),
        _edge('d2', 'save', 'textOut', 'copy', 'value', kind: EdgeKind.data),
      ]);
      final vars = await _run(s);
      // 文本经「文本」透传输出继续流向下游
      expect(vars['savedText'], '测试文本');
      final saved = File('${tmp.path}/save/note.txt');
      expect(saved.existsSync(), isTrue, reason: '文件应实际落盘');
      expect(await saved.readAsString(), '测试文本');
      // 再跑一次 → 同名加序号，不覆盖
      await _run(_build([
        _node('a', 'start'),
        _node('o', 'ocr', {'useRegion': false}),
        _node('save', 'saveData', {'fileName': 'note'}),
      ], [
        _edge('e1', 'a', 'out', 'o', 'in'),
        _edge('e2', 'o', 'out', 'save', 'in'),
        _edge('d1', 'o', 'text', 'save', 'text', kind: EdgeKind.data),
      ]));
      final again = File('${tmp.path}/save/note-1.txt');
      expect(again.existsSync(), isTrue, reason: '同名文件应自动加序号');
      expect(await again.readAsString(), '测试文本');
      expect(saved.existsSync(), isTrue, reason: '原文件不被覆盖');
    });

    test('数据保存：图像输入保存为 .png 并透传图像输出', () async {
      final tmp = await Directory.systemTemp.createTemp('bpc_save_img_test');
      addTearDown(() async {
        SaveFileService.overrideDir(Directory.systemTemp.parent);
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      SaveFileService.overrideDir(tmp);
      final s = _build([
        _node('a', 'start'),
        _node('shot', 'screenshot', {'useRegion': false}),
        _node('save', 'saveData', {'fileName': 'shot'}),
        _node('copy', 'setVar', {'name': 'img', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'shot', 'in'),
        _edge('e2', 'shot', 'out', 'save', 'in'),
        _edge('e3', 'save', 'out', 'copy', 'in'),
        _edge('d1', 'shot', 'imageOut', 'save', 'image', kind: EdgeKind.data),
        _edge('d2', 'save', 'imageOut', 'copy', 'value', kind: EdgeKind.data),
      ]);
      final vars = await _run(s);
      expect(vars['img'], isA<RawImage>(), reason: '图像经「图像」透传输出继续流向下游');
      final f = File('${tmp.path}/save/shot.png');
      expect(f.existsSync(), isTrue, reason: '截图应保存为 png');
      final bytes = await f.readAsBytes();
      // PNG 魔数：89 50 4E 47
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('数据保存：未连接文本/图像输入时不生成文件、不透传', () async {
      final tmp = await Directory.systemTemp.createTemp('bpc_save_none_test');
      addTearDown(() async {
        SaveFileService.overrideDir(Directory.systemTemp.parent);
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      SaveFileService.overrideDir(tmp);
      final s = _build([
        _node('a', 'start'),
        _node('save', 'saveData', {'fileName': 'nothing'}),
        _node('copy', 'setVar', {'name': 'copyOf', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'save', 'in'),
        _edge('e2', 'save', 'out', 'copy', 'in'),
        _edge('d1', 'save', 'textOut', 'copy', 'value', kind: EdgeKind.data),
      ]);
      final vars = await _run(s);
      expect(vars['copyOf'], '', reason: '无输入时透传输出无值，setVar 回退常量');
      expect(Directory('${tmp.path}/save').existsSync(), isFalse,
          reason: '未保存任何文件时不应创建 save 目录');
    });

    test('OCR 目标文本由数据输入决定（覆盖参数）', () async {
      final recognition = MockRecognition()
        ..ocrText = '点击 开始 游戏'
        ..words = const [
          OcrWordBox('点击', 0, 0, 20, 10),
          OcrWordBox('开始', 30, 0, 20, 10),
          OcrWordBox('游戏', 60, 0, 20, 10),
        ];
      final s = _build([
        _node('a', 'start'),
        _node('src', 'setVar', {'name': 'target', 'const': '开始'}),
        _node('o', 'ocr', {'useRegion': false, 'targetText': '参数目标'}),
        _node('copy', 'setVar', {'name': 'hit', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'src', 'in'),
        _edge('e2', 'src', 'out', 'o', 'in'),
        _edge('e3', 'o', 'out', 'copy', 'in'),
        _edge('d1', 'src', 'valueOut', 'o', 'targetText', kind: EdgeKind.data),
        _edge('d2', 'o', 'found', 'copy', 'value', kind: EdgeKind.data),
      ]);
      final hooks = Hooks();
      final engine = BlueprintInterpreter(
        automation: MockAutomation(),
        recognition: recognition,
        hooks: hooks.engineHooks,
      );
      await engine.run(s);
      expect(engine.vars['hit'], true, reason: '输入连接的目标文本优先于参数');
    });

    test('OCR 是否命中输出（目标为空时识别文本非空为 true）', () async {
      final s = _build([
        _node('a', 'start'),
        _node('o', 'ocr', {'useRegion': false}),
        _node('copy', 'setVar', {'name': 'hit', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'o', 'in'),
        _edge('e2', 'o', 'out', 'copy', 'in'),
        _edge('d1', 'o', 'found', 'copy', 'value', kind: EdgeKind.data),
      ]);
      final vars = await _run(s);
      expect(vars['hit'], true);
    });

    test('OCR 坐标输出为识别区域中心点（区域坐标X + 区域宽/2）', () async {
      final s = _build([
        _node('a', 'start'),
        _node('o', 'ocr', {
          'useRegion': true,
          'left': 100,
          'top': 200,
          'right': 400,
          'bottom': 600,
        }),
        _node('cx', 'setVar', {'name': 'cx', 'const': ''}),
        _node('cy', 'setVar', {'name': 'cy', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'o', 'in'),
        _edge('e2', 'o', 'out', 'cx', 'in'),
        _edge('e3', 'cx', 'out', 'cy', 'in'),
        _edge('d1', 'o', 'x', 'cx', 'value', kind: EdgeKind.data),
        _edge('d2', 'o', 'y', 'cy', 'value', kind: EdgeKind.data),
      ]);
      final vars = await _run(s);
      expect(vars['cx'], 100 + 300 ~/ 2, reason: '区域坐标X + 区域宽/2');
      expect(vars['cy'], 200 + 400 ~/ 2, reason: '区域坐标Y + 区域高/2');
    });

    test('拖拽参数解析（方向模式）与坐标模式', () async {
      final s = _build([
        _node('a', 'start'),
        _mouse('sw', 'swipe', {
          'mode': 'direction',
          'x': 100,
          'y': 100,
          'angle': 0,
          'distance': 50,
          'durationMs': 1,
        }),
        _mouse('sw2', 'swipe', {
          'mode': 'coords',
          'x': 1,
          'y': 2,
          'endX': 3,
          'endY': 4,
          'durationMs': 1,
        }),
      ], [
        _edge('e1', 'a', 'out', 'sw', 'in'),
        _edge('e2', 'sw', 'out', 'sw2', 'in'),
      ]);
      final auto = MockAutomation();
      await _run(s, auto: auto);
      expect(auto.calls, contains('swipe(100,100->150,100)'));
      expect(auto.calls, contains('swipe(1,2->3,4)'));
    });

    test('拖拽支持鼠标键与起终点数据输入（起点复用 x/y）', () async {
      final s = _build([
        _node('a', 'start'),
        _node('sx', 'setVar', {'name': 'sx', 'const': '10'}),
        _node('sy', 'setVar', {'name': 'sy', 'const': '20'}),
        _node('ex', 'setVar', {'name': 'ex', 'const': '30'}),
        _node('ey', 'setVar', {'name': 'ey', 'const': '40'}),
        _mouse('sw', 'swipe', {
          'mode': 'coords',
          'x': 1,
          'y': 2,
          'endX': 3,
          'endY': 4,
          'durationMs': 1,
          'button': 'right',
        }),
      ], [
        _edge('e1', 'a', 'out', 'sx', 'in'),
        _edge('e2', 'sx', 'out', 'sy', 'in'),
        _edge('e3', 'sy', 'out', 'ex', 'in'),
        _edge('e4', 'ex', 'out', 'ey', 'in'),
        _edge('e5', 'ey', 'out', 'sw', 'in'),
        // 拖拽起点复用 x/y 数据输入
        _edge('d1', 'sx', 'valueOut', 'sw', 'x', kind: EdgeKind.data),
        _edge('d2', 'sy', 'valueOut', 'sw', 'y', kind: EdgeKind.data),
        _edge('d3', 'ex', 'valueOut', 'sw', 'endX', kind: EdgeKind.data),
        _edge('d4', 'ey', 'valueOut', 'sw', 'endY', kind: EdgeKind.data),
      ]);
      final auto = MockAutomation();
      final hooks = Hooks();
      await _run(s, auto: auto, hooks: hooks);
      expect(auto.calls, contains('swipe(10,20->30,40,right)'));
      expect(hooks.logs.join(), contains('拖拽 (10,20) → (30,40) 1ms 右键'));
    });

    test('拖拽方向模式忽略终点数据输入', () async {
      final s = _build([
        _node('a', 'start'),
        _node('ex', 'setVar', {'name': 'ex', 'const': '999'}),
        _mouse('sw', 'swipe', {
          'mode': 'direction',
          'x': 100,
          'y': 100,
          'angle': 0,
          'distance': 50,
          'durationMs': 1,
        }),
      ], [
        _edge('e1', 'a', 'out', 'ex', 'in'),
        _edge('e2', 'ex', 'out', 'sw', 'in'),
        _edge('d1', 'ex', 'valueOut', 'sw', 'endX', kind: EdgeKind.data),
      ]);
      final auto = MockAutomation();
      await _run(s, auto: auto);
      expect(auto.calls, contains('swipe(100,100->150,100)'));
    });

    test('移动到：moveDurationMs=0 瞬移，>0 带时长分步移动', () async {
      final s = _build([
        _node('a', 'start'),
        _mouse('m1', 'move', {'x': 9, 'y': 10}),
        _mouse('m2', 'move', {'x': 11, 'y': 12, 'moveDurationMs': 300}),
      ], [
        _edge('e1', 'a', 'out', 'm1', 'in'),
        _edge('e2', 'm1', 'out', 'm2', 'in'),
      ]);
      final auto = MockAutomation();
      await _run(s, auto: auto);
      expect(auto.calls, contains('move(9,10)'));
      expect(auto.calls, contains('move(11,12,300)'));
    });

    test('强制停止：恒真条件循环可被 stop 终止', () async {
      final s = _build([
        _node('a', 'start'),
        _node('loop', 'loop', {
          'op': '==',
          'leftConst': '1',
          'rightConst': '1',
          'maxIterations': 0,
        }),
        _node('d', 'delay', {'ms': 1}),
      ], [
        _edge('e1', 'a', 'out', 'loop', 'in'),
        _edge('e2', 'loop', 'true', 'd', 'in'),
      ]);
      final hooks = Hooks();
      final automation = MockAutomation();
      final engine = BlueprintInterpreter(
        automation: automation,
        recognition: MockRecognition(),
        hooks: hooks.engineHooks,
      );
      Future<void>.delayed(const Duration(milliseconds: 120), engine.stop);
      await engine.run(s);
      expect(engine.isRunning, isFalse);
    });

    test('循环体无延时时事件循环不被饿死，stop 仍可终止', () async {
      final s = _build([
        _node('a', 'start'),
        _node('loop', 'loop', {
          'op': '==',
          'leftConst': '1',
          'rightConst': '1',
          'maxIterations': 0,
        }),
        // 循环体只有同步节点、没有延时/IO：若不让出事件循环，下面的定时器永不触发
        _node('inc', 'setVar', {'name': 'n', 'const': '1'}),
      ], [
        _edge('e1', 'a', 'out', 'loop', 'in'),
        _edge('e2', 'loop', 'true', 'inc', 'in'),
      ]);
      final hooks = Hooks();
      final engine = BlueprintInterpreter(
        automation: MockAutomation(),
        recognition: MockRecognition(),
        hooks: hooks.engineHooks,
      );
      Future<void>.delayed(const Duration(milliseconds: 120), engine.stop);
      await engine.run(s);
      expect(engine.isRunning, isFalse);
      expect(hooks.logs.join(), contains('■ 已停止'));
    });

    test('循环体连回 in：每轮只执行一次，假出口只执行一次', () async {
      final s = _build([
        _node('a', 'start'),
        _node('set0', 'setVar', {'name': 'count', 'const': '0'}),
        _node('exit0', 'setVar', {'name': 'exitCount', 'const': '0'}),
        _node('loop', 'loop', {
          'op': '<',
          'leftConst': '0',
          'rightConst': '3',
          'maxIterations': 20,
        }),
        _node('get', 'getVar', {'name': 'count'}),
        _node('add', 'add', {'a': 0, 'b': 1}),
        _node('set2', 'setVar', {'name': 'count', 'const': ''}),
        _node('getExit', 'getVar', {'name': 'exitCount'}),
        _node('addExit', 'add', {'a': 0, 'b': 1}),
        _node('setExit', 'setVar', {'name': 'exitCount', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'set0', 'in'),
        _edge('e2', 'set0', 'out', 'exit0', 'in'),
        _edge('e3', 'exit0', 'out', 'loop', 'in'),
        _edge('e4', 'loop', 'true', 'add', 'in'),
        _edge('e5', 'add', 'out', 'set2', 'in'),
        // 旧写法：循环体链尾连回循环输入口
        _edge('e6', 'set2', 'out', 'loop', 'in'),
        _edge('e7', 'loop', 'false', 'addExit', 'in'),
        _edge('e8', 'addExit', 'out', 'setExit', 'in'),
        _edge('d1', 'get', 'value', 'add', 'a', kind: EdgeKind.data),
        _edge('d2', 'add', 'result', 'set2', 'value', kind: EdgeKind.data),
        _edge('d3', 'set2', 'valueOut', 'loop', 'left', kind: EdgeKind.data),
        _edge('d4', 'getExit', 'value', 'addExit', 'a', kind: EdgeKind.data),
        _edge('d5', 'addExit', 'result', 'setExit', 'value', kind: EdgeKind.data),
      ]);
      final vars = await _run(s);
      expect(vars['count'], 3, reason: '回边只结束本轮循环体，不应递归叠加轮次');
      expect(
        vars['exitCount'],
        1,
        reason: '假出口只执行一次，不能随嵌套层数重复执行',
      );
    });

    test('循环条件数据源一直未产出：告警一次并回退常量', () async {
      final s = _build([
        _node('a', 'start'),
        // 未接入执行流的数据节点：其输出端口永远没有缓存值
        _node('src', 'setVar', {'name': 'flag', 'const': 'x'}),
        _node('loop', 'loop', {
          'op': 'notContains',
          'leftConst': 'abc',
          'rightConst': 'zzz',
          'maxIterations': 3,
        }),
        _node('body', 'setVar', {'name': 'tick', 'const': '1'}),
        _node('done', 'setVar', {'name': 'done', 'const': 'yes'}),
      ], [
        _edge('e1', 'a', 'out', 'loop', 'in'),
        _edge('e2', 'loop', 'true', 'body', 'in'),
        _edge('e3', 'loop', 'false', 'done', 'in'),
        _edge('d1', 'src', 'valueOut', 'loop', 'left', kind: EdgeKind.data),
      ]);
      final hooks = Hooks();
      final vars = await _run(s, hooks: hooks);
      final warns =
          hooks.logs.where((l) => l.contains('数据源一直未产出')).toList();
      expect(warns.length, 1, reason: '同一端口每次运行只告警一次');
      expect(vars['tick'], 1, reason: '回退常量后条件成立，循环体正常执行');
      expect(vars['done'], 'yes', reason: '达到安全阀后走假出口');
    });

    test('循环体无延时：每轮之间真实让出事件循环（定时器持续触发）', () async {
      final s = _build([
        _node('a', 'start'),
        _node('loop', 'loop', {
          'op': '==',
          'leftConst': '1',
          'rightConst': '1',
          'maxIterations': 30,
        }),
        _node('inc', 'setVar', {'name': 'n', 'const': '1'}),
      ], [
        _edge('e1', 'a', 'out', 'loop', 'in'),
        _edge('e2', 'loop', 'true', 'inc', 'in'),
      ]);
      var ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
        ticks++;
      });
      addTearDown(timer.cancel);

      await _run(s);
      // 30 轮、每轮至少 1ms 真实定时器让步：2ms 定时器必然能多次执行。
      // 修复前零时长定时器会让事件队列永远排不到期，ticks 恒为 0。
      expect(
        ticks,
        greaterThan(3),
        reason: '循环期间事件任务必须有机会执行，否则界面会冻结、F10 失效',
      );
    });

    test('循环间隙调用 yieldToFrame 钩子（UI 层按帧让出）', () async {
      final s = _build([
        _node('a', 'start'),
        _node('loop', 'loop', {
          'op': '==',
          'leftConst': '1',
          'rightConst': '1',
          'maxIterations': 60,
        }),
        _node('inc', 'setVar', {'name': 'n', 'const': '1'}),
      ], [
        _edge('e1', 'a', 'out', 'loop', 'in'),
        _edge('e2', 'loop', 'true', 'inc', 'in'),
      ]);
      var frames = 0;
      final hooks = Hooks(
        yieldToFrame: () async {
          frames++;
        },
      );
      await _run(s, hooks: hooks);
      expect(
        frames,
        greaterThanOrEqualTo(2),
        reason: '60 轮无延时循环跨越多帧间隔，必须等待真实帧而不是满速空转',
      );
    });

    test('快速空转的循环可以及时停止', () async {
      final s = _build([
        _node('a', 'start'),
        _node('loop', 'loop', {
          'op': '==',
          'leftConst': '1',
          'rightConst': '1',
          'maxIterations': 0,
        }),
        _node('inc', 'setVar', {'name': 'n', 'const': '1'}),
      ], [
        _edge('e1', 'a', 'out', 'loop', 'in'),
        _edge('e2', 'loop', 'true', 'inc', 'in'),
      ]);
      final engine = BlueprintInterpreter(
        automation: MockAutomation(),
        recognition: MockRecognition(),
        hooks: Hooks().engineHooks,
      );
      final sw = Stopwatch()..start();
      Future<void>.delayed(const Duration(milliseconds: 30), engine.stop);
      await engine.run(s);
      sw.stop();
      expect(engine.isRunning, isFalse);
      expect(
        sw.elapsedMilliseconds,
        lessThan(1000),
        reason: '停止请求应在下一轮让步时立即生效，不能被空转拖住',
      );
    });

    test('循环体内死路不再每轮清空节点高亮', () async {
      final s = _build([
        _node('a', 'start'),
        _node('loop', 'loop', {
          'op': '==',
          'leftConst': '1',
          'rightConst': '1',
          'maxIterations': 3,
        }),
        _node('body', 'setVar', {'name': 'n', 'const': '1'}),
      ], [
        _edge('e1', 'a', 'out', 'loop', 'in'),
        // 循环体走到这里即死路（用户蓝图里"条件为假"分支断开的情形）
        _edge('e2', 'loop', 'true', 'body', 'in'),
      ]);
      final hooks = Hooks();
      await _run(s, hooks: hooks);
      final clears = hooks.nodeChanges.where((id) => id == null).length;
      expect(clears, 1, reason: '只在运行结束时清空一次，循环内不应每轮 null ↔ 节点往返');
    });

    test('长执行链每 256 步让出一次事件循环', () async {
      // 600 个同步节点组成的线性链：只在微任务里 await 会整段跑完不抬头
      final nodes = <BPNode>[_node('a', 'start')];
      final edges = <BPEdge>[_edge('e0', 'a', 'out', 's0', 'in')];
      for (var i = 0; i < 600; i++) {
        nodes.add(_node('s$i', 'setVar', {'name': 'v$i', 'const': '1'}));
        if (i > 0) edges.add(_edge('e$i', 's${i - 1}', 'out', 's$i', 'in'));
      }
      var ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        ticks++;
      });
      addTearDown(timer.cancel);
      await _run(_build(nodes, edges));
      expect(ticks, greaterThanOrEqualTo(1), reason: '长链必须周期性让出事件循环');
    });

    test('已移除的节点类型：记日志并中断执行流，不抛异常', () async {
      final s = _build([
        _node('a', 'start'),
        _node('old', 'subScript', {'scriptName': 'x'}),
        _mouse('after', 'click', {'x': 1, 'y': 1}),
      ], [
        _edge('e1', 'a', 'out', 'old', 'in'),
        _edge('e2', 'old', 'out', 'after', 'in'),
      ]);
      final auto = MockAutomation();
      final hooks = Hooks();
      await _run(s, auto: auto, hooks: hooks);
      expect(hooks.logs.join(), contains('节点类型已移除或未知：subScript'));
      // 未知节点之后的操作语义不可知，必须停下而不是继续执行后续节点
      expect(auto.calls.any((c) => c.startsWith('click')), isFalse);
    });

    test('执行录制节点：回放录制的动作序列', () async {
      final hooks = Hooks()
        ..recording = Recording(
          id: 'r1',
          name: '测试录制',
          createdAt: DateTime(2026, 1, 1),
          actions: const [
            RecClick(0, 100, 200),
            RecScroll(120, 300, 400, dy: 240),
            RecKey(300, 0x43, durationMs: 80), // C 键
          ],
        );
      final s = _build([
        _node('a', 'start'),
        _node('pr', 'playRecording', {'recordingId': 'r1'}),
      ], [
        _edge('e1', 'a', 'out', 'pr', 'in'),
      ]);
      final auto = MockAutomation();
      await _run(s, auto: auto, hooks: hooks);
      expect(auto.calls, contains('click(100,200,count:1,left)'));
      expect(auto.calls, contains('scrollWheel(300,400,dy:240,dx:0)'));
      // 键动作走事件流：down/up 成对
      expect(auto.calls, contains('keyDown(67,ext:false)'));
      expect(auto.calls, contains('keyUp(67,ext:false)'));
      expect(hooks.logs.join(), contains('测试录制'));
    });

    test('执行录制节点：未选择/找不到录制时给出错误日志', () async {
      final s1 = _build([
        _node('a', 'start'),
        _node('pr', 'playRecording', {'recordingId': ''}),
      ], [
        _edge('e1', 'a', 'out', 'pr', 'in'),
      ]);
      final hooks1 = Hooks();
      await _run(s1, hooks: hooks1);
      expect(hooks1.logs.join(), contains('未选择录制'));

      final s2 = _build([
        _node('a', 'start'),
        _node('pr', 'playRecording', {'recordingId': 'ghost'}),
      ], [
        _edge('e1', 'a', 'out', 'pr', 'in'),
      ]);
      final hooks2 = Hooks();
      await _run(s2, hooks: hooks2);
      expect(hooks2.logs.join(), contains('找不到录制'));
    });

    test('缺少开始节点给出错误日志', () async {
      final s = _build([_node('d', 'delay', {'ms': 1})], []);
      final hooks = Hooks();
      await _run(s, hooks: hooks);
      expect(hooks.logs.join(), contains('没有「开始」节点'));
    });

    test('不支持平台：动作报错并记录日志，不崩溃', () async {
      final auto = MockAutomation()..supported = false;
      final s = _build([
        _node('a', 'start'),
        _mouse('c', 'click', {'x': 1, 'y': 1, 'button': 'left'}),
      ], [
        _edge('e1', 'a', 'out', 'c', 'in'),
      ]);
      final hooks = Hooks();
      final engine = BlueprintInterpreter(
        automation: auto,
        recognition: MockRecognition(),
        hooks: hooks.engineHooks,
      );
      await engine.run(s);
      expect(hooks.logs.join(), contains('平台不支持'));
    });
  });

  group('区域裁剪安全（越界不崩溃）', () {
    // 旧实现会裁剪上游图像；现改为「图像优先 + 现场按区域截屏」，不再裁剪。
    test('识别节点连接输入图像时直接使用该图像整体（区域不生效）', () async {
      final recognition = MockRecognition();
      final automation = MockAutomation();
      final s = _build([
        _node('a', 'start'),
        _node('shot', 'screenshot', {'useRegion': false}),
        _node('ocr', 'ocr', {
          'useRegion': true,
          'left': 500,
          'top': 500,
          'right': 700,
          'bottom': 700,
        }),
      ], [
        _edge('e1', 'a', 'out', 'shot', 'in'),
        _edge('e2', 'shot', 'out', 'ocr', 'in'),
        _edge('d1', 'shot', 'imageOut', 'ocr', 'image', kind: EdgeKind.data),
      ]);
      final hooks = Hooks();
      final engine = BlueprintInterpreter(
        automation: automation,
        recognition: recognition,
        hooks: hooks.engineHooks,
      );
      await engine.run(s);
      expect(automation.regions, [null], reason: '截图节点只截一次全屏；识别节点不应再截屏');
      expect(recognition.ocrCalls, hasLength(1));
      expect(
        recognition.ocrCalls.single.width,
        100,
        reason: '图像优先：识别的是整张上游图像（mock 全屏 100×100），不按区域二次裁剪',
      );
    });

    test('未连接输入图像时按区域现场截屏，坐标以实际采集原点为准', () async {
      final automation = MockAutomation()..captureX = -1920;
      final recognition = MockRecognition();
      final s = _build([
        _node('a', 'start'),
        _node('ocr', 'ocr', {
          'useRegion': true,
          'left': -1900,
          'top': 10,
          'right': -1800,
          'bottom': 110,
        }),
      ], [
        _edge('e1', 'a', 'out', 'ocr', 'in'),
      ]);
      final hooks = Hooks();
      final engine = BlueprintInterpreter(
        automation: automation,
        recognition: recognition,
        hooks: hooks.engineHooks,
      );
      await engine.run(s);
      expect(automation.lastRegion, isNotNull);
      expect(automation.lastRegion!.w, 100);
      expect(engine.vars, isNotNull);
      expect(hooks.logs.join(), isNot(contains('失败')));
    });

    test('区域坐标接数据边时，即使未勾选「仅指定区域」也按区域截屏', () async {
      final automation = MockAutomation();
      final s = _build([
        _node('a', 'start'),
        _node('src', 'setVar', {'name': 'x', 'const': '10'}),
        _node('shot', 'screenshot', {
          'useRegion': false,
          'left': 0,
          'top': 0,
          'right': 100,
          'bottom': 100,
        }),
      ], [
        _edge('e1', 'a', 'out', 'src', 'in'),
        _edge('e2', 'src', 'out', 'shot', 'in'),
        _edge('d1', 'src', 'valueOut', 'shot', 'left', kind: EdgeKind.data),
      ]);
      await BlueprintInterpreter(
        automation: automation,
        recognition: MockRecognition(),
        hooks: Hooks().engineHooks,
      ).run(s);
      final region = automation.lastRegion;
      expect(region, isNotNull, reason: '坐标有连线时不应截全屏');
      expect(
        (region!.x, region.y, region.w, region.h),
        (10, 0, 90, 100),
        reason: '左值来自数据边（10），其余取参数',
      );
    });

    test('未连接图像时不复用「上次截图」，按本节点区域重新截屏', () async {
      final automation = MockAutomation();
      final s = _build([
        _node('a', 'start'),
        _node('shot', 'screenshot', {
          'useRegion': true,
          'left': 0,
          'top': 0,
          'right': 300,
          'bottom': 300,
        }),
        _node('ocr', 'ocr', {
          'useRegion': true,
          'left': 500,
          'top': 500,
          'right': 600,
          'bottom': 600,
        }),
      ], [
        _edge('e1', 'a', 'out', 'shot', 'in'),
        _edge('e2', 'shot', 'out', 'ocr', 'in'),
      ]);
      await BlueprintInterpreter(
        automation: automation,
        recognition: MockRecognition(),
        hooks: Hooks().engineHooks,
      ).run(s);
      expect(automation.regions, hasLength(2), reason: '截图节点 + 识别节点各截一次');
      final ocrRegion = automation.regions.last!;
      expect(
        (ocrRegion.x, ocrRegion.y, ocrRegion.w, ocrRegion.h),
        (500, 500, 100, 100),
        reason: '识别节点必须按自己的区域截屏，不能复用上一次截图',
      );
    });
  });

  group('调试探针（运行到指定节点之前）', () {
    test('停在目标节点之前，返回上游图像、区域状态与前置步数', () async {
      final recognition = MockRecognition();
      final automation = MockAutomation();
      final s = _build([
        _node('a', 'start'),
        _node('shot', 'screenshot', {
          'useRegion': true,
          'left': 10,
          'top': 20,
          'right': 110,
          'bottom': 120,
        }),
        _node('ocr', 'ocr', {
          'useRegion': true,
          'left': 0,
          'top': 0,
          'right': 50,
          'bottom': 50,
        }),
      ], [
        _edge('e1', 'a', 'out', 'shot', 'in'),
        _edge('e2', 'shot', 'out', 'ocr', 'in'),
        _edge('d1', 'shot', 'imageOut', 'ocr', 'image', kind: EdgeKind.data),
      ]);
      final hooks = Hooks();
      final engine = BlueprintInterpreter(
        automation: automation,
        recognition: recognition,
        hooks: hooks.engineHooks,
      );
      final probe = await engine.probeBefore(s, 'ocr');
      expect(probe.reached, isTrue);
      expect(probe.steps, 2, reason: '开始 + 截图两个前置节点');
      expect(probe.image, isNotNull);
      expect(probe.image!.width, 100, reason: '上游截图区域 100×100');
      expect(probe.imageOrigin.$1, 10);
      expect(probe.region.enabled, isFalse, reason: '连接输入图像时区域不生效');
      expect(recognition.ocrCalls, isEmpty, reason: '探针只运行到目标节点之前，不执行它');
      expect(hooks.logs.join(), contains('已运行到目标节点之前'));
    });

    test('未连接图像时返回解析后的区域', () async {
      final s = _build([
        _node('a', 'start'),
        _node('ocr', 'ocr', {
          'useRegion': true,
          'left': 500,
          'top': 500,
          'right': 600,
          'bottom': 600,
        }),
      ], [
        _edge('e1', 'a', 'out', 'ocr', 'in'),
      ]);
      final engine = BlueprintInterpreter(
        automation: MockAutomation(),
        recognition: MockRecognition(),
        hooks: Hooks().engineHooks,
      );
      final probe = await engine.probeBefore(s, 'ocr');
      expect(probe.reached, isTrue);
      expect(probe.image, isNull);
      expect(probe.region.enabled, isTrue);
      expect(
        (probe.region.rect!.x, probe.region.rect!.y, probe.region.rect!.w, probe.region.rect!.h),
        (500, 500, 100, 100),
      );
    });

    test('目标节点不可达：reached=false，不误报成功', () async {
      final s = _build([
        _node('a', 'start'),
        _node('orphan', 'ocr', {'useRegion': false}),
      ], [
        _edge('e1', 'a', 'out', 'orphan', 'in'),
      ]);
      // 删掉执行流入口，模拟"节点没连在链上"
      s.edges.clear();
      final engine = BlueprintInterpreter(
        automation: MockAutomation(),
        recognition: MockRecognition(),
        hooks: Hooks().engineHooks,
      );
      final probe = await engine.probeBefore(s, 'orphan');
      expect(probe.reached, isFalse);
    });
  });

  group('已删除动作的旧脚本降级', () {
    test('mouse press/release：不执行任何鼠标动作，仅记录未知动作', () async {
      final s = _build([
        _node('a', 'start'),
        _mouse('p', 'press', {'x': 10, 'y': 20, 'button': 'left'}),
        _mouse('r', 'release', {'button': 'right'}),
      ], [
        _edge('e1', 'a', 'out', 'p', 'in'),
        _edge('e2', 'p', 'out', 'r', 'in'),
      ]);
      final auto = MockAutomation();
      final hooks = Hooks();
      await _run(s, auto: auto, hooks: hooks);
      expect(auto.calls, isEmpty);
      expect(
        hooks.logs.where((l) => l.contains('[鼠标] 未知动作')).length,
        2,
      );
      expect(hooks.logs.join(), contains('✓ 执行完成'));
    });

    test('keyboard down/up：不注入任何按键，仅记录未知动作', () async {
      final s = _build([
        _node('a', 'start'),
        _keyboard('d', 'down', {'vkCode': 0x41}),
        _keyboard('u', 'up', {'vkCode': 0x41}),
      ], [
        _edge('e1', 'a', 'out', 'd', 'in'),
        _edge('e2', 'd', 'out', 'u', 'in'),
      ]);
      final auto = MockAutomation();
      final hooks = Hooks();
      await _run(s, auto: auto, hooks: hooks);
      expect(auto.calls, isEmpty);
      expect(
        hooks.logs.where((l) => l.contains('[键盘] 未知动作')).length,
        2,
      );
      expect(hooks.logs.join(), contains('✓ 执行完成'));
    });
  });

  group('OCR 输出坐标语义', () {
    test('x/y 输出端口是识别区域中心点（区域坐标X + 区域宽/2）', () async {
      final s = _build([
        _node('a', 'start'),
        _node('o', 'ocr', {
          'useRegion': true,
          'left': 10,
          'top': 20,
          'right': 40,
          'bottom': 60,
        }),
        _node('vx', 'setVar', {'name': 'vx'}),
        _node('vy', 'setVar', {'name': 'vy'}),
      ], [
        _edge('e1', 'a', 'out', 'o', 'in'),
        _edge('e2', 'o', 'out', 'vx', 'in'),
        _edge('e3', 'vx', 'out', 'vy', 'in'),
        _edge('e4', 'o', 'x', 'vx', 'value', kind: EdgeKind.data),
        _edge('e5', 'o', 'y', 'vy', 'value', kind: EdgeKind.data),
      ]);
      final vars = await _run(s);
      expect(vars['vx'], 10 + 30 ~/ 2, reason: '区域坐标X + 区域宽/2');
      expect(vars['vy'], 20 + 40 ~/ 2, reason: '区域坐标Y + 区域高/2');
    });
  });

  group('OCR 目标文本命中坐标', () {
    test('命中目标文本时 x/y 为文字包围盒中心（含图像原点）', () async {
      final recognition = MockRecognition()
        ..ocrText = '开始 游戏'
        ..words = const [
          OcrWordBox('开始', 40, 60, 20, 10),
          OcrWordBox('游戏', 100, 200, 30, 20),
        ];
      final auto = MockAutomation()..captureX = 1000;
      final s = _build([
        _node('a', 'start'),
        _node('o', 'ocr', {'useRegion': false, 'targetText': '开始 游'}),
        _node('vx', 'setVar', {'name': 'vx', 'const': ''}),
        _node('vy', 'setVar', {'name': 'vy', 'const': ''}),
        _node('vf', 'setVar', {'name': 'vf', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'o', 'in'),
        _edge('e2', 'o', 'out', 'vx', 'in'),
        _edge('e3', 'vx', 'out', 'vy', 'in'),
        _edge('e4', 'vy', 'out', 'vf', 'in'),
        _edge('d1', 'o', 'x', 'vx', 'value', kind: EdgeKind.data),
        _edge('d2', 'o', 'y', 'vy', 'value', kind: EdgeKind.data),
        _edge('d3', 'o', 'found', 'vf', 'value', kind: EdgeKind.data),
      ]);
      final engine = BlueprintInterpreter(
        automation: auto,
        recognition: recognition,
        hooks: Hooks().engineHooks,
      );
      await engine.run(s);
      // 命中字符跨越两个词框：并集 (40,60)-(130,220)，中心 (85,140)，加图像原点 X=1000
      expect(engine.vars['vf'], true);
      expect(engine.vars['vx'], 1000 + 85);
      expect(engine.vars['vy'], 140);
    });

    test('未命中目标文本：found=false、x/y=null 并记录日志', () async {
      final recognition = MockRecognition()
        ..ocrText = '开始 游戏'
        ..words = const [OcrWordBox('开始', 0, 0, 20, 10)];
      final s = _build([
        _node('a', 'start'),
        _node('o', 'ocr', {'useRegion': false, 'targetText': '不存在'}),
        _node('vx', 'setVar', {'name': 'vx', 'const': ''}),
        _node('vf', 'setVar', {'name': 'vf', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'o', 'in'),
        _edge('e2', 'o', 'out', 'vx', 'in'),
        _edge('e3', 'vx', 'out', 'vf', 'in'),
        _edge('d1', 'o', 'x', 'vx', 'value', kind: EdgeKind.data),
        _edge('d2', 'o', 'found', 'vf', 'value', kind: EdgeKind.data),
      ]);
      final hooks = Hooks();
      final engine = BlueprintInterpreter(
        automation: MockAutomation(),
        recognition: recognition,
        hooks: hooks.engineHooks,
      );
      await engine.run(s);
      expect(engine.vars['vf'], false);
      expect(engine.vars['vx'], '', reason: '坐标输出 null，setVar 兜底为空字符串');
      expect(hooks.logs.join(), contains('[文字识别] 未找到目标「不存在」'));
      expect(hooks.logs.join(), contains('坐标X=null'));
    });

    test('未命中时坐标 null：下游鼠标动作被跳过并记录日志', () async {
      final recognition = MockRecognition()
        ..ocrText = '开始 游戏'
        ..words = const [OcrWordBox('开始', 0, 0, 20, 10)];
      final s = _build([
        _node('a', 'start'),
        _node('o', 'ocr', {'useRegion': false, 'targetText': '不存在'}),
        _mouse('m', 'click', {'x': 10, 'y': 20}),
      ], [
        _edge('e1', 'a', 'out', 'o', 'in'),
        _edge('e2', 'o', 'out', 'm', 'in'),
        _edge('d1', 'o', 'x', 'm', 'x', kind: EdgeKind.data),
        _edge('d2', 'o', 'y', 'm', 'y', kind: EdgeKind.data),
      ]);
      final auto = MockAutomation();
      final hooks = Hooks();
      final engine = BlueprintInterpreter(
        automation: auto,
        recognition: recognition,
        hooks: hooks.engineHooks,
      );
      await engine.run(s);
      expect(auto.calls.where((c) => c.startsWith('click')), isEmpty,
          reason: '坐标输入为空时不得回退参数坐标执行点击');
      expect(hooks.logs.join(), contains('跳过单击：X 坐标输入为空'));
    });

    test('空目标文本：found=识别非空，无词框时坐标回退区域中心', () async {
      final s = _build([
        _node('a', 'start'),
        _node('o', 'ocr', {
          'useRegion': true,
          'left': 100,
          'top': 200,
          'right': 400,
          'bottom': 600,
        }),
        _node('vf', 'setVar', {'name': 'vf', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'o', 'in'),
        _edge('e2', 'o', 'out', 'vf', 'in'),
        _edge('d1', 'o', 'found', 'vf', 'value', kind: EdgeKind.data),
      ]);
      final vars = await _run(s);
      expect(vars['vf'], true);
    });
  });

  group('加减法节点', () {
    test('int + int 输出 int；double 结果保留小数', () async {
      final s = _build([
        _node('a', 'start'),
        _node('s1', 'setVar', {'name': 'x', 'const': '2'}),
        _node('s2', 'setVar', {'name': 'y', 'const': '3'}),
        _node('add', 'add', {'a': 0, 'b': 0}),
        _node('copy', 'setVar', {'name': 'sum', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 's1', 'in'),
        _edge('e2', 's1', 'out', 's2', 'in'),
        _edge('e3', 's2', 'out', 'add', 'in'),
        _edge('e4', 'add', 'out', 'copy', 'in'),
        _edge('d1', 's1', 'valueOut', 'add', 'a', kind: EdgeKind.data),
        _edge('d2', 's2', 'valueOut', 'add', 'b', kind: EdgeKind.data),
        _edge('d3', 'add', 'result', 'copy', 'value', kind: EdgeKind.data),
      ]);
      final vars = await _run(s);
      expect(vars['sum'], 5);
      expect(vars['sum'], isA<int>());
    });

    test('减法允许负数；非数字输出 0 并打日志', () async {
      final s = _build([
        _node('a', 'start'),
        _node('s1', 'setVar', {'name': 'x', 'const': '1.5'}),
        _node('s2', 'setVar', {'name': 'y', 'const': '3'}),
        _node('sub', 'subtract', {'a': 0, 'b': 0}),
        _node('copy', 'setVar', {'name': 'diff', 'const': ''}),
        _node('bad', 'subtract', {'a': 0, 'b': 0}),
        _node('copy2', 'setVar', {'name': 'badResult', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 's1', 'in'),
        _edge('e2', 's1', 'out', 's2', 'in'),
        _edge('e3', 's2', 'out', 'sub', 'in'),
        _edge('e4', 'sub', 'out', 'copy', 'in'),
        _edge('e5', 'copy', 'out', 'bad', 'in'),
        _edge('e6', 'bad', 'out', 'copy2', 'in'),
        _edge('d1', 's1', 'valueOut', 'sub', 'a', kind: EdgeKind.data),
        _edge('d2', 's2', 'valueOut', 'sub', 'b', kind: EdgeKind.data),
        _edge('d3', 'sub', 'result', 'copy', 'value', kind: EdgeKind.data),
        _edge('d4', 's1', 'valueOut', 'bad', 'a', kind: EdgeKind.data),
        _edge('d5', 'bad', 'result', 'copy2', 'value', kind: EdgeKind.data),
      ]);
      // bad 的 B 未连接，使用参数 0 → 1.5 - 0 = 1.5，不是失败
      final vars = await _run(s);
      expect(vars['diff'], -1.5);
      expect(vars['badResult'], 1.5);
    });

    test('非数字操作数：结果 0 并记录失败日志', () async {
      final s = _build([
        _node('a', 'start'),
        _node('s1', 'setVar', {'name': 'x', 'const': 'abc'}),
        _node('add', 'add', {'a': 0, 'b': 1}),
        _node('copy', 'setVar', {'name': 'sum', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 's1', 'in'),
        _edge('e2', 's1', 'out', 'add', 'in'),
        _edge('e3', 'add', 'out', 'copy', 'in'),
        _edge('d1', 's1', 'valueOut', 'add', 'a', kind: EdgeKind.data),
        _edge('d2', 'add', 'result', 'copy', 'value', kind: EdgeKind.data),
      ]);
      final hooks = Hooks();
      final vars = await _run(s, hooks: hooks);
      expect(vars['sum'], 0);
      expect(hooks.logs.join(), contains('[加法] 失败：A 不是数字'));
    });
  });

  group('success 输出（仅执行录制保留）', () {
    test('执行录制：找不到录制 success=false 且继续执行', () async {
      final s = _build([
        _node('a', 'start'),
        _node('pr', 'playRecording', {'recordingId': 'ghost'}),
        _node('copy', 'setVar', {'name': 'ok', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'pr', 'in'),
        _edge('e2', 'pr', 'out', 'copy', 'in'),
        _edge('d1', 'pr', 'success', 'copy', 'value', kind: EdgeKind.data),
      ]);
      final vars = await _run(s);
      expect(vars['ok'], false);
    });

    test('截图区域四角点支持数据边；坐标有连线时未勾选也按区域截取', () async {
      final s = _build([
        _node('a', 'start'),
        _node('s1', 'setVar', {'name': 'l', 'const': '10'}),
        _node('s2', 'setVar', {'name': 't', 'const': '20'}),
        _node('s3', 'setVar', {'name': 'r', 'const': '110'}),
        _node('s4', 'setVar', {'name': 'b', 'const': '120'}),
        _node('shot', 'screenshot', {
          'useRegion': true,
          'left': 0,
          'top': 0,
          'right': 400,
          'bottom': 300,
        }),
        _node('shot2', 'screenshot', {
          'useRegion': false,
          'left': 0,
          'top': 0,
          'right': 400,
          'bottom': 300,
        }),
      ], [
        _edge('e1', 'a', 'out', 's1', 'in'),
        _edge('e2', 's1', 'out', 's2', 'in'),
        _edge('e3', 's2', 'out', 's3', 'in'),
        _edge('e4', 's3', 'out', 's4', 'in'),
        _edge('e5', 's4', 'out', 'shot', 'in'),
        _edge('e6', 'shot', 'out', 'shot2', 'in'),
        _edge('d1', 's1', 'valueOut', 'shot', 'left', kind: EdgeKind.data),
        _edge('d2', 's2', 'valueOut', 'shot', 'top', kind: EdgeKind.data),
        _edge('d3', 's3', 'valueOut', 'shot', 'right', kind: EdgeKind.data),
        _edge('d4', 's4', 'valueOut', 'shot', 'bottom', kind: EdgeKind.data),
        // useRegion=false 时这些连线应被忽略
        _edge('d5', 's1', 'valueOut', 'shot2', 'left', kind: EdgeKind.data),
        _edge('d6', 's3', 'valueOut', 'shot2', 'right', kind: EdgeKind.data),
      ]);
      final auto = MockAutomation();
      final engine = BlueprintInterpreter(
        automation: auto,
        recognition: MockRecognition(),
        hooks: Hooks().engineHooks,
      );
      await engine.run(s);
      expect(auto.regions.length, 2);
      final r = auto.regions.first;
      expect(r, isNotNull, reason: 'useRegion=true 时角点数据边应生效');
      expect((r!.x, r.y, r.w, r.h), (10, 20, 100, 100));
      // 坐标有数据边即视为按区域截取（属性面板会显示为开并锁定开关）
      final r2 = auto.regions.last;
      expect(r2, isNotNull, reason: '坐标有连线时不应退回全屏');
      expect((r2!.x, r2.y, r2.w, r2.h), (10, 0, 100, 300));
    });

    test('截图：区域无效时 imageOut 为空，继续执行', () async {
      final s = _build([
        _node('a', 'start'),
        _node('shot', 'screenshot', {
          'useRegion': true,
          'left': 100,
          'top': 100,
          'right': 100,
          'bottom': 300,
        }),
        _node('copy', 'setVar', {'name': 'img', 'const': 'x'}),
      ], [
        _edge('e1', 'a', 'out', 'shot', 'in'),
        _edge('e2', 'shot', 'out', 'copy', 'in'),
        _edge('d1', 'shot', 'imageOut', 'copy', 'value', kind: EdgeKind.data),
      ]);
      final hooks = Hooks();
      final vars = await _run(s, hooks: hooks);
      // imageOut 为空 → 下游拿不到数据，回退到常量 'x'（证明图像输出为空）
      expect(vars['img'], 'x');
      expect(hooks.logs.join(), contains('区域无效'));
    });
  });

  group('负坐标截屏（副屏在主屏左侧）', () {
    test('截图节点读取区域参数并把负坐标原样传给截屏', () async {
      final s = _build([
        _node('a', 'start'),
        _node('shot', 'screenshot', {
          'useRegion': true,
          'left': -1500,
          'top': 100,
          'right': -1100,
          'bottom': 400,
        }),
      ], [
        _edge('e1', 'a', 'out', 'shot', 'in'),
      ]);
      final auto = MockAutomation();
      await _run(s, auto: auto);

      final r = auto.lastRegion;
      expect(r, isNotNull, reason: '运行时必须按区域采集');
      expect((r!.x, r.y, r.w, r.h), (-1500, 100, 400, 300));
    });

    test('截图输出的图像原点是区域左上角，识别 x 输出负的区域中心', () async {
      final s = _build([
        _node('a', 'start'),
        _node('shot', 'screenshot', {
          'useRegion': true,
          'left': -1500,
          'top': 100,
          'right': -1100,
          'bottom': 400,
        }),
        _node('o', 'ocr'),
        _node('copy', 'setVar', {'name': 'x', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'shot', 'in'),
        _edge('e2', 'shot', 'out', 'o', 'in'),
        _edge('e3', 'o', 'out', 'copy', 'in'),
        _edge('d1', 'shot', 'imageOut', 'o', 'image', kind: EdgeKind.data),
        _edge('d2', 'o', 'x', 'copy', 'value', kind: EdgeKind.data),
      ]);
      final vars = await _run(s);
      // 上游图像为负坐标区域截图（400×300），OCR 未框选 → 输出该图像中心
      expect(vars['x'], -1500 + 400 ~/ 2, reason: '识别坐标应保持负的屏幕坐标语义');
    });

    test('未指定区域时识别坐标以截屏图像原点为基准（图像中心）', () async {
      final auto = MockAutomation()..captureX = -1920;
      final s = _build([
        _node('a', 'start'),
        _node('o', 'ocr', {'useRegion': false}),
        _node('copy', 'setVar', {'name': 'x', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'o', 'in'),
        _edge('e2', 'o', 'out', 'copy', 'in'),
        _edge('d1', 'o', 'x', 'copy', 'value', kind: EdgeKind.data),
      ]);
      final vars = await _run(s, auto: auto);
      // 全屏截图原点 -1920、Mock 图像 100×100 → 中心 = -1920 + 50
      expect(vars['x'], -1920 + 50);
    });
  });

  group('运行日志去重', () {
    test('同一节点多轮输出相同：只记录首次并汇总省略次数', () async {
      final s = _build([
        _node('a', 'start', {'count': 3}),
        _node('shot', 'screenshot', {'useRegion': false}),
      ], [
        _edge('e1', 'a', 'out', 'shot', 'in'),
      ]);
      final hooks = Hooks();
      await _run(s, hooks: hooks);

      expect(hooks.logs.where((l) => l == '[截图] 成功').length, 1,
          reason: '连续相同输出只保留首次');
      expect(
        hooks.logs.where((l) => l.contains('输出：图像=<图像 100×100>')).length,
        1,
      );
      expect(hooks.logs.join(), contains('「截图」相同输出已省略 2 次'));
    });

    test('同一节点输出值变化时逐次记录', () async {
      final s = _build([
        _node('a', 'start', {'count': 3}),
        _node('get', 'getVar', {'name': 'n'}),
        _node('add', 'add', {'a': 0, 'b': 1}),
        _node('set', 'setVar', {'name': 'n', 'const': ''}),
      ], [
        _edge('e1', 'a', 'out', 'add', 'in'),
        _edge('e2', 'add', 'out', 'set', 'in'),
        _edge('d1', 'get', 'value', 'add', 'a', kind: EdgeKind.data),
        _edge('d2', 'add', 'result', 'set', 'value', kind: EdgeKind.data),
      ]);
      final hooks = Hooks();
      final vars = await _run(s, hooks: hooks);

      expect(vars['n'], 2, reason: '前两轮累加：0+1、1+1');
      expect(hooks.logs.where((l) => l.startsWith('[加法]')).length, 3,
          reason: '每轮操作数不同，签名变化时逐次记录');
      expect(hooks.logs.join(), isNot(contains('相同输出已省略')));
    });

    test('无数据输出的节点连续相同动作只记录一次', () async {
      final s = _build([
        _node('a', 'start', {'count': 3}),
        _mouse('m', 'click', {'x': 10, 'y': 20}),
      ], [
        _edge('e1', 'a', 'out', 'm', 'in'),
      ]);
      final hooks = Hooks();
      await _run(s, hooks: hooks);

      expect(hooks.logs.where((l) => l == '[鼠标] 单击 (10, 20)').length, 1);
      expect(hooks.logs.join(), contains('相同输出已省略 2 次'));
    });

    test('错误日志不参与去重：每次执行都输出', () async {
      final s = _build([
        _node('a', 'start', {'count': 3}),
        _mouse('m', 'press', {'x': 1, 'y': 1}),
      ], [
        _edge('e1', 'a', 'out', 'm', 'in'),
      ]);
      final hooks = Hooks();
      await _run(s, hooks: hooks);

      expect(
        hooks.logs.where((l) => l.contains('[鼠标] 未知动作')).length,
        3,
        reason: '错误始终输出，不因重复而被省略',
      );
    });
  });
}
