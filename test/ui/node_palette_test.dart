import 'package:bluedot_clicker/models/blueprint.dart';
import 'package:bluedot_clicker/state/providers.dart';
import 'package:bluedot_clicker/ui/editor/node_bridge.dart';
import 'package:bluedot_clicker/ui/editor/node_palette.dart';
import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late fl.NodeEditorController controller;
  late ProviderContainer container;

  setUp(() {
    controller = fl.NodeEditorController(definitions: blueprintNodeRegistry);
    container = ProviderContainer();
  });

  tearDown(() {
    container.dispose();
    controller.dispose();
  });

  /// 打开一个带初始变量的脚本（变量面板数据源）
  void openScriptWithVars(Map<String, Object> variables) {
    container.read(currentScriptProvider.notifier).open(
          BlueprintScript(name: 't')..variables.addAll(variables),
        );
  }

  Future<void> pumpPalette(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: NodePalette(controller: controller)),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 展开节点库的「变量」分类
  Future<void> expandVariables(WidgetTester tester) async {
    await tester.tap(find.text('变量'));
    await tester.pumpAndSettle();
  }

  group('节点库「变量」分类', () {
    testWidgets('位于「数据」分类下方', (tester) async {
      await pumpPalette(tester);
      // 两个分类都存在
      expect(find.text('数据'), findsOneWidget);
      expect(find.text('变量'), findsOneWidget);
      final dataTile = tester.getTopLeft(find.text('数据'));
      final varTile = tester.getTopLeft(find.text('变量'));
      expect(varTile.dy, greaterThan(dataTile.dy), reason: '变量分类在数据分类之后');
    });

    testWidgets('展开显示已初始化的变量与图中引用的变量', (tester) async {
      openScriptWithVars({'hp': 100});
      controller.addNode(
        blueprintNodeRegistry.instantiate('setVar', id: 'sv', position: Offset.zero),
      );
      controller.updateNode('sv', (n) => n.withData({'name': 'score'}));
      await pumpPalette(tester);
      await expandVariables(tester);

      expect(find.text('hp'), findsOneWidget, reason: '变量面板已初始化的变量应显示');
      expect(find.text('score'), findsOneWidget, reason: '图中 varName 引用的变量应显示');
      // 初始值输入框显示已初始化的值
      expect(find.widgetWithText(TextField, '100'), findsOneWidget);
      expect(find.text('新建变量'), findsOneWidget);
    });

    testWidgets('初始值失焦提交后写入变量表', (tester) async {
      openScriptWithVars({'hp': 100});
      await pumpPalette(tester);
      await expandVariables(tester);

      final initField = find.widgetWithText(TextField, '100');
      await tester.tap(initField);
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(text: '200'),
      );
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      expect(container.read(scriptVariablesProvider)['hp'], 200);
    });

    testWidgets('点击变量名在画布创建预填的「获取变量」节点', (tester) async {
      openScriptWithVars({'hp': 100});
      await pumpPalette(tester);
      await expandVariables(tester);

      await tester.tap(find.text('hp'));
      await tester.pumpAndSettle();

      final created = controller.graph.nodes.values
          .where((n) => n.type == 'getVar')
          .toList();
      expect(created.length, 1);
      expect(created.single.data['name'], 'hp');
    });

    testWidgets('「新建变量」对话框写入变量表', (tester) async {
      await pumpPalette(tester);
      await expandVariables(tester);

      // 「新建变量」入口在列表底部，先滚动到可见再点击
      await tester.ensureVisible(find.text('新建变量'));
      await tester.pump();
      await tester.tap(find.text('新建变量'), warnIfMissed: false);
      await tester.pumpAndSettle();

      final nameField = find.widgetWithText(TextField, '变量名');
      await tester.enterText(nameField, 'gold');
      final initField = find.widgetWithText(TextField, '初始值（可空）');
      await tester.enterText(initField, '50');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(container.read(scriptVariablesProvider)['gold'], 50);
      // 新变量出现在列表中
      expect(find.text('gold'), findsOneWidget);
    });

    testWidgets('无变量时显示空状态提示', (tester) async {
      await pumpPalette(tester);
      await expandVariables(tester);
      expect(find.text('暂无变量：用「设置变量」节点、或在此新建'), findsOneWidget);
    });

    testWidgets('新建变量初始值为空也创建成功（值为空字符串）', (tester) async {
      await pumpPalette(tester);
      await expandVariables(tester);
      await tester.ensureVisible(find.text('新建变量'));
      await tester.pump();
      await tester.tap(find.text('新建变量'), warnIfMissed: false);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, '变量名'), 'gold');
      // 初始值留空，直接确定
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(container.read(scriptVariablesProvider)['gold'], '',
          reason: '空初始值也应把变量登记进变量表');
      expect(find.text('gold'), findsOneWidget, reason: '变量应出现在列表中');
    });

    testWidgets('删除按钮移除变量初始值，图中仍引用时给出提示', (tester) async {
      openScriptWithVars({'hp': 100});
      // 图中 setVar 节点引用 score（删除 score 后应出现提示）
      controller.addNode(
        blueprintNodeRegistry.instantiate('setVar', id: 'sv', position: Offset.zero),
      );
      controller.updateNode('sv', (n) => n.withData({'name': 'score'}));
      await pumpPalette(tester);
      await expandVariables(tester);

      // hp 行的删除按钮（列表按字母排序，hp 在 score 前）
      await tester.tap(find.byTooltip('删除变量').first);
      await tester.pumpAndSettle();
      expect(container.read(scriptVariablesProvider).containsKey('hp'), isFalse);
      expect(find.text('hp'), findsNothing, reason: '无引用的变量从列表移除');

      // score 行的删除按钮（列表顺序按字母：hp < score，删除后 score 行的按钮是剩下的第一个）
      await tester.tap(find.byTooltip('删除变量').first);
      await tester.pumpAndSettle();
      expect(
        find.text('图中仍有节点引用 score，变量仍会显示在列表中'),
        findsOneWidget,
      );
    });
  });
}
