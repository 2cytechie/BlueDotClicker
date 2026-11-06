import 'package:bluedot_clicker/ui/editor/editor_localizations.dart';
import 'package:bluedot_clicker/ui/editor/editor_menus.dart';
import 'package:bluedot_clicker/ui/editor/node_bridge.dart';
import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造画布右键菜单请求（与 NodeEditor 内部一致：文案取自定义本地化）
fl.NodeMenuRequest _canvasRequest(fl.NodeEditorController controller) =>
    fl.NodeMenuRequest(
      controller: controller,
      target: const fl.NodeMenuCanvasTarget(Offset.zero),
      viewportSize: const Size(800, 600),
      describeNode: (node, description) {},
      renameGroup: (group) {},
      newProject: () {},
      openProject: () {},
      saveProject: () {},
      localizations: const AppNodeEditorLocalizations(),
    );

/// 展开子菜单收集全部非空标签
List<String> _labels(List<fl.NodeMenuEntry> entries) {
  final out = <String>[];
  void walk(List<fl.NodeMenuEntry> list) {
    for (final e in list) {
      if (e.label.isNotEmpty) out.add(e.label);
      walk(e.children);
    }
  }

  walk(entries);
  return out;
}

void main() {
  late fl.NodeEditorController controller;

  setUp(() {
    controller = fl.NodeEditorController(definitions: blueprintNodeRegistry);
  });

  tearDown(() => controller.dispose());

  test('关闭「项目」子菜单：不再出现会清空画布的「新建项目/打开/保存」', () {
    final menus = buildEditorContextMenus();
    expect(menus.showProjectMenu, isFalse);

    final labels = _labels(menus.entriesFor(_canvasRequest(controller)));
    expect(labels, isNot(contains('项目')));
    expect(labels, isNot(contains('新建项目')));
    expect(labels, isNot(contains('打开')));
    expect(labels, isNot(contains('保存')));
  });

  test('菜单文案全中文，且补充了撤销/重做', () {
    final labels = _labels(
      buildEditorContextMenus().entriesFor(_canvasRequest(controller)),
    );
    expect(labels, containsAll(['新建节点', '添加注释', '撤销', '重做']));
    // 英文默认项不应出现（证明本地化生效）
    expect(labels, isNot(contains('Create')));
    expect(labels, isNot(contains('Add comment')));
    expect(labels, isNot(contains('Undo')));
  });

  test('撤销/重做按历史栈状态置灰', () {
    List<fl.NodeMenuEntry> entries() =>
        buildEditorContextMenus().entriesFor(_canvasRequest(controller));

    fl.NodeMenuEntry entryById(List<fl.NodeMenuEntry> list, fl.NodeMenuEntryId id) {
      for (final e in list) {
        if (e.id == id) return e;
      }
      fail('菜单中缺少 $id');
    }

    expect(entryById(entries(), fl.NodeMenuEntryId.undo).onSelected, isNull);

    controller.addNode(
      blueprintNodeRegistry.instantiate(
        'delay',
        id: 'd1',
        position: Offset.zero,
      ),
    );
    expect(controller.history.canUndo, isTrue);
    expect(entryById(entries(), fl.NodeMenuEntryId.undo).onSelected, isNotNull);
    expect(entryById(entries(), fl.NodeMenuEntryId.redo).onSelected, isNull);
  });
}
