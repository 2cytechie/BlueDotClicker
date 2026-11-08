import 'package:bluedot_clicker/ui/editor/node_body.dart';
import 'package:bluedot_clicker/ui/editor/node_bridge.dart';
import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// M-12：开始节点跨轮提示（每轮清空端口缓存/截图，变量跨轮保留）
/// 以及循环节点摘要「数据边优先、常量兜底」的回归测试。
void main() {
  const crossRoundHint = '每轮清空端口缓存/截图，变量跨轮保留';

  fl.NodeRenderState state([Set<String> connectedPorts = const {}]) =>
      fl.NodeRenderState(
        isSelected: false,
        isHovered: false,
        isDragging: false,
        isConnectionTarget: false,
        connectedPorts: connectedPorts,
      );

  Future<void> pumpNode(
    WidgetTester tester,
    fl.GraphNode node, [
    Set<String> connectedPorts = const {},
  ]) async {
    final builder = nodeBodyBuilder();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: Builder(
                builder: (context) => builder(context, node, state(connectedPorts)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('开始节点：旧脚本无 count 参数时按 1 次处理，不显示跨轮提示', (
    tester,
  ) async {
    final node = blueprintNodeRegistry.instantiate('start', position: Offset.zero, id: 's1');
    await pumpNode(tester, node);
    expect(find.textContaining(crossRoundHint), findsNothing);
    expect(find.textContaining('执行 1 次'), findsOneWidget);
  });

  testWidgets('开始节点：count=1 不显示跨轮提示', (tester) async {
    final node = blueprintNodeRegistry
        .instantiate('start', position: Offset.zero, id: 's2')
        .withData({'count': 1});
    await pumpNode(tester, node);
    expect(find.textContaining(crossRoundHint), findsNothing);
  });

  testWidgets('开始节点：count=0（一直执行）显示跨轮提示', (tester) async {
    final node = blueprintNodeRegistry
        .instantiate('start', position: Offset.zero, id: 's3')
        .withData({'count': 0});
    await pumpNode(tester, node);
    expect(find.textContaining(crossRoundHint), findsOneWidget);
    expect(find.textContaining('一直执行'), findsOneWidget);
  });

  testWidgets('开始节点：count=2 显示跨轮提示', (tester) async {
    final node = blueprintNodeRegistry
        .instantiate('start', position: Offset.zero, id: 's4')
        .withData({'count': 2});
    await pumpNode(tester, node);
    expect(find.textContaining(crossRoundHint), findsOneWidget);
    expect(find.textContaining('执行 2 次'), findsOneWidget);
  });

  testWidgets('循环节点：左右值均未连接时兜底显示常量', (tester) async {
    final node = blueprintNodeRegistry.instantiate('loop', position: Offset.zero, id: 'l1').withData({
      'op': '<',
      'leftConst': '0',
      'rightConst': '10',
    });
    await pumpNode(tester, node);
    // _opLabel 将比较符渲染为中文（如 '<' → 「小于」）
    expect(find.textContaining('当 0 小于 10 时循环'), findsOneWidget);
  });

  testWidgets('循环节点：常量为空且未连接时显示左值/右值占位', (tester) async {
    final node = blueprintNodeRegistry.instantiate('loop', position: Offset.zero, id: 'l2');
    await pumpNode(tester, node);
    expect(find.textContaining('当 左值 等于 右值 时循环'), findsOneWidget);
  });

  testWidgets('循环节点：左值接数据边时摘要显示上游数据（数据边优先）', (tester) async {
    final node = blueprintNodeRegistry.instantiate('loop', position: Offset.zero, id: 'l3').withData({
      'op': '<',
      'leftConst': '0',
      'rightConst': '10',
    });
    await pumpNode(tester, node, {'left'});
    expect(find.textContaining('当 上游数据 小于 10 时循环'), findsOneWidget);
  });

  testWidgets('循环节点：左右值均接数据边时摘要双侧显示上游数据', (tester) async {
    final node = blueprintNodeRegistry.instantiate('loop', position: Offset.zero, id: 'l4').withData({
      'op': 'notContains',
      'leftConst': 'a',
      'rightConst': 'b',
    });
    await pumpNode(tester, node, {'left', 'right'});
    expect(find.textContaining('当 上游数据 不包含 上游数据 时循环'), findsOneWidget);
  });

  testWidgets('循环节点：设置了最大循环次数时摘要显示上限', (tester) async {
    final node = blueprintNodeRegistry.instantiate('loop', position: Offset.zero, id: 'l5').withData({
      'op': '<',
      'leftConst': '0',
      'rightConst': '10',
      'maxIterations': 100,
    });
    await pumpNode(tester, node);
    expect(find.textContaining('最多 100 次'), findsOneWidget);
  });
}
