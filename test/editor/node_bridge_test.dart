import 'dart:convert';

import 'package:bluedot_clicker/models/blueprint.dart';
import 'package:bluedot_clicker/models/node_types.dart' show isKnownNodeType;
import 'package:bluedot_clicker/ui/editor/node_bridge.dart';
import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter_test/flutter_test.dart';

BlueprintScript _sample() {
  final s = BlueprintScript(name: '桥接测试')..variables['found'] = true;
  s.nodes['a'] = BPNode(id: 'a', type: 'start', x: 10, y: 20);
  s.nodes['b'] = BPNode(id: 'b', type: 'delay', x: 220, y: 20, params: {'ms': 350});
  s.nodes['c'] = BPNode(id: 'c', type: 'condition', x: 430, y: 20, params: {'op': '>=', 'leftVar': 'found', 'rightConst': 'true'});
  s.edges['e1'] = BPEdge(
    id: 'e1',
    from: const PortRef(nodeId: 'a', port: 'out'),
    to: const PortRef(nodeId: 'b', port: 'in'),
    kind: EdgeKind.exec,
  );
  s.edges['e2'] = BPEdge(
    id: 'e2',
    from: const PortRef(nodeId: 'b', port: 'out'),
    to: const PortRef(nodeId: 'c', port: 'in'),
    kind: EdgeKind.exec,
  );
  return s;
}

