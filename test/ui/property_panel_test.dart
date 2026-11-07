import 'package:bluedot_clicker/core/theme.dart';
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

  group('鼠标节点排版与内联拾取', () {
    testWidgets('旧版独立「屏幕坐标拾取」区已删除，拾取入口在坐标行尾', (tester) async {
      await pumpPanel(tester);

      expect(find.text('屏幕坐标拾取'), findsNothing);
      expect(find.byIcon(Icons.my_location_rounded), findsOneWidget);
      expect(find.byTooltip('拾取坐标'), findsOneWidget);
    });

    testWidgets('字段顺序：动作 → 鼠标键 → X/Y', (tester) async {
      await pumpPanel(tester);

      final actionY = tester.getTopLeft(find.text('动作')).dy;
      final buttonY = tester.getTopLeft(find.text('鼠标键')).dy;
      final xY = tester.getTopLeft(find.text('X 坐标')).dy;
      expect(actionY, lessThan(buttonY));
      expect(buttonY, lessThan(xY));
    });

    testWidgets('滚轮动作：无鼠标键，坐标行尾仅一个拾取按钮', (tester) async {
      controller.updateNode(
        'n1',
        (n) => n.withData(const {'action': 'scroll'}),
      );
      await pumpPanel(tester);

      expect(find.text('鼠标键'), findsNothing);
      expect(find.text('滚轮水平(120=一格,正=右)'), findsOneWidget);
      expect(find.text('滚轮垂直(120=一格,正=上)'), findsOneWidget);
      expect(find.byIcon(Icons.my_location_rounded), findsOneWidget);
    });

    testWidgets('滑动：起点/终点各一个拾取按钮，方向模式只保留起点', (tester) async {
      controller.updateNode(
        'n1',
        (n) => n.withData(const {'action': 'swipe'}),
      );
      await pumpPanel(tester);
      expect(find.byIcon(Icons.my_location_rounded), findsNWidgets(2));

      controller.updateNode(
        'n1',
        (n) => n.withData(const {'action': 'swipe', 'mode': 'direction'}),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.my_location_rounded), findsOneWidget);
      expect(find.text('终点X'), findsNothing);
      expect(find.text('方向角(度,0=右,逆时针)'), findsOneWidget);
    });

    testWidgets('键盘节点：独立键位拾取区已删除，拾取按钮内联到按键字段行尾', (tester) async {
      controller.addNode(
        blueprintNodeRegistry.instantiate(
          'keyboard',
          id: 'k1',
          position: Offset.zero,
        ),
      );
      controller.selection.selectNode('k1');
      await pumpPanel(tester);

      // 无坐标拾取按钮、无独立键位拾取区
      expect(find.byIcon(Icons.my_location_rounded), findsNothing);
      expect(find.text('键位拾取'), findsNothing);
      // tap 动作：按键下拉行尾内联拾取按钮（keyboard_rounded 出现 2 次：
      // 面板头部节点图标 + 拾取按钮图标，故用 tooltip 精确断言）
      expect(find.byTooltip('拾取按键'), findsOneWidget);

      // combo 动作：标题行尾拾取组合键按钮
      controller.updateNode('k1', (n) => n.withData(const {'action': 'combo'}));
      await tester.pumpAndSettle();
      expect(find.byTooltip('拾取组合键'), findsOneWidget);
    });

    testWidgets('媒体节点：区域X/Y 行尾有框选按钮，非媒体节点没有', (tester) async {
      controller.addNode(
        blueprintNodeRegistry.instantiate(
          'screenshot',
          id: 's1',
          position: Offset.zero,
        ),
      );
      controller.selection.selectNode('s1');
      await pumpPanel(tester);

      expect(find.byIcon(Icons.crop_free_rounded), findsOneWidget);
      expect(find.byTooltip('框选区域'), findsOneWidget);
      // 截图节点不再有 image 数据输入端口说明中提到输入
      expect(find.text('端口说明'), findsOneWidget);

      // 鼠标节点（非媒体）无框选按钮
      controller.selection.selectNode('n1');
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.crop_free_rounded), findsNothing);
    });

    testWidgets('OCR 节点：端口说明分输入/输出且只列数据端口', (tester) async {
      controller.addNode(
        blueprintNodeRegistry.instantiate(
          'ocr',
          id: 'o1',
          position: Offset.zero,
        ),
      );
      controller.selection.selectNode('o1');
      await pumpPanel(tester);

      expect(find.text('端口说明'), findsOneWidget);
      expect(find.text('输入'), findsOneWidget);
      expect(find.text('输出'), findsOneWidget);
      // 4 条数据端口说明：图像、文本、区域X、区域Y（无执行流条目）
      expect(find.text('识别出的完整文本（字符串），可连接下游节点的数据输入'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_rounded), findsNothing);
    });

    testWidgets('下拉弹出层使用统一暗色圆角样式', (tester) async {
      await pumpPanel(tester);

      final dropdowns = tester
          .widgetList<DropdownButton<String>>(find.byType(DropdownButton<String>))
          .toList();
      expect(dropdowns.length, 2); // 动作 + 鼠标键
      for (final d in dropdowns) {
        expect(d.dropdownColor, AppColors.moonWhite);
        expect(d.borderRadius, kDropdownMenuRadius);
      }
    });
  });

  group('第二轮排版与端口说明', () {
    void addAndSelect(String type, String id) {
      controller.addNode(
        blueprintNodeRegistry.instantiate(type, id: id, position: Offset.zero),
      );
      controller.selection.selectNode(id);
    }

    testWidgets('坐标拾取按钮与输入框垂直居中', (tester) async {
      await pumpPanel(tester);
      final fieldCenter = tester.getCenter(
        find.widgetWithText(TextField, 'X 坐标'),
      );
      final buttonCenter = tester.getCenter(find.byTooltip('拾取坐标'));
      expect(
        (fieldCenter.dy - buttonCenter.dy).abs(),
        lessThan(6),
        reason: '按钮图标中心应与输入框中心对齐（计划第 1 项）',
      );
    });

    testWidgets('条件判断：左值/右值各自并排一行', (tester) async {
      addAndSelect('condition', 'c1');
      await pumpPanel(tester);
      double dy(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(dy('左值变量名(可空)'), dy('左值常量(无连接/变量时)'));
      expect(dy('右值变量名(可空)'), dy('右值常量(无连接/变量时)'));
      expect(dy('左值变量名(可空)'), lessThan(dy('右值变量名(可空)')));
    });

    testWidgets('数据存取：存储键与关联变量名并排', (tester) async {
      addAndSelect('storage', 'st1');
      await pumpPanel(tester);
      expect(
        tester.getTopLeft(find.text('存储键')).dy,
        tester.getTopLeft(find.text('关联变量名')).dy,
      );
    });

    testWidgets('设置变量：变量名与常量并排', (tester) async {
      addAndSelect('setVar', 'sv1');
      await pumpPanel(tester);
      // 「变量名」同时是标签与 varName 字段的 hint，按 labelText 精确定位输入框
      TextField byLabel(String label) => tester
          .widgetList<TextField>(find.byType(TextField))
          .firstWhere((f) => f.decoration?.labelText == label);
      expect(
        tester.getTopLeft(find.byWidget(byLabel('变量名'))).dy,
        tester.getTopLeft(find.byWidget(byLabel('常量值(无连接时)'))).dy,
      );
    });

    testWidgets('图像识别：命中X/命中Y 变量并排', (tester) async {
      addAndSelect('imageMatch', 'im1');
      await pumpPanel(tester);
      await tester.scrollUntilVisible(
        find.text('命中Y存入变量'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.getTopLeft(find.text('命中X存入变量')).dy,
        tester.getTopLeft(find.text('命中Y存入变量')).dy,
      );
    });

    testWidgets('截图节点：端口说明只有输出图像，不含输入端口', (tester) async {
      addAndSelect('screenshot', 's1');
      await pumpPanel(tester);
      await tester.scrollUntilVisible(
        find.text('端口说明'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('输入'), findsNothing);
      expect(find.text('输出'), findsOneWidget);
      expect(
        find.text('截取的屏幕图像，可连接「文字识别/图像识别」的图像输入'),
        findsOneWidget,
      );
    });

    testWidgets('媒体节点框选按钮与坐标拾取按钮互不干扰', (tester) async {
      addAndSelect('screenshot', 's1');
      await pumpPanel(tester);
      expect(find.byIcon(Icons.crop_free_rounded), findsOneWidget);
      expect(find.byIcon(Icons.my_location_rounded), findsNothing);
    });
  });
}
