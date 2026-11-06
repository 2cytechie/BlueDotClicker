import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 编辑器右键菜单。
///
/// 关闭 fl_nodes_v2 自带的「项目」子菜单：它面向"整份文档"语义，与本应用的
/// 脚本文件系统不匹配——其中「新建项目」会直接清空画布，「打开/保存」又因为
/// 没有接 project 的 source/sink 而恒为禁用态，容易误操作丢图。
/// 撤销/重做从该子菜单移出，作为独立项追加到每个菜单末尾。
fl.NodeEditorMenus buildEditorContextMenus() => fl.NodeEditorMenus(
  showProjectMenu: false,
  build: appendUndoRedoEntries,
);

/// 在默认菜单项后追加撤销/重做（按历史栈状态置灰）。
List<fl.NodeMenuEntry> appendUndoRedoEntries(
  fl.NodeMenuRequest request,
  List<fl.NodeMenuEntry> defaults,
) {
  final history = request.controller.history;
  return [
    ...defaults,
    const fl.NodeMenuEntry.separator(),
    fl.NodeMenuEntry(
      id: fl.NodeMenuEntryId.undo,
      label: '撤销',
      icon: Icons.undo_rounded,
      shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, control: true),
      onSelected: history.canUndo ? history.undo : null,
    ),
    fl.NodeMenuEntry(
      id: fl.NodeMenuEntryId.redo,
      label: '重做',
      icon: Icons.redo_rounded,
      shortcut: const SingleActivator(
        LogicalKeyboardKey.keyZ,
        control: true,
        shift: true,
      ),
      onSelected: history.canRedo ? history.redo : null,
    ),
  ];
}
