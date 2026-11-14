import 'dart:convert';

import 'package:bluedot_clicker/core/theme.dart' show AppColors;
import 'package:bluedot_clicker/models/blueprint.dart';
import 'package:bluedot_clicker/models/node_types.dart' show isKnownNodeType;
import 'package:bluedot_clicker/ui/editor/node_bridge.dart';
import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';

BlueprintScript _sample() {
  final s = BlueprintScript(name: '桥接测试')..variables['found'] = true;
  s.nodes['a'] = BPNode(id: 'a', type: 'start', x: 10, y: 20);
  s.nodes['b'] = BPNode(id: 'b', type: 'delay', x: 220, y: 20, params: {'ms': 350});
  s.nodes['c'] = BPNode(id: 'c', type: 'condition', x: 430, y: 20, params: {'op': '>=', 'leftConst': '5', 'rightConst': 'true'});
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
  test('定义注册表包含全部 15 种节点类型', () {
    expect(blueprintNodeRegistry, isNotNull);
    // 抽查几种关键类型定义可实例化（start 无参数字段，data 允许为空）
    for (final type in ['start', 'mouse', 'keyboard', 'playRecording', 'screenshot', 'ocr', 'imageMatch', 'condition', 'loop', 'delay', 'setVar', 'getVar', 'add', 'subtract', 'saveData']) {
      final node = blueprintNodeRegistry.instantiate(type, id: 't_$type', position: Offset.zero);
      expect(node.type, type, reason: '类型 $type 应可实例化');
      if (type != 'start') {
        expect(node.data, isNotEmpty, reason: '类型 $type 应带默认参数');
      }
      // 端口由定义派生
      expect(node.ports, isNotEmpty, reason: '类型 $type 应有派生端口');
    }
  });

  test('连线配色：执行流（control）白色、数据连线绿色', () {
    final node = blueprintNodeRegistry.instantiate('mouse', id: 'm', position: Offset.zero);
    final controlPort = node.ports.firstWhere((p) => p.kind == fl.PortKind.control);
    final dataPort = node.ports.firstWhere((p) => p.kind == fl.PortKind.data);
    expect(connectionAppearanceFor(controlPort).color, Colors.white);
    expect(connectionAppearanceFor(dataPort).color, AppColors.success);
  });

  test('varName 参数收集：图中变量名去重汇集', () {
    final c = fl.NodeEditorController(definitions: blueprintNodeRegistry);
    addTearDown(c.dispose);
    c.addNodes([
      blueprintNodeRegistry.instantiate('setVar', id: 'a', position: Offset.zero),
      blueprintNodeRegistry.instantiate('setVar', id: 'b', position: const Offset(200, 0)),
      blueprintNodeRegistry.instantiate('getVar', id: 'g', position: const Offset(400, 0)),
    ]);
    c.updateNode('a', (n) => n.withData({'name': 'hp'}));
    c.updateNode('b', (n) => n.withData({'name': 'hp'}));
    c.updateNode('g', (n) => n.withData({'name': ' '}));
    final names = graphVarNames(c.graph);
    expect(names, {'hp'}, reason: '去重、剔除空白名');
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

  test('旧脚本 getVar 执行流连线在加载时被丢弃（纯数据节点）', () {
    final s = BlueprintScript(name: 'getvar-legacy');
    s.nodes['g'] = BPNode(id: 'g', type: 'getVar', params: {'name': 'hp'});
    s.nodes['d'] = BPNode(id: 'd', type: 'delay', params: {'ms': 10});
    s.edges['e1'] = BPEdge(
      id: 'e1',
      from: const PortRef(nodeId: 'g', port: 'out'),
      to: const PortRef(nodeId: 'd', port: 'in'),
      kind: EdgeKind.exec,
    );
    final graph = blueprintToGraph(s);
    expect(graph.nodes.containsKey('g'), isTrue, reason: '节点本身保留');
    expect(graph.connections, isEmpty, reason: 'getVar 已无执行流端口，旧连线丢弃');
    final out = graphToBlueprint(graph, name: s.name);
    expect(out.nodes['g']!.params['name'], 'hp');
    expect(out.edges, isEmpty);
  });

  test('端口级过滤：指向已删端口（screenshot 的 image 输入）的旧连线被丢弃', () {
    final s = BlueprintScript(name: 'legacy-port');
    s.nodes['sh'] = BPNode(id: 'sh', type: 'screenshot');
    s.nodes['o'] = BPNode(id: 'o', type: 'ocr');
    // 旧脚本可能存在指向 screenshot.image 输入端口的连线（该端口已被移除）
    s.edges['e1'] = BPEdge(
      id: 'e1',
      from: const PortRef(nodeId: 'sh', port: 'imageOut'),
      to: const PortRef(nodeId: 'sh', port: 'image'),
      kind: EdgeKind.data,
    );
    // 正常端口（截图图像 → OCR 图像输入）不受影响
    s.edges['e2'] = BPEdge(
      id: 'e2',
      from: const PortRef(nodeId: 'sh', port: 'imageOut'),
      to: const PortRef(nodeId: 'o', port: 'image'),
      kind: EdgeKind.data,
    );
    final graph = blueprintToGraph(s);
    expect(
      graph.connections.values.any((c) => c.to.portId == 'image' && c.to.nodeId == 'sh'),
      isFalse,
      reason: 'screenshot 已无 image 输入端口，指向它的连线必须过滤',
    );
    expect(
      graph.connections.values.any((c) => c.id == 'e2'),
      isTrue,
      reason: '端口仍然存在的连线不受影响',
    );
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
    expect(c.params['leftConst'], '5');

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
    s.nodes['a'] = BPNode(id: 'a', type: 'ocr');
    s.nodes['b'] = BPNode(id: 'b', type: 'condition', params: {'op': 'contains', 'rightConst': 'ok'});
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

    test('条件判断的两个出口可汇入同一个执行输入口', () {
      final c = controller();
      expect(
        c.connect(const fl.PortRef('c1', 'true'), const fl.PortRef('a', 'in')),
        isNotNull,
      );
      expect(
        c.connect(const fl.PortRef('c1', 'false'), const fl.PortRef('a', 'in')),
        isNotNull,
      );
      expect(c.graph.connections.length, 2);
    });

    test('不同执行流出口可各连一条', () {
      final c = controller();
      expect(c.connect(const fl.PortRef('st', 'out'), const fl.PortRef('a', 'in')), isNotNull);
      expect(c.connect(const fl.PortRef('a', 'out'), const fl.PortRef('b', 'in')), isNotNull);
      expect(c.graph.connections.length, 2);
    });
  });

  group('数据输入接管参数：连接不改写参数值', () {
    fl.NodeEditorController mouseWithSource() {
      final c = fl.NodeEditorController(definitions: blueprintNodeRegistry);
      addTearDown(c.dispose);
      c.addNodes([
        blueprintNodeRegistry.instantiate('setVar', id: 'v', position: Offset.zero),
        blueprintNodeRegistry.instantiate('mouse', id: 'm', position: const Offset(200, 0)),
      ]);
      return c;
    }

    test('X 接入数据后参数原值保留，y 不受影响', () {
      final c = mouseWithSource();
      c.updateNode('m', (n) => n.withData(const {'x': -809, 'y': 428}));

      final id = c.connect(
        const fl.PortRef('v', 'valueOut'),
        const fl.PortRef('m', 'x'),
      );
      expect(id, isNotNull);

      expect(c.graph.nodes['m']!.data['x'], -809,
          reason: '参数接管只禁用不做归零，断开后可直接复用');
      expect(c.graph.nodes['m']!.data['y'], 428);
    });
  });

  group('端口类型校验', () {
    fl.NodeEditorController typedController() {
      final c = fl.NodeEditorController(definitions: blueprintNodeRegistry)
        ..connectionValidator = blueprintConnectionValidator;
      addTearDown(c.dispose);
      c.addNodes([
        blueprintNodeRegistry.instantiate('start', id: 'st', position: Offset.zero),
        blueprintNodeRegistry.instantiate('screenshot', id: 'ss', position: const Offset(0, 100)),
        blueprintNodeRegistry.instantiate('ocr', id: 'o1', position: const Offset(200, 100)),
        blueprintNodeRegistry.instantiate('ocr', id: 'o2', position: const Offset(200, 200)),
        blueprintNodeRegistry.instantiate('imageMatch', id: 'im', position: const Offset(400, 200)),
        blueprintNodeRegistry.instantiate('mouse', id: 'm', position: const Offset(400, 100)),
      ]);
      return c;
    }

    test('图像输出 → 图像输入允许连接', () {
      final c = typedController();
      expect(
        c.connect(const fl.PortRef('ss', 'imageOut'), const fl.PortRef('o1', 'image')),
        isNotNull,
      );
    });

    test('图像输出 → 值输入被拒绝', () {
      final c = typedController();
      expect(
        c.connect(const fl.PortRef('ss', 'imageOut'), const fl.PortRef('m', 'x')),
        isNull,
      );
    });

    test('文本输出 → 图像输入被拒绝', () {
      final c = typedController();
      expect(
        c.connect(const fl.PortRef('o1', 'text'), const fl.PortRef('im', 'image')),
        isNull,
      );
    });

    test('执行流连线不受数据类型影响', () {
      final c = typedController();
      expect(
        c.connect(const fl.PortRef('st', 'out'), const fl.PortRef('m', 'in')),
        isNotNull,
      );
    });
  });
}
