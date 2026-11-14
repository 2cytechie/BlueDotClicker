import 'dart:convert';

import 'package:bluedot_clicker/engine/interpreter.dart';
import 'package:bluedot_clicker/models/blueprint.dart';
import 'package:bluedot_clicker/platform/platform_automation.dart';
import 'package:bluedot_clicker/services/recognition.dart';
import 'package:bluedot_clicker/ui/editor/node_bridge.dart';
import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter_test/flutter_test.dart';

// 仅记录动作，测试不接触真实桌面。
class _Automation extends UnsupportedPlatformAutomation {
  final List<int> clicks = [];
  void Function()? onClick;

  @override
  bool get isSupported => true;

  @override
  Future<void> click(
    int x,
    int y, {
    MouseButton button = MouseButton.left,
    int count = 1,
  }) async {
    clicks.add(x);
    onClick?.call();
  }
}

class _UnusedRecognition implements RecognitionService {
  @override
  bool get isAvailable => false;

  @override
  Future<OcrResult> recognizeText(
    RawImage image, {
    int? regionX,
    int? regionY,
    int? regionW,
    int? regionH,
  }) => throw StateError('本测试不应执行 OCR');

  @override
  Future<MatchResult> matchTemplate(
    RawImage image,
    RawImage template, {
    double threshold = 0.8,
  }) => throw StateError('本测试不应执行图像识别');
}

fl.NodeEditorController _editor() {
  final c = fl.NodeEditorController(definitions: blueprintNodeRegistry)
    ..connectionValidator = blueprintConnectionValidator;
  addTearDown(c.dispose);
  return c;
}

void _node(
  fl.NodeEditorController c,
  String id,
  String type, [
  Map<String, Object?> params = const {},
]) {
  c.addNodes([
    blueprintNodeRegistry.instantiate(
      type,
      id: id,
      position: Offset(c.graph.nodes.length * 220.0, 0),
      data: params,
    ),
  ]);
}

String _wire(
  fl.NodeEditorController c,
  String from,
  String to, {
  String output = 'out',
  String input = 'in',
}) {
  final id = c.connect(fl.PortRef(from, output), fl.PortRef(to, input));
  expect(id, isNotNull, reason: '$from.$output → $to.$input 应可连接');
  return id!;
}

// 每个运行场景都经过编辑器 → 脚本 JSON → 编辑器，覆盖重新打开时的端口派生。
BlueprintScript _savedScript(
  fl.NodeEditorController c, {
  Map<String, Object> variables = const {},
}) {
  final script = graphToBlueprint(c.graph, name: '分支汇合', variables: variables);
  final decoded = BlueprintScript.fromJson(
    jsonDecode(jsonEncode(script.toJson())) as Map<String, dynamic>,
  );
  final reopened = _editor();
  reopened.replaceGraph(blueprintToGraph(decoded), recordHistory: false);
  expect(
    reopened.graph.connections.keys,
    unorderedEquals(c.graph.connections.keys),
  );
  return graphToBlueprint(
    reopened.graph,
    name: decoded.name,
    variables: decoded.variables,
  );
}

BlueprintInterpreter _engine(_Automation automation) => BlueprintInterpreter(
  automation: automation,
  recognition: _UnusedRecognition(),
  hooks: EngineHooks(
    log: (message) {
      expect(message, isNot(startsWith('✗')), reason: message);
    },
    onNodeChange: (_) {},
  ),
);

fl.NodeEditorController _branches({bool direct = false}) {
  final c = _editor();
  _node(c, 'start', 'start');
  _node(c, 'condition', 'condition', {
    'leftConst': 'true',
    'rightConst': 'true',
  });
  _node(c, 'shared', 'mouse', {'x': 10, 'y': 1});
  _node(c, 'tail', 'mouse', {'x': 99, 'y': 1});
  _wire(c, 'start', 'condition');
  _wire(c, 'shared', 'tail');
  if (direct) {
    _wire(c, 'condition', 'shared', output: 'true');
    _wire(c, 'condition', 'shared', output: 'false');
  } else {
    _node(c, 'yes', 'setVar', {'name': 'position', 'const': '11'});
    _node(c, 'no', 'setVar', {'name': 'position', 'const': '22'});
    _node(c, 'position', 'getVar', {'name': 'position'});
    _wire(c, 'condition', 'yes', output: 'true');
    _wire(c, 'condition', 'no', output: 'false');
    _wire(c, 'yes', 'shared');
    _wire(c, 'no', 'shared');
    _wire(c, 'position', 'shared', output: 'value', input: 'x');
  }
  return c;
}

