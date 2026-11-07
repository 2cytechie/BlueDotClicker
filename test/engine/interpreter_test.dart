import 'dart:io';
import 'dart:typed_data';

import 'package:bluedot_clicker/engine/interpreter.dart';
import 'package:bluedot_clicker/engine/variables.dart';
import 'package:bluedot_clicker/models/blueprint.dart';
import 'package:bluedot_clicker/platform/platform_automation.dart';
import 'package:bluedot_clicker/services/recognition.dart';
import 'package:bluedot_clicker/services/script_storage.dart' show DataStore;
import 'package:flutter_test/flutter_test.dart';

// ---- 测试替身 ----

class MockAutomation implements PlatformAutomation {
  final List<String> calls = [];
  bool supported = true;

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
  Future<void> moveMouse(int x, int y) async {
    _check();
    calls.add('move($x,$y)');
  }

  @override
  Future<void> click(int x, int y, {MouseButton button = MouseButton.left, int count = 1}) async {
    _check();
    calls.add('click($x,$y,count:$count,${button.name})');
  }

  @override
  Future<void> swipe(int x1, int y1, int x2, int y2, {int durationMs = 300}) async {
    _check();
    calls.add('swipe($x1,$y1->$x2,$y2)');
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
    final w = region?.w ?? 100;
    final h = region?.h ?? 100;
    return ScreenCapture(w, h, Uint8List(w * h * 4));
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
  @override
  bool get isAvailable => true;
  @override
  Future<OcrResult> recognizeText(RawImage image, {int? regionX, int? regionY, int? regionW, int? regionH}) async =>
      OcrResult(ocrText);
  @override
  Future<MatchResult> matchTemplate(RawImage image, RawImage template, {double threshold = 0.8}) async =>
      const MatchResult(true, 50, 60, 0.95);
}

/// 测试钩子集合：捕获日志/节点高亮，支持注入录制
class Hooks {
  final List<String> logs = [];
  final List<String?> nodeChanges = [];
  Recording? recording;

