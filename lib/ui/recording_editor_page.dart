import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../models/blueprint.dart';
import '../platform/recording.dart' show describeAction, replayActions, vkName;
import '../platform/screen_marker.dart';
import '../platform/win32/user32.dart' as u32;
import '../services/script_storage.dart' show RecordingStorage;
import '../state/providers.dart';
import 'common.dart';

/// 录制动作编辑页：从历史记录点击名称进入。
/// 支持修改每个动作参数、删除、上移/下移、追加新动作、试运行（F10 中止）、
/// 屏幕定位（分层窗口置顶图标 + 拖拽改坐标）。所有修改即时保存。
class RecordingEditorPage extends ConsumerStatefulWidget {
  final Recording recording;
  const RecordingEditorPage({super.key, required this.recording});

  @override
  ConsumerState<RecordingEditorPage> createState() =>
      _RecordingEditorPageState();
}

class _RecordingEditorPageState extends ConsumerState<RecordingEditorPage> {
  late String _name;
  late final List<RecordedAction> _actions;
  late final List<int> _uids; // 动作稳定标识（ReorderableListView key 用，跟动作走）
  int _uidNext = 0;
  int _expandedIndex = -1; // 展开编辑面板的动作（-1 = 全收起）
  int _markerIndex = -1; // 屏幕定位激活的动作（-1 = 无）
  bool _replaying = false;
  Future<void> _saveChain = Future.value(); // 串行化保存，避免乱序覆盖

  // dispose/异步闭包中禁止使用 ref（Riverpod 3 会抛 StateError），
  // 须在 didChangeDependencies 捕获应用级服务引用
  ScreenMarkerService? _markerService;
  RecordingStorage? _storage; // 保存链闭包可能在页面销毁后执行

  // ---- 撤销/重做（快照式；参数微调按 1 秒窗口合并为一步）----
  final List<(List<RecordedAction>, List<int>)> _undoStack = [];
  final List<(List<RecordedAction>, List<int>)> _redoStack = [];
  static const _maxUndo = 50;
  String? _lastMergeKey;
  DateTime? _lastSnapshotTime;

