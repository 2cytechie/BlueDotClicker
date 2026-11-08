import '../models/blueprint.dart';

/// 内置示例脚本：条件循环计数器
///
/// 开始 → 设置变量(count=0)
///      → 循环（count < 10）
///           ├─ 真 → 加法(count + 1) → 设置变量(count) → 延时 → 循环.in
///           └─ 假 → 结束
///
/// 演示条件循环、纯数据节点（获取变量）、加法与数据边连线，
/// 不依赖图像识别与鼠标操作，安全可跑。
BlueprintScript buildDemoScript() {
  final nodes = <String, BPNode>{
    'demo_start': BPNode(id: 'demo_start', type: 'start', x: 80, y: 60),
    'demo_setvar1': BPNode(
      id: 'demo_setvar1',
      type: 'setVar',
      x: 80,
      y: 200,
      params: {'name': 'count', 'const': '0'},
    ),
    'demo_loop': BPNode(
      id: 'demo_loop',
      type: 'loop',
      x: 80,
      y: 340,
      params: {
        'op': '<',
        'leftConst': '0',
        'rightConst': '10',
        'maxIterations': 0,
      },
    ),
    'demo_getvar': BPNode(
      id: 'demo_getvar',
      type: 'getVar',
      x: 80,
      y: 500,
      params: {'name': 'count'},
    ),
    'demo_add': BPNode(
      id: 'demo_add',
      type: 'add',
      x: 340,
      y: 480,
      params: {'a': 0, 'b': 1},
    ),
    'demo_setvar2': BPNode(
      id: 'demo_setvar2',
      type: 'setVar',
      x: 340,
      y: 620,
      params: {'name': 'count', 'const': ''},
    ),
    'demo_delay': BPNode(
      id: 'demo_delay',
      type: 'delay',
      x: 340,
      y: 760,
      params: {'ms': 100},
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
      to: const PortRef(nodeId: 'demo_loop', port: 'in'),
      kind: EdgeKind.exec,
    ),
    // 条件成立 → 循环体：加法 → 设置变量 → 延时
    'demo_e3': BPEdge(
      id: 'demo_e3',
      from: const PortRef(nodeId: 'demo_loop', port: 'true'),
      to: const PortRef(nodeId: 'demo_add', port: 'in'),
      kind: EdgeKind.exec,
    ),
    'demo_e4': BPEdge(
      id: 'demo_e4',
      from: const PortRef(nodeId: 'demo_add', port: 'out'),
      to: const PortRef(nodeId: 'demo_setvar2', port: 'in'),
      kind: EdgeKind.exec,
    ),
    'demo_e5': BPEdge(
      id: 'demo_e5',
      from: const PortRef(nodeId: 'demo_setvar2', port: 'out'),
      to: const PortRef(nodeId: 'demo_delay', port: 'in'),
      kind: EdgeKind.exec,
    ),
    // 循环体末尾连回 in，形成闭环
    'demo_e6': BPEdge(
      id: 'demo_e6',
      from: const PortRef(nodeId: 'demo_delay', port: 'out'),
      to: const PortRef(nodeId: 'demo_loop', port: 'in'),
      kind: EdgeKind.exec,
    ),
    // 加法 A ← 获取变量(count)；结果 ← 加法.result
    'demo_d1': BPEdge(
      id: 'demo_d1',
      from: const PortRef(nodeId: 'demo_getvar', port: 'value'),
      to: const PortRef(nodeId: 'demo_add', port: 'a'),
      kind: EdgeKind.data,
    ),
    'demo_d2': BPEdge(
      id: 'demo_d2',
      from: const PortRef(nodeId: 'demo_add', port: 'result'),
      to: const PortRef(nodeId: 'demo_setvar2', port: 'value'),
      kind: EdgeKind.data,
    ),
    // 循环左值读循环体内刚写入的新值（首轮无缓存时用 leftConst=0）
    'demo_d3': BPEdge(
      id: 'demo_d3',
      from: const PortRef(nodeId: 'demo_setvar2', port: 'valueOut'),
      to: const PortRef(nodeId: 'demo_loop', port: 'left'),
      kind: EdgeKind.data,
    ),
  };

  return BlueprintScript(
    name: '示例 · 条件循环计数',
    nodes: nodes,
    edges: edges,
    variables: {'count': 0},
  );
}