  late final EngineHooks engineHooks = EngineHooks(
    log: logs.add,
    onNodeChange: nodeChanges.add,
    loadRecording: (id) async => id == recording?.id ? recording : null,
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
      s.nodes['cond'] = _node('cond', 'condition', {'op': '==', 'leftVar': 'found', 'rightConst': 'true'});
      s.nodes['yes'] = _mouse('yes', 'click', {'x': 1, 'y': 1, 'button': 'left'});
      s.nodes['no'] = _mouse('no', 'longPress', {'x': 2, 'y': 2, 'holdMs': 1});
      s.edges['e1'] = _edge('e1', 'a', 'out', 'cond', 'in');
      s.edges['e2'] = _edge('e2', 'cond', 'true', 'yes', 'in');
      s.edges['e3'] = _edge('e3', 'cond', 'false', 'no', 'in');

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

    test('循环执行 N 次后完成', () async {
      final s = _build([
        _node('a', 'start'),
        _node('loop', 'loop', {'count': 3}),
        _node('d', 'delay', {'ms': 1}),
      ], [
        _edge('e1', 'a', 'out', 'loop', 'enter'),
        _edge('e2', 'loop', 'body', 'd', 'in'),
        _edge('e3', 'd', 'out', 'loop', 'continue'),
      ]);
      final hooks = Hooks();
      await _run(s, hooks: hooks);
      final logs = hooks.logs.where((l) => l.contains('循环 → body')).length;
      expect(logs, 3);
    });

    test('设置变量并在条件中使用', () async {
      final s = _build([
        _node('a', 'start'),
        _node('set', 'setVar', {'name': 'score', 'const': '88'}),
        _node('cond', 'condition', {'op': '>', 'leftVar': 'score', 'rightConst': '60'}),
        _mouse('ok', 'click', {'x': 9, 'y': 9, 'button': 'left'}),
      ], [
        _edge('e1', 'a', 'out', 'set', 'in'),
        _edge('e2', 'set', 'out', 'cond', 'in'),
        _edge('e3', 'cond', 'true', 'ok', 'in'),
      ]);
      final vars = await _run(s);
      expect(vars['score'], 88);
    });

    test('OCR 结果写入变量', () async {
      final s = _build([
        _node('a', 'start'),
        _node('ocr', 'ocr', {'resultVar': 'ocrText', 'useRegion': false}),
      ], [
        _edge('e1', 'a', 'out', 'ocr', 'in'),
      ]);
      final vars = await _run(s);
      expect(vars['ocrText'], '测试文本');
    });

    test('数据存取节点持久化', () async {
      DataStore.overrideDir(Directory.systemTemp);
      final s1 = _build([
        _node('a', 'start'),
        _node('set', 'setVar', {'name': 'persistMe', 'const': 'v1'}),
        _node('save', 'storage', {'action': 'save', 'key': 'k1', 'name': 'persistMe'}),
      ], [
        _edge('e1', 'a', 'out', 'set', 'in'),
        _edge('e2', 'set', 'out', 'save', 'in'),
      ]);
      await _run(s1);
      final s2 = _build([
        _node('a', 'start'),
        _node('load', 'storage', {'action': 'load', 'key': 'k1', 'name': 'loaded'}),
      ], [
        _edge('e1', 'a', 'out', 'load', 'in'),
      ]);
      final vars = await _run(s2);
      expect(vars['loaded'], 'v1');
      DataStore.overrideDir(Directory.systemTemp.parent);
    });

    test('滑动参数解析（方向模式）与坐标模式', () async {
      final s = _build([
        _node('a', 'start'),
        _mouse('sw', 'swipe', {
          'mode': 'direction',
          'startX': 100,
          'startY': 100,
          'angle': 0,
          'distance': 50,
          'durationMs': 1,
        }),
        _mouse('sw2', 'swipe', {
          'mode': 'coords',
          'startX': 1,
          'startY': 2,
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

    test('强制停止：无限循环可被 stop 终止', () async {
      final s = _build([
        _node('a', 'start'),
        _node('loop', 'loop', {'count': 0}),
        _node('d', 'delay', {'ms': 1}),
      ], [
        _edge('e1', 'a', 'out', 'loop', 'enter'),
        _edge('e2', 'loop', 'body', 'd', 'in'),
        _edge('e3', 'd', 'out', 'loop', 'continue'),
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
    // 构造 w×h 纯色图：每 4 字节一个像素（BGRA）
    RawImage img(int w, int h) => RawImage(w, h, Uint8List(w * h * 4));

    test('正常区域裁剪保持内容与尺寸', () {
      final src = RawImage(100, 100, Uint8List.fromList(List.filled(100 * 100 * 4, 7, growable: false)));
      final out = BlueprintInterpreter.cropImage(src, const RectPx(10, 20, 30, 40));
      expect(out.width, 30);
      expect(out.height, 40);
      expect(out.bgra.length, 30 * 40 * 4);
    });

    test('区域起点越出图像：钳制到边缘，1×1 不抛 ArgumentError', () {
      final src = img(100, 100);
      final out = BlueprintInterpreter.cropImage(src, const RectPx(150, 150, 10, 10));
      expect(out.width, 1);
      expect(out.height, 1);
    });

    test('负起点与超大宽高：钳到图像内', () {
      final src = img(100, 100);
      final out = BlueprintInterpreter.cropImage(src, const RectPx(-20, -20, 500, 500));
      expect(out.width, 100);
      expect(out.height, 100);
    });

    test('部分越界：只保留与图像相交的部分', () {
      final src = img(100, 100);
      final out = BlueprintInterpreter.cropImage(src, const RectPx(80, 90, 50, 50));
      expect(out.width, 20);
      expect(out.height, 10);
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
        hooks.logs.where((l) => l.contains('鼠标操作失败：未知动作')).length,
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
        hooks.logs.where((l) => l.contains('键盘操作失败：未知动作')).length,
        2,
      );
      expect(hooks.logs.join(), contains('✓ 执行完成'));
    });
  });

  group('OCR 输出坐标语义', () {
    test('x/y 输出端口是识别区域原点（未指定区域时为 0）', () async {
      final s = _build([
        _node('a', 'start'),
        _node('o', 'ocr', {
          'useRegion': true,
          'rx': 10,
          'ry': 20,
          'rw': 30,
          'rh': 40,
          'resultVar': 'txt',
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
      // 不是识别文本的位置，而是区域左上角（当前实现）
      expect(vars['vx'], 10);
      expect(vars['vy'], 20);
    });
  });
}
