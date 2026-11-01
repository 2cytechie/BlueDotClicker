import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../models/blueprint.dart';
import '../platform/recording.dart' show replayActions, describeAction;
import '../state/providers.dart';
import 'common.dart';
import 'recording_editor_page.dart';

/// 录制与回放页
class RecordingPage extends ConsumerStatefulWidget {
  const RecordingPage({super.key});

  @override
  ConsumerState<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends ConsumerState<RecordingPage> {
  StreamSubscription<RecordedAction>? _sub;
  int _liveCount = 0; // 录制中实时捕获的动作数
  Recording? _previewRecording; // 左侧预览的录制：录制完成自动置入，也可从历史图标点入

  @override
  void initState() {
    super.initState();
    // 监听录制事件流：每捕获一个动作就刷新计数
    _sub = ref.read(recordingServiceProvider).events.listen((_) {
      if (mounted) setState(() => _liveCount++);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 开始录制
  void _startRecording() {
    final automation = ref.read(automationProvider);
    if (!automation.isSupported) {
      _toast(automation.unsupportedReason ?? '当前平台暂不支持录制');
      return;
    }
    if (ref.read(replayBusyProvider)) {
      _toast('回放进行中，无法开始录制');
      return;
    }
    final service = ref.read(recordingServiceProvider);
    service.start();
    setState(() {
      _liveCount = 0;
      _previewRecording = null;
    });
    _toast('录制已开始，请切换到目标窗口进行操作');
  }

  /// 停止录制并弹出命名对话框后保存；点「取消」则放弃本次录制
  Future<void> _stopRecording() async {
    final service = ref.read(recordingServiceProvider);
    final actions = service.stop();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final defaultName =
        '录制 ${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    final name = await _promptName(initial: defaultName, title: '保存录制');
    if (name == null) {
      // 用户点「取消」：放弃本次录制，不保存
      if (!mounted) return;
      _toast('已放弃本次录制');
      setState(() {
        _previewRecording = null;
        _liveCount = 0;
      });
      return;
    }
    final r = Recording(
      id: 'r_${now.millisecondsSinceEpoch}',
      name: name.isEmpty ? defaultName : name,
      createdAt: now,
      actions: actions,
    );
    await ref.read(recordingStorageProvider).save(r);
    if (!mounted) return;
    setState(() {
      _previewRecording = r;
      _liveCount = 0;
    });
    ref.invalidate(recordingsProvider);
  }

  /// 历史图标点击：在左侧「新建录制」下方预览该录制的动作；再点一次收起
  void _showPreview(Recording r) {
    setState(() {
      _previewRecording = _previewRecording?.id == r.id ? null : r;
    });
  }

  /// 命名输入对话框；返回输入的名称（留空由调用方使用默认名），
  /// 点「取消」返回 null（调用方放弃本次录制）。
  Future<String?> _promptName({
    required String initial,
    required String title,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '名称'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx), // 取消 = 放弃（返回 null）
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result == null) return null;
    return result.trim();
  }

  /// 回放动作序列（按录制时的偏移间隔执行；F10 随时中止；与其他回放互斥）
  Future<void> _replay(List<RecordedAction> actions) async {
    final automation = ref.read(automationProvider);
    if (!automation.isSupported) {
      _toast(automation.unsupportedReason ?? '当前平台暂不支持回放');
      return;
    }
    if (actions.isEmpty) return;
    if (ref.read(replayBusyProvider)) {
      _toast('已有回放进行中');
      return;
    }
    if (ref.read(recordingServiceProvider).isRecording) {
      // 否则会把回放动作录进进行中的录制
      _toast('录制进行中，无法回放');
      return;
    }
    final ok = await ref.read(replayBusyProvider.notifier).runGuarded(() async {
      try {
        await replayActions(automation, actions);
        _toast('回放完成');
      } catch (e) {
        _toast('回放中断：$e');
      }
    });
    if (!ok && mounted) _toast('已有回放进行中');
  }

  String _actionLabel(RecordedAction a) => describeAction(a);

  @override
  Widget build(BuildContext context) {
    final service = ref.read(recordingServiceProvider);
    final recording = service.isRecording;
    // 应用级回放互斥：历史条目回放同样驱动徽章与按钮禁用
    final replaying = ref.watch(replayBusyProvider);

    // 左侧：录制操作 + 最近预览
    final leftCards = <Widget>[
      // ---- 新建录制 ----
      SectionCard(
        title: '新建录制',
        icon: Icons.fiber_manual_record_rounded,
        trailing: recording
            ? const StatusBadge(text: '录制中', color: AppColors.danger)
            : const StatusBadge(text: '待机', color: AppColors.inkSecondary),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              recording
                  ? '正在录制 · 已捕获 $_liveCount 个动作，请切换到目标窗口操作'
                  : '点击「开始录制」后，切换到目标窗口进行点击/滑动/长按/滚轮/键盘操作',
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.inkSecondary,
              ),
            ),
            const SizedBox(height: 14),
            recording
                ? FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.danger,
                    ),
                    onPressed: _stopRecording,
                    icon: const Icon(Icons.stop_rounded),
                    label: const Text('停止录制'),
                  )
                : FilledButton.icon(
                    onPressed: replaying ? null : _startRecording,
                    icon: const Icon(Icons.fiber_manual_record_rounded),
                    label: const Text('开始录制'),
                  ),
          ],
        ),
      ),
      // ---- 动作预览（录制完成自动置入；也可从历史记录图标点入） ----
      if (_previewRecording != null) ...[
        const SizedBox(height: 14),
        SectionCard(
          title: '「${_previewRecording!.name}」动作预览',
          icon: Icons.list_alt_rounded,
          // 立即回放按钮：放在「动作预览」标题文字右侧
          trailing: FilledButton.icon(
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
            onPressed: replaying
                ? null
                : () {
                    final r = _previewRecording;
                    if (r != null) _replay(r.actions);
                  },
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('立即回放'),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < _previewRecording!.actions.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(
                    '${i + 1}. [+${_previewRecording!.actions[i].offsetMs}ms] ${_actionLabel(_previewRecording!.actions[i])}',
                    style: const TextStyle(fontSize: 13, color: AppColors.ink),
                  ),
                ),
            ],
          ),
        ),
      ],
    ];

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PageHeader(
              title: '录制与回放',
              trailing: [
                if (replaying)
                  const StatusBadge(
                    text: '回放中 · F10 中止',
                    color: AppColors.nodeLogic,
                  ),
              ],
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final twoColumn = constraints.maxWidth >= 900;
                  if (twoColumn) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 500,
                          child: ListView(
                            padding: const EdgeInsets.only(right: 16),
                            children: leftCards,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _HistoryPane(
                            onPreview: _showPreview,
                            selectedId: _previewRecording?.id,
                          ),
                        ),
                      ],
                    );
                  }
                  // 窄窗口：单列堆叠
                  return ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      ...leftCards,
                      const SizedBox(height: 14),
                      _HistoryPane(
                        asCard: true,
                        onPreview: _showPreview,
                        selectedId: _previewRecording?.id,
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 历史记录面板：双栏模式下填满高度并内部滚动；单栏模式下自然高度
class _HistoryPane extends ConsumerWidget {
  final bool asCard;

  /// 点击条目图标：在左侧「新建录制」下方预览该录制的动作
  final void Function(Recording recording)? onPreview;

  /// 当前正在左侧预览的录制 id（对应条目图标高亮）
  final String? selectedId;

  const _HistoryPane({this.asCard = false, this.onPreview, this.selectedId});

  /// 从 JSON 文件导入录制
  Future<void> _importRecording(BuildContext context, WidgetRef ref) async {
    const typeGroup = XTypeGroup(label: 'JSON 录制文件', extensions: ['json']);
    final f = await openFile(acceptedTypeGroups: [typeGroup]);
    if (f == null || !context.mounted) return;
    try {
      final text = await f.readAsString();
      final fallback = f.name.replaceAll(RegExp(r'\.json$'), '');
      await ref
          .read(recordingStorageProvider)
          .importFromString(text, fallbackName: fallback);
      ref.invalidate(recordingsProvider);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('导入成功')));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('导入失败：文件不是有效的录制 JSON')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(recordingsProvider);
    final content = list.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Text(
        '加载失败：$e',
        style: const TextStyle(fontSize: 13, color: AppColors.danger),
      ),
      data: (items) {
        if (items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: Text(
                '暂无历史录制，完成一次录制后会自动保存在这里',
                style: TextStyle(fontSize: 13, color: AppColors.inkSecondary),
              ),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.only(bottom: 4),
          shrinkWrap: asCard,
          children: [
            for (final r in items)
              _HistoryTile(
                key: ValueKey(r.id),
                recording: r,
                isLast: r == items.last,
                onPreview: onPreview == null ? null : () => onPreview!(r),
                previewing: r.id == selectedId,
              ),
          ],
        );
      },
    );

    final importBtn = IconButton(
      icon: const Icon(Icons.file_download_outlined, size: 18),
      color: AppColors.inkSecondary,
      tooltip: '导入录制 JSON',
      onPressed: () => _importRecording(context, ref),
    );

    if (asCard) {
      return SectionCard(
        title: '历史记录',
        icon: Icons.history_rounded,
        trailing: importBtn,
        child: content,
      );
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.moonWhite,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_rounded, size: 18, color: Colors.white),
              const SizedBox(width: 6),
              const Text(
                '历史记录',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.ink,
                ),
              ),
              const Spacer(),
              importBtn,
            ],
          ),
          const SizedBox(height: 12),
          Expanded(child: content),
        ],
      ),
    );
  }
}

