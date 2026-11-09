import 'package:bluedot_clicker/core/theme.dart';
import 'package:bluedot_clicker/models/blueprint.dart';
import 'package:bluedot_clicker/state/providers.dart';
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

  Future<void> pumpPanel(WidgetTester tester, {ProviderContainer? container}) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container ?? ProviderContainer(),
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

  group('鼠标节点排版与坐标操作按钮', () {
    testWidgets('旧版独立「屏幕坐标拾取」区已删除，坐标上方有拾取/定位两按钮', (tester) async {
      await pumpPanel(tester);

      expect(find.text('屏幕坐标拾取'), findsNothing);
      expect(find.byIcon(Icons.my_location_rounded), findsOneWidget);
      expect(find.text('拾取坐标'), findsOneWidget);
      expect(find.text('屏幕定位'), findsOneWidget);
    });

    testWidgets('字段顺序：动作 → 鼠标键 → X/Y', (tester) async {
      await pumpPanel(tester);

      final actionY = tester.getTopLeft(find.text('动作')).dy;
      final buttonY = tester.getTopLeft(find.text('鼠标键')).dy;
      // 「X 坐标」也是端口说明区的端口名，用 TextField 精确取参数输入框位置
      final xY = tester
          .getTopLeft(find.widgetWithText(TextField, 'X 坐标'))
          .dy;
      expect(actionY, lessThan(buttonY));
      expect(buttonY, lessThan(xY));
    });

    testWidgets('滚轮动作：无鼠标键，坐标上方仍是一组拾取/定位按钮', (tester) async {
      controller.updateNode(
        'n1',
        (n) => n.withData(const {'action': 'scroll'}),
      );
      await pumpPanel(tester);

      expect(find.text('鼠标键'), findsNothing);
      expect(find.text('滚轮水平滚动'), findsOneWidget);
      expect(find.text('滚轮垂直滚动'), findsOneWidget);
      expect(find.text('拾取坐标'), findsOneWidget);
      expect(find.text('屏幕定位'), findsOneWidget);
    });

    testWidgets('拖拽：起点/终点各一组按钮，方向模式只保留起点', (tester) async {
      controller.updateNode(
        'n1',
        (n) => n.withData(const {'action': 'swipe'}),
      );
      await pumpPanel(tester);
      expect(find.text('拾取坐标'), findsNWidgets(2));
      expect(find.text('屏幕定位'), findsNWidgets(2));

      controller.updateNode(
        'n1',
        (n) => n.withData(const {'action': 'swipe', 'mode': 'direction'}),
      );
      await tester.pumpAndSettle();
      expect(find.text('拾取坐标'), findsOneWidget);
      expect(find.text('屏幕定位'), findsOneWidget);
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

    testWidgets('拾取/定位按钮位于坐标输入框上方且各占一半宽度', (tester) async {
      await pumpPanel(tester);
      final pick = tester.getRect(find.byTooltip('拾取坐标'));
      final locate = tester.getRect(find.byTooltip('在屏幕上拖动图标设置坐标'));
      final field = tester.getRect(find.widgetWithText(TextField, 'X 坐标'));
      expect(pick.top, locate.top, reason: '两个按钮同一行');
      expect(
        (pick.width - locate.width).abs(),
        lessThan(0.5),
        reason: '两个按钮各占一半宽度',
      );
      expect(pick.right, lessThan(locate.left), reason: '拾取在左，定位在右');
      expect(
        pick.bottom,
        lessThanOrEqualTo(field.top),
        reason: '按钮行应位于坐标输入框上方',
      );
    });

    testWidgets('条件判断：只保留左右常量，不再有变量名参数', (tester) async {
      addAndSelect('condition', 'c1');
      await pumpPanel(tester);
      expect(find.text('左值(无连接时)'), findsOneWidget);
      expect(find.text('右值(无连接时)'), findsOneWidget);
      expect(find.text('左值变量名(可空)'), findsNothing);
      expect(find.text('右值变量名(可空)'), findsNothing);
      expect(find.widgetWithText(TextField, '左值(无连接时)'), findsOneWidget);
      expect(find.widgetWithText(TextField, '右值(无连接时)'), findsOneWidget);
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

    testWidgets('截图节点：端口说明包含区域角点输入与图像输出', (tester) async {
      addAndSelect('screenshot', 's1');
      await pumpPanel(tester);
      await tester.scrollUntilVisible(
        find.text('端口说明'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('输入'), findsOneWidget);
      expect(find.text('输出'), findsOneWidget);
      expect(
        find.text('截取的屏幕图像，可连接「文字识别/图像识别」的图像输入'),
        findsOneWidget,
      );
      // 两角点区域输入说明
      expect(find.textContaining('仅勾选「仅指定区域」时生效'), findsWidgets);
    });

    testWidgets('媒体节点框选按钮与坐标拾取按钮互不干扰', (tester) async {
      addAndSelect('screenshot', 's1');
      await pumpPanel(tester);
      expect(find.byIcon(Icons.crop_free_rounded), findsOneWidget);
      expect(find.byIcon(Icons.my_location_rounded), findsNothing);
    });
  });

  group('坐标数据输入锁定', () {
    var srcIndex = 0;

    /// 用 setVar 作为数据源，把 valueOut 接到 mouse 节点的指定输入端口
    void connectSource(String port) {
      final id = 'src${srcIndex++}';
      controller.addNode(
        blueprintNodeRegistry.instantiate(
          'setVar',
          id: id,
          position: const Offset(0, 300),
        ),
      );
      controller.connect(
        fl.PortRef(id, 'valueOut'),
        fl.PortRef('n1', port),
      );
    }

    testWidgets('X 输入已连接：X 坐标禁用并加锁图标，Y 坐标不受影响', (tester) async {
      connectSource('x');
      await pumpPanel(tester);

      expect(find.text('X 坐标（锁定）'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Y 坐标'),
        findsOneWidget,
        reason: 'Y 未连接不应锁定（端口说明区的端口名不算）',
      );
      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);

      final xField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'X 坐标（锁定）'),
      );
      expect(xField.enabled, isFalse);
      final yField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Y 坐标'),
      );
      expect(yField.enabled, isNot(isFalse), reason: 'Y 未连接应保持可编辑');
    });

    testWidgets('X/Y 均连接：两个坐标都锁定，拾取与屏幕定位按钮隐藏', (tester) async {
      connectSource('x');
      connectSource('y');
      await pumpPanel(tester);

      expect(find.byIcon(Icons.lock_outline_rounded), findsNWidgets(2));
      expect(find.text('拾取坐标'), findsNothing);
      expect(find.text('屏幕定位'), findsNothing);
    });

    testWidgets('未连接任何输入时坐标可编辑且拾取按钮可见', (tester) async {
      await pumpPanel(tester);

      expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);
      expect(find.text('拾取坐标'), findsOneWidget);
      final xField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'X 坐标'),
      );
      expect(xField.enabled, isNot(isFalse));
    });

    testWidgets('锁定与可编辑输入框等高，锁定态保留并显示参数原值', (tester) async {
      controller.updateNode(
        'n1',
        (n) => n.withData(const {'x': -809, 'y': 428}),
      );
      connectSource('x');
      await pumpPanel(tester);

      final locked = tester.getRect(
        find.widgetWithText(TextField, 'X 坐标（锁定）'),
      );
      final editable = tester.getRect(find.widgetWithText(TextField, 'Y 坐标'));
      expect(
        locked.height,
        editable.height,
        reason: '锁定不应把输入框撑高（suffixIcon 默认 48×48 约束所致）',
      );
      expect(find.text('-809'), findsOneWidget,
          reason: '锁定只禁用编辑，参数原值保留并显示');
    });

    testWidgets('解除连接后参数恢复可编辑并保留原值', (tester) async {
      controller.updateNode(
        'n1',
        (n) => n.withData(const {'x': -809, 'y': 428}),
      );
      connectSource('x');
      await pumpPanel(tester);
      expect(find.text('-809'), findsOneWidget);

      controller.removeConnections(
        controller.graph.connectionsOf('n1').map((c) => c.id).toList(),
      );
      await tester.pumpAndSettle();

      expect(find.text('-809'), findsOneWidget, reason: '解锁后仍显示参数真实值');
      expect(
        find.widgetWithText(TextField, 'X 坐标'),
        findsOneWidget,
        reason: '解锁后标签不再带「（锁定）」',
      );
    });
  });

  group('第四轮：varName 下拉与模板图片整行', () {
    testWidgets('获取变量：变量名字段带已有变量下拉，选择后写入参数', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // 下拉来源一：脚本初始变量表（变量面板已初始化的变量）
      final script = BlueprintScript(name: 't')..variables['hp'] = 100;
      container.read(currentScriptProvider.notifier).open(script);
      // 下拉来源二：图中 varName 参数引用的变量
      controller.addNode(
        blueprintNodeRegistry.instantiate('setVar', id: 'sv', position: Offset.zero),
      );
      controller.updateNode('sv', (n) => n.withData({'name': 'score'}));
      controller.addNode(
        blueprintNodeRegistry.instantiate('getVar', id: 'g1', position: Offset.zero),
      );
      controller.selection.selectNode('g1');
      await pumpPanel(tester, container: container);

      final arrow = find.byIcon(Icons.arrow_drop_down_rounded);
      expect(arrow, findsOneWidget, reason: 'varName 字段尾部应有下拉箭头');
      await tester.tap(arrow);
      await tester.pumpAndSettle();
      expect(find.text('hp'), findsOneWidget);
      expect(find.text('score'), findsOneWidget);
      await tester.tap(find.text('hp'));
      await tester.pumpAndSettle();

      expect(controller.graph.nodes['g1']!.data['name'], 'hp');
      expect(find.widgetWithText(TextField, 'hp'), findsOneWidget,
          reason: '选择后输入框同步显示所选变量名');
    });

    testWidgets('数据保存：文件名字段带扩展名提示', (tester) async {
      controller.addNode(
        blueprintNodeRegistry.instantiate('saveData', id: 'sd', position: Offset.zero),
      );
      controller.selection.selectNode('sd');
      await pumpPanel(tester);

      final field = find.widgetWithText(TextField, '保存文件名');
      expect(field, findsOneWidget);
      expect(find.text('不含扩展名'), findsOneWidget);
    });

    testWidgets('图像识别：选择图片整行显示文件名（文件不存在不显示预览）', (tester) async {
      controller.addNode(
        blueprintNodeRegistry.instantiate('imageMatch', id: 'im1', position: Offset.zero),
      );
      controller.selection.selectNode('im1');
      controller.updateNode('im1', (n) => n.withData({'templatePath': 'C:/pics/target.png'}));
      await pumpPanel(tester);

      final btn = find.widgetWithText(OutlinedButton, 'target.png');
      expect(btn, findsOneWidget);
      final rect = tester.getRect(btn);
      // 测试视口默认 800 宽，整宽按钮应接近视口全宽（减去面板 padding 28）
      expect(rect.width, greaterThan(750), reason: '选择图片应整宽独占一行');
      // 文件不存在（C:/pics/target.png）：不显示预览
      expect(find.byType(Image), findsNothing);
    });
  });

  group('第五轮：识别文本输入锁定与文件名截断', () {
    testWidgets('文字识别：「目标文本」连接输入后锁定并保留原值', (tester) async {
      controller.addNode(
        blueprintNodeRegistry.instantiate('ocr', id: 'o1', position: Offset.zero),
      );
      controller.selection.selectNode('o1');
      // 未连接：参数可编辑、无下拉箭头（string 类型无已有变量建议）
      await pumpPanel(tester);
      final field = find.widgetWithText(TextField, '目标文本');
      expect(field, findsOneWidget);
      expect(
        tester.widget<TextField>(field).decoration?.suffixIcon,
        isNull,
        reason: '目标文本为 string 字段，不应有已有变量下拉',
      );

      // 连接上游数据 → 参数锁定只读
      controller.addNode(
        blueprintNodeRegistry.instantiate('setVar', id: 'src', position: const Offset(0, 300)),
      );
      final connId = controller.connect(
        fl.PortRef('src', 'valueOut'),
        fl.PortRef('o1', 'targetText'),
      );
      expect(connId, isNotNull, reason: '诊断：连接应建立');
      await tester.pumpAndSettle();

      expect(find.text('目标文本（锁定）'), findsOneWidget);
      final locked = tester.widget<TextField>(
        find.widgetWithText(TextField, '目标文本（锁定）'),
      );
      expect(locked.enabled, isFalse);
      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    });

    testWidgets('图像识别：超长文件名中段截断并保留扩展名，Tooltip 显示完整路径', (tester) async {
      controller.addNode(
        blueprintNodeRegistry.instantiate('imageMatch', id: 'im1', position: Offset.zero),
      );
      controller.selection.selectNode('im1');
      const longName = '屏幕截图_2026年11月08日_100021_windows.png';
      controller.updateNode('im1', (n) => n.withData({'templatePath': 'C:/pics/$longName'}));
      await pumpPanel(tester);

      // 按钮文本保留头部 + 省略号 + 扩展名（而不是「屏幕…」丢掉类型信息）
      expect(find.text('屏幕截图_2026年….png'), findsOneWidget,
          reason: '长文件名应中段截断并保留 .png 扩展名');
      // 悬浮提示显示完整路径
      expect(find.byTooltip('C:/pics/$longName'), findsOneWidget);
    });
  });
}
