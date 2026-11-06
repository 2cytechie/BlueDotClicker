import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// fl_nodes_v2 内置界面（右键菜单、对话框、小地图、注释占位）的中文文案。
///
/// 继承 [fl.DefaultNodeEditorLocalizations] 而不是 implements：包内后续小版本
/// 新增文案时会退回英文而非编译失败；升级包后按下方清单补译即可。
class AppNodeEditorLocalizations extends fl.DefaultNodeEditorLocalizations {
  const AppNodeEditorLocalizations();

  /// 挂到 `MaterialApp.localizationsDelegates`（Material/Widgets 默认委托由
  /// MaterialApp 自动补齐），整个编辑器的内置文案即变为中文。
  static const LocalizationsDelegate<fl.NodeEditorLocalizations> delegate =
      _AppNodeEditorLocalizationsDelegate();

  // ---- 右键菜单 ----
  @override
  String get cut => '剪切';
  @override
  String get copy => '复制';
  @override
  String get paste => '粘贴';
  @override
  String get delete => '删除';
  @override
  String get deleteWithContents => '删除（含组内节点）';
  @override
  String get description => '节点说明';
  @override
  String get group => '组合';
  @override
  String get addToGroup => '加入组合';
  @override
  String get disband => '解散组合';
  @override
  String get rename => '重命名';
  @override
  String get colour => '颜色';
  @override
  String get neutralColour => '默认颜色';
  @override
  String cutLinks(int count) => count <= 1 ? '断开连线' : '断开连线（$count 条）';
  @override
  String get goToSource => '跳到源节点';
  @override
  String get goToDestination => '跳到目标节点';
  @override
  String get removeWaypoint => '删除拐点';
  @override
  String get addWaypointHere => '在此添加拐点';
  @override
  String get clearWaypoints => '清除全部拐点';
  @override
  String get centerView => '居中显示';
  @override
  String get resetZoom => '重置缩放';
  @override
  String get create => '新建节点';
  @override
  String get addComment => '添加注释';
  @override
  String get project => '项目';
  @override
  String get undo => '撤销';
  @override
  String get redo => '重做';
  @override
  String get open => '打开';
  @override
  String get save => '保存';
  @override
  String get newProject => '新建项目';

  // ---- 对话框 ----
  @override
  String get aboutThisNode => '节点说明';
  @override
  String get close => '关闭';
  @override
  String get cancel => '取消';
  @override
  String get groupNameTitle => '组合名称';
  @override
  String groupNameHint(String defaultName) => '留空则使用「$defaultName」';
  @override
  String get renameConfirm => '重命名';
  @override
  String get linkLabelTitle => '连线标签';
  @override
  String get linkLabelHint => '留空则移除标签';
  @override
  String get saveConfirm => '保存';
  @override
  String get discardChangesTitle => '放弃未保存的修改？';
  @override
  String get discardChangesMessage => '当前文档有尚未保存的修改。';
  @override
  String get discardConfirm => '放弃';

  // ---- 小地图（当前未启用，提前中文化） ----
  @override
  String get minimapTitle => '小地图';
  @override
  String get minimapMinimise => '收起';
  @override
  String get minimapRestore => '展开';
  @override
  String get minimapZoomCap => '缩放上限';
  @override
  String get minimapSize => '尺寸';
  @override
  String get minimapShow => '显示';
  @override
  String get minimapWhenIdle => '空闲时';
  @override
  String get minimapConnections => '连线';
  @override
  String get minimapGroupFrames => '组合框';
  @override
  String get minimapComments => '注释';
  @override
  String minimapSizePresetLabel(Size size) =>
      '${size.width.round()} × ${size.height.round()}';
  @override
  String minimapZoomCapLabel(double scale) => '${(scale * 100).round()}%';
  @override
  String minimapIdleOpacityLabel(double opacity) =>
      '${(opacity * 100).round()}%';

  // ---- 画布 ----
  @override
  String get commentHint => '输入注释…';
}

class _AppNodeEditorLocalizationsDelegate
    extends LocalizationsDelegate<fl.NodeEditorLocalizations> {
  const _AppNodeEditorLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<fl.NodeEditorLocalizations> load(Locale locale) =>
      SynchronousFuture<fl.NodeEditorLocalizations>(
        const AppNodeEditorLocalizations(),
      );

  @override
  bool shouldReload(_AppNodeEditorLocalizationsDelegate old) => false;
}