void main() {
  group('汇合连线编辑', () {
    test('从已占用的执行输入口反向拖线也能新增入边，重复边仍拒绝', () {
      final c = _branches(direct: true);
      _node(c, 'other', 'delay');
      expect(
        c.connect(
          const fl.PortRef('shared', 'in'),
          const fl.PortRef('other', 'out'),
        ),
        isNotNull,
      );
      expect(
        c.connect(
          const fl.PortRef('condition', 'true'),
          const fl.PortRef('shared', 'in'),
        ),
        isNull,
      );
      expect(
        c.graph.connectionsAt(const fl.PortRef('shared', 'in')),
        hasLength(3),
      );
    });

    test('执行出口仍单出边，普通数据和图像输入仍单入边', () {
      final c = _branches();
      _node(c, 'otherValue', 'getVar', {'name': 'other'});
      _node(c, 'shot1', 'screenshot');
      _node(c, 'shot2', 'screenshot');
      _node(c, 'ocr', 'ocr');
      expect(
        c.connect(
          const fl.PortRef('yes', 'out'),
          const fl.PortRef('tail', 'in'),
        ),
        isNull,
      );
      expect(
        c.connect(
          const fl.PortRef('otherValue', 'value'),
          const fl.PortRef('shared', 'x'),
        ),
        isNull,
      );
      _wire(c, 'shot1', 'ocr', output: 'imageOut', input: 'image');
      expect(
        c.connect(
          const fl.PortRef('shot2', 'imageOut'),
          const fl.PortRef('ocr', 'image'),
        ),
        isNull,
      );
    });

    test('新增第二条入边可以撤销和重做', () {
      final c = _editor();
      _node(c, 'condition', 'condition');
      _node(c, 'shared', 'delay');
      final first = _wire(c, 'condition', 'shared', output: 'true');
      final second = _wire(c, 'condition', 'shared', output: 'false');
      c.history.undo();
      expect(c.graph.connections.keys, [first]);
      c.history.redo();
      expect(c.graph.connections.keys, unorderedEquals([first, second]));
    });

    test('删除一条入边保留另一条，撤销后完整恢复', () {
      final c = _branches(direct: true);
      final removed = c.graph.connections.values
          .firstWhere((e) => e.from == const fl.PortRef('condition', 'false'))
          .id;
      final original = c.graph.connections.keys.toSet();
      c.removeConnections([removed]);
      expect(c.graph.connections.keys.toSet(), original.difference({removed}));
      expect(
        c.graph.connectionsAt(const fl.PortRef('shared', 'in')),
        hasLength(1),
      );
      c.history.undo();
      expect(c.graph.connections.keys.toSet(), original);
      _savedScript(c);
    });

    test('复制粘贴整个分支结构后保留所有内部汇合连线', () {
      final c = _branches();
      final edgeCount = c.graph.connections.length;
      c.selection.selectNodes(c.graph.nodes.keys);
      expect(c.clipboard.copy(), isTrue);
      final pasted = c.clipboard.paste();
      expect(pasted, hasLength(7));
      expect(c.graph.connections, hasLength(edgeCount * 2));
      final shared = pasted.singleWhere(
        (id) =>
            c.graph.nodes[id]!.type == 'mouse' &&
            c.graph.nodes[id]!.data['x'] == 10,
      );
      expect(c.graph.connectionsAt(fl.PortRef(shared, 'in')), hasLength(2));
      _savedScript(c);
    });
  });

  group('汇合后的实际执行', () {
    for (final value in [true, false]) {
      test('判断为 $value：两个出口直接汇合，公共链只执行一次', () async {
        final c = _branches(direct: true);
        c.updateNode('condition', (n) => n.withData({'leftConst': '$value'}));
        final automation = _Automation();
        await _engine(automation).run(_savedScript(c));
        expect(automation.clicks, [10, 99]);
      });

      test('判断为 $value：各分支赋值后汇合，公共节点读取所选分支的变量', () async {
        final c = _branches();
        c.updateNode('condition', (n) => n.withData({'leftConst': '$value'}));
        final automation = _Automation();
        await _engine(automation).run(_savedScript(c));
        expect(automation.clicks, [value ? 11 : 22, 99]);
      });

      test('判断为 $value：探针首次到达公共节点前停止', () async {
        final c = _branches();
        c.updateNode('condition', (n) => n.withData({'leftConst': '$value'}));
        final automation = _Automation();
        final engine = _engine(automation);
        final probe = await engine.probeBefore(_savedScript(c), 'shared');
        expect(probe.reached, isTrue);
        expect(engine.vars['position'], value ? 11 : 22);
        expect(automation.clicks, isEmpty);
      });
    }

    for (final (outer, inner, expected) in [
      (true, true, 11),
      (true, false, 22),
      (false, true, 33),
    ]) {
      test('嵌套判断 $outer/$inner：三条路径共用一个尾部', () async {
        final c = _editor();
        _node(c, 'start', 'start');
        _node(c, 'outer', 'condition', {
          'leftConst': '$outer',
          'rightConst': 'true',
        });
        _node(c, 'inner', 'condition', {
          'leftConst': '$inner',
          'rightConst': 'true',
        });
        for (final (id, x) in [
          ('a', 11),
          ('b', 22),
          ('c', 33),
          ('shared', 99),
        ]) {
          _node(c, id, 'mouse', {'x': x, 'y': 1});
        }
        _wire(c, 'start', 'outer');
        _wire(c, 'outer', 'inner', output: 'true');
        _wire(c, 'outer', 'c', output: 'false');
        _wire(c, 'inner', 'a', output: 'true');
        _wire(c, 'inner', 'b', output: 'false');
        for (final id in ['a', 'b', 'c']) {
          _wire(c, id, 'shared');
        }
        final automation = _Automation();
        await _engine(automation).run(_savedScript(c));
        expect(automation.clicks, [expected, 99]);
      });
    }

    test('循环切换分支：公共节点每轮读取新变量，回边不递归，退出链仅一次', () async {
      final c = _branches();
      c.removeConnections(
        c.graph.connections.values
            .where((e) => e.from.nodeId == 'start' || e.from.nodeId == 'shared')
            .map((e) => e.id)
            .toList(),
      );
      _node(c, 'loop', 'loop', {'op': '<', 'rightConst': '3'});
      _node(c, 'i', 'getVar', {'name': 'i'});
      _node(c, 'increment', 'add', {'b': 1});
      _node(c, 'saveI', 'setVar', {'name': 'i'});
      c.updateNode(
        'condition',
        (n) => n.withData({'op': '<', 'rightConst': '1'}),
      );
      _wire(c, 'start', 'loop');
      _wire(c, 'loop', 'condition', output: 'true');
      _wire(c, 'loop', 'tail', output: 'false');
      _wire(c, 'shared', 'increment');
      _wire(c, 'increment', 'saveI');
      _wire(c, 'saveI', 'loop');
      _wire(c, 'i', 'loop', output: 'value', input: 'left');
      _wire(c, 'i', 'condition', output: 'value', input: 'left');
      _wire(c, 'i', 'increment', output: 'value', input: 'a');
      _wire(c, 'increment', 'saveI', output: 'result', input: 'value');
      final automation = _Automation();
      final engine = _engine(automation);
      await engine.run(_savedScript(c, variables: {'i': 0}));
      expect(automation.clicks, [11, 22, 22, 99]);
      expect(engine.vars['i'], 3);
    });

    test('循环体和结束出口汇合时，每轮及退出均执行，不隐式去重', () async {
      final c = _editor();
      _node(c, 'start', 'start');
      _node(c, 'loop', 'loop', {
        'leftConst': '1',
        'rightConst': '1',
        'maxIterations': 3,
      });
      _node(c, 'shared', 'mouse', {'x': 10, 'y': 1});
      _wire(c, 'start', 'loop');
      _wire(c, 'loop', 'shared', output: 'true');
      _wire(c, 'loop', 'shared', output: 'false');
      final automation = _Automation();
      await _engine(automation).run(_savedScript(c));
      expect(automation.clicks, [10, 10, 10, 10]);
    });

    test('开始节点执行多轮时，公共链每轮都执行', () async {
      final c = _branches(direct: true);
      c.updateNode('start', (n) => n.withData({'count': 3}));
      final automation = _Automation();
      await _engine(automation).run(_savedScript(c));
      expect(automation.clicks, [10, 99, 10, 99, 10, 99]);
    });

    test('执行路径回到判断节点时仍可停止，不再执行后续节点', () async {
      final c = _branches(direct: true);
      c.removeConnections(
        c.graph.connections.values
            .where((e) => e.from.nodeId == 'shared')
            .map((e) => e.id)
            .toList(),
      );
      _wire(c, 'shared', 'condition');
      final automation = _Automation();
      final engine = _engine(automation);
      automation.onClick = () {
        if (automation.clicks.length == 3) engine.stop();
      };
      await engine.run(_savedScript(c));
      expect(automation.clicks, [10, 10, 10]);
      expect(engine.isRunning, isFalse);
    });
  });
}
