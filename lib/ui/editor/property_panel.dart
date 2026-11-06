import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../models/blueprint.dart';
import '../../models/key_names.dart';
import '../../models/node_types.dart';
import '../../services/media_tester.dart';
import '../../state/providers.dart';

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

  /// 各节点的拾取目标：(按钮标签, keyX, keyY, 按键参数键或 null)
  List<(String, String, String, String?)> _pickTargets(
    String type,
    Map<String, Object?> data,
  ) => switch (type) {
    'mouse' => switch ('${data['action']}') {
      'click' || 'doubleClick' || 'longPress' || 'press' => [
        ('拾取坐标', 'x', 'y', 'button'),
      ],
      // 滚轮/移动只需要位置；抬起不需要坐标
      'scroll' || 'move' => [('拾取坐标', 'x', 'y', null)],
      'swipe' => [
        ('拾取起点', 'startX', 'startY', null),
        if (data['mode'] != 'direction') ('拾取终点', 'endX', 'endY', null),
      ],
      _ => const [],
    },
    _ => const [],
  };

  /// 屏幕坐标拾取区：点击按钮进入全局拾取（左/右/中键确认，Esc 取消）。
  /// 点击/双击/长按/按住节点的按键类型随确认点击一并记录。
  Widget _buildPickSection(WidgetRef ref, fl.GraphNode node) {
    final automation = ref.watch(automationProvider);
    if (!automation.isSupported) return const SizedBox.shrink();
    final data = _effectiveData(node);
    final targets = _pickTargets(node.type, data);
    if (targets.isEmpty) return const SizedBox.shrink();
    final action = '${data['action']}';
    final recordsButton = node.type == 'mouse' &&
        (action == 'click' || action == 'doubleClick');

    final pick = ref.watch(
      coordinatePickProvider.select(
        (s) => s.active && s.target?.nodeId == node.id,
      ),
    );
    final pickBusy = ref.watch(coordinatePickProvider.select((s) => s.active));

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '屏幕坐标拾取${recordsButton ? '（按键类型随点击记录）' : ''}',
            style: const TextStyle(fontSize: 12, color: AppColors.inkSecondary),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final (label, keyX, keyY, buttonKey) in targets)
                OutlinedButton.icon(
                  onPressed: pickBusy
                      ? null
                      : () => ref
                            .read(coordinatePickProvider.notifier)
                            .start(
                              controller: controller,
                              target: PickTarget(
                                nodeId: node.id,
                                keyX: keyX,
                                keyY: keyY,
                                buttonKey: buttonKey,
                                label: label,
                              ),
                            ),
                  icon: const Icon(Icons.my_location_rounded, size: 15),
                  label: Text(pick ? '拾取中…' : label),
                ),
              if (pick)
                TextButton(
                  onPressed: () =>
                      ref.read(coordinatePickProvider.notifier).cancel(),
                  child: const Text('取消'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 键盘键位拾取区（仅键盘节点）：拾取的单键写入 vkCode，组合键动作追加到
  /// comboKeys（每按一次追加一个，顺序即按下顺序）。
  Widget _buildKeyPickSection(WidgetRef ref, fl.GraphNode node) {
    if (node.type != 'keyboard') return const SizedBox.shrink();
    final automation = ref.watch(automationProvider);
    if (!automation.isSupported) return const SizedBox.shrink();
    final data = _effectiveData(node);
    final isCombo = '${data['action']}' == 'combo';

    final picking = ref.watch(
      keyPickProvider.select((s) => s.active && s.target?.nodeId == node.id),
    );
    final busy = ref.watch(keyPickProvider.select((s) => s.active));

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isCombo ? '键位拾取（每次追加一个键）' : '键位拾取',
            style: const TextStyle(fontSize: 12, color: AppColors.inkSecondary),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => ref.read(keyPickProvider.notifier).start(
                          controller: controller,
                          target: KeyPickTarget(
                            nodeId: node.id,
                            paramKey: isCombo ? 'comboKeys' : 'vkCode',
                            append: isCombo,
                            label: isCombo ? '拾取组合键' : '拾取按键',
                          ),
                        ),
                icon: const Icon(Icons.keyboard_rounded, size: 15),
                label: Text(picking ? '拾取中…' : (isCombo ? '拾取组合键' : '拾取按键')),
              ),
              if (picking)
                TextButton(
                  onPressed: () => ref.read(keyPickProvider.notifier).cancel(),
                  child: const Text('取消'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 左右并排渲染的坐标参数对（其余字段维持上下排列）
  static const List<(String, String)> _kCoordPairs = [
    ('x', 'y'),
    ('startX', 'startY'),
    ('endX', 'endY'),
    ('dx', 'dy'),
    // 媒体节点区域参数：区域X/区域Y 一行，区域宽/区域高 一行
    ('rx', 'ry'),
    ('rw', 'rh'),
  ];

  /// 参数列表：先按节点当前取值过滤掉不适用的字段（如非滑动动作不显示起终点），
  /// 再让坐标对左右并排（各占一半宽），其余字段一字段一行。
  List<Widget> _buildParamFields(WidgetRef ref, fl.GraphNode node) {
    final data = _effectiveData(node);
    final params =
        nodeDef(node.type).params.where((f) => f.visibleFor(data)).toList();
    final children = <Widget>[];
    var i = 0;
    while (i < params.length) {
      final f = params[i];
      final next = i + 1 < params.length ? params[i + 1] : null;
      if (next != null &&
          _kCoordPairs.any((p) => p.$1 == f.key && p.$2 == next.key)) {
        children.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildField(ref, node, f)),
              const SizedBox(width: 10),
              Expanded(child: _buildField(ref, node, next)),
            ],
          ),
        );
        i += 2;
        continue;
      }
      children.add(_buildField(ref, node, f));
      i += 1;
    }
    return children;
  }

  /// 媒体节点测试区（仅媒体节点显示）：按当前参数执行一次并弹窗展示结果
  Widget _buildTestSection(fl.GraphNode node) {
    if (nodeDef(node.type).category != NodeCategory.media) {
      return const SizedBox.shrink();
    }
    return _MediaTestSection(node: node);
  }

  /// 输入端口说明区：解释左侧输入端口的含义（仅填写了说明的端口，即媒体节点）
  Widget _buildInputDocSection(fl.GraphNode node) {
    final inputs = nodeDef(
      node.type,
    ).inputs.where((p) => p.note != null).toList();
    if (inputs.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.ivory,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '输入端口说明',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            for (final p in inputs) ...[
              _PortDocHeader(port: p),
              const SizedBox(height: 4),
              Text(
                p.note!,
                style: const TextStyle(
                  fontSize: 16,
                  height: 1.5,
                  color: AppColors.inkSecondary,
                ),
              ),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildField(WidgetRef ref, fl.GraphNode node, ParamFieldDef f) {
    void onCommit(Object v) => _commit(node, f, v);
    switch (f.type) {
      case ParamType.int:
        return _ParamTextField(
          controller: controller,
          node: node,
          field: f,
          onCommit: onCommit,
          numberMode: _NumberMode.int,
        );
      case ParamType.double:
        return _ParamTextField(
          controller: controller,
          node: node,
          field: f,
          onCommit: onCommit,
          numberMode: _NumberMode.double,
        );
      case ParamType.string:
      case ParamType.varName:
        return _ParamTextField(
          controller: controller,
          node: node,
          field: f,
          onCommit: onCommit,
          numberMode: _NumberMode.none,
        );
      case ParamType.bool:
        final v = node.data[f.key];
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(
            f.label,
            style: const TextStyle(fontSize: 13, color: AppColors.ink),
          ),
          value: v is bool ? v : f.defaultValue == true,
          onChanged: onCommit,
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
        return _KeyField(node: node, field: f, onCommit: onCommit);
      case ParamType.keyList:
        return _KeyListField(node: node, field: f, onCommit: onCommit);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListenableBuilder(
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
                Text(
                  '选中节点以编辑属性',
                  style: TextStyle(fontSize: 13, color: AppColors.inkSecondary),
                ),
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
                      color: color.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(def.icon, color: color, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          def.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.ink,
                          ),
                        ),
                        Text(
                          known ? def.type : '原类型：${node.type}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.inkSecondary,
                          ),
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
                        _buildPickSection(ref, node),
                        _buildKeyPickSection(ref, node),
                        ..._buildParamFields(ref, node),
                        _buildInputDocSection(node),
                        const SizedBox(height: 12),
                        Text(
                          def.description,
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.5,
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
            color: AppColors.danger.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.danger.withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '该节点类型已移除',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.danger,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '原类型「${node.type}」不再支持，无法编辑或执行。'
                '与其相连的连线在打开脚本时已被移除，请删除该节点后重建对应操作。',
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: AppColors.inkSecondary,
                ),
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
                child: Text(
                  '注释',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink,
                  ),
                ),
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
  });

  final fl.NodeEditorController controller;
  final fl.GraphNode node;
  final ParamFieldDef field;
  final void Function(Object value) onCommit;
  final _NumberMode numberMode;

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
    // 节点值被外部改写（如拾取写入新坐标）时同步文本；
    // 输入过程中节点值与输入一致，不会打断光标
    final raw = _rawValue;
    if (!_sameValue(raw, _lastApplied)) {
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        keyboardType: widget.numberMode == _NumberMode.none
            ? null
            : TextInputType.number,
        style: const TextStyle(fontSize: 13, color: AppColors.ink),
        decoration: InputDecoration(labelText: f.label, hintText: hint),
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

/// 单键字段：常用键下拉（拾取到的特殊键会临时补进选项）。
/// 「拾取按键」按钮在节点上方的键位拾取区。
class _KeyField extends StatelessWidget {
  const _KeyField({
    required this.node,
    required this.field,
    required this.onCommit,
  });

  final fl.GraphNode node;
  final ParamFieldDef field;
  final void Function(Object value) onCommit;

  int get _current {
    final v = node.data[field.key];
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final vk = _current;
    final options = List.of(kCommonKeys);
    if (vk > 0 && !options.any((o) => o.$1 == vk)) {
      options.insert(0, (vk, keyLabel(vk)));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<int>(
        key: ValueKey('${node.id}-${field.key}-$vk'),
        initialValue: vk > 0 ? vk : null,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: field.label,
          hintText: '未设置（点上方「拾取按键」）',
        ),
        items: [
          for (final (code, _) in options)
            DropdownMenuItem(value: code, child: Text(keyLabel(code))),
        ],
        onChanged: (v) {
          if (v != null) onCommit(v);
        },
      ),
    );
  }
}

/// 组合键字段：有序 chips（可删）+ 追加下拉。顺序即按下顺序。
class _KeyListField extends StatelessWidget {
  const _KeyListField({
    required this.node,
    required this.field,
    required this.onCommit,
  });

  final fl.GraphNode node;
  final ParamFieldDef field;
  final void Function(Object value) onCommit;

  @override
  Widget build(BuildContext context) {
    final keys = parseKeyList(node.data[field.key]);
    final addable = kCommonKeys
        .where((o) => !keys.contains(o.$1))
        .toList(growable: false);
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
          if (keys.isEmpty)
            const Text(
              '尚未添加按键（可用上方「拾取组合键」或下方下拉逐个添加）',
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

  @override
  Widget build(BuildContext context) {
    final path = node.data[field.key] as String? ?? '';
    final name = path.isEmpty ? '' : path.replaceAll('\\', '/').split('/').last;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  field.label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.inkSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.ivory,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.outline),
                  ),
                  child: Text(
                    path.isEmpty ? '未选择模板图片' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: path.isEmpty
                          ? AppColors.inkSecondary
                          : AppColors.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: _pick, child: const Text('选择…')),
        ],
      ),
    );
  }
}

