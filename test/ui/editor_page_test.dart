import 'dart:async';

import 'package:bluedot_clicker/models/blueprint.dart';
import 'package:bluedot_clicker/services/script_storage.dart';
import 'package:bluedot_clicker/state/providers.dart';
import 'package:bluedot_clicker/ui/editor/editor_page.dart';
import 'package:bluedot_clicker/ui/editor/node_bridge.dart';
import 'package:bluedot_clicker/ui/editor/node_palette.dart';
import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 门控存储：save 可被 Completer 阻塞，用于制造「保存落盘期间发生编辑」的竞态窗口
class _GatedScriptStorage extends ScriptStorage {
  Completer<void> gate = Completer<void>();
  final List<BlueprintScript> saved = [];
  bool failSave = false;
  List<BlueprintScript> onDisk = [];

  @override
  Future<void> save(BlueprintScript s) async {
    await gate.future;
    gate = Completer<void>();
    if (failSave) throw Exception('磁盘不可用');
    saved.add(s);
  }

  @override
  Future<List<BlueprintScript>> listScripts() async => onDisk;

  @override
  Future<bool> exists(String name) async => false;

  @override
  Future<BlueprintScript?> load(String name) async => null;
}

BlueprintScript _script(String name) {
  final s = BlueprintScript(name: name);
  s.nodes['n_start'] = BPNode(id: 'n_start', type: 'start', x: 0, y: 0);
  s.nodes['n_click'] = BPNode(id: 'n_click', type: 'mouse', x: 200, y: 0);
  s.edges['e1'] = BPEdge(
    id: 'e1',
    from: const PortRef(nodeId: 'n_start', port: 'out'),
    to: const PortRef(nodeId: 'n_click', port: 'in'),
    kind: EdgeKind.exec,
  );
  return s;
}

Future<ProviderContainer> _pumpEditor(WidgetTester tester, ScriptStorage storage) async {
  final container = ProviderContainer(overrides: [
    scriptStorageProvider.overrideWith((_) => storage),
  ]);
  container.read(currentScriptProvider.notifier).open(_script('竞态'));
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: EditorPage()),
  ));
  await tester.pumpAndSettle();
  return container;
}

fl.NodeEditorController _controllerOf(WidgetTester tester) =>
    tester.state<fl.NodeEditorState>(find.byType(fl.NodeEditor)).widget.controller;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EditorPage 保存竞态', () {
    testWidgets('落盘期间的新编辑不得被标净（isDirty 保持）', (tester) async {
      final storage = _GatedScriptStorage();
      final container = await _pumpEditor(tester, storage);
      final controller = _controllerOf(tester);
      expect(controller.project.isDirty, isFalse, reason: '刚载入应为干净基线');

      // 点击保存 → _save 阻塞在 storage.save 的 await 上
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pump();

      // 保存落盘期间发生编辑（相当于用户拖动节点/改参数）
      controller.updateNode(
        'n_click',
        (n) => n.withData(const {'x': 999}),
      );
      await tester.pump();

      // 放行保存
      storage.gate.complete();
      await tester.pumpAndSettle();

      // 保存已完成（SnackBar 提示 + 确有落盘）
      expect(find.text('脚本已保存'), findsOneWidget);
      expect(storage.saved, isNotEmpty);
      // 关键断言：新编辑未被误标为已保存，离开编辑器时仍会提示
      expect(controller.project.isDirty, isTrue,
          reason: '修复前 markSaved 会把落盘后更新的图也标为已保存，导致新编辑丢失');

      // 再次保存（此时已无并发编辑）→ 恢复干净
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pump();
      storage.gate.complete();
      await tester.pumpAndSettle();
      expect(controller.project.isDirty, isFalse);

      // 推进 SnackBar 自动关闭计时器，避免测试结束时残留 pending timer
      await tester.pump(const Duration(seconds: 5));
      // 先卸载 widget 树（触发 EditorPage.dispose），再销毁容器
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    });

    testWidgets('保存失败提示并留在编辑器', (tester) async {
      final storage = _GatedScriptStorage()..failSave = true;
      final container = await _pumpEditor(tester, storage);

      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pump();
      storage.gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('保存失败'), findsOneWidget);
      expect(storage.saved, isEmpty);

      // 推进 SnackBar 自动关闭计时器，避免测试结束时残留 pending timer
      await tester.pump(const Duration(seconds: 5));
      // 先卸载 widget 树（触发 EditorPage.dispose），再销毁容器
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    });
  });

  group('NodePalette 开始节点唯一性', () {
    testWidgets('已存在开始节点时重复添加被拦截', (tester) async {
      final controller = fl.NodeEditorController(definitions: blueprintNodeRegistry);
      final container = ProviderContainer();
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: NodePalette(controller: controller),
          ),
        ),
      ));

      // 「脚本」类别在列表底部，先滚动到可见再展开
      final category = find.text('脚本');
      await tester.ensureVisible(category);
      await tester.pumpAndSettle();
      await tester.tap(category);
      await tester.pumpAndSettle();

      int startCount() =>
          controller.graph.nodes.values.where((n) => n.type == 'start').length;

      final startTile = find.text('开始');
      await tester.ensureVisible(startTile);
      await tester.pumpAndSettle();
      await tester.tap(startTile);
      await tester.pumpAndSettle();
      expect(startCount(), 1, reason: '第一次添加应成功');

      await tester.tap(startTile);
      await tester.pumpAndSettle();
      expect(find.text('开始节点已存在，一个脚本只需一个入口'), findsOneWidget);
      expect(startCount(), 1, reason: '第二次添加应被拦截');

      // 推进 SnackBar 自动关闭计时器，避免测试结束时残留 pending timer
      await tester.pump(const Duration(seconds: 5));
      // 先卸载 widget 树，再销毁控制器与容器
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      container.dispose();
    });
  });
}
