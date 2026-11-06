import 'package:bluedot_clicker/ui/editor/node_bridge.dart';
import 'package:bluedot_clicker/ui/editor/property_panel.dart';
import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late fl.NodeEditorController controller;

  setUp(() {
    controller = fl.NodeEditorController(definitions: blueprintNodeRegistry);
    controller.addNode(
      blueprintNodeRegistry.instantiate('mouse', id: 'n1', position: Offset.zero),
    );
    controller.selection.selectNode('n1');
  });

  tearDown(() {
    controller.dispose();
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: ProviderContainer(),
      child: MaterialApp(
        home: Scaffold(
          body: PropertyPanel(controller: controller),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('参数输入撤销折叠（焦点事务）', () {
    testWidgets('整段输入折叠为一条撤销记录，一次 undo 全部回退', (tester) async {
      await pumpPanel(tester);

      // 定位 X 坐标输入框并聚焦
      final xField = find.widgetWithText(TextField, 'X 坐标');
      expect(xField, findsOneWidget);
      await tester.tap(xField);
      await tester.pump();

      // 模拟逐键输入 5 个字符（每次 updateEditingValue 触发一次 onChanged → 一次 updateNode）
      var text = '100';
      for (final ch in ['1', '2', '3', '4', '5']) {
        text += ch;
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
        );
        await tester.pump();
      }

      // 失焦：提交事务
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      expect(controller.graph.nodes['n1']!.data['x'], 10012345);
      expect(controller.history.canUndo, isTrue);

      // 关键断言：修复前每键一条撤销记录，undo 一次只回退一个字符（1001234）；
      // 修复后整段输入是一条记录，一次 undo 回到初始值 100
      controller.history.undo();
      expect(controller.graph.nodes['n1']!.data['x'], 100,
          reason: '一次 undo 应回退整段输入，而不是单个字符');
      // 文本同步回显（x/y 默认值均为 100）
      await tester.pump();
      expect(find.text('100'), findsNWidgets(2));
    });

    testWidgets('空输入聚焦再失焦不产生撤销记录', (tester) async {
      await pumpPanel(tester);
      final before = controller.history.canUndo;

      await tester.tap(find.widgetWithText(TextField, 'X 坐标'));
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      // 无编辑时 baseline == graph，commitTransaction 不产生记录
      expect(controller.history.canUndo, before);
    });
  });

  group('外部写入同步', () {
    testWidgets('节点值被外部改写（如坐标拾取）后文本框同步显示', (tester) async {
      await pumpPanel(tester);

      // x/y 默认值均为 100
      expect(find.text('100'), findsNWidgets(2));

      // 模拟坐标拾取写回：controller.updateNode 直接改数据
      controller.updateNode('n1', (n) => n.withData(const {'x': 640, 'y': 360}));
      await tester.pumpAndSettle();

      expect(controller.graph.nodes['n1']!.data['x'], 640);
      expect(find.text('640'), findsOneWidget);
      expect(find.text('360'), findsOneWidget);
      expect(find.text('100'), findsNothing);
    });
  });
}
