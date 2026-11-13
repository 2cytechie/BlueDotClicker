import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../engine/interpreter.dart';
import '../../models/blueprint.dart';
import '../../models/key_names.dart';
import '../../models/node_types.dart';
import '../../services/media_tester.dart';
import '../../state/frame_yield.dart';
import '../../state/providers.dart';
import 'node_bridge.dart' show graphToBlueprint, graphVarNames;

/// 属性面板：编辑当前选中节点的参数（数据存储于 GraphNode.data，
/// 经 NodeEditorController.updateNode 提交，支持撤销/重做）
class PropertyPanel extends ConsumerWidget {
  const PropertyPanel({super.key, required this.controller});

  final fl.NodeEditorController controller;

  Future<void> _confirmDelete(BuildContext context, fl.GraphNode node) async {
    final def = nodeDef(node.type);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除节点？'),
        content: Text('将删除「${def.title}」及其所有连线。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) controller.removeNodes([node.id]);
  }

  void _commit(fl.GraphNode node, ParamFieldDef f, Object value) {
    controller.updateNode(node.id, (n) => n.withData({f.key: value}));
  }

  /// 参数默认值 + 节点当前值（缺失键用默认值补齐，供显隐判断/摘要使用）
  Map<String, Object?> _effectiveData(fl.GraphNode node) {
    final data = <String, Object?>{};
    for (final f in nodeDef(node.type).params) {
      data[f.key] = f.defaultValue;
    }
    data.addAll(node.data);
    return data;
  }

  /// 各行坐标对应的操作：拾取坐标（点坐标）/ 屏幕定位（拖动图标改坐标）。
  /// 键为坐标对的 X 参数键（'x' / 'endX'；拖拽起点复用 'x'）。
  Map<String, _CoordActions> _coordActions(
    fl.GraphNode node,
    Map<String, Object?> data,
  ) {
    if (node.type != 'mouse') return const {};
    final action = '${data['action'] ?? 'click'}';
    if (action == 'swipe') {
      // 方向距离模式只显示起点；起点终点模式两端可定位并自动连线
      final withEnd = data['mode'] != 'direction';
      final locate = ScreenLocateTarget(
        nodeId: node.id,
        label: '拖拽起点',
        points: [
          LocatePointDef('x', 'y', AppColors.peacock.toARGB32()),
          if (withEnd)
            LocatePointDef('endX', 'endY', AppColors.nodeMedia.toARGB32()),
        ],
      );
      return {
        'x': _CoordActions(
          pick: PickTarget(
            nodeId: node.id,
            keyX: 'x',
            keyY: 'y',
            label: '拾取起点坐标',
          ),
          locate: locate,
        ),
        if (withEnd)
          'endX': _CoordActions(
            pick: PickTarget(
              nodeId: node.id,
              keyX: 'endX',
              keyY: 'endY',
              label: '拾取终点坐标',
            ),
            locate: locate,
          ),
      };
    }
    // 单击/双击/长按点击哪个鼠标键就记录为「鼠标键」；滚轮/移动只需位置
    final withButton =
        action == 'click' || action == 'doubleClick' || action == 'longPress';
    return {
      'x': _CoordActions(
        pick: PickTarget(
          nodeId: node.id,
          keyX: 'x',
          keyY: 'y',
          buttonKey: withButton ? 'button' : null,
          label: '拾取坐标',
        ),
        locate: ScreenLocateTarget(
          nodeId: node.id,
          label: '位置',
          points: [LocatePointDef('x', 'y', AppColors.peacock.toARGB32())],
        ),
      ),
    };
  }

  /// 左右并排渲染的参数对（其余字段维持上下排列）
  static const List<(String, String)> _kCoordPairs = [
    ('x', 'y'),
    ('endX', 'endY'),
    ('dx', 'dy'),
    // 媒体节点区域参数：左上角 X/Y 一行，右下角 X/Y 一行
    ('left', 'top'),
    ('right', 'bottom'),
    // 设置变量：变量名+常量
    ('name', 'const'),
  ];

  /// 节点的某个输入端口是否已有连线（连接后对应参数锁定为只读，执行时以输入值为准）
  bool _hasDataInput(fl.GraphNode node, String port) => controller.graph
      .connectionsOf(node.id)
      .any((c) => c.to.nodeId == node.id && c.to.portId == port);

  /// varName 字段的已有变量候选（变量面板已初始化的 + 图中 varName 参数引用的），排序
  List<String> _varNameSuggestions(WidgetRef ref) => ({
    ...ref.watch(scriptVariablesProvider).keys,
    ...graphVarNames(controller.graph),
  }).toList()..sort();

  /// 参数列表：先按节点当前取值过滤掉不适用的字段（如非拖拽动作不显示起终点），
  /// 再让参数对左右并排（各占一半宽）。坐标对上方渲染「拾取坐标 + 屏幕定位」
  /// 两个半宽按钮；媒体节点的区域X/Y 行尾渲染框选按钮，其余字段一字段一行。
  List<Widget> _buildParamFields(WidgetRef ref, fl.GraphNode node) {
    final data = _effectiveData(node);
    final def = nodeDef(node.type);
    final params = def.params.where((f) => f.visibleFor(data)).toList();
    // 坐标操作按 keyX 索引：'x'/'endX' 分别对应一行坐标对（拖拽起点复用 x）
    final actionsByKeyX = _coordActions(node, data);
    // 数据输入已连接且接管了某个参数 → 参数灰显只读并保留原值。
    // 默认同名接管；`lockedByPort` 支持不同名映射（如 setVar.value → const）。
    // 识别节点连接「输入图像」后图像优先：区域参数整体不生效并锁定只读
    final imageInputConnected = _hasDataInput(node, 'image');
    // 截图节点：任一区域坐标（左/上/右/下）接了数据边 → 区域由数据驱动，
    // 「仅指定区域」强制开启并锁定，避免出现「坐标有连线但开关被关掉」的静默忽略
    final regionDrivenByData = const ['left', 'top', 'right', 'bottom']
        .any((p) => _hasDataInput(node, p));
    final lockedKeys = <String>{
      for (final f in def.params)
        if (_hasDataInput(node, f.lockedByPort ?? f.key)) f.key,
      if (imageInputConnected) ...const ['useRegion', 'left', 'top', 'right', 'bottom'],
      if (regionDrivenByData) 'useRegion',
    };
    // 媒体节点区域可通过屏幕框选获取：左上角 X/Y 行尾放框选按钮
    // （连接输入图像时区域不生效，框选入口一并关闭）
    final regionPickable =
        def.category == NodeCategory.media &&
        data['useRegion'] != null &&
        !imageInputConnected;
    final children = <Widget>[];
    var i = 0;
    while (i < params.length) {
      final f = params[i];
      final next = i + 1 < params.length ? params[i + 1] : null;
      if (f.key == 'useRegion' && imageInputConnected) {
        children.add(const _RegionLockedHint());
      } else if (f.key == 'useRegion' && regionDrivenByData) {
        children.add(const _RegionDrivenHint());
      }
      if (next != null &&
          _kCoordPairs.any((p) => p.$1 == f.key && p.$2 == next.key)) {
        final actions = actionsByKeyX[f.key];
        final regionButton = regionPickable && f.key == 'left';
        final pairLocked =
            lockedKeys.contains(f.key) || lockedKeys.contains(next.key);
        // 拾取/定位按钮独占一整行，放在坐标输入框上方
        if (actions != null && !pairLocked) {
          children.add(
            _CoordActionBar(
              controller: controller,
              node: node,
              actions: actions,
            ),
          );
        }
        children.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _buildField(
                  ref,
                  node,
                  f,
                  locked: lockedKeys.contains(f.key),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildField(
                  ref,
                  node,
                  next,
                  locked: lockedKeys.contains(next.key),
                ),
              ),
              if (regionButton) ...[
                const SizedBox(width: 6),
                _InlineRegionPickButton(controller: controller, node: node),
              ],
            ],
          ),
        );
        i += 2;
        continue;
      }
      children.add(
        _buildField(
          ref,
          node,
          f,
          locked: lockedKeys.contains(f.key),
          // 区域由数据驱动时开关显示为开（实际执行也按区域截取）
          boolValueOverride:
              f.key == 'useRegion' && regionDrivenByData ? true : null,
        ),
      );
      i += 1;
    }
    return children;
  }

  /// 媒体节点测试区（仅媒体节点显示）：按当前参数执行一次并弹窗展示结果
  Widget _buildTestSection(fl.GraphNode node) {
    if (nodeDef(node.type).category != NodeCategory.media) {
      return const SizedBox.shrink();
    }
    return _MediaTestSection(node: node, controller: controller);
  }

  /// 端口说明区：分「输入」「输出」两组列出填写了说明的数据端口，
  /// 让用户快速了解节点各数据端口接什么、产出什么（执行流口不写说明）。
  Widget _buildPortDocSection(fl.GraphNode node) {
    final def = nodeDef(node.type);
    final inputs = def.inputs.where((p) => p.note != null).toList();
    final outputs = def.outputs.where((p) => p.note != null).toList();
    if (inputs.isEmpty && outputs.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: AppDecor.sunken,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('端口说明', style: AppTextStyles.sectionTitle),
            for (final (title, ports) in [('输入', inputs), ('输出', outputs)])
              if (ports.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text(title, style: AppTextStyles.caption),
                ),
                for (final p in ports) ...[
                  _PortDocHeader(port: p),
                  const SizedBox(height: 4),
                  Text(p.note!, style: AppTextStyles.caption),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
          ],
        ),
      ),
    );
  }

  Widget _buildField(
    WidgetRef ref,
    fl.GraphNode node,
    ParamFieldDef f, {
    bool locked = false,
    bool? boolValueOverride,
  }) {
    void onCommit(Object v) => _commit(node, f, v);
    switch (f.type) {
      case ParamType.int:
        return _ParamTextField(
          controller: controller,
          node: node,
          field: f,
          onCommit: onCommit,
          numberMode: _NumberMode.int,
          locked: locked,
        );
      case ParamType.double:
        return _ParamTextField(
          controller: controller,
          node: node,
          field: f,
          onCommit: onCommit,
          numberMode: _NumberMode.double,
          locked: locked,
        );
      case ParamType.string:
        return _ParamTextField(
          controller: controller,
          node: node,
          field: f,
          onCommit: onCommit,
          numberMode: _NumberMode.none,
          locked: locked,
        );
      case ParamType.varName:
        return _ParamTextField(
          controller: controller,
          node: node,
          field: f,
          onCommit: onCommit,
          numberMode: _NumberMode.none,
          locked: locked,
          // 已有变量下拉：变量面板已初始化的 + 图中 varName 参数引用的
          suggestions: _varNameSuggestions(ref),
        );
      case ParamType.bool:
        final v = boolValueOverride ?? node.data[f.key];
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Row(
            children: [
              Text(
                f.label,
                style: TextStyle(
                  fontSize: 13,
                  color: locked ? AppColors.inkSecondary : AppColors.ink,
                ),
              ),
              if (locked) ...[
                const SizedBox(width: 4),
                const Icon(
                  Icons.lock_outline_rounded,
                  size: 14,
                  color: AppColors.inkSecondary,
                ),
              ],
            ],
          ),
          value: v is bool ? v : f.defaultValue == true,
          onChanged: locked ? null : onCommit,
        );
      case ParamType.enum_:
        final current =
            node.data[f.key] as String? ?? f.defaultValue as String?;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DropdownButtonFormField<String>(
            // 值变化（含坐标拾取写入的鼠标键）时重建，确保展示最新选择
            key: ValueKey('${node.id}-${f.key}-$current'),
            initialValue: f.options.any((o) => o.value == current)
                ? current
                : null,
            dropdownColor: AppColors.moonWhite,
            borderRadius: kDropdownMenuRadius,
            decoration: InputDecoration(labelText: f.label),
            items: [
              for (final o in f.options)
                DropdownMenuItem(value: o.value, child: Text(o.label)),
            ],
            onChanged: (v) {
              if (v != null) onCommit(v);
            },
          ),
        );
      case ParamType.templateFile:
        return _TemplateFileField(node: node, field: f, onCommit: onCommit);
      case ParamType.recording:
        return _RecordingField(node: node, field: f, onCommit: onCommit);
      case ParamType.key:
        return _KeyField(
          controller: controller,
          node: node,
          field: f,
          onCommit: onCommit,
        );
      case ParamType.keyList:
        return _KeyListField(
          controller: controller,
          node: node,
          field: f,
          onCommit: onCommit,
        );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: AppColors.moonWhite,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final selectedIds = controller.selection.nodeIds;
          final node = selectedIds.isEmpty
              ? null
              : controller.graph.nodes[selectedIds.first];

          if (node == null) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.tune_rounded, size: 44, color: AppColors.outline),
                  SizedBox(height: 12),
                  Text('选中节点以编辑属性', style: AppTextStyles.caption),
                ],
              ),
            );
          }

          // 注释是 fl_nodes 的画布节点（类型 __comment__），不参与执行，
          // 也不是"已移除类型"——单独给只读说明，避免误报为未知节点。
          if (fl.NodeComment.isComment(node)) {
            return _buildCommentNotice(context, node);
          }

          final def = nodeDef(node.type);
          final color = def.category.color;
          final known = isKnownNodeType(node.type);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 头部：类别色图标 + 标题 + 类型名 + 删除
              Container(
                color: AppColors.moonWhite,
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(
                          color: color.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Icon(def.icon, color: color, size: 20),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            def.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.sectionTitle,
                          ),
                          Text(
                            known ? def.type : '原类型：${node.type}',
                            style: AppTextStyles.captionMuted,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '删除节点',
                      color: AppColors.danger,
                      onPressed: () => _confirmDelete(context, node),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                  children: known
                      ? [
                          _buildTestSection(node),
                          ..._buildParamFields(ref, node),
                          _buildPortDocSection(node),
                          const SizedBox(height: 12),
                          Text(
                            def.description,
                            style: AppTextStyles.body.copyWith(
                              color: AppColors.inkSecondary,
                            ),
                          ),
                        ]
                      : [_buildUnknownNotice(context, node)],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 已移除/未知节点：只给说明与删除入口（不渲染参数，避免写入无意义字段）
  Widget _buildUnknownNotice(BuildContext context, fl.GraphNode node) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.dangerSoft,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.danger.withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '该节点类型已移除',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.danger,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '原类型「${node.type}」不再支持，无法编辑或执行。'
                '与其相连的连线在打开脚本时已被移除，请删除该节点后重建对应操作。',
                style: AppTextStyles.caption,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => _confirmDelete(context, node),
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: const Text('删除该节点'),
          ),
        ),
      ],
    );
  }

  /// 画布注释：内容在画布上直接编辑，这里只做说明与删除。
  Widget _buildCommentNotice(BuildContext context, fl.GraphNode node) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.sticky_note_2_outlined,
                size: 20,
                color: AppColors.nodeData,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('注释', style: AppTextStyles.sectionTitle),
              ),
              IconButton(
                tooltip: '删除注释',
                color: AppColors.danger,
                onPressed: () => _confirmDelete(context, node),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '注释只是画布上的文字说明，不参与执行。'
            '在画布上双击注释即可编辑内容。',
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: AppColors.inkSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

enum _NumberMode { none, int, double }

/// 一行坐标可用的操作：拾取（点选屏幕取坐标）与定位（拖动屏幕图标改坐标）
class _CoordActions {
  final PickTarget? pick;
  final ScreenLocateTarget? locate;
  const _CoordActions({this.pick, this.locate});
}

/// 连接「输入图像」后的区域锁定提示：图像优先，区域参数不生效。
class _RegionLockedHint extends StatelessWidget {
  const _RegionLockedHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Icon(
            Icons.info_outline_rounded,
            size: 14,
            color: AppColors.inkSecondary,
          ),
          SizedBox(width: 4),
          Expanded(
            child: Text(
              '已连接「输入图像」：识别范围就是该图像整体，区域设置不生效',
              style: TextStyle(fontSize: 12, color: AppColors.inkSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 区域坐标接了数据边时的提示：开关强制开启并锁定。
class _RegionDrivenHint extends StatelessWidget {
  const _RegionDrivenHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Icon(
            Icons.info_outline_rounded,
            size: 14,
            color: AppColors.inkSecondary,
          ),
          SizedBox(width: 4),
          Expanded(
            child: Text(
              '区域坐标已由数据输入接管：已自动开启并锁定「仅指定区域」',
              style: TextStyle(fontSize: 12, color: AppColors.inkSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 坐标输入框上方的操作条：「拾取坐标」「屏幕定位」各占一半宽度。
/// 定位中再次点击即关闭；定位时拖动屏幕上的图标，拖拽结束回写坐标。
class _CoordActionBar extends ConsumerWidget {
  const _CoordActionBar({
    required this.controller,
    required this.node,
    required this.actions,
  });

  final fl.NodeEditorController controller;
  final fl.GraphNode node;
  final _CoordActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pickTarget = actions.pick;
    final locateTarget = actions.locate;
    final pickActive = ref.watch(
      coordinatePickProvider.select(
        (s) =>
            s.active &&
            pickTarget != null &&
            s.target?.nodeId == node.id &&
            s.target?.keyX == pickTarget.keyX,
      ),
    );
    final locateActive = ref.watch(
      screenLocateProvider.select(
        (s) =>
            s.active &&
            locateTarget != null &&
            sameScreenLocateTarget(s.target!, locateTarget),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          if (pickTarget != null)
            Expanded(
              child: _CoordActionButton(
                icon: Icons.my_location_rounded,
                label: '拾取坐标',
                tooltip: pickActive ? '拾取中（Esc 取消）' : pickTarget.label,
                active: pickActive,
                activeColor: AppColors.peacock,
                onPressed: () => ref
                    .read(coordinatePickProvider.notifier)
                    .start(controller: controller, target: pickTarget),
              ),
            ),
          if (pickTarget != null && locateTarget != null)
            const SizedBox(width: 8),
          if (locateTarget != null)
            Expanded(
              child: _CoordActionButton(
                icon: locateActive
                    ? Icons.location_on_rounded
                    : Icons.location_on_outlined,
                label: '屏幕定位',
                tooltip: locateActive
                    ? '定位中 · 拖动屏幕图标改坐标（再点关闭）'
                    : '在屏幕上拖动图标设置坐标',
                active: locateActive,
                activeColor: AppColors.success,
                onPressed: () => ref
                    .read(screenLocateProvider.notifier)
                    .toggle(controller: controller, target: locateTarget),
              ),
            ),
        ],
      ),
    );
  }
}

/// 坐标操作按钮（半宽）：图标 + 文字，激活时用操作色填充。
class _CoordActionButton extends StatelessWidget {
  const _CoordActionButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.active,
    required this.activeColor,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final bool active;
  final Color activeColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: active ? activeColor : AppColors.canvasBg,
          foregroundColor: active ? AppColors.onAccent : AppColors.inkSecondary,
          side: BorderSide(
            color: active ? activeColor : AppColors.outlineSubtle,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          minimumSize: const Size(0, 34),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
        ),
        icon: Icon(icon, size: 16),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// 媒体节点区域X/Y 行尾的内联框选按钮：点击进入屏幕框选（左键拖出矩形、
/// 绿色描边实时预览、松开确认、Esc 取消），确认后回填 rx/ry/rw/rh
/// 并自动勾选「仅指定区域」。
class _InlineRegionPickButton extends ConsumerWidget {
  const _InlineRegionPickButton({required this.controller, required this.node});

  final fl.NodeEditorController controller;
  final fl.GraphNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(
      regionPickProvider.select((s) => s.active && s.target?.nodeId == node.id),
    );
    final busy = ref.watch(regionPickProvider.select((s) => s.active));
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: IconButton(
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        tooltip: active ? '框选中（Esc 取消）' : '框选区域',
        onPressed: busy
            ? null
            : () => ref
                  .read(regionPickProvider.notifier)
                  .start(
                    controller: controller,
                    target: RegionPickTarget(
                      nodeId: node.id,
                      keyLeft: 'left',
                      keyTop: 'top',
                      keyRight: 'right',
                      keyBottom: 'bottom',
                      label: '框选区域',
                    ),
                  ),
        icon: Icon(
          Icons.crop_free_rounded,
          size: 20,
          color: active ? AppColors.success : AppColors.inkSecondary,
        ),
      ),
    );
  }
}

/// 键位拾取按钮（键盘节点）：单键动作写入 vkCode，组合键动作追加到
/// comboKeys（每按一次追加一个，顺序即按下顺序）。
class _InlineKeyPickButton extends ConsumerWidget {
  const _InlineKeyPickButton({
    required this.controller,
    required this.node,
    required this.target,
  });

  final fl.NodeEditorController controller;
  final fl.GraphNode node;
  final KeyPickTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(
      keyPickProvider.select((s) => s.active && s.target?.nodeId == node.id),
    );
    final busy = ref.watch(keyPickProvider.select((s) => s.active));
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: IconButton(
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        tooltip: active ? '拾取中（Esc 取消）' : target.label,
        onPressed: busy
            ? null
            : () => ref
                  .read(keyPickProvider.notifier)
                  .start(controller: controller, target: target),
        icon: Icon(
          Icons.keyboard_rounded,
          size: 20,
          color: active ? AppColors.peacock : AppColors.inkSecondary,
        ),
      ),
    );
  }
}

/// 文本参数字段：持有本地 controller，避免每次全局刷新导致光标跳动。
/// 焦点期间开启撤销事务：整段输入折叠为一条撤销记录（否则每键一条，
/// 几十个字符就会冲掉全部撤销历史）。
class _ParamTextField extends StatefulWidget {
  const _ParamTextField({
    required this.controller,
    required this.node,
    required this.field,
    required this.onCommit,
    required this.numberMode,
    this.locked = false,
    this.suggestions,
  });

  final fl.NodeEditorController controller;
  final fl.GraphNode node;
  final ParamFieldDef field;
  final void Function(Object value) onCommit;
  final _NumberMode numberMode;

  /// 已连接数据输入时为 true：输入框禁用（值由上游决定）
  final bool locked;

  /// varName 字段的已有变量候选（非空时输入框尾部显示下拉箭头）
  final List<String>? suggestions;

  @override
  State<_ParamTextField> createState() => _ParamTextFieldState();
}

class _ParamTextFieldState extends State<_ParamTextField> {
  late final TextEditingController _controller;
  late final FocusNode _focus;
  bool _txnOpen = false;

  /// 最近一次已知的字段值：外部写入（如坐标拾取）时据此同步文本
  Object? _lastApplied;

  Object? get _rawValue =>
      widget.node.data[widget.field.key] ?? widget.field.defaultValue;

  @override
  void initState() {
    super.initState();
    _lastApplied = _rawValue;
    _controller = TextEditingController(text: _valueText());
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (_focus.hasFocus && !_txnOpen) {
      widget.controller.history.beginTransaction();
      _txnOpen = true;
    } else if (!_focus.hasFocus && _txnOpen) {
      // 空输入时 baseline == graph，commitTransaction 不会产生撤销记录
      widget.controller.history.commitTransaction();
      _txnOpen = false;
    }
  }

  String _valueText() {
    // 锁定（已接入数据输入）时参数不再生效，但保留并显示原值，
    // 断开连线后可直接继续使用
    final v = widget.node.data[widget.field.key] ?? widget.field.defaultValue;
    if (v == null) return '';
    if (v is num) {
      final d = v.toDouble();
      return d == d.roundToDouble() ? d.round().toString() : '$d';
    }
    return '$v';
  }

  /// 数值等价比较（1 与 1.0 视为相同）
  static bool _sameValue(Object? a, Object? b) {
    if (a is num && b is num) return a == b;
    if (a == null || b == null) return a == b;
    return '$a' == '$b';
  }

  @override
  void didUpdateWidget(_ParamTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 节点值被外部改写（如拾取写入新坐标）或锁定状态切换时同步文本；
    // 输入过程中节点值与输入一致，不会打断光标
    final raw = _rawValue;
    if (oldWidget.locked != widget.locked || !_sameValue(raw, _lastApplied)) {
      _lastApplied = raw;
      final t = _valueText();
      if (_controller.text != t) _controller.text = t;
    }
  }

  @override
  void dispose() {
    // 节点被删/面板切换等卸载时兜底提交事务，防止事务泄漏破坏后续撤销粒度
    _focus.removeListener(_onFocusChange);
    if (_txnOpen) {
      widget.controller.history.commitTransaction();
      _txnOpen = false;
    }
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    switch (widget.numberMode) {
      case _NumberMode.int:
        final v = int.tryParse(text.trim());
        if (v != null) {
          _lastApplied = v;
          widget.onCommit(v);
        }
      case _NumberMode.double:
        final v = double.tryParse(text.trim());
        if (v != null) {
          _lastApplied = v;
          widget.onCommit(v);
        }
      case _NumberMode.none:
        _lastApplied = text;
        widget.onCommit(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.field;
    final hint = f.hint ?? (f.type == ParamType.varName ? '变量名' : null);
    final suggestions = widget.suggestions;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        enabled: !widget.locked,
        keyboardType: widget.numberMode == _NumberMode.none
            ? null
            : TextInputType.number,
        style: const TextStyle(fontSize: 13, color: AppColors.ink),
        decoration: InputDecoration(
          labelText: f.label,
          // 锁定态只显示锁图标：图标已足够明确，不再改写标签文字
          hintText: hint,
          suffixIcon: widget.locked
              ? const Icon(
                  Icons.lock_outline_rounded,
                  size: 16,
                  color: AppColors.inkSecondary,
                )
              // varName 字段：尾部下拉箭头快速选择已有变量（也支持手动输入新变量名）
              : suggestions != null && suggestions.isNotEmpty
              ? PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.arrow_drop_down_rounded,
                    size: 22,
                    color: AppColors.inkSecondary,
                  ),
                  tooltip: '选择已有变量',
                  position: PopupMenuPosition.under,
                  onSelected: (v) {
                    _lastApplied = v;
                    _controller.text = v;
                    widget.onCommit(v);
                  },
                  itemBuilder: (_) => [
                    for (final s in suggestions)
                      PopupMenuItem(
                        value: s,
                        child: Text(
                          s,
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.ink,
                          ),
                        ),
                      ),
                  ],
                )
              : null,
          // suffixIcon 默认约束为 48×48，会把锁定态输入框撑得更高；
          // 收到小于文本行高即可，保证锁定前后输入框等高
          suffixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
        ),
        onChanged: _onChanged,
      ),
    );
  }
}

/// 录制选择字段：下拉列出所有已保存录制（显示名称、存储 id，重命名不影响引用）
class _RecordingField extends ConsumerWidget {
  const _RecordingField({
    required this.node,
    required this.field,
    required this.onCommit,
  });

  final fl.GraphNode node;
  final ParamFieldDef field;
  final void Function(Object value) onCommit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listAsync = ref.watch(recordingsProvider);
    final current = node.data[field.key] as String? ?? '';

    return listAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: LinearProgressIndicator(minHeight: 2),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          '录制列表加载失败：$e',
          style: const TextStyle(fontSize: 12, color: AppColors.danger),
        ),
      ),
      data: (items) {
        final exists = items.any((r) => r.id == current);
        final missing = current.isNotEmpty && !exists;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: exists ? current : null,
                dropdownColor: AppColors.moonWhite,
                borderRadius: kDropdownMenuRadius,
                decoration: InputDecoration(
                  labelText: field.label,
                  hintText: items.isEmpty ? '暂无录制，请先到「录制与回放」页录制' : null,
                ),
                items: [
                  for (final Recording r in items)
                    DropdownMenuItem(
                      value: r.id,
                      child: Text(r.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) onCommit(v);
                },
              ),
              if (missing)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '当前选择的录制已删除，请重新选择',
                    style: TextStyle(fontSize: 12, color: AppColors.danger),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 单键字段：常用键下拉（拾取到的特殊键会临时补进选项）+ 行尾内联拾取按钮。
class _KeyField extends ConsumerWidget {
  const _KeyField({
    required this.controller,
    required this.node,
    required this.field,
    required this.onCommit,
  });

  final fl.NodeEditorController controller;
  final fl.GraphNode node;
  final ParamFieldDef field;
  final void Function(Object value) onCommit;

  int get _current {
    final v = node.data[field.key];
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supported = ref.watch(
      automationProvider.select((a) => a.isSupported),
    );
    final vk = _current;
    final options = List.of(kCommonKeys);
    if (vk > 0 && !options.any((o) => o.$1 == vk)) {
      options.insert(0, (vk, keyLabel(vk)));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              key: ValueKey('${node.id}-${field.key}-$vk'),
              initialValue: vk > 0 ? vk : null,
              dropdownColor: AppColors.moonWhite,
              borderRadius: kDropdownMenuRadius,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: field.label,
                hintText: '未设置（点右侧按钮拾取）',
              ),
              items: [
                for (final (code, _) in options)
                  DropdownMenuItem(value: code, child: Text(keyLabel(code))),
              ],
              onChanged: (v) {
                if (v != null) onCommit(v);
              },
            ),
          ),
          if (supported) ...[
            const SizedBox(width: 6),
            _InlineKeyPickButton(
              controller: controller,
              node: node,
              target: KeyPickTarget(
                nodeId: node.id,
                paramKey: field.key,
                label: '拾取按键',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 组合键字段：标题行尾内联拾取按钮 + 有序 chips（可删）+ 追加下拉。顺序即按下顺序。
class _KeyListField extends ConsumerWidget {
  const _KeyListField({
    required this.controller,
    required this.node,
    required this.field,
    required this.onCommit,
  });

  final fl.NodeEditorController controller;
  final fl.GraphNode node;
  final ParamFieldDef field;
  final void Function(Object value) onCommit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supported = ref.watch(
      automationProvider.select((a) => a.isSupported),
    );
    final keys = parseKeyList(node.data[field.key]);
    final addable = kCommonKeys
        .where((o) => !keys.contains(o.$1))
        .toList(growable: false);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  field.label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.inkSecondary,
                  ),
                ),
              ),
              if (supported)
                _InlineKeyPickButton(
                  controller: controller,
                  node: node,
                  target: KeyPickTarget(
                    nodeId: node.id,
                    paramKey: field.key,
                    append: true,
                    label: '拾取组合键',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (keys.isEmpty)
            const Text(
              '尚未添加按键（可用右侧拾取按钮或下方下拉逐个添加）',
              style: TextStyle(fontSize: 12, color: AppColors.inkSecondary),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (var i = 0; i < keys.length; i++)
                  InputChip(
                    label: Text(keyLabel(keys[i])),
                    onDeleted: () {
                      final next = List.of(keys)..removeAt(i);
                      onCommit(next);
                    },
                  ),
              ],
            ),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            key: ValueKey('${node.id}-${field.key}-add-${keys.length}'),
            initialValue: null,
            dropdownColor: AppColors.moonWhite,
            borderRadius: kDropdownMenuRadius,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '添加按键',
              hintText: '选择要追加的键',
            ),
            items: [
              for (final (code, _) in addable)
                DropdownMenuItem(value: code, child: Text(keyLabel(code))),
            ],
            onChanged: (v) {
              if (v != null) onCommit([...keys, v]);
            },
          ),
        ],
      ),
    );
  }
}

