import 'package:flutter/material.dart';

import '../core/theme.dart';

/// 统一页头：左侧标题（含可选说明），右侧状态徽章/操作按钮
class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> trailing;

  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.peacock,
              borderRadius: BorderRadius.circular(2),
              boxShadow: AppShadows.accentGlow,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTextStyles.pageTitle),
                if (subtitle != null) ...[
                  const SizedBox(height: AppSpacing.xxs),
                  Text(subtitle!, style: AppTextStyles.caption),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          ...trailing,
        ],
      ),
    );
  }
}

/// 通用分节卡片：月白圆角底 + 标题行（图标/标题/尾部组件）+ 内容
class SectionCard extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;

  const SectionCard({
    super.key,
    required this.title,
    this.icon,
    this.trailing,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: AppDecor.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: AppColors.peacock.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(icon, size: 16, color: AppColors.peacock),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(child: Text(title, style: AppTextStyles.sectionTitle)),
              ?trailing,
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          child,
        ],
      ),
    );
  }
}

/// 小圆角状态徽章
class StatusBadge extends StatelessWidget {
  final String text;
  final Color color;

  const StatusBadge({super.key, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// 紧凑数字输入：外部数据变化自动回显，输入中不打断焦点
class NumField extends StatefulWidget {
  final String label;
  final int value;
  final int width;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  const NumField({
    super.key,
    required this.label,
    required this.value,
    required this.width,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  State<NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<NumField> {
  late final TextEditingController _controller;
  int _lastReported = 0;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
    _lastReported = widget.value;
  }

  @override
  void didUpdateWidget(NumField old) {
    super.didUpdateWidget(old);
    // 外部数据变化（如拖拽屏幕图标改坐标）→ 同步回显
    if (widget.value != _lastReported) {
      _controller.text = widget.value.toString();
      _lastReported = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width.toDouble(),
      child: TextField(
        controller: _controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: widget.label),
        onChanged: (t) {
          final v = int.tryParse(t.trim());
          if (v == null) return;
          final clamped = v.clamp(widget.min, widget.max);
          _lastReported = clamped;
          widget.onChanged(clamped);
        },
      ),
    );
  }
}
