import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../models/node_types.dart';
import '../../state/providers.dart';
import 'node_bridge.dart';

/// 画布视口中心的场景坐标（用于新节点落点）；无编辑器状态时回退固定点
Offset _canvasCenter(
  fl.NodeEditorController controller,
  GlobalKey<fl.NodeEditorState>? editorStateKey,
) {
  Offset center = const Offset(200, 200);
  final editorState = editorStateKey?.currentState;
  if (editorState != null) {
    final vp = editorState.viewportSize;
    center = controller.camera.viewport.toScene(
      Offset(vp.width / 2, vp.height / 2),
    );
  }
  return center;
}

/// 节点库面板：按类别分组列出全部可用节点，点击添加到画布视口中心。
class NodePalette extends ConsumerWidget {
  const NodePalette({
    super.key,
    required this.controller,
    this.editorStateKey,
    this.popOnAdd = false,
  });

  final fl.NodeEditorController controller;
  final GlobalKey<fl.NodeEditorState>? editorStateKey;

  /// 窄屏模式下置于 ModalBottomSheet 中，添加节点后关闭面板
  final bool popOnAdd;

  void _addType(WidgetRef ref, BuildContext context, NodeTypeDef def) {
    // 开始节点是唯一执行入口（引擎 findStart 任取其一），重复添加会造成不确定性
    if (def.type == 'start' &&
        controller.graph.nodes.values.any((n) => n.type == 'start')) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('开始节点已存在，一个脚本只需一个入口')));
      return;
    }
    // 视口中心（scene 坐标）附近，附随机偏移避免完全重叠
    final center = _canvasCenter(controller, editorStateKey);
    final jitter = DateTime.now().microsecondsSinceEpoch % 60 - 30;
    controller.addNode(
      blueprintNodeRegistry.instantiate(
        def.type,
        id: 'n_${DateTime.now().microsecondsSinceEpoch}',
        position: Offset(center.dx - 100 + jitter, center.dy - 50 + jitter),
      ),
    );
    if (popOnAdd && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Material 而非 ColoredBox：ListTile 的墨迹/背景绘制在最近的 Material 上，
    // ColoredBox 会遮蔽点击反馈并触发调试断言
    return Material(
      color: AppColors.moonWhite,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(
              '节点库',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.inkSecondary,
              ),
            ),
          ),
          for (final category in NodeCategory.values) ...[
            ExpansionTile(
              leading: Icon(category.icon, color: category.color),
              title: Text(
                category.label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: AppColors.ink,
                ),
              ),
              initiallyExpanded: category == NodeCategory.interaction,
              childrenPadding: const EdgeInsets.only(bottom: 4),
              children: [
                for (final def in kNodeTypes)
                  if (def.category == category)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        def.icon,
                        color: def.category.color,
                        size: 22,
                      ),
                      title: Text(
                        def.title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: AppColors.ink,
                        ),
                      ),
                      subtitle: Text(
                        def.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.inkSecondary,
                        ),
                      ),
                      onTap: () => _addType(ref, context, def),
                    ),
              ],
            ),
            // 「数据」分类下方：蓝图变量面板（列出已设置的变量并初始化）
            if (category == NodeCategory.data)
              ExpansionTile(
                leading: Icon(
                  Icons.data_object_rounded,
                  color: AppColors.nodeData,
                ),
                title: const Text(
                  '变量',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: AppColors.ink,
                  ),
                ),
                childrenPadding: const EdgeInsets.only(bottom: 4),
                children: [
                  _VariablesSection(
                    controller: controller,
                    editorStateKey: editorStateKey,
                    popOnAdd: popOnAdd,
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

/// 蓝图变量面板（节点库「变量」分类内容）：
/// 列出已设置的变量（已初始化的 + 图中 varName 参数引用的），
/// 可编辑初始值；点击变量名在画布创建预填的「获取变量」节点。
class _VariablesSection extends ConsumerWidget {
  const _VariablesSection({
    required this.controller,
    this.editorStateKey,
    this.popOnAdd = false,
  });

  final fl.NodeEditorController controller;
  final GlobalKey<fl.NodeEditorState>? editorStateKey;
  final bool popOnAdd;

  Future<void> _newVariable(BuildContext context, WidgetRef ref) async {
    // 不持 controller：对话框 pop 后退出动画仍在使用输入框，
    // 手动 dispose 会在动画期间触发 "used after being disposed"
    var newName = '';
    var newInit = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建变量'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(labelText: '变量名'),
              onChanged: (v) => newName = v,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(
                labelText: '初始值（可空）',
                hintText: '数字/字符串/布尔',
              ),
              onChanged: (v) => newInit = v,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok == true) {
      ref.read(scriptVariablesProvider.notifier).setInitial(newName, newInit);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initialized = ref.watch(scriptVariablesProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final names = {...initialized.keys, ...graphVarNames(controller.graph)}
            .toList()
          ..sort();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, 4),
              child: Text(
                '点击变量名在画布创建「获取变量」节点；右侧输入框为初始值',
                style: TextStyle(fontSize: 11, color: AppColors.inkSecondary),
              ),
            ),
            if (names.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  '暂无变量：用「设置变量」节点、或在此新建',
                  style: TextStyle(fontSize: 12, color: AppColors.inkSecondary),
                ),
              )
            else
              for (final name in names)
                _VariableRow(
                  key: ValueKey(name),
                  controller: controller,
                  editorStateKey: editorStateKey,
                  popOnAdd: popOnAdd,
                  name: name,
                  initialValue: initialized[name],
                ),
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: const Icon(
                Icons.add_circle_outline,
                size: 20,
                color: AppColors.nodeData,
              ),
              title: const Text(
                '新建变量',
                style: TextStyle(fontSize: 13, color: AppColors.ink),
              ),
              onTap: () => _newVariable(context, ref),
            ),
          ],
        );
      },
    );
  }
}

