import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bluedot_clicker/core/theme.dart';
import 'package:bluedot_clicker/models/blueprint.dart';
import 'package:bluedot_clicker/services/template_storage.dart';
import 'package:bluedot_clicker/state/providers.dart';
import 'package:bluedot_clicker/ui/editor/node_bridge.dart';
import 'package:bluedot_clicker/ui/editor/property_panel.dart';
// 用已有插件的平台接口替换原生文件对话框，不新增生产依赖。
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Selector extends FileSelectorPlatform {
  Future<XFile?> Function() select = () async => XFile('C:/external/image.png');
  int calls = 0;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) {
    calls++;
    return select();
  }
}

class _Templates extends TemplateStorage {
  final paths = <String>[];
  Future<String> Function() save = () async => 'C:/managed/templates/hash.png';

  @override
  Future<String> importFile(String sourcePath) {
    paths.add(sourcePath);
    return save();
  }
}

void main() {
  late fl.NodeEditorController controller;
  late ProviderContainer container;
  late _Selector selector;
  late _Templates templates;
  late FileSelectorPlatform originalSelector;
  final previewKey = GlobalKey();

  void select(String type, String id) {
    controller.addNode(
      blueprintNodeRegistry.instantiate(type, id: id, position: Offset.zero),
    );
    controller.selection.selectNode(id);
  }

  setUp(() {
    controller = fl.NodeEditorController(definitions: blueprintNodeRegistry);
    templates = _Templates();
    selector = _Selector();
    originalSelector = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = selector;
    container = ProviderContainer(
      overrides: [
        templateStorageProvider.overrideWithValue(templates),
        recordingsProvider.overrideWith(
          (_) async => [
            Recording(
              id: 'r1',
              name: '录制',
              createdAt: DateTime(2026),
              actions: const [],
            ),
          ],
        ),
      ],
    );
  });
  tearDown(() {
    FileSelectorPlatform.instance = originalSelector;
    container.dispose();
    controller.dispose();
  });

  Future<void> pumpPanel(WidgetTester tester, {double scale = 1}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme().copyWith(
            platform: TargetPlatform.windows,
            visualDensity: VisualDensity.compact,
          ),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: RepaintBoundary(
                  key: previewKey,
                  child: SizedBox(
                    width: 320,
                    child: PropertyPanel(controller: controller),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder textField(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );
  Finder getImageButton() => find.ancestor(
    of: find.byIcon(Icons.image_outlined),
    matching: find.byType(OutlinedButton),
  );

  // InputDecorator 的外层尺寸包含未填充的空间，必须量实际绘制边框的容器。
  Rect fieldContainer(WidgetTester tester, Finder field) {
    final descendants = find.descendant(
      of: field,
      matching: find.byWidgetPredicate((_) => true),
    );
    for (final element in tester.elementList(descendants)) {
      final box = InputDecorator.containerOf(element);
      if (box != null) return box.localToGlobal(Offset.zero) & box.size;
    }
    throw StateError('未找到输入框边框容器');
  }

  Future<void> loadFonts() async {
    final font = FontLoader(kAppFontFamily)
      ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  }

  Future<void> savePreview(WidgetTester tester, String output) async {
    if (output.isEmpty) return;
    final boundary =
        previewKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File(output).writeAsBytes(data.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('使用实际字体渲染设置变量面板', (tester) async {
    await loadFonts();
    await tester.binding.setSurfaceSize(const Size(800, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    select('setVar', 'preview');
    controller.updateNode(
      'preview',
      (n) => n.withData({'name': 'score', 'const': '100'}),
    );
    await pumpPanel(tester);
    expect(tester.getSize(textField('变量名')).height, 44);
    expect(tester.getSize(textField('常量值(无连接时)')).height, 44);
    expect(tester.takeException(), isNull);
    const output = String.fromEnvironment('NODE_FIELDS_SCREENSHOT');
    await savePreview(tester, output);
  });

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('区域坐标的实际边框采用锁定框高度，文字缩放 $scale', (tester) async {
      await loadFonts();
      select('getVar', 'source');
      select('screenshot', 'shot');
      for (final port in ['left', 'top', 'right']) {
        controller.connect(
          const fl.PortRef('source', 'value'),
          fl.PortRef('shot', port),
        );
      }
      await pumpPanel(tester, scale: scale);
      final locked = textField('右下角X');
      final editable = textField('右下角Y');
      final lockedRect = fieldContainer(tester, locked);
      final editableRect = fieldContainer(tester, editable);
      if (scale == 1) {
        expect(lockedRect.height, 32, reason: '保留原锁定框的可见高度');
        const output = String.fromEnvironment('REGION_FIELDS_SCREENSHOT');
        await savePreview(tester, output);
      }
      expect(tester.widget<TextField>(locked).enabled, isFalse);
      expect(tester.widget<TextField>(editable).enabled, isTrue);
      expect(editableRect.top, lockedRect.top);
      expect(editableRect.height, lockedRect.height);
      await tester.enterText(editable, '');
      await tester.pumpAndSettle();
      expect(fieldContainer(tester, editable).height, lockedRect.height);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      controller.removeConnections(
        controller.graph.connections.values.map((c) => c.id).toList(),
      );
      await tester.pumpAndSettle();
      expect(fieldContainer(tester, locked).height, lockedRect.height);
      expect(tester.takeException(), isNull);
    });

    testWidgets('设置变量：实际侧栏宽度下空值/常量/锁定等高，文字缩放 $scale', (tester) async {
      select('setVar', 'sv');
      await pumpPanel(tester, scale: scale);
      final name = textField('变量名');
      final value = textField('常量值(无连接时)');
      final a = tester.getRect(name);
      final b = tester.getRect(value);
      expect(a.top, b.top);
      expect(a.bottom, b.bottom);
      final nameBorder = fieldContainer(tester, name);
      expect(fieldContainer(tester, value).height, nameBorder.height);
      expect(a.height, scale == 1 ? 44 : greaterThan(44));
      expect(find.byIcon(Icons.arrow_drop_down_rounded), findsOneWidget);
      await tester.enterText(name, '');
      await tester.pump();
      expect(find.byIcon(Icons.arrow_drop_down_rounded), findsNothing);
      expect(tester.getSize(name).height, a.height);
      expect(fieldContainer(tester, name).height, nameBorder.height);
      await tester.enterText(name, 'score');
      await tester.pump();
      expect(find.byIcon(Icons.arrow_drop_down_rounded), findsOneWidget);
      await tester.enterText(value, '123');
      await tester.pump();
      expect(tester.getSize(value).height, a.height);
      select('getVar', 'source');
      controller.connect(
        const fl.PortRef('source', 'value'),
        const fl.PortRef('sv', 'value'),
      );
      controller.selection.selectNode('sv');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(value).enabled, isFalse);
      expect(tester.getSize(value).height, a.height);
      expect(fieldContainer(tester, value).height, nameBorder.height);
      controller.removeConnections(
        controller.graph.connections.values.map((c) => c.id).toList(),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(value).enabled, isTrue);
      expect(tester.getSize(value).height, a.height);
      expect(fieldContainer(tester, value).height, nameBorder.height);
      expect(tester.takeException(), isNull);
    });
  }

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('枚举/录制/按键下拉与普通输入框实际边框等高，文字缩放 $scale', (tester) async {
      await loadFonts();
      select('mouse', 'm');
      await pumpPanel(tester, scale: scale);
      final height = tester.getSize(textField('X 坐标')).height;
      final borderHeight = fieldContainer(tester, textField('X 坐标')).height;
      for (final field in tester.widgetList<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>),
      )) {
        expect(tester.getSize(find.byWidget(field)).height, height);
        expect(
          fieldContainer(tester, find.byWidget(field)).height,
          borderHeight,
        );
      }
      select('playRecording', 'r');
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(DropdownButtonFormField<String>)).height,
        height,
      );
      expect(
        fieldContainer(
          tester,
          find.byType(DropdownButtonFormField<String>),
        ).height,
        borderHeight,
      );
      controller.updateNode('r', (n) => n.withData({'recordingId': 'r1'}));
      await tester.pumpAndSettle();
      expect(
        fieldContainer(
          tester,
          find.byType(DropdownButtonFormField<String>),
        ).height,
        borderHeight,
      );
      select('keyboard', 'k');
      await tester.pumpAndSettle();
      for (final field in tester.widgetList<DropdownButtonFormField<int>>(
        find.byType(DropdownButtonFormField<int>),
      )) {
        expect(tester.getSize(find.byWidget(field)).height, height);
        expect(
          fieldContainer(tester, find.byWidget(field)).height,
          borderHeight,
        );
      }
      controller.updateNode('k', (n) => n.withData({'action': 'combo'}));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(DropdownButtonFormField<int>)).height,
        height,
      );
      expect(
        fieldContainer(
          tester,
          find.byType(DropdownButtonFormField<int>),
        ).height,
        borderHeight,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('选图保存成功后引用副本，撤销恢复原路径', (tester) async {
    select('imageMatch', 'im');
    controller.updateNode(
      'im',
      (n) => n.withData({'templatePath': 'C:/old.png'}),
    );
    await pumpPanel(tester);
    await tester.ensureVisible(getImageButton());
    await tester.tap(getImageButton());
    await tester.pumpAndSettle();
    expect(templates.paths, ['C:/external/image.png']);
    expect(
      controller.graph.nodes['im']!.data['templatePath'],
      'C:/managed/templates/hash.png',
    );
    controller.history.undo();
    await tester.pumpAndSettle();
    expect(controller.graph.nodes['im']!.data['templatePath'], 'C:/old.png');
  });

  for (final cancel in [true, false]) {
    testWidgets(cancel ? '取消选图保留原值' : '存储失败提示错误并保留原值', (tester) async {
      select('imageMatch', 'im');
      controller.updateNode(
        'im',
        (n) => n.withData({'templatePath': 'C:/old.png'}),
      );
      if (cancel) {
        selector.select = () async => null;
      } else {
        templates.save = () async => throw StateError('disk full');
      }
      await pumpPanel(tester);
      await tester.ensureVisible(getImageButton());
      await tester.tap(getImageButton());
      await tester.pumpAndSettle();
      expect(controller.graph.nodes['im']!.data['templatePath'], 'C:/old.png');
      expect(
        find.textContaining('图片保存失败'),
        cancel ? findsNothing : findsOneWidget,
      );
      expect(selector.calls, 1);
      if (cancel) expect(templates.paths, isEmpty);
    });
  }

  testWidgets('复制期间重复点击无效，切换节点不提交过期结果', (tester) async {
    select('imageMatch', 'im');
    final complete = Completer<String>();
    templates.save = () => complete.future;
    await pumpPanel(tester);
    await tester.ensureVisible(getImageButton());
    await tester.tap(getImageButton());
    await tester.pump();
    expect(tester.widget<OutlinedButton>(getImageButton()).onPressed, isNull);
    await tester.tap(getImageButton());
    expect(selector.calls, 1);
    select('imageMatch', 'other');
    await tester.pump();
    complete.complete('C:/managed/late.png');
    await tester.pumpAndSettle();
    expect(controller.graph.nodes['im']!.data['templatePath'], isEmpty);
    expect(controller.graph.nodes['other']!.data['templatePath'], isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文件对话框等待期间卸载面板，不导入图片', (tester) async {
    select('imageMatch', 'im');
    final complete = Completer<XFile?>();
    selector.select = () => complete.future;
    await pumpPanel(tester);
    await tester.ensureVisible(getImageButton());
    await tester.tap(getImageButton());
    await tester.pumpWidget(const SizedBox());
    complete.complete(XFile('C:/external/late.png'));
    await tester.pumpAndSettle();
    expect(templates.paths, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