/// 模板图片字段：只读路径展示 + 文件选择按钮
class _TemplateFileField extends StatelessWidget {
  const _TemplateFileField({
    required this.node,
    required this.field,
    required this.onCommit,
  });

  final fl.GraphNode node;
  final ParamFieldDef field;
  final void Function(Object value) onCommit;

  Future<void> _pick() async {
    const group = XTypeGroup(
      label: '图片',
      extensions: ['png', 'jpg', 'jpeg', 'bmp'],
    );
    final file = await openFile(
      acceptedTypeGroups: [group],
      confirmButtonText: '选择',
    );
    if (file != null) onCommit(file.path);
  }

  /// 长文件名中段截断并保留扩展名（如「屏幕截图…png」），
  /// 避免尾部 ellipsis 把「屏幕截图xxx.png」截成「屏幕…」看不出文件类型
  static String _elideName(String name) {
    const keep = 14; // 保留的头部字符数（不含 … 与扩展名）
    if (name.length <= keep + 3) return name;
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot) : '';
    final headLen = math.max(1, keep - ext.length);
    return '${name.substring(0, headLen)}…$ext';
  }

  @override
  Widget build(BuildContext context) {
    final path = node.data[field.key] as String? ?? '';
    final name = path.isEmpty ? '' : path.replaceAll('\\', '/').split('/').last;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            field.label,
            style: const TextStyle(fontSize: 12, color: AppColors.inkSecondary),
          ),
          const SizedBox(height: 6),
          // 选择图片独占一行（整宽）：未选择显示引导，已选择显示文件名
          // 悬浮 Tooltip 显示完整路径
          SizedBox(
            width: double.infinity,
            child: Tooltip(
              message: path,
              child: OutlinedButton.icon(
                onPressed: _pick,
                icon: const Icon(Icons.image_outlined, size: 18),
                label: Text(
                  path.isEmpty ? '选择图片…' : _elideName(name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          // 已选择且文件存在 → 下方展示图片预览
          if (path.isNotEmpty)
            FutureBuilder<bool>(
              future: File(path).exists(),
              builder: (context, exists) {
                if (exists.data != true) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: AppColors.ivory,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.outline),
                      ),
                      child: Image.file(
                        File(path),
                        height: 120,
                        width: double.infinity,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            '图片无法预览（文件可能已移动）',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.inkSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// 端口说明的单行抬头：类型/方向徽标（数据·输入 / 数据·输出）+ 端口名称
class _PortDocHeader extends StatelessWidget {
  const _PortDocHeader({required this.port});

  final PortDef port;

  @override
  Widget build(BuildContext context) {
    final color = port.kind == PortKind.exec
        ? AppColors.execWire
        : port.dataType == kPortTypeImage
        ? AppColors.imageWire
        : AppColors.dataWire;
    final badge =
        '${port.kind == PortKind.exec
            ? '执行流'
            : port.dataType == kPortTypeImage
            ? '图像'
            : '数据'}'
        '·${port.dir == PortDir.input ? '输入' : '输出'}';
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: 0.55)),
          ),
          child: Text(
            badge,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            port.label.isEmpty
                ? (port.dir == PortDir.input ? '进入' : '执行出口')
                : port.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body,
          ),
        ),
      ],
    );
  }
}

