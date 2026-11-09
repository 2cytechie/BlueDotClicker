import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../models/key_names.dart';
import '../../models/node_types.dart';
import '../../state/providers.dart';

/// 生成 NodeEditor.nodeBuilder 回调；运行中节点以孔雀蓝发光高亮。
/// [runningNode] 为运行中节点 id 的通知器：只重建高亮状态翻转的节点体，
/// 避免节点切换时整页/整张画布重建。
fl.NodeWidgetBuilder nodeBodyBuilder({ValueListenable<String?>? runningNode}) =>
    (context, node, state) => _NodeHighlight(
      runningNode: runningNode,
      nodeId: node.id,
      builder: (highlight) => _NodeBodyContent(
        node: node,
        def: nodeDef(node.type),
        categoryColor: nodeDef(node.type).category.color,
        selected: state.isSelected,
        highlight: highlight,
        connectedPorts: state.connectedPorts,
      ),
    );

/// 高亮订阅器：仅在自身高亮状态翻转时重建（其余节点不受影响）
class _NodeHighlight extends StatefulWidget {
  const _NodeHighlight({
    required this.runningNode,
    required this.nodeId,
    required this.builder,
  });

  final ValueListenable<String?>? runningNode;
  final String nodeId;
  final Widget Function(bool highlight) builder;

  @override
  State<_NodeHighlight> createState() => _NodeHighlightState();
}

class _NodeHighlightState extends State<_NodeHighlight> {
  bool _highlight = false;

  @override
  void initState() {
    super.initState();
    _highlight = widget.runningNode?.value == widget.nodeId;
    widget.runningNode?.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(_NodeHighlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.runningNode, widget.runningNode) &&
        oldWidget.nodeId == widget.nodeId) {
      return;
    }
    oldWidget.runningNode?.removeListener(_onChanged);
    _highlight = widget.runningNode?.value == widget.nodeId;
    widget.runningNode?.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.runningNode?.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    final next = widget.runningNode?.value == widget.nodeId;
    if (next == _highlight) return;
    setState(() => _highlight = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(_highlight);
}

class _NodeBodyContent extends StatelessWidget {
  const _NodeBodyContent({
    required this.node,
    required this.def,
    required this.categoryColor,
    required this.selected,
    required this.highlight,
    this.connectedPorts = const {},
  });

  final fl.GraphNode node;
  final NodeTypeDef def;
  final Color categoryColor;
  final bool selected;
  final bool highlight;

  /// 当前已有连线的端口 id 集合（由 NodeRenderState 提供），
  /// 用于摘要中体现「数据边优先」的取值来源。
  final Set<String> connectedPorts;