/// 输入端口说明的单行抬头：类型徽标（执行流/数据）+ 端口名称
class _PortDocHeader extends StatelessWidget {
  const _PortDocHeader({required this.port});

  final PortDef port;

  @override
  Widget build(BuildContext context) {
    final exec = port.kind == PortKind.exec;
    final color = exec ? AppColors.execWire : AppColors.dataWire;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color),
          ),
          child: Text(
            exec ? '执行流' : '数据',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            port.label.isEmpty ? (exec ? '进入' : port.key) : port.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.ink,
            ),
          ),
        ),
      ],
    );
  }
}

/// 媒体节点测试区：按当前参数执行一次采集/识别，弹窗展示结果
class _MediaTestSection extends ConsumerStatefulWidget {
  const _MediaTestSection({required this.node});

  final fl.GraphNode node;

  @override
  ConsumerState<_MediaTestSection> createState() => _MediaTestSectionState();
}

class _MediaTestSectionState extends ConsumerState<_MediaTestSection> {
  bool _busy = false;

  String get _label => switch (widget.node.type) {
    'screenshot' => '测试截图',
    'ocr' => '测试识别',
    'imageMatch' => '测试匹配',
    _ => '测试',
  };

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    MediaTestResult result;
    Uint8List? png;
    try {
      result = await ref
          .read(mediaTesterProvider)
          .runTest(widget.node.type, widget.node.data);
      final preview = result.preview;
      if (preview != null) {
        // 预览图编码失败不影响文本结果展示
        try {
          png = await preview.toPng();
        } catch (_) {}
      }
    } catch (e) {
      result = MediaTestResult(ok: false, title: '测试失败', lines: ['$e']);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await showDialog<void>(
      context: context,
      builder: (_) => _MediaTestResultDialog(result: result, png: png),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '节点测试（按当前参数执行一次）',
            style: TextStyle(fontSize: 12, color: AppColors.inkSecondary),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _run,
              icon: const Icon(Icons.science_outlined, size: 18),
              label: Text(_busy ? '测试中…' : _label),
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
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
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