/// 媒体节点测试区：先运行前置节点，再按真实输入测试本节点并弹窗展示结果
class _MediaTestSection extends ConsumerStatefulWidget {
  const _MediaTestSection({required this.node, required this.controller});

  final fl.GraphNode node;
  final fl.NodeEditorController controller;

  @override
  ConsumerState<_MediaTestSection> createState() => _MediaTestSectionState();
}

class _MediaTestSectionState extends ConsumerState<_MediaTestSection> {
  bool _busy = false;
  BlueprintInterpreter? _probeEngine;

  /// 全局停止热键 F10（与整包运行一致）
  static const int _vkF10 = 0x79;

  /// 调试运行的安全上限：避免前置节点里的无限循环一直跑
  static const Duration _probeTimeout = Duration(seconds: 60);

  String get _label => switch (widget.node.type) {
    'screenshot' => '测试截图',
    'ocr' => '测试识别',
    'imageMatch' => '测试匹配',
    _ => '测试',
  };

  Future<void> _run() async {
    // 运行中再次点击 = 停止调试运行（按钮同时可被 F10 中止）
    if (_busy) {
      _probeEngine?.stop();
      return;
    }
    if (ref.read(runnerProvider).running) {
      _showMessage('脚本正在运行，请先停止后再测试');
      return;
    }
    final script = _currentAsScript();
    if (script == null) {
      _showMessage('无法构建当前蓝图（缺少开始节点）');
      return;
    }
    setState(() => _busy = true);
    final automation = ref.read(automationProvider);
    final logs = <String>[];
    final engine = BlueprintInterpreter(
      automation: automation,
      recognition: ref.read(recognitionProvider),
      hooks: EngineHooks(
        log: logs.add,
        onNodeChange: (_) {},
        yieldToFrame: waitForNextFrame,
      ),
    );
    _probeEngine = engine;
    // 前置节点会真实操作鼠标键盘：期间同样支持 F10 中止
    final hotkey = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (automation.isKeyDown(_vkF10)) engine.stop();
    });
    var timedOut = false;
    final timeout = Timer(_probeTimeout, () {
      timedOut = true;
      engine.stop();
    });
    MediaTestResult result;
    Uint8List? png;
    try {
      final probe = await engine.probeBefore(script, widget.node.id);
      if (timedOut && !probe.reached) {
        result = const MediaTestResult(
          ok: false,
          title: '调试运行超时',
          lines: ['前置节点运行超过 60 秒，已停止。请检查循环是否有退出条件。'],
        );
      } else {
        final inputs = MediaTestInputs(
          reached: probe.reached,
          image: probe.image,
          imageOrigin: probe.imageOrigin,
          region: probe.region,
          targetText: probe.inputs['targetText']?.toString(),
          steps: probe.steps,
          logs: logs,
        );
        result = await ref
            .read(mediaTesterProvider)
            .runTest(widget.node.type, widget.node.data, inputs: inputs);
        final preview = result.preview;
        if (preview != null) {
          // 预览图编码失败不影响文本结果展示
          try {
            png = await preview.toPng();
          } catch (_) {}
        }
      }
    } catch (e) {
      result = MediaTestResult(ok: false, title: '测试失败', lines: ['$e']);
    } finally {
      hotkey.cancel();
      timeout.cancel();
      _probeEngine = null;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await showDialog<void>(
      context: context,
      builder: (_) => _MediaTestResultDialog(result: result, png: png),
    );
  }

  /// 当前编辑器图 → 可执行蓝图（与整包运行的构建方式一致）
  BlueprintScript? _currentAsScript() {
    final loaded = ref.read(currentScriptProvider);
    final script = graphToBlueprint(
      widget.controller.graph,
      name: loaded?.name ?? '未命名',
      createdAt: loaded?.createdAt,
      variables: Map<String, Object>.of(ref.read(scriptVariablesProvider)),
    );
    return script.nodes.values.any((n) => n.type == 'start') ? script : null;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _busy ? '正在运行前置节点…（F10 或再次点击可停止）' : '节点测试（先运行前置节点，再测试本节点）',
            style: const TextStyle(fontSize: 12, color: AppColors.inkSecondary),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _run,
              icon: Icon(
                _busy ? Icons.stop_circle_outlined : Icons.science_outlined,
                size: 18,
              ),
              label: Text(_busy ? '停止调试运行' : _label),
            ),
          ),
        ],
      ),
    );
  }
}

