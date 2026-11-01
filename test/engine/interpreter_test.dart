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
  Future<void> press(int x, int y, {MouseButton button = MouseButton.left}) async {
    _check();
    calls.add('press($x,$y)');
  }

  @override
  Future<void> release({MouseButton button = MouseButton.left}) async {
    _check();
    calls.add('release');
  }

  @override
  Future<void> swipe(int x1, int y1, int x2, int y2, {int durationMs = 300}) async {
    _check();
    calls.add('swipe($x1,$y1->$x2,$y2)');
  }

  @override
  Future<void> longPress(int x, int y, {int durationMs = 800, MouseButton button = MouseButton.left}) async {
    _check();
    calls.add('longPress($x,$y,$durationMs)');
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

/// 测试钩子集合：捕获日志/节点高亮，支持注入子脚本/录制
class Hooks {
  final List<String> logs = [];
  final List<String?> nodeChanges = [];
  BlueprintScript? subScript;
  Recording? recording;

  late final EngineHooks engineHooks = EngineHooks(
    log: logs.add,
    onNodeChange: nodeChanges.add,
    loadScript: (name) async => name == 'sub' ? subScript : null,
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
    test('顺序执行：开始→延时→点击', () async {
      final s = _build([
        _node('a', 'start'),
        _node('b', 'delay', {'ms': 1}),
        _node('c', 'click', {'x': 10, 'y': 20, 'fingers': 1, 'button': 'left'}),
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
        _node('c', 'click', {'x': 1, 'y': 2, 'button': 'left'}),
      ], [
        _edge('e1', 'a', 'out', 'c', 'in'),
      ]);
      final auto = MockAutomation();
      await _run(s, auto: auto);
      expect(auto.calls.where((c) => c == 'click(1,2,count:1,left)').length, 3);
    });

    test('双击节点：以 count:2 执行并传递按键类型', () async {
      final s = _build([
        _node('a', 'start'),
        _node('d', 'doubleClick', {'x': 5, 'y': 6, 'button': 'middle'}),
      ], [
        _edge('e1', 'a', 'out', 'd', 'in'),
      ]);
      final auto = MockAutomation();
      await _run(s, auto: auto);
      expect(auto.calls, contains('click(5,6,count:2,middle)'));
    });

    test('条件分支走向 true/false 出口', () async {
      // found == true → 点击；否则长按
      final s = BlueprintScript(name: 'cond')..variables['found'] = true;
      s.nodes['a'] = _node('a', 'start');
      s.nodes['cond'] = _node('cond', 'condition', {'op': '==', 'leftVar': 'found', 'rightConst': 'true'});
      s.nodes['yes'] = _node('yes', 'click', {'x': 1, 'y': 1, 'fingers': 1, 'button': 'left'});
      s.nodes['no'] = _node('no', 'longPress', {'x': 2, 'y': 2, 'durationMs': 1});
      s.edges['e1'] = _edge('e1', 'a', 'out', 'cond', 'in');
      s.edges['e2'] = _edge('e2', 'cond', 'true', 'yes', 'in');
      s.edges['e3'] = _edge('e3', 'cond', 'false', 'no', 'in');

      final auto = MockAutomation();
      await _run(s, auto: auto);
      expect(auto.calls, contains('click(1,1,count:1,left)'));
      expect(auto.calls, isNot(contains('longPress(2,2,1)')));

      // 改变量为 false 走另一分支
      s.variables['found'] = false;
      final auto2 = MockAutomation();
      await _run(s, auto: auto2);
      expect(auto2.calls, contains('longPress(2,2,1)'));
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
      final auto = MockAutomation();
      final hooks = Hooks();
      await _run(s, auto: auto, hooks: hooks);
      final logs = hooks.logs.where((l) => l.contains('循环 → body')).length;
      expect(logs, 3);
    });

    test('设置变量并在条件中使用', () async {
      final s = _build([
        _node('a', 'start'),
        _node('set', 'setVar', {'name': 'score', 'const': '88'}),
        _node('cond', 'condition', {'op': '>', 'leftVar': 'score', 'rightConst': '60'}),
        _node('ok', 'click', {'x': 9, 'y': 9, 'fingers': 1, 'button': 'left'}),
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

    test('滑动与长按参数解析（方向模式）', () async {
      final s = _build([
        _node('a', 'start'),
        _node('sw', 'swipe', {
          'mode': 'direction',
          'startX': 100,
          'startY': 100,
          'angle': 0,
          'distance': 50,
          'durationMs': 1,
        }),
        _node('lp', 'longPress', {'x': 5, 'y': 6, 'durationMs': 1}),
      ], [
        _edge('e1', 'a', 'out', 'sw', 'in'),
        _edge('e2', 'sw', 'out', 'lp', 'in'),
      ]);
      final auto = MockAutomation();
      await _run(s, auto: auto);
      expect(auto.calls, contains('swipe(100,100->150,100)'));
      expect(auto.calls, contains('longPress(5,6,1)'));
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

    test('子脚本调用（深度保护）', () async {
      final sub = _build([
        _node('sa', 'start'),
        _node('sc', 'click', {'x': 7, 'y': 8, 'fingers': 1, 'button': 'left'}),
      ], [
        _edge('se', 'sa', 'out', 'sc', 'in'),
      ], name: 'sub');
      final hooks = Hooks()..subScript = sub;
      final main = _build([
        _node('a', 'start'),
        _node('sub', 'subScript', {'scriptName': 'sub'}),
      ], [
        _edge('e1', 'a', 'out', 'sub', 'in'),
      ]);
      final auto = MockAutomation();
      final engine = BlueprintInterpreter(
          automation: auto, recognition: MockRecognition(), hooks: hooks.engineHooks);
      await engine.run(main);
      expect(auto.calls, contains('click(7,8,count:1,left)'));
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
        _node('c', 'click', {'x': 1, 'y': 1, 'fingers': 1, 'button': 'left'}),
      ], [
        _edge('e1', 'a', 'out', 'c', 'in'),
      ]);
      final hooks = Hooks();
      final engine = BlueprintInterpreter(
          automation: auto, recognition: MockRecognition(), hooks: hooks.engineHooks);
      await engine.run(s);
      expect(hooks.logs.join(), contains('平台不支持'));
    });
  });

  group('区域裁剪安全（越界不崩溃）', () {
    // 构造 w×h 纯色图：每 4 字节一个像素（BGRA）
    RawImage img(int w, int h) =>
        RawImage(w, h, Uint8List(w * h * 4));

    test('正常区域裁剪保持内容与尺寸', () {
      final src = RawImage(100, 100, Uint8List.fromList(
          List.filled(100 * 100 * 4, 7, growable: false)));
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
}