/// 单条历史记录（展开状态由自身管理）
class _HistoryTile extends ConsumerStatefulWidget {
  final Recording recording;
  final bool isLast;

  /// 点击图标：在左侧预览动作（null = 不支持预览）
  final VoidCallback? onPreview;

  /// 该录制正在左侧预览中（图标高亮实心）
  final bool previewing;

  const _HistoryTile({
    super.key,
    required this.recording,
    required this.isLast,
    this.onPreview,
    this.previewing = false,
  });

  @override
  ConsumerState<_HistoryTile> createState() => _HistoryTileState();
}

class _HistoryTileState extends ConsumerState<_HistoryTile> {
  bool _expanded = false;

  Recording get recording => widget.recording;
  VoidCallback? get onPreview => widget.onPreview;
  bool get previewing => widget.previewing;

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 点击名称进入动作编辑页；返回后刷新列表（编辑页即时保存）
  Future<void> _openEditor(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecordingEditorPage(recording: recording),
      ),
    );
    ref.invalidate(recordingsProvider);
  }

  /// 导出为 JSON 文件
  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final location = await getSaveLocation(
      suggestedName: '${recording.name}.json',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON 录制文件', extensions: ['json']),
      ],
    );
    final path = location?.path;
    if (path == null || path.isEmpty || !context.mounted) return;
    try {
      final text = await ref
          .read(recordingStorageProvider)
          .exportToString(recording);
      await File(path).writeAsString(text);
      if (!context.mounted) return;
      _toast(context, '已导出录制文件');
    } catch (_) {
      if (!context.mounted) return;
      _toast(context, '导出失败');
    }
  }

  /// 紧凑操作按钮（减少占用宽度，给名称留空间）
  Widget _btn(
    IconData icon,
    String tooltip,
    VoidCallback? onPressed, {
    Color? color,
  }) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      padding: const EdgeInsets.all(5),
      icon: Icon(icon, size: 18),
      color: color ?? AppColors.inkSecondary,
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = recording;
    final replaying = ref.watch(replayBusyProvider); // 回放互斥驱动按钮禁用
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              // 录像图标：点击在左侧「新建录制」下方预览动作，再点收起
              Tooltip(
                message: previewing ? '收起预览' : '预览动作（左侧展示）',
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                    icon: Icon(
                      previewing
                          ? Icons.videocam_rounded
                          : Icons.videocam_outlined,
                      size: 20,
                    ),
                    color: previewing
                        ? AppColors.nodeLogic
                        : AppColors.peacock,
                    onPressed: onPreview,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Tooltip(
                  message: '点击名称编辑动作',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => _openEditor(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.name,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.ink,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${_fmtTime(r.createdAt)} · ${r.actions.length} 个动作',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.inkSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _btn(
                _expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                _expanded ? '收起' : '查看',
                () => setState(() => _expanded = !_expanded),
                color: _expanded ? AppColors.peacock : AppColors.inkSecondary,
              ),
              _btn(
                Icons.edit_outlined,
                '编辑动作',
                () => _openEditor(context),
                color: AppColors.peacock,
              ),
              _btn(
                Icons.play_arrow_rounded,
                '回放',
                replaying ? null : () => _replayRecording(context, ref),
                color: AppColors.peacock,
              ),
              _btn(
                Icons.ios_share_rounded,
                '导出 JSON',
                () => _export(context, ref),
              ),
              _btn(
                Icons.drive_file_rename_outline_rounded,
                '重命名',
                () => _rename(context, ref),
              ),
              _btn(
                Icons.delete_outline_rounded,
                '删除',
                () => _delete(context, ref),
                color: AppColors.danger,
              ),
            ],
          ),
        ),
        // 展开的动作明细
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.ivory,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < r.actions.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${i + 1}. [+${r.actions[i].offsetMs}ms] ${_label(r.actions[i])}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.inkSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          crossFadeState: _expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 150),
        ),
        if (!widget.isLast) const Divider(),
      ],
    );
  }

  String _label(RecordedAction a) => describeAction(a);

  /// 重命名录制（文件名是 id，改名后直接覆盖保存）
  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: recording.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名录制'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '名称'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    final newName = (name ?? '').trim();
    if (newName.isEmpty || newName == recording.name) return;
    recording.name = newName;
    await ref.read(recordingStorageProvider).save(recording);
    ref.invalidate(recordingsProvider);
  }

  Future<void> _replayRecording(BuildContext context, WidgetRef ref) async {
    final automation = ref.read(automationProvider);
    if (!automation.isSupported) {
      _toast(context, automation.unsupportedReason ?? '当前平台暂不支持回放');
      return;
    }
    if (ref.read(replayBusyProvider)) {
      _toast(context, '已有回放进行中');
      return;
    }
    if (ref.read(recordingServiceProvider).isRecording) {
      // 否则会把回放动作录进进行中的录制
      _toast(context, '录制进行中，无法回放');
      return;
    }
    // 回放为耗时操作，逐个执行动作（间隔按录制偏移差；F10 随时中止）
    final ok = await ref.read(replayBusyProvider.notifier).runGuarded(() async {
      try {
        await replayActions(automation, recording.actions);
        if (context.mounted) _toast(context, '回放完成');
      } catch (e) {
        if (context.mounted) _toast(context, '回放中断：$e');
      }
    });
    if (!ok && context.mounted) _toast(context, '已有回放进行中');
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除录制'),
        content: Text('确定删除「${recording.name}」吗？此操作不可恢复。'),
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
    if (ok != true) return;
    await ref.read(recordingStorageProvider).delete(recording.id);
    ref.invalidate(recordingsProvider);
  }
}

String _fmtTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