/// 测试结果对话框：状态图标 + 预览图（含命中框）+ 文本结果
class _MediaTestResultDialog extends StatelessWidget {
  const _MediaTestResultDialog({required this.result, this.png});

  final MediaTestResult result;
  final Uint8List? png;

  @override
  Widget build(BuildContext context) {
    final color = result.ok ? AppColors.success : AppColors.danger;
    final preview = result.preview;
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            result.ok
                ? Icons.check_circle_rounded
                : Icons.error_outline_rounded,
            color: color,
            size: 22,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              result.title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        // shrinkWrap：内容短时对话框贴合内容，避免 SingleChildScrollView
        // 撑满 Flexible 高度导致「关闭」按钮被大片空白推到屏幕底部
        child: ListView(
          shrinkWrap: true,
          children: [
            if (png != null && preview != null) ...[
              _PreviewWithMarker(
                png: png!,
                imgW: preview.width,
                imgH: preview.height,
                marker: result.marker,
              ),
              const SizedBox(height: 12),
            ],
            for (final line in result.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: SelectableText(
                  line,
                  style: const TextStyle(fontSize: 13, color: AppColors.ink),
                ),
              ),
            if (result.debugLogs.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text(
                '前置节点日志（最近 10 条）',
                style: TextStyle(fontSize: 12, color: AppColors.inkSecondary),
              ),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 140),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.canvasBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final log in result.debugLogs.length > 10
                        ? result.debugLogs.sublist(result.debugLogs.length - 10)
                        : result.debugLogs)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: SelectableText(
                          log,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.inkSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 预览图 + 命中红框：按图片像素尺寸等比缩放，命中框坐标随之换算
class _PreviewWithMarker extends StatelessWidget {
  const _PreviewWithMarker({
    required this.png,
    required this.imgW,
    required this.imgH,
    this.marker,
  });

  final Uint8List png;
  final int imgW, imgH;
  final (int, int, int, int)? marker;

  @override
  Widget build(BuildContext context) {
    if (imgW <= 0 || imgH <= 0) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        const maxH = 260.0;
        final maxW = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 420.0;
        final scale = math.min(maxW / imgW, maxH / imgH);
        final m = marker;
        return Center(
          child: Container(
            width: imgW * scale,
            height: imgH * scale,
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.outline),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Image.memory(
                    png,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.none,
                    gaplessPlayback: true,
                  ),
                ),
                if (m != null)
                  Positioned(
                    left: m.$1 * scale,
                    top: m.$2 * scale,
                    width: m.$3 * scale,
                    height: m.$4 * scale,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: AppColors.danger, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