  void _pushUndo({String? mergeKey}) {
    final now = DateTime.now();
    // 同一目标 1 秒内的连续微调（打字/方向键长按）合并为一个撤销步
    if (mergeKey != null &&
        _lastMergeKey == mergeKey &&
        _lastSnapshotTime != null &&
        now.difference(_lastSnapshotTime!) < const Duration(seconds: 1)) {
      return;
    }
    _lastMergeKey = mergeKey;
    _lastSnapshotTime = now;
    _undoStack.add((List.of(_actions), List.of(_uids)));
    if (_undoStack.length > _maxUndo) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  void _undo() {
    if (_undoStack.isEmpty || _replaying || _focusInEditable()) return;
    _redoStack.add((List.of(_actions), List.of(_uids)));
    final (actions, uids) = _undoStack.removeLast();
    _lastMergeKey = null;
    setState(() {
      _actions
        ..clear()
        ..addAll(actions);
      _uids
        ..clear()
        ..addAll(uids);
      _expandedIndex = -1;
    });
    _hideMarker();
    _save();
  }

  void _redo() {
    if (_redoStack.isEmpty || _replaying || _focusInEditable()) return;
    _undoStack.add((List.of(_actions), List.of(_uids)));
    final (actions, uids) = _redoStack.removeLast();
    _lastMergeKey = null;
    setState(() {
      _actions
        ..clear()
        ..addAll(actions);
      _uids
        ..clear()
        ..addAll(uids);
      _expandedIndex = -1;
    });
    _hideMarker();
    _save();
  }

  /// 焦点是否在文本输入框内（快捷键不抢文本框的方向键/Delete/退格）
  bool _focusInEditable() {
    var node = FocusManager.instance.primaryFocus;
    while (node != null) {
      if (node.context?.widget is EditableText) return true;
      node = node.parent;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _name = widget.recording.name;
    _actions = List.of(widget.recording.actions);
    _uids = [for (var i = 0; i < _actions.length; i++) i];
    _uidNext = _actions.length;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _markerService ??= ref.read(screenMarkerProvider);
    _storage ??= ref.read(recordingStorageProvider);
  }

  @override
  void dispose() {
    // Riverpod 3 禁止在 dispose 中使用 ref（会抛 StateError 使 hide 不执行，
    // 屏幕定位图标与全局钩子将残留在屏幕上）——用捕获的引用收尾
    _markerService?.hide();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 即时保存（串行链避免连续编辑乱序写文件）。
  /// 快照与 storage 引用在调用时同步捕获——闭包可能在页面 dispose 之后执行，
  /// 那时使用 ref 会抛 StateError，导致退出前的最后一次编辑丢失。
  void _save() {
    final storage = _storage;
    if (storage == null) return; // 理论不可达（didChangeDependencies 先于任何交互）
    final recording = Recording(
      id: widget.recording.id,
      name: _name,
      createdAt: widget.recording.createdAt,
      actions: List.of(_actions),
    );
    _saveChain = _saveChain
        .then((_) async {
          await storage.save(recording);
          // 页面已销毁时不再 invalidate：列表刷新由录制页 _openEditor 返回时兜底
          if (mounted) ref.invalidate(recordingsProvider);
        })
        .catchError((e, st) {
          // 单次失败（如磁盘错误）不拖垮后续保存链
          debugPrint('保存录制失败: $e\n$st');
        });
  }

  void _updateAction(int index, RecordedAction action) {
    _pushUndo(mergeKey: 'edit_$index'); // 连续微调合并为一个撤销步
    setState(() => _actions[index] = action);
    _save();
    _refreshMarker();
  }

  /// 添加动作；[insertAt] 为插入位置（null = 追加到末尾）
  void _addAction(RecordedAction action, {int? insertAt}) {
    _pushUndo();
    setState(() {
      final at = (insertAt == null || insertAt > _actions.length)
          ? _actions.length
          : insertAt;
      _actions.insert(at, action);
      _uids.insert(at, _uidNext++);
      _expandedIndex = at; // 新动作直接展开便于编辑
    });
    _save();
  }

  void _removeAction(int index) {
    _pushUndo();
    setState(() {
      _actions.removeAt(index);
      _uids.removeAt(index);
      if (_expandedIndex >= _actions.length) _expandedIndex = -1;
    });
    if (_markerIndex == index) {
      _hideMarker();
    } else if (_markerIndex > index) {
      _markerIndex--;
    }
    _save();
  }

  void _moveAction(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _actions.length) return;
    _pushUndo();
    if (_markerIndex == index) {
      _hideMarker();
    } else if (_markerIndex == target) {
      _markerIndex = index;
    }
    setState(() {
      final a = _actions.removeAt(index);
      _actions.insert(target, a);
      final uid = _uids.removeAt(index);
      _uids.insert(target, uid);
      if (_expandedIndex == index) {
        _expandedIndex = target;
      } else if (_expandedIndex == target) {
        _expandedIndex = index;
      }
    });
    _save();
  }

  /// 拖拽重排（ReorderableListView）：同步展开状态与屏幕定位的索引。
  /// onReorderItem 的 newIndex 已按"移除原项后"的语义调整，无需再 -1。
  void _onReorderItem(int oldIndex, int newIndex) {
    if (newIndex == oldIndex) return;
    _pushUndo();
    setState(() {
      final a = _actions.removeAt(oldIndex);
      _actions.insert(newIndex, a);
      final uid = _uids.removeAt(oldIndex);
      _uids.insert(newIndex, uid);
      _expandedIndex = _remapIndex(_expandedIndex, oldIndex, newIndex);
      _markerIndex = _remapIndex(_markerIndex, oldIndex, newIndex);
    });
    _save();
    _refreshMarker();
  }

  /// 元素从 oldIndex 移到 newIndex 后，原 index 的元素的新位置
  int _remapIndex(int idx, int oldIndex, int newIndex) {
    if (idx < 0) return idx;
    if (idx == oldIndex) return newIndex;
    if (oldIndex < newIndex) {
      if (idx > oldIndex && idx <= newIndex) return idx - 1;
    } else {
      if (idx >= newIndex && idx < oldIndex) return idx + 1;
    }
    return idx;
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _name);
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
    if (newName.isEmpty || newName == _name) return;
    setState(() => _name = newName);
    _save();
  }

  Future<void> _replay() async {
    if (_replaying) return;
    final automation = ref.read(automationProvider);
    if (!automation.isSupported) {
      _toast(automation.unsupportedReason ?? '当前平台暂不支持回放');
      return;
    }
    if (_actions.isEmpty) {
      _toast('没有可回放的动作');
      return;
    }
    if (ref.read(replayBusyProvider)) {
      _toast('已有回放进行中');
      return;
    }
    if (ref.read(recordingServiceProvider).isRecording) {
      // 录制在后台运行时试运行，会把回放动作录进进行中的录制
      _toast('录制进行中，无法回放');
      return;
    }
    ref.read(screenMarkerProvider).hide();
    final ok = await ref.read(replayBusyProvider.notifier).runGuarded(() async {
      setState(() {
        _replaying = true;
        _markerIndex = -1;
      });
      try {
        await replayActions(
          automation,
          List.of(_actions), // 快照：回放中编辑不影响本轮
        );
        _toast('回放完成');
      } catch (e) {
        _toast('回放中断：$e');
      } finally {
        if (mounted) setState(() => _replaying = false);
      }
    });
    if (!ok && mounted) _toast('已有回放进行中');
  }

  // ---- 键盘快捷键（方向键微调坐标 / Delete 删除；焦点在输入框时不触发）----

  /// 录制总时长（最后一个动作的结束时刻，秒，1 位小数）
  String get _totalSeconds {
    if (_actions.isEmpty) return '0.0';
    var end = 0;
    for (final a in _actions) {
      final dur = switch (a) {
        RecSwipe w => w.durationMs,
        RecLongPress p => p.durationMs,
        RecKey k => k.durationMs,
        RecCombo c => c.durationMs,
        _ => 0,
      };
      final e = a.offsetMs + dur;
      if (e > end) end = e;
    }
    return (end / 1000).toStringAsFixed(1);
  }

  void _deleteExpandedAction() {
    if (_focusInEditable() || _expandedIndex < 0) return;
    _removeAction(_expandedIndex);
  }

  /// 方向键微调展开动作的坐标（步长 1，Shift 步长 10）；滑动则整体平移
  void _nudgeExpanded(int dx, int dy, {int step = 1}) {
    if (_focusInEditable() || _expandedIndex < 0) return;
    final i = _expandedIndex;
    switch (_actions[i]) {
      case RecClick c:
        _updateAction(
          i,
          RecClick(
            c.offsetMs,
            c.x + dx * step,
            c.y + dy * step,
            count: c.count,
            button: c.button,
          ),
        );
      case RecLongPress p:
        _updateAction(
          i,
          RecLongPress(
            p.offsetMs,
            p.x + dx * step,
            p.y + dy * step,
            p.durationMs,
          ),
        );
      case RecScroll s:
        _updateAction(
          i,
          RecScroll(
            s.offsetMs,
            s.x + dx * step,
            s.y + dy * step,
            dx: s.dx,
            dy: s.dy,
          ),
        );
      case RecSwipe w:
        _updateAction(
          i,
          RecSwipe(
            w.offsetMs,
            w.x1 + dx * step,
            w.y1 + dy * step,
            w.x2 + dx * step,
            w.y2 + dy * step,
            w.durationMs,
          ),
        );
      default:
        break; // 按键/组合键无坐标
    }
  }

  // ---- 屏幕定位 ----

  void _hideMarker() {
    ref.read(screenMarkerProvider).hide();
    _markerIndex = -1;
  }

  void _toggleMarker(int index) {
    // 回放中禁用：标记的 LL 钩子会吞掉回放注入到标记坐标的点击
    if (ref.read(replayBusyProvider)) return;
    if (_markerIndex == index) {
      _hideMarker();
      setState(() {});
      return;
    }
    _markerIndex = index;
    final points = _markerPointsFor(_actions[index]);
    if (points == null) {
      _markerIndex = -1;
      return;
    }
    ref
        .read(screenMarkerProvider)
        .show(
          points,
          // 动态读取当前 _markerIndex：列表重排/增删后不会指错动作
          onDragEnd: (pointIndex, x, y) {
            final mi = _markerIndex;
            if (mi >= 0 && mi < _actions.length) {
              _onMarkerDragged(mi, pointIndex, x, y);
            }
          },
        );
    setState(() {});
  }

  void _refreshMarker() {
    if (_markerIndex < 0 || _markerIndex >= _actions.length) return;
    final points = _markerPointsFor(_actions[_markerIndex]);
    if (points == null) return;
    ref.read(screenMarkerProvider).updatePoints(points);
  }

  /// 拖拽屏幕图标结束：新坐标写回动作并保存
  void _onMarkerDragged(int actionIndex, int pointIndex, int x, int y) {
    final a = _actions[actionIndex];
    switch (a) {
      case RecClick c:
        _updateAction(
          actionIndex,
          RecClick(c.offsetMs, x, y, count: c.count, button: c.button),
        );
      case RecLongPress p:
        _updateAction(
          actionIndex,
          RecLongPress(p.offsetMs, x, y, p.durationMs),
        );
      case RecScroll s:
        _updateAction(
          actionIndex,
          RecScroll(s.offsetMs, x, y, dx: s.dx, dy: s.dy),
        );
      case RecSwipe w:
        _updateAction(
          actionIndex,
          pointIndex == 0
              ? RecSwipe(w.offsetMs, x, y, w.x2, w.y2, w.durationMs)
              : RecSwipe(w.offsetMs, w.x1, w.y1, x, y, w.durationMs),
        );
      default:
        break;
    }
  }

  /// 含坐标动作 → 屏幕标记点（null = 该动作无坐标）；只显示图标不显示坐标文字
  List<MarkerPoint>? _markerPointsFor(RecordedAction a) {
    switch (a) {
      case RecClick c:
        return [MarkerPoint(c.x, c.y, AppColors.peacock.toARGB32())];
      case RecLongPress p:
        return [MarkerPoint(p.x, p.y, AppColors.danger.toARGB32())];
      case RecScroll s:
        return [MarkerPoint(s.x, s.y, AppColors.nodeScript.toARGB32())];
      case RecSwipe w:
        return [
          MarkerPoint(w.x1, w.y1, AppColors.nodeData.toARGB32()),
          MarkerPoint(w.x2, w.y2, AppColors.nodeMedia.toARGB32()),
        ];
      default:
        return null;
    }
  }

  // ---- 添加动作 ----

  Future<void> _pickAndAddAction() async {
    // 返回 (动作类型, 是否插入到当前展开动作之后)
    var insertAfterExpanded = false;
    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return SimpleDialog(
            title: const Text('添加动作'),
            children: [
              CheckboxListTile(
                dense: true,
                value: insertAfterExpanded,
                onChanged: (v) =>
                    setDialogState(() => insertAfterExpanded = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text(
                  '插入到当前展开动作之后',
                  style: TextStyle(fontSize: 13, color: AppColors.inkSecondary),
                ),
              ),
              for (final entry in const {
                'RecClick': ('点击', Icons.mouse_rounded, AppColors.peacock),
                'RecSwipe': ('滑动', Icons.swipe_rounded, AppColors.nodeMedia),
                'RecLongPress': ('长按', Icons.timer_rounded, AppColors.danger),
                'RecScroll': (
                  '滚轮',
                  Icons.swap_vert_rounded,
                  AppColors.nodeScript,
                ),
                'RecKey': ('按键', Icons.keyboard_rounded, AppColors.nodeData),
                'RecCombo': (
                  '组合键',
                  Icons.keyboard_command_key_rounded,
                  AppColors.success,
                ),
              }.entries)
                SimpleDialogOption(
                  onPressed: () =>
                      Navigator.pop(ctx, (entry.key, insertAfterExpanded)),
                  child: Row(
                    children: [
                      Icon(entry.value.$2, size: 20, color: entry.value.$3),
                      const SizedBox(width: 12),
                      Text(
                        entry.value.$1,
                        style: const TextStyle(
                          fontSize: 15,
                          color: AppColors.ink,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
    if (result == null) return;
    final (kind, insertAfter) = result;
    final (sw, sh) = ref.read(automationProvider).screenSize;
    final cx = sw ~/ 2;
    final cy = sh ~/ 2;
    final lastOffset = _actions.isEmpty ? 0 : _actions.last.offsetMs;
    final offset = lastOffset + 500;
    final action = switch (kind) {
      'RecClick' => RecClick(offset, cx, cy),
      'RecSwipe' => RecSwipe(offset, cx - 100, cy, cx + 100, cy, 300),
      'RecLongPress' => RecLongPress(offset, cx, cy, 800),
      'RecScroll' => RecScroll(offset, cx, cy, dy: 120),
      'RecKey' => RecKey(offset, 0x41, durationMs: 60),
      _ => RecCombo(offset, [0x11, 0x43], durationMs: 100),
    };
    _addAction(
      action,
      insertAt: insertAfter && _expandedIndex >= 0 ? _expandedIndex + 1 : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): _redo,
        const SingleActivator(LogicalKeyboardKey.delete): _deleteExpandedAction,
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _nudgeExpanded(0, -1),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _nudgeExpanded(0, 1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _nudgeExpanded(-1, 0),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _nudgeExpanded(1, 0),
        const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true): () =>
            _nudgeExpanded(0, -1, step: 10),
        const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true): () =>
            _nudgeExpanded(0, 1, step: 10),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () =>
            _nudgeExpanded(-1, 0, step: 10),
        const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () =>
            _nudgeExpanded(1, 0, step: 10),
      },
      child: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: '返回',
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: PageHeader(
                      title: '编辑录制',
                      subtitle:
                          '$_name · ${_actions.length} 个动作 · 总时长 ${_totalSeconds}s',
                      trailing: [
                        IconButton(
                          tooltip: '重命名',
                          icon: const Icon(
                            Icons.drive_file_rename_outline_rounded,
                            size: 20,
                          ),
                          onPressed: _rename,
                        ),
                        if (_replaying)
                          const StatusBadge(
                            text: '回放中 · F10 中止',
                            color: AppColors.nodeLogic,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // 操作行：添加 / 试运行 / 撤销重做
              Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _replaying ? null : _pickAndAddAction,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('添加动作'),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: AppColors.peacock),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                    ),
                    onPressed: _replaying ? null : _replay,
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('试运行'),
                  ),
                  IconButton(
                    tooltip: '撤销 (Ctrl+Z)',
                    icon: const Icon(Icons.undo_rounded, size: 20),
                    color: _undoStack.isEmpty
                        ? AppColors.inkSecondary.withValues(alpha: 0.4)
                        : AppColors.inkSecondary,
                    onPressed: _undoStack.isEmpty || _replaying ? null : _undo,
                  ),
                  IconButton(
                    tooltip: '重做 (Ctrl+Y)',
                    icon: const Icon(Icons.redo_rounded, size: 20),
                    color: _redoStack.isEmpty
                        ? AppColors.inkSecondary.withValues(alpha: 0.4)
                        : AppColors.inkSecondary,
                    onPressed: _redoStack.isEmpty || _replaying ? null : _redo,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: _actions.isEmpty
                    ? Center(
                        child: Text(
                          '暂无动作，点击「添加动作」开始编排',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.inkSecondary,
                          ),
                        ),
                      )
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        padding: const EdgeInsets.only(bottom: 6),
                        itemCount: _actions.length,
                        onReorderItem: _onReorderItem,
                        itemBuilder: (context, i) => Padding(
                          key: ValueKey('a${_uids[i]}'),
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _ActionTile(
                            index: i,
                            action: _actions[i],
                            expanded: _expandedIndex == i,
                            marking: _markerIndex == i,
                            replaying: _replaying,
                            isFirst: i == 0,
                            isLast: i == _actions.length - 1,
                            hasCoordinate:
                                _markerPointsFor(_actions[i]) != null,
                            onToggleExpand: () => setState(
                              () =>
                                  _expandedIndex = _expandedIndex == i ? -1 : i,
                            ),
                            onUpdate: (a) => _updateAction(i, a),
                            onMoveUp: () => _moveAction(i, -1),
                            onMoveDown: () => _moveAction(i, 1),
                            onDelete: () => _removeAction(i),
                            onToggleMarker: () => _toggleMarker(i),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- 动作行 ----

class _ActionTile extends StatelessWidget {
  final int index;
  final RecordedAction action;
  final bool expanded;
  final bool marking;
  final bool replaying;
  final bool isFirst;
  final bool isLast;
  final bool hasCoordinate;
  final VoidCallback onToggleExpand;
  final ValueChanged<RecordedAction> onUpdate;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onDelete;
  final VoidCallback onToggleMarker;

  const _ActionTile({
    required this.index,
    required this.action,
    required this.expanded,
    required this.marking,
    required this.replaying,
    required this.isFirst,
    required this.isLast,
    required this.hasCoordinate,
    required this.onToggleExpand,
    required this.onUpdate,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDelete,
    required this.onToggleMarker,
  });

  static (Color, String, IconData) _typeMeta(RecordedAction a) => switch (a) {
    RecClick() => (AppColors.peacock, '点击', Icons.mouse_rounded),
    RecSwipe() => (AppColors.nodeMedia, '滑动', Icons.swipe_rounded),
    RecLongPress() => (AppColors.danger, '长按', Icons.timer_rounded),
    RecScroll() => (AppColors.nodeScript, '滚轮', Icons.swap_vert_rounded),
    RecKey() => (AppColors.nodeData, '按键', Icons.keyboard_rounded),
    RecCombo() => (
      AppColors.success,
      '组合键',
      Icons.keyboard_command_key_rounded,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final (color, name, icon) = _typeMeta(action);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.moonWhite,
        borderRadius: BorderRadius.circular(12),
        border: marking ? Border.all(color: AppColors.peacock, width: 2) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 拖拽排序把手（长按拖动调整执行顺序；试运行中禁用）
              IgnorePointer(
                ignoring: replaying,
                child: ReorderableDragStartListener(
                  index: index,
                  child: const Icon(
                    Icons.drag_indicator_rounded,
                    size: 18,
                    color: AppColors.inkSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: color),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 13, color: color),
                    const SizedBox(width: 4),
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // 摘要文字整体可点击展开/收起
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: onToggleExpand,
                  child: Row(
                    children: [
                      Text(
                        '${index + 1}.',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: AppColors.ink,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '[+${action.offsetMs}ms]',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.inkSecondary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          describeAction(action),
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _iconBtn(
                Icons.arrow_upward_rounded,
                '上移',
                isFirst ? null : onMoveUp,
              ),
              _iconBtn(
                Icons.arrow_downward_rounded,
                '下移',
                isLast ? null : onMoveDown,
              ),
              _iconBtn(
                Icons.delete_outline_rounded,
                '删除',
                onDelete,
                color: AppColors.danger,
              ),
              _iconBtn(
                expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                expanded ? '收起' : '编辑',
                onToggleExpand,
                color: expanded ? AppColors.peacock : AppColors.inkSecondary,
              ),
            ],
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _EditPanel(
                action: action,
                hasCoordinate: hasCoordinate,
                marking: marking,
                replaying: replaying,
                onUpdate: onUpdate,
                onToggleMarker: onToggleMarker,
              ),
            ),
            crossFadeState: expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 150),
          ),
        ],
      ),
    );
  }

  Widget _iconBtn(
    IconData icon,
    String tooltip,
    VoidCallback? onPressed, {
    Color? color,
  }) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      padding: EdgeInsets.zero,
      icon: Icon(icon, size: 18),
      color: color ?? AppColors.inkSecondary,
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}

// ---- 展开的编辑面板（按动作类型渲染字段） ----

class _EditPanel extends StatelessWidget {
  final RecordedAction action;
  final bool hasCoordinate;
  final bool marking;
  final bool replaying;
  final ValueChanged<RecordedAction> onUpdate;
  final VoidCallback onToggleMarker;

  const _EditPanel({
    required this.action,
    required this.hasCoordinate,
    required this.marking,
    required this.replaying,
    required this.onUpdate,
    required this.onToggleMarker,
  });

  @override
  Widget build(BuildContext context) {
    final fields = <Widget>[
      NumField(
        label: '偏移(ms)',
        value: action.offsetMs,
        width: 150,
        min: 0,
        max: 3600000,
        onChanged: (v) => _update(v: v),
      ),
      ..._typeFields(context),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.ivory,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: fields,
          ),
          if (hasCoordinate) ...[
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                backgroundColor: marking
                    ? AppColors.peacock
                    : AppColors.canvasBg,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
              ),
              onPressed: replaying ? null : onToggleMarker,
              icon: Icon(
                marking
                    ? Icons.location_on_rounded
                    : Icons.location_on_outlined,
                size: 16,
              ),
              label: Text(
                replaying
                    ? '回放中 · 屏幕定位不可用'
                    : marking
                    ? '屏幕定位中 · 拖拽图标改坐标'
                    : '屏幕定位',
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _update({int? v}) {
    final offset = v ?? action.offsetMs;
    switch (action) {
      case RecClick c:
        onUpdate(RecClick(offset, c.x, c.y, count: c.count, button: c.button));
      case RecSwipe w:
        onUpdate(RecSwipe(offset, w.x1, w.y1, w.x2, w.y2, w.durationMs));
      case RecLongPress p:
        onUpdate(RecLongPress(offset, p.x, p.y, p.durationMs));
      case RecScroll s:
        onUpdate(RecScroll(offset, s.x, s.y, dx: s.dx, dy: s.dy));
      case RecKey k:
        onUpdate(
          RecKey(
            offset,
            k.vkCode,
            durationMs: k.durationMs,
            extended: k.extended,
          ),
        );
      case RecCombo b:
        onUpdate(
          RecCombo(
            offset,
            b.vkCodes,
            extendeds: b.extendeds,
            durationMs: b.durationMs,
          ),
        );
    }
  }

  List<Widget> _typeFields(BuildContext context) => switch (action) {
    RecClick c => [
      _num(
        'x',
        c.x,
        (v) => RecClick(c.offsetMs, v, c.y, count: c.count, button: c.button),
      ),
      _num(
        'y',
        c.y,
        (v) => RecClick(c.offsetMs, c.x, v, count: c.count, button: c.button),
      ),
      _num(
        '次数',
        c.count,
        (v) => RecClick(c.offsetMs, c.x, c.y, count: v, button: c.button),
        min: 1,
        max: 99,
      ),
      _buttonSelector(c),
    ],
    RecSwipe w => [
      _num(
        '起点x',
        w.x1,
        (v) => RecSwipe(w.offsetMs, v, w.y1, w.x2, w.y2, w.durationMs),
      ),
      _num(
        '起点y',
        w.y1,
        (v) => RecSwipe(w.offsetMs, w.x1, v, w.x2, w.y2, w.durationMs),
      ),
      _num(
        '终点x',
        w.x2,
        (v) => RecSwipe(w.offsetMs, w.x1, w.y1, v, w.y2, w.durationMs),
      ),
      _num(
        '终点y',
        w.y2,
        (v) => RecSwipe(w.offsetMs, w.x1, w.y1, w.x2, v, w.durationMs),
      ),
      _num(
        '时长(ms)',
        w.durationMs,
        (v) => RecSwipe(w.offsetMs, w.x1, w.y1, w.x2, w.y2, v),
        min: 10,
        max: 60000,
      ),
    ],
    RecLongPress p => [
      _num('x', p.x, (v) => RecLongPress(p.offsetMs, v, p.y, p.durationMs)),
      _num('y', p.y, (v) => RecLongPress(p.offsetMs, p.x, v, p.durationMs)),
      _num(
        '时长(ms)',
        p.durationMs,
        (v) => RecLongPress(p.offsetMs, p.x, p.y, v),
        min: 10,
        max: 60000,
      ),
    ],
    RecScroll s => [
      _num('x', s.x, (v) => RecScroll(s.offsetMs, v, s.y, dx: s.dx, dy: s.dy)),
      _num('y', s.y, (v) => RecScroll(s.offsetMs, s.x, v, dx: s.dx, dy: s.dy)),
      _num(
        '垂直Δ',
        s.dy,
        (v) => RecScroll(s.offsetMs, s.x, s.y, dx: s.dx, dy: v),
      ),
      _num(
        '水平Δ',
        s.dx,
        (v) => RecScroll(s.offsetMs, s.x, s.y, dx: v, dy: s.dy),
      ),
    ],
    RecKey k => [
      _keyPicker(
        context,
        label: '按键',
        text: vkName(k.vkCode),
        onPicked: (vk) => onUpdate(
          RecKey(
            k.offsetMs,
            vk,
            durationMs: k.durationMs,
            extended: k.extended,
          ),
        ),
      ),
      _num(
        '时长(ms)',
        k.durationMs,
        (v) =>
            RecKey(k.offsetMs, k.vkCode, durationMs: v, extended: k.extended),
        min: 1,
        max: 60000,
      ),
    ],
    RecCombo b => [
      _comboEditor(context, b),
      _num(
        '时长(ms)',
        b.durationMs,
        (v) => RecCombo(
          b.offsetMs,
          b.vkCodes,
          extendeds: b.extendeds,
          durationMs: v,
        ),
        min: 1,
        max: 60000,
      ),
    ],
  };

  /// 数字字段（自动从数据回显；外部更新坐标时输入框同步）
  Widget _num(
    String label,
    int value,
    RecordedAction Function(int v) make, {
    int min = -1000000,
    int max = 1000000,
  }) {
    return NumField(
      label: label,
      value: value,
      width: 150,
      min: min,
      max: max,
      onChanged: (v) => onUpdate(make(v)),
    );
  }

  Widget _buttonSelector(RecClick c) {
    return SizedBox(
      width: 150,
      child: DropdownButtonFormField<String>(
        initialValue: c.button,
        decoration: const InputDecoration(labelText: '按键'),
        items: const [
          DropdownMenuItem(value: 'left', child: Text('左键')),
          DropdownMenuItem(value: 'middle', child: Text('中键')),
          DropdownMenuItem(value: 'right', child: Text('右键')),
        ],
        onChanged: (v) {
          if (v == null) return;
          onUpdate(RecClick(c.offsetMs, c.x, c.y, count: c.count, button: v));
        },
      ),
    );
  }

  Widget _keyPicker(
    BuildContext context, {
    required String label,
    required String text,
    required ValueChanged<int> onPicked,
  }) {
    return SizedBox(
      width: 150,
      child: InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () async {
            final vk = await listenVirtualKeyDialog(context);
            if (vk != null) onPicked(vk);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(fontSize: 14, color: AppColors.ink),
                  ),
                ),
                const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _comboEditor(BuildContext context, RecCombo b) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < b.vkCodes.length; i++)
              InputChip(
                label: Text(vkName(b.vkCodes[i])),
                deleteIcon: const Icon(Icons.close_rounded, size: 14),
                onDeleted: () {
                  final codes = List.of(b.vkCodes)..removeAt(i);
                  final exts = List.of(b.extendeds);
                  if (i < exts.length) exts.removeAt(i);
                  onUpdate(
                    RecCombo(
                      b.offsetMs,
                      codes,
                      extendeds: List<bool>.from(exts),
                      durationMs: b.durationMs,
                    ),
                  );
                },
              ),
            ActionChip(
              avatar: const Icon(Icons.add_rounded, size: 16),
              label: const Text('添加键'),
              onPressed: () async {
                final vk = await listenVirtualKeyDialog(context);
                if (vk == null) return;
                final codes = List.of(b.vkCodes)..add(vk);
                final exts = List.of(b.extendeds);
                while (exts.length < codes.length - 1) {
                  exts.add(false);
                }
                exts.add(false);
                onUpdate(
                  RecCombo(
                    b.offsetMs,
                    codes,
                    extendeds: List<bool>.from(exts),
                    durationMs: b.durationMs,
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}

// ---- 通用小组件 ----

/// 常用可选虚拟键（编辑动作的按键/组合键用）
const List<int> kSelectableVks = [
  0x08,
  0x09,
  0x0D,
  0x13,
  0x14,
  0x1B,
  0x20, // Backspace Tab Enter Pause Caps Esc Space
  0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E, // PgUp..Delete
  0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, // 0-9
  0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, //
  0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
  0x59, 0x5A, // A-Z
  0x5B, // Win
  0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, // 小键盘 0-9
  0x6A, 0x6B, 0x6D, 0x6E, 0x6F, // Num* + - . /
  0x70,
  0x71,
  0x72,
  0x73,
  0x74,
  0x75,
  0x76,
  0x77,
  0x78,
  0x79,
  0x7A,
  0x7B, // F1-F12
  0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, // LShift RShift LCtrl RCtrl LAlt RAlt
  0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xC0, 0xDB, 0xDC, 0xDD, 0xDE, // 符号
];

/// 虚拟键选择对话框（列表展示 vkName）
Future<int?> pickVirtualKeyDialog(BuildContext context) {
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('选择按键'),
      content: SizedBox(
        width: 420,
        height: 460,
        child: ListView.builder(
          itemCount: kSelectableVks.length,
          itemBuilder: (_, i) {
            final vk = kSelectableVks[i];
            return ListTile(
              dense: true,
              title: Text(
                vkName(vk),
                style: const TextStyle(fontSize: 14, color: AppColors.ink),
              ),
              onTap: () => Navigator.pop(ctx, vk),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

/// 键位监听对话框：打开后直接按下键盘任意键即捕获为该动作的键位
/// （10ms 轮询 GetAsyncKeyState，与录制器同源、天然输出 Windows VK）。
/// Esc 取消；「从列表选择」保留 pickVirtualKeyDialog 作为备选入口。
Future<int?> listenVirtualKeyDialog(BuildContext context) {
  return showDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _KeyListenDialog(),
  );
}

class _KeyListenDialog extends StatefulWidget {
  const _KeyListenDialog();

  @override
  State<_KeyListenDialog> createState() => _KeyListenDialogState();
}

class _KeyListenDialogState extends State<_KeyListenDialog> {
  Timer? _timer;
  final Set<int> _initialDown = {}; // 打开瞬间已按下的键（不报告，防误触）

  @override
  void initState() {
    super.initState();
    for (var vk = 0x08; vk <= 0xFE; vk++) {
      if (u32.isKeyDown(vk)) _initialDown.add(vk);
    }
    _timer = Timer.periodic(const Duration(milliseconds: 10), (_) => _poll());
  }

  void _poll() {
    // Esc 取消
    if (u32.isKeyDown(u32.vkEscape) && !_initialDown.contains(u32.vkEscape)) {
      _finish(null);
      return;
    }
    for (var vk = 0x08; vk <= 0xFE; vk++) {
      if (vk == u32.vkEscape) continue;
      if (u32.isKeyDown(vk) && !_initialDown.contains(vk)) {
        _finish(vk);
        return;
      }
    }
  }

  void _finish(int? vk) {
    _timer?.cancel();
    _timer = null;
    if (mounted) Navigator.pop(context, vk);
  }

  Future<void> _pickFromList() async {
    _timer?.cancel();
    _timer = null;
    if (!mounted) return;
    final vk = await pickVirtualKeyDialog(context);
    _finish(vk);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('按键监听中'),
      content: const Text('请直接按下要设置的按键\n按 Esc 取消'),
      actions: [
        TextButton(onPressed: () => _finish(null), child: const Text('取消')),
        OutlinedButton(onPressed: _pickFromList, child: const Text('从列表选择')),
      ],
    );
  }
}
