import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../models/node_types.dart';
import 'node_bridge.dart';

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
    Offset center = const Offset(200, 200);
    final editorState = editorStateKey?.currentState;
    if (editorState != null) {
      final vp = editorState.viewportSize;
      center = controller.camera.viewport.toScene(
        Offset(vp.width / 2, vp.height / 2),
      );
    }
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
          for (final category in NodeCategory.values)
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
        ],
      ),
    );
  }
}