/// 单个变量行：变量名（点击创建「获取变量」节点）+ 初始值输入框
class _VariableRow extends ConsumerStatefulWidget {
  const _VariableRow({
    super.key,
    required this.controller,
    this.editorStateKey,
    this.popOnAdd = false,
    required this.name,
    this.initialValue,
  });

  final fl.NodeEditorController controller;
  final GlobalKey<fl.NodeEditorState>? editorStateKey;
  final bool popOnAdd;
  final String name;
  final Object? initialValue;

  @override
  ConsumerState<_VariableRow> createState() => _VariableRowState();
}

class _VariableRowState extends ConsumerState<_VariableRow> {
  late final TextEditingController _initCtl;
  late final FocusNode _initFocus;

  @override
  void initState() {
    super.initState();
    _initCtl = TextEditingController(text: widget.initialValue?.toString() ?? '');
    _initFocus = FocusNode()..addListener(_commitOnUnfocus);
  }

  @override
  void dispose() {
    _initFocus.removeListener(_commitOnUnfocus);
    _initFocus.dispose();
    _initCtl.dispose();
    super.dispose();
  }

  /// 失焦时把初始值写入脚本变量表（空输入 = 值置为空字符串）
  void _commitOnUnfocus() {
    if (!_initFocus.hasFocus) {
      ref
          .read(scriptVariablesProvider.notifier)
          .setInitial(widget.name, _initCtl.text);
    }
  }

  /// 删除变量初始值；图中仍有节点引用时给出提示（引用使变量仍显示在列表）
  void _deleteVariable() {
    ref.read(scriptVariablesProvider.notifier).remove(widget.name);
    if (graphVarNames(widget.controller.graph).contains(widget.name) &&
        context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('图中仍有节点引用 ${widget.name}，变量仍会显示在列表中'),
        ),
      );
    }
  }

  void _addGetVarNode() {
    final center = _canvasCenter(widget.controller, widget.editorStateKey);
    final jitter = DateTime.now().microsecondsSinceEpoch % 60 - 30;
    widget.controller.addNode(
      blueprintNodeRegistry.instantiate(
        'getVar',
        id: 'n_${DateTime.now().microsecondsSinceEpoch}',
        position: Offset(center.dx - 100 + jitter, center.dy - 50 + jitter),
        data: {'name': widget.name},
      ),
    );
    if (widget.popOnAdd && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: const Icon(
        Icons.add_circle_outline,
        size: 20,
        color: AppColors.nodeData,
      ),
      title: Text(
        widget.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, color: AppColors.ink),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 104,
            child: TextField(
              controller: _initCtl,
              focusNode: _initFocus,
              style: const TextStyle(fontSize: 12, color: AppColors.ink),
              decoration: const InputDecoration(
                hintText: '初始值',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              onSubmitted: (_) => _initFocus.unfocus(),
            ),
          ),
          IconButton(
            tooltip: '删除变量',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.close_rounded, size: 18),
            color: AppColors.danger,
            onPressed: _deleteVariable,
          ),
        ],
      ),
      onTap: _addGetVarNode,
    );
  }
}
