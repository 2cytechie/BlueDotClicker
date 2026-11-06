import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../models/blueprint.dart';
import '../../models/key_names.dart';
import '../../models/node_types.dart' show nodeDef;
import '../../state/providers.dart';
import 'editor_menus.dart';
import 'node_body.dart';
import 'node_bridge.dart';
import 'node_palette.dart';
import 'property_panel.dart';

/// 蓝图编辑器页面：基于 fl_nodes_v2，全屏显示（侧边栏不显示）
class EditorPage extends ConsumerStatefulWidget {
  const EditorPage({super.key});

  @override
  ConsumerState<EditorPage> createState() => _EditorPageState();
}

/// 未保存离开编辑器时的选择
enum _LeaveAction { save, discard, cancel }

class _EditorPageState extends ConsumerState<EditorPage> {
  late final fl.NodeEditorController _controller;
  final GlobalKey<fl.NodeEditorState> _editorKey = GlobalKey();
  BlueprintScript? _loadedScript;
  bool _showLogs = false;
  // dispose 中禁止使用 ref（Riverpod 3 抛 StateError）——didChangeDependencies 捕获
  CoordinatePickNotifier? _pickNotifier;
  KeyPickNotifier? _keyPickNotifier;

  @override
  void initState() {
    super.initState();
    _controller = fl.NodeEditorController(definitions: blueprintNodeRegistry);
    // 执行流输出口单出边约束（引擎只走首条执行流边，多条会被静默忽略）
    _controller.connectionValidator = blueprintConnectionValidator;
    // Ctrl+S 保存：编辑界面挂载期间监听（不依赖具体控件的焦点）
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    // 打开脚本 → 载入图（不同实例才载入，避免编辑引起的刷新重置画布）
    ref.listenManual(currentScriptProvider, (prev, next) {
      if (next == null) return;
      if (identical(next, _loadedScript)) return;
      _loadedScript = next;
      _controller.replaceGraph(
        blueprintToGraph(next),
        recordHistory: false,
        normalise: true,
      );
      // 刚载入的内容与磁盘一致：登记为干净基线，避免脏标记常亮
      _controller.project.markSaved();
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitContent());
    });
    final initial = ref.read(currentScriptProvider);
    if (initial != null) {
      _loadedScript = initial;
      _controller.replaceGraph(blueprintToGraph(initial), recordHistory: false);
      _controller.project.markSaved();
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitContent());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pickNotifier ??= ref.read(coordinatePickProvider.notifier);
    _keyPickNotifier ??= ref.read(keyPickProvider.notifier);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    // 页面销毁时兜底退出拾取（钩子必须卸载；用捕获引用，Riverpod 3 禁止 dispose 中用 ref，
    // 否则拾取中切走页签时钩子泄漏——全局左/右/中键被吞 + 应用窗口保持最小化）
    _pickNotifier?.cancel();
    _keyPickNotifier?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// 键盘事件：Ctrl+S 保存当前蓝图
  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyS) return false;
    if (!HardwareKeyboard.instance.isControlPressed) return false;
    _save();
    return true;
  }

  void _fitContent() {
    final editor = _editorKey.currentState;
    if (editor != null) {
      _controller.camera.fitToContent(editor.viewportSize);
    }
  }

  /// 从编辑器图模型转回脚本（所见即所得；variables 由脚本承载，graph 不含）
  BlueprintScript? _currentAsScript() {
    final loaded = _loadedScript;
    if (loaded == null) return null;
    return graphToBlueprint(
      _controller.graph,
      name: loaded.name,
      createdAt: loaded.createdAt,
      variables: Map.of(loaded.variables),
    );
  }

  /// 保存当前脚本；成功返回 true
  Future<bool> _save() async {
    final script = _currentAsScript();
    if (script == null) return false;
    final graphAtSave = _controller.graph; // 保存时刻的图快照（identity）
    try {
      await ref.read(scriptStorageProvider).save(script);
      // 先登记已载入实例、再同步 provider：否则会被误判为「切换到另一个脚本」
      // 而重建整张画布（撤销历史与相机位置都会丢失）
      _loadedScript = script;
      ref.read(currentScriptProvider.notifier).open(script);
      // 落盘期间图若被编辑（异步写入窗口），不得标净——脏标记保留，
      // 离开编辑器时仍会提示保存，防止新编辑丢失
      if (identical(_controller.graph, graphAtSave)) {
        _controller.project.markSaved();
      }
      // 刷新首页列表：列表缓存的是打开时的旧对象，不刷新会导致再次编辑载入旧内容
      await ref.read(scriptListProvider.notifier).refresh();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('脚本已保存')));
      }
      return true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('保存失败')));
      }
      return false;
    }
  }

  /// 是否有未保存的修改
  bool get _isDirty => _loadedScript != null && _controller.project.isDirty;

  /// 返回首页：有未保存修改时先询问是否保存
  Future<void> _leaveEditor() async {
    if (!_isDirty) {
      ref.read(appNavProvider.notifier).go(AppTab.home);
      return;
    }
    final action = await showDialog<_LeaveAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('脚本尚未保存'),
        content: Text('「${_loadedScript?.name ?? ''}」有未保存的修改，是否保存后再返回？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _LeaveAction.cancel),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _LeaveAction.discard),
            child: const Text('不保存'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _LeaveAction.save),
            child: const Text('保存并返回'),
          ),
        ],
      ),
    );
    if (!mounted || action == null || action == _LeaveAction.cancel) return;
    if (action == _LeaveAction.save && !await _save()) return; // 保存失败则留在编辑器
    if (!mounted) return;
    ref.read(appNavProvider.notifier).go(AppTab.home);
  }

  void _run() {
    final script = _currentAsScript();
    if (script == null) return;
    ref.read(runnerProvider.notifier).start(script);
  }

  void _showPaletteSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.moonWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      builder: (_) => NodePalette(
        controller: _controller,
        editorStateKey: _editorKey,
        popOnAdd: true,
      ),
    );
  }

  void _showPropsSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.ivory,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.6,
      ),
      builder: (_) => PropertyPanel(controller: _controller),
    );
  }

  /// 画布上的拾取状态悬浮条：拾取进行中实时显示光标坐标与操作提示。
  /// 悬浮条为独立 ConsumerWidget，光标刷新只重建它本身，不触发整页重绘。
  Widget _withPickBanner(Widget child) => Stack(
    children: [
      child,
      const Positioned(top: 12, left: 0, right: 0, child: _PickBanner()),
      const Positioned(top: 12, left: 0, right: 0, child: _KeyPickBanner()),
    ],
  );

  Future<void> _confirmDeleteConnection(fl.NodeConnection c) async {
    final fromNode = _controller.graph.nodes[c.from.nodeId];
    final toNode = _controller.graph.nodes[c.to.nodeId];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除连线？'),
        content: Text(
          '将删除 ${fromNode?.type ?? '?'} → ${toNode?.type ?? '?'} 的连线。',
        ),
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
    if (ok == true) _controller.removeConnections([c.id]);
  }

  @override
  Widget build(BuildContext context) {
    final script = ref.watch(currentScriptProvider);
    // select 拆分：日志每步追加，若整页 watch 会在运行中导致整页（含画布）每条日志重建
    final running = ref.watch(runnerProvider.select((s) => s.running));
    final runningNodeId = ref.watch(
      runnerProvider.select((s) => s.currentNodeId),
    );
    final currentNodeTitle = () {
      if (runningNodeId == null || _loadedScript == null) return '…';
      final n = _controller.graph.nodes[runningNodeId];
      return n == null ? '…' : nodeDef(n.type).title;
    }();

    return Scaffold(
      body: Column(
        children: [
          _buildToolbar(script, running, currentNodeTitle),
          const Divider(height: 1),
          Expanded(
            child: _loadedScript == null
                ? _buildGuide()
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final editor = fl.NodeEditor(
                        key: _editorKey,
                        controller: _controller,
                        nodeBuilder: nodeBodyBuilder(
                          runningNodeId: runningNodeId,
                        ),
                        theme: fl.NodeEditorTheme.dark(
                          accent: AppColors.peacock,
                        ).copyWith(background: AppColors.canvasBg),
                        contextMenus: buildEditorContextMenus(),
                        onConnectionTap: _confirmDeleteConnection,
                      );
                      if (constraints.maxWidth >= 1100) {
                        return Row(
                          children: [
                            SizedBox(
                              width: 240,
                              child: NodePalette(
                                controller: _controller,
                                editorStateKey: _editorKey,
                              ),
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(child: _withPickBanner(editor)),
                            const VerticalDivider(width: 1),
                            SizedBox(
                              width: 320,
                              child: PropertyPanel(controller: _controller),
                            ),
                          ],
                        );
                      }
                      // 窄屏：画布占满，节点库与属性面板从弹出层打开
                      return Stack(
                        children: [
                          Positioned.fill(child: _withPickBanner(editor)),
                          Positioned(
                            top: 12,
                            left: 12,
                            child: FloatingActionButton.small(
                              heroTag: 'editor_palette',
                              tooltip: '节点库',
                              onPressed: _showPaletteSheet,
                              child: const Icon(Icons.apps_rounded),
                            ),
                          ),
                          Positioned(
                            right: 12,
                            bottom: 12,
                            child: FloatingActionButton.extended(
                              heroTag: 'editor_props',
                              tooltip: '属性面板',
                              onPressed: _showPropsSheet,
                              icon: const Icon(Icons.tune_rounded),
                              label: const Text('属性'),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          // 可展开的运行日志面板
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: _showLogs
                ? const _LogsPanel()
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  // ---- 顶部工具栏 ----

  Widget _buildToolbar(
    BlueprintScript? script,
    bool running,
    String currentNodeTitle,
  ) {
    return Container(
      color: AppColors.moonWhite,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回首页',
            onPressed: _leaveEditor,
            icon: const Icon(
              Icons.arrow_back_rounded,
              size: 20,
              color: AppColors.inkSecondary,
            ),
          ),
          const Icon(
            Icons.account_tree_rounded,
            color: AppColors.peacock,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              script?.name ?? '未打开脚本',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: AppColors.ink,
              ),
            ),
          ),
          // 未保存提示（跟随图变化实时刷新）
          ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => _controller.project.isDirty
                ? const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.fiber_manual_record,
                          size: 10,
                          color: AppColors.peacock,
                        ),
                        SizedBox(width: 4),
                        Text(
                          '未保存',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.peacock,
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          // 运行中显示当前节点指示
          if (running)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '运行中 · $currentNodeTitle',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: AppColors.success,
                    ),
                  ),
                ],
              ),
            ),
          running
              ? FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.danger,
                  ),
                  onPressed: () => ref.read(runnerProvider.notifier).stop(),
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: const Text('停止'),
                )
              : FilledButton.icon(
                  onPressed: script == null ? null : _run,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('运行'),
                ),
          const SizedBox(width: 8),
          Tooltip(
            message: '保存（Ctrl+S）',
            child: FilledButton.icon(
              onPressed: script == null ? null : _save,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('保存'),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: _showLogs ? '收起日志' : '运行日志',
            onPressed: () => setState(() => _showLogs = !_showLogs),
            icon: Icon(
              Icons.article_outlined,
              color: _showLogs ? AppColors.peacock : AppColors.inkSecondary,
            ),
          ),
        ],
      ),
    );
  }

  // ---- 未打开脚本时的引导 ----

  Widget _buildGuide() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.schema_outlined, size: 72, color: AppColors.outline),
          const SizedBox(height: 16),
          const Text(
            '尚未打开脚本',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w400,
              color: AppColors.inkSecondary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '从首页选择或新建一个蓝图脚本后开始编辑',
            style: TextStyle(fontSize: 12, color: AppColors.inkSecondary),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => ref.read(appNavProvider.notifier).go(AppTab.home),
            icon: const Icon(Icons.home_outlined, size: 18),
            label: const Text('返回首页'),
          ),
        ],
      ),
    );
  }
}