  @override
  Widget build(BuildContext context) {
    final summary = _summaryLines();
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.moonWhite,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: highlight
              ? AppColors.success
              : (selected ? AppColors.peacock : AppColors.outline),
          width: highlight || selected ? 2 : 1,
        ),
        boxShadow: highlight
            ? [
                BoxShadow(
                  color: AppColors.peacock.withValues(alpha: 0.35),
                  blurRadius: 12,
                ),
              ]
            : const [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 类别色顶栏
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: categoryColor,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(9),
              ),
            ),
            child: Row(
              children: [
                Icon(def.icon, size: 15, color: Colors.white),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    def.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 参数摘要
          if (summary.isNotEmpty || node.type == 'playRecording')
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in summary.take(4))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 1),
                      child: Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.inkSecondary,
                        ),
                      ),
                    ),
                  // 执行录制节点：显示所选录制（跟随录制重命名/删除实时更新）
                  if (node.type == 'playRecording')
                    _RecordingSummary(
                      recordingId: node.data['recordingId'] as String? ?? '',
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 参数摘要（最多 4 行）：按节点当前动作只列出适用参数
  List<String> _summaryLines() {
    final lines = <String>[];
    // 默认值 + 当前值补齐（动作切换后旧数据可能缺字段）
    final data = <String, Object?>{};
    for (final f in def.params) {
      data[f.key] = f.defaultValue;
    }
    data.addAll(node.data);
    String? v(String key) => data[key]?.toString();

    switch (node.type) {
      case 'mouse':
        {
          final action = v('action') ?? 'click';
          lines.add('动作：${mouseActionLabel(action)}');
          switch (action) {
            case 'swipe':
              if (v('mode') == 'direction') {
                lines.add('方向 ${v('angle')}° 距离 ${v('distance')}');
              } else {
                lines.add(
                  '(${v('x')},${v('y')}) → (${v('endX')},${v('endY')})',
                );
              }
              lines.add('${v('durationMs')}ms ${_buttonName(v('button'))}');
            case 'scroll':
              lines.add('(${v('x')}, ${v('y')})');
              lines.add('dx=${v('dx')} dy=${v('dy')}');
            case 'move':
              final dur = _asInt(data['moveDurationMs']);
              lines.add('→ (${v('x')}, ${v('y')})${dur > 0 ? ' ${dur}ms' : ''}');
            case 'longPress':
              lines.add('(${v('x')}, ${v('y')}) ${_buttonName(v('button'))}');
              lines.add('保持 ${v('holdMs')}ms');
            default: // click / doubleClick
              lines.add('(${v('x')}, ${v('y')}) ${_buttonName(v('button'))}');
          }
        }
      case 'keyboard':
        {
          final action = v('action') ?? 'tap';
          lines.add('动作：${keyboardActionLabel(action)}');
          if (action == 'combo') {
            final combo = formatKeyList(parseKeyList(data['comboKeys']));
            lines.add(combo.isEmpty ? '未设置组合键' : combo);
          } else {
            lines.add(keyLabel(_asInt(data['vkCode'])));
          }
          if (action == 'tap' || action == 'combo') {
            lines.add('按住 ${v('durationMs')}ms');
          }
        }
      case 'screenshot':
      case 'ocr':
      case 'imageMatch':
        if (node.type != 'screenshot') {
          if (node.type == 'imageMatch') {
            final tpl = v('templatePath') ?? '';
            lines.add(
              '模板 ${tpl.isEmpty ? '未选择' : tpl.split('\\').last.split('/').last}',
            );
            lines.add('阈值 ${v('threshold')}');
          }
          if (node.type == 'ocr') {
            final target = v('targetText');
            if (target != null && target.isNotEmpty) {
              lines.add('目标文本：$target');
            }
          }
        }
        if (v('useRegion') == 'true') {
          lines.add(
            '区域 (${v('left')},${v('top')}) → (${v('right')},${v('bottom')})',
          );
        } else {
          lines.add(node.type == 'screenshot' ? '全屏' : '全屏区域');
        }
      case 'condition':
        lines.add('左值 ${v('leftConst')}');
        lines.add('${_opLabel(v('op'))} 右值 ${v('rightConst')}');
      case 'loop':
        // 数据边优先：左值/右值接入数据边时摘要显示「上游数据」，
        // 否则兜底显示常量参数（与引擎 _resolveInput 的取值顺序一致）
        String operandText(String port, String constKey, String fallback) =>
            connectedPorts.contains(port)
            ? '上游数据'
            : (v(constKey)?.isEmpty == false ? v(constKey)! : fallback);
        lines.add(
          '当 ${operandText('left', 'leftConst', '左值')} ${_opLabel(v('op'))} ${operandText('right', 'rightConst', '右值')} 时循环',
        );
        final maxIt = _asInt(data['maxIterations']);
        if (maxIt > 0) lines.add('最多 $maxIt 次');
      case 'add':
      case 'subtract':
        lines.add(
          '${v('a')} ${node.type == 'add' ? '+' : '−'} ${v('b')}',
        );
      case 'delay':
        lines.add('等待 ${v('ms')}ms');
      case 'setVar':
        lines.add('${v('name')} = ${v('const')}');
      case 'getVar':
        lines.add(v('name')?.isEmpty == false ? '读取 ${v('name')}' : '未选择变量');
      case 'saveData':
        lines.add('保存 ${v('fileName')}');
      case 'start':
        final c = v('count') ?? '1'; // 旧脚本无此参数时按默认 1 次
        lines.add(c == '0' ? '一直执行（F10 停止）' : '执行 $c 次');
        // 跨轮语义提示：每轮清空端口缓存/截图，变量跨轮保留
        if (_asInt(data['count']) != 1) {
          lines.add('每轮清空端口缓存/截图，变量跨轮保留');
        }
      default:
        // 已移除/未知类型：显式提示，避免看起来像正常节点
        lines.add('已移除的类型：${node.type}');
    }
    return lines;
  }

  static int _asInt(Object? v) {
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  static String _buttonName(String? button) => switch (button) {
    'right' => '右键',
    'middle' => '中键',
    _ => '左键',
  };

  String _opLabel(String? op) => switch (op) {
    '==' => '等于',
    '!=' => '不等于',
    '>' => '大于',
    '<' => '小于',
    '>=' => '≥',
    '<=' => '≤',
    'contains' => '包含',
    'notContains' => '不包含',
    _ => '?',
  };
}

/// 执行录制节点的录制摘要：按 id 解析录制名（未选择/已删除给出提示）
class _RecordingSummary extends ConsumerWidget {
  const _RecordingSummary({required this.recordingId});

  final String recordingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const style = TextStyle(fontSize: 11, color: AppColors.inkSecondary);
    final async = ref.watch(recordingsProvider);

    Widget line(String label) => Text(
      '录制：$label',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );

    if (recordingId.isEmpty) return line('未选择录制');
    return async.when(
      loading: () => line('…'),
      error: (e, _) => line('加载失败'),
      data: (list) {
        var name = '';
        for (final r in list) {
          if (r.id == recordingId) {
            name = r.name;
            break;
          }
        }
        return line(name.isEmpty ? '录制已删除' : name);
      },
    );
  }
}
