import 'package:bluedot_clicker/ui/editor/editor_localizations.dart';
import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const l = AppNodeEditorLocalizations();

  test('菜单关键文案为中文', () {
    expect(l.cut, '剪切');
    expect(l.copy, '复制');
    expect(l.paste, '粘贴');
    expect(l.delete, '删除');
    expect(l.deleteWithContents, '删除（含组内节点）');
    expect(l.description, '节点说明');
    expect(l.group, '组合');
    expect(l.addToGroup, '加入组合');
    expect(l.disband, '解散组合');
    expect(l.rename, '重命名');
    expect(l.colour, '颜色');
    expect(l.neutralColour, '默认颜色');
    expect(l.goToSource, '跳到源节点');
    expect(l.goToDestination, '跳到目标节点');
    expect(l.removeWaypoint, '删除拐点');
    expect(l.addWaypointHere, '在此添加拐点');
    expect(l.clearWaypoints, '清除全部拐点');
    expect(l.centerView, '居中显示');
    expect(l.resetZoom, '重置缩放');
    expect(l.create, '新建节点');
    expect(l.addComment, '添加注释');
    expect(l.undo, '撤销');
    expect(l.redo, '重做');
  });

  test('对话框与画布文案为中文', () {
    expect(l.aboutThisNode, '节点说明');
    expect(l.close, '关闭');
    expect(l.cancel, '取消');
    expect(l.groupNameTitle, '组合名称');
    expect(l.groupNameHint('组合 1'), contains('组合 1'));
    expect(l.renameConfirm, '重命名');
    expect(l.linkLabelTitle, '连线标签');
    expect(l.saveConfirm, '保存');
    expect(l.discardChangesTitle, isNotEmpty);
    expect(l.discardChangesMessage, isNotEmpty);
    expect(l.discardConfirm, '放弃');
    expect(l.commentHint, '输入注释…');
  });

  test('动态文案（连线数量/小地图）不留英文占位', () {
    expect(l.cutLinks(1), '断开连线');
    expect(l.cutLinks(3), contains('3'));
    expect(l.minimapTitle, '小地图');
    expect(l.minimapZoomCapLabel(2), '200%');
    expect(l.minimapIdleOpacityLabel(0.5), '50%');
    expect(l.minimapSizePresetLabel(const Size(240, 160)), '240 × 160');
  });

  test('delegate 对任意语言返回中文实现', () async {
    expect(AppNodeEditorLocalizations.delegate.isSupported(const Locale('zh', 'CN')), isTrue);
    final loaded =
        await AppNodeEditorLocalizations.delegate.load(const Locale('zh', 'CN'));
    expect(loaded.cut, '剪切');
    expect(loaded, isA<fl.NodeEditorLocalizations>());
  });
}