/// 拾取状态悬浮条（独立订阅拾取状态，光标更新只重建此组件）
class _PickBanner extends ConsumerWidget {
  const _PickBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pick = ref.watch(coordinatePickProvider);
    if (!pick.active) return const SizedBox.shrink();
    final cursor = pick.cursor;
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.ink.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(999),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.my_location_rounded,
                size: 15,
                color: AppColors.peacock,
              ),
              const SizedBox(width: 8),
              Text(
                '${pick.target!.label} · 当前 (${cursor?.$1 ?? '-'}, ${cursor?.$2 ?? '-'})'
                ' · 左/右/中键确认 · Esc 取消',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.moonWhite,
                ),
              ),
              if (pick.target?.buttonKey != null)
                const Text(
                  ' · 按键随点击记录',
                  style: TextStyle(fontSize: 12, color: AppColors.peacock),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 按键拾取悬浮条（独立订阅按键拾取状态，命中即消失）
class _KeyPickBanner extends ConsumerWidget {
  const _KeyPickBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pick = ref.watch(keyPickProvider);
    if (!pick.active) return const SizedBox.shrink();
    final pressed = pick.pressedVk;
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.ink.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(999),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.keyboard_rounded,
                size: 15,
                color: AppColors.peacock,
              ),
              const SizedBox(width: 8),
              Text(
                '${pick.target!.label} · '
                '${pressed == null ? '请按下要绑定的按键' : '已捕获 ${keyLabel(pressed)}'}'
                ' · Esc 取消',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.moonWhite,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 底部运行日志面板：最新日志在底部，自动滚动
class _LogsPanel extends ConsumerStatefulWidget {
  const _LogsPanel();

  @override
  ConsumerState<_LogsPanel> createState() => _LogsPanelState();
}

class _LogsPanelState extends ConsumerState<_LogsPanel> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _jumpBottom();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _jumpBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.hasClients) {
        _controller.jumpTo(_controller.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(runnerProvider.select((s) => s.logs));
    // 新日志到达时滚动到底部
    ref.listen(
      runnerProvider.select((s) => s.logs.length),
      (_, _) => _jumpBottom(),
    );
    return Container(
      height: 220,
      color: AppColors.canvasBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: const BoxDecoration(color: AppColors.peacockDeep),
            child: Row(
              children: [
                const Icon(
                  Icons.article_outlined,
                  size: 16,
                  color: AppColors.ink,
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '运行日志',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: AppColors.ink,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () =>
                      ref.read(runnerProvider.notifier).clearLogs(),
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    size: 16,
                    color: AppColors.ink,
                  ),
                  label: const Text(
                    '清空',
                    style: TextStyle(fontSize: 12, color: AppColors.ink),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _controller,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: logs.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(
                  logs[i],
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: AppColors.ink,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
