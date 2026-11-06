import '../models/blueprint.dart';

/// 内置示例脚本：开始 → 设置变量 → 循环(3次){ 延时 → 点击 → 设置变量 } → 结束
///
/// 演示脚本类/逻辑类/数据类节点与执行流连线的组织方式，
/// 不依赖图像识别，安全可跑。
BlueprintScript buildDemoScript() {
  final nodes = <String, BPNode>{
    'demo_start': BPNode(id: 'demo_start', type: 'start', x: 80, y: 60),
    'demo_setvar1': BPNode(
      id: 'demo_setvar1',
      type: 'setVar',
      x: 80,
      y: 200,
      params: {'name': 'myVar', 'const': '0'},
    ),
    'demo_loop': BPNode(
      id: 'demo_loop',
      type: 'loop',
      x: 80,
      y: 340,
      params: {'count': 3},
    ),
    'demo_delay': BPNode(
      id: 'demo_delay',
      type: 'delay',
      x: 340,
      y: 480,
      params: {'ms': 500},
    ),
    'demo_click': BPNode(
      id: 'demo_click',
      type: 'mouse',
      x: 340,
      y: 620,
      params: {'action': 'click', 'x': 500, 'y': 400, 'button': 'left'},
    ),
    'demo_setvar2': BPNode(
      id: 'demo_setvar2',
      type: 'setVar',
      x: 600,
      y: 760,
      params: {'name': 'myVar', 'const': 'step'},
    ),
  };

  final edges = <String, BPEdge>{
    'demo_e1': BPEdge(
      id: 'demo_e1',
      from: const PortRef(nodeId: 'demo_start', port: 'out'),
      to: const PortRef(nodeId: 'demo_setvar1', port: 'in'),
      kind: EdgeKind.exec,
    ),
    'demo_e2': BPEdge(
      id: 'demo_e2',
      from: const PortRef(nodeId: 'demo_setvar1', port: 'out'),
      to: const PortRef(nodeId: 'demo_loop', port: 'enter'),
      kind: EdgeKind.exec,
    ),
    'demo_e3': BPEdge(
      id: 'demo_e3',
      from: const PortRef(nodeId: 'demo_loop', port: 'body'),
      to: const PortRef(nodeId: 'demo_delay', port: 'in'),
      kind: EdgeKind.exec,
    ),
    'demo_e4': BPEdge(
      id: 'demo_e4',
      from: const PortRef(nodeId: 'demo_delay', port: 'out'),
      to: const PortRef(nodeId: 'demo_click', port: 'in'),
      kind: EdgeKind.exec,
    ),
    'demo_e5': BPEdge(
      id: 'demo_e5',
      from: const PortRef(nodeId: 'demo_click', port: 'out'),
      to: const PortRef(nodeId: 'demo_setvar2', port: 'in'),
      kind: EdgeKind.exec,
    ),
    // 循环体最后节点连回 continue 输入，形成闭环
    'demo_e6': BPEdge(
      id: 'demo_e6',
      from: const PortRef(nodeId: 'demo_setvar2', port: 'out'),
      to: const PortRef(nodeId: 'demo_loop', port: 'continue'),
      kind: EdgeKind.exec,
    ),
  };

  return BlueprintScript(
    name: '示例 · 循环点击演示',
    nodes: nodes,
    edges: edges,
    variables: {'myVar': '0'},
  );
}