void main() {
  test('定义注册表包含全部 12 种节点类型', () {
    expect(blueprintNodeRegistry, isNotNull);
    // 抽查几种关键类型定义可实例化（start 无参数字段，data 允许为空）
    for (final type in ['start', 'mouse', 'keyboard', 'playRecording', 'screenshot', 'ocr', 'imageMatch', 'condition', 'loop', 'delay', 'setVar', 'storage']) {
      final node = blueprintNodeRegistry.instantiate(type, id: 't_$type', position: Offset.zero);
      expect(node.type, type, reason: '类型 $type 应可实例化');
      if (type != 'start') {
        expect(node.data, isNotEmpty, reason: '类型 $type 应带默认参数');
      }
      // 端口由定义派生
      expect(node.ports, isNotEmpty, reason: '类型 $type 应有派生端口');
    }
  });

  test('已移除的节点类型不再注册，且加载时连同连线被过滤', () {
    final s = BlueprintScript(name: 'legacy');
    s.nodes['old'] = BPNode(id: 'old', type: 'click', x: 0, y: 0);
    s.nodes['keep'] = BPNode(id: 'keep', type: 'delay', params: {'ms': 10});
    s.edges['e1'] = BPEdge(
      id: 'e1',
      from: const PortRef(nodeId: 'old', port: 'out'),
      to: const PortRef(nodeId: 'keep', port: 'in'),
      kind: EdgeKind.exec,
    );
    expect(isKnownNodeType('click'), isFalse);
    final graph = blueprintToGraph(s);
    expect(graph.nodes.containsKey('old'), isTrue, reason: '节点本身保留，供用户识别后删除');
    expect(graph.connections, isEmpty, reason: '未知类型无端口，连线必须过滤');
    // 保存不回写已过滤的连线，节点与参数仍保留
    final out = graphToBlueprint(graph, name: s.name);
    expect(out.nodes.containsKey('old'), isTrue);
    expect(out.edges, isEmpty);
  });

  test('BlueprintScript → Graph → BlueprintScript 往返一致', () {
    final original = _sample();
    final graph = blueprintToGraph(original);
    expect(graph.nodes.length, 3);
    expect(graph.connections.length, 2);

    final restored = graphToBlueprint(graph, name: original.name);
    expect(restored.name, '桥接测试');
    expect(restored.nodes.keys.toSet(), original.nodes.keys.toSet());
    expect(restored.edges.keys.toSet(), original.edges.keys.toSet());

    // 节点位置与参数
    final b = restored.nodes['b']!;
    expect(b.type, 'delay');
    expect(b.x, 220);
    expect(b.y, 20);
    expect(b.params['ms'], 350);

    final c = restored.nodes['c']!;
    expect(c.params['op'], '>=');
    expect(c.params['leftVar'], 'found');

    // 边端点与类型
    final e1 = restored.edges['e1']!;
    expect(e1.kind, EdgeKind.exec);
    expect(e1.from.nodeId, 'a');
    expect(e1.from.port, 'out');
    expect(e1.to.nodeId, 'b');
    expect(e1.to.port, 'in');
  });

  test('数据边经输出端口 kind 正确识别为 data', () {
    final s = BlueprintScript(name: 'data-edge');
    s.nodes['a'] = BPNode(id: 'a', type: 'ocr', params: {'resultVar': 'ocrText'});
    s.nodes['b'] = BPNode(id: 'b', type: 'condition', params: {'op': 'contains', 'leftVar': '', 'rightConst': 'ok'});
    // OCR 的 text 输出端口（data 类型）连到 condition 的 left 输入（data 类型）
    s.edges['d1'] = BPEdge(
      id: 'd1',
      from: const PortRef(nodeId: 'a', port: 'text'),
      to: const PortRef(nodeId: 'b', port: 'left'),
      kind: EdgeKind.data,
    );
    final graph = blueprintToGraph(s);
    final restored = graphToBlueprint(graph, name: s.name);
    expect(restored.edges['d1']!.kind, EdgeKind.data);
    expect(restored.edges['d1']!.from.port, 'text');
  });

  test('编辑器控制器往返：normalise 后图仍可正确转回脚本并 JSON 序列化', () {
    final s = _sample();
    final controller = fl.NodeEditorController(definitions: blueprintNodeRegistry);
    controller.replaceGraph(blueprintToGraph(s), recordHistory: false, normalise: true);

    final out = graphToBlueprint(controller.graph, name: s.name, createdAt: s.createdAt);
    expect(out.nodes.length, s.nodes.length, reason: '节点不应丢失');
    expect(out.edges.length, s.edges.length, reason: '连线不应丢失');
    expect(out.nodes['b']!.params['ms'], 350);
    expect(out.nodes['b']!.x, 220);
    // 写盘前会做 JSON 编码，参数必须是可序列化的原始值
    expect(jsonEncode(out.toJson()), contains('"b"'));
  });

  test('graphToBlueprint 透传脚本级 variables（不透传会在保存时清空）', () {
    final s = _sample()..variables['hp'] = 100;
    s.variables['name0'] = 'hero';
    final graph = blueprintToGraph(s);
    // 不带 variables 参数 → 默认空（旧的调用方错误用法）
    final wiped = graphToBlueprint(graph, name: s.name);
    expect(wiped.variables, isEmpty);
    // 带 variables 参数 → 保留
    final kept = graphToBlueprint(
      graph,
      name: s.name,
      createdAt: s.createdAt,
      variables: Map.of(s.variables),
    );
    expect(kept.variables['hp'], 100);
    expect(kept.variables['name0'], 'hero');
    // 透传的是拷贝：修改目标脚本不影响源
    kept.variables['hp'] = 1;
    expect(s.variables['hp'], 100);
  });

  group('连线校验：执行流输出口单出边（引擎只走首条执行流边）', () {
    fl.NodeEditorController controller() {
      final c = fl.NodeEditorController(definitions: blueprintNodeRegistry)
        ..connectionValidator = blueprintConnectionValidator;
      c.addNodes([
        blueprintNodeRegistry.instantiate('start', id: 'st', position: Offset.zero),
        blueprintNodeRegistry.instantiate('mouse', id: 'a', position: const Offset(200, 0)),
        blueprintNodeRegistry.instantiate('mouse', id: 'b', position: const Offset(200, 150)),
        blueprintNodeRegistry.instantiate('ocr', id: 'ocr', position: const Offset(0, 300)),
        blueprintNodeRegistry.instantiate('condition', id: 'c1', position: const Offset(300, 300)),
        blueprintNodeRegistry.instantiate('condition', id: 'c2', position: const Offset(300, 450)),
      ]);
      return c;
    }

    test('执行流出口第二条出边被拒', () {
      final c = controller();
      expect(
        c.connect(const fl.PortRef('st', 'out'), const fl.PortRef('a', 'in')),
        isNotNull,
      );
      // 同一出口连第二个节点：静默丢分支的陷阱，必须拒绝
      expect(
        c.connect(const fl.PortRef('st', 'out'), const fl.PortRef('b', 'in')),
        isNull,
      );
      expect(c.graph.connections.length, 1);
    });

    test('数据输出口多出边仍允许（一源多消费是正常语义）', () {
      final c = controller();
      expect(
        c.connect(const fl.PortRef('ocr', 'text'), const fl.PortRef('c1', 'left')),
        isNotNull,
      );
      expect(
        c.connect(const fl.PortRef('ocr', 'text'), const fl.PortRef('c2', 'left')),
        isNotNull,
      );
      expect(c.graph.connections.length, 2);
    });

    test('执行流输入口第二条入边被拒（maxConnections 既有约束）', () {
      final c = controller();
      expect(
        c.connect(const fl.PortRef('st', 'out'), const fl.PortRef('a', 'in')),
        isNotNull,
      );
      c.addNodes([
        blueprintNodeRegistry.instantiate('start', id: 'st2', position: Offset.zero),
      ]);
      // a 的入边已占满（maxConnections: 1）——再连第二个开始节点应被拒
      expect(
        c.connect(const fl.PortRef('st2', 'out'), const fl.PortRef('a', 'in')),
        isNull,
      );
    });

    test('不同执行流出口可各连一条', () {
      final c = controller();
      expect(c.connect(const fl.PortRef('st', 'out'), const fl.PortRef('a', 'in')), isNotNull);
      expect(c.connect(const fl.PortRef('a', 'out'), const fl.PortRef('b', 'in')), isNotNull);
      expect(c.graph.connections.length, 2);
    });
  });
}
