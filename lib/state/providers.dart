import 'dart:async';

import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/interpreter.dart';
import '../engine/variables.dart';
import '../models/blueprint.dart';
import '../models/key_names.dart';
import '../models/node_types.dart';
import '../platform/automation_factory.dart';
import '../platform/coordinate_picker.dart';
import '../platform/key_picker.dart';
import '../platform/platform_automation.dart';
import '../platform/recording.dart';
import '../platform/region_picker.dart';
import '../platform/screen_marker.dart';
import '../services/media_tester.dart';
import '../services/recognition.dart';
import '../services/script_storage.dart';
import '../services/template_storage.dart';
import '../services/windows_recognition.dart';
import 'frame_yield.dart';

// ---- 应用导航 ----

/// 侧边栏导航页签；编辑器为全屏页（不显示侧边栏）
enum AppTab { home, editor, recordings }

class AppNavNotifier extends Notifier<AppTab> {
  @override
  AppTab build() => AppTab.home;

  void go(AppTab tab) => state = tab;
}

final appNavProvider = NotifierProvider<AppNavNotifier, AppTab>(
  AppNavNotifier.new,
);

// ---- 平台服务单例 ----

final automationProvider = Provider<PlatformAutomation>(
  (ref) => createAutomation(),
);

final recognitionProvider = Provider<RecognitionService>((ref) {
  final service = WindowsRecognitionService(log: debugPrint);
  ref.onDispose(service.dispose);
  return service;
});

/// 媒体节点测试器（属性面板「测试」按钮使用）
final mediaTesterProvider = Provider<MediaTester>(
  (ref) => MediaTester(
    ref.watch(automationProvider),
    ref.watch(recognitionProvider),
  ),
);

final scriptStorageProvider = Provider<ScriptStorage>((ref) => ScriptStorage());

final templateStorageProvider = Provider<TemplateStorage>(
  (ref) => TemplateStorage(),
);

final recordingStorageProvider = Provider<RecordingStorage>(
  (ref) => RecordingStorage(),
);

final recordingServiceProvider = Provider<RecordingService>((ref) {
  final automation = ref.watch(automationProvider);
  if (automation.isSupported) return WindowsRecordingService(automation);
  return _NoopRecording();
});

/// 屏幕定位图标服务（动作编辑页「屏幕定位」用；单例持有钩子与重绘状态）
final screenMarkerProvider = Provider<ScreenMarkerService>(
  (_) => ScreenMarkerService(),
);

/// 回放互斥：任意回放进行中为 true（录制页立即回放/历史条目回放/编辑页试运行共用）。
/// 页面局部状态无法覆盖 IndexedStack 跨 tab 与路由栈场景，故提升为应用级。
class ReplayBusyNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// 尝试执行一段回放；已有回放进行中返回 false（调用方 toast）。
  /// body 内部自行 try/catch 与 UI 状态复位；异常经 finally 保证互斥复位。
  Future<bool> runGuarded(Future<void> Function() body) async {
    if (state) return false;
    state = true;
    try {
      await body();
    } finally {
      state = false;
    }
    return true;
  }
}

final replayBusyProvider = NotifierProvider<ReplayBusyNotifier, bool>(
  ReplayBusyNotifier.new,
);

/// 录制历史列表（录制页展示、属性面板「执行录制」节点下拉共用；操作后 invalidate 刷新）
final recordingsProvider = FutureProvider<List<Recording>>(
  (ref) => ref.watch(recordingStorageProvider).list(),
);

class _NoopRecording implements RecordingService {
  @override
  bool get isRecording => false;
  @override
  Stream<RecordedAction> get events => const Stream.empty();
  @override
  void start() {}
  @override
  List<RecordedAction> stop() => [];
}

// ---- 脚本列表 ----

class ScriptListNotifier extends AsyncNotifier<List<BlueprintScript>> {
  @override
  Future<List<BlueprintScript>> build() async =>
      ref.watch(scriptStorageProvider).listScripts();

  /// 刷新时不置 AsyncLoading：保留旧数据直到新数据到达，避免每次保存后列表闪转圈
  Future<void> refresh() async {
    state = await AsyncValue.guard(
      () => ref.read(scriptStorageProvider).listScripts(),
    );
  }
}

final scriptListProvider =
    AsyncNotifierProvider<ScriptListNotifier, List<BlueprintScript>>(
      ScriptListNotifier.new,
    );

// ---- 当前编辑脚本 ----

class CurrentScriptNotifier extends Notifier<BlueprintScript?> {
  @override
  BlueprintScript? build() => null;

  void open(BlueprintScript s) => state = s;
  void close() => state = null;
}

final currentScriptProvider =
    NotifierProvider<CurrentScriptNotifier, BlueprintScript?>(
      CurrentScriptNotifier.new,
    );

// ---- 当前脚本的初始变量表 ----

/// 当前脚本的初始变量表（节点库「变量」分类与 varName 字段下拉共用）。
/// 跟随 currentScriptProvider 自动同步：载入/切换脚本 → 脚本 variables，
/// 关闭脚本 → 清空；编辑由变量面板经 [setInitial] 写入，
/// 保存时由编辑器读取回 BlueprintScript.variables（graph 不承载变量）。
class ScriptVariablesNotifier extends Notifier<Map<String, Object>> {
  @override
  Map<String, Object> build() =>
      Map.of(ref.watch(currentScriptProvider)?.variables ?? const {});

  /// 设置变量初始值；raw 为空时保留该键（值为空字符串）——
  /// 新建变量初始值留空也能创建成功，运行时该变量值为空字符串
  void setInitial(String name, String raw) {
    if (name.trim().isEmpty) return;
    final next = Map.of(state);
    next[name] = raw.trim().isEmpty ? '' : VariableTable.parseLiteral(raw);
    state = next;
  }

  /// 删除变量（从初始变量表移除；图中节点对该变量名的引用不受影响）
  void remove(String name) {
    final next = Map.of(state)..remove(name);
    state = next;
  }
}

final scriptVariablesProvider =
    NotifierProvider<ScriptVariablesNotifier, Map<String, Object>>(
      ScriptVariablesNotifier.new,
    );

// ---- 全局坐标拾取 ----

/// 一次拾取目标：确认后写回哪个节点的哪些参数
class PickTarget {
  final String nodeId;

  /// 坐标写入的参数键（如 'x'/'y'、'endX'/'endY'）
  final String keyX, keyY;

  /// 按键类型写入的参数键（'button'，仅 click/doubleClick）；null = 不写按键
  final String? buttonKey;

  /// 悬浮提示标签（「拾取坐标」「拾取起点」…）
  final String label;
  const PickTarget({
    required this.nodeId,
    required this.keyX,
    required this.keyY,
    this.buttonKey,
    required this.label,
  });
}

/// 拾取进行中的状态（编辑器悬浮条实时显示光标坐标）
class CoordinatePickState {
  final PickTarget? target; // null = 空闲
  final (int, int)? cursor;
  const CoordinatePickState({this.target, this.cursor});

  bool get active => target != null;
}

class CoordinatePickNotifier extends Notifier<CoordinatePickState> {
  /// provider 被销毁后（离开编辑器页）异步恢复的代码不得再写 state
  bool _alive = true;

  @override
  CoordinatePickState build() {
    _alive = true;
    ref.onDispose(() => _alive = false);
    return const CoordinatePickState();
  }

  CoordinatePicker get _picker => ref.read(coordinatePickerProvider);

  void _set(CoordinatePickState s) {
    if (_alive) state = s;
  }

  /// 开始拾取；确认后坐标（及按键类型）经 [controller] 写回节点（支持撤销/重做）。
  Future<void> start({
    required fl.NodeEditorController controller,
    required PickTarget target,
  }) async {
    if (state.active) return;
    if (!ref.read(automationProvider).isSupported) return;
    // 定位拖拽与拾取共用全局鼠标钩子，拾取开始前先收起定位图标
    ref.read(screenLocateProvider.notifier).stop();
    _set(CoordinatePickState(target: target, cursor: null));
    final result = await _picker.pickPoint(
      onCursorMove: (pos) {
        if (state.active) {
          _set(CoordinatePickState(target: target, cursor: pos));
        }
      },
    );
    // 拾取期间节点可能已被删除/切换
    if (result != null && controller.graph.nodes.containsKey(target.nodeId)) {
      controller.updateNode(
        target.nodeId,
        (n) => n.withData({
          target.keyX: result.x,
          target.keyY: result.y,
          if (target.buttonKey != null) target.buttonKey!: result.button.name,
        }),
      );
    }
    _set(const CoordinatePickState());
  }

  /// UI 主动取消。
  /// provider 已销毁时为 no-op：EditorPage.dispose 会兜底调用本方法，
  /// 而 cancel 内部经 [_picker] 使用 ref——dispose/销毁阶段再用 ref 会抛
  /// UnmountedRefException，须以 _alive 守卫。
  void cancel() {
    if (!_alive) return;
    _picker.cancel();
    _set(const CoordinatePickState());
  }
}

final coordinatePickerProvider = Provider<CoordinatePicker>(
  (ref) => CoordinatePicker(),
);

final coordinatePickProvider =
    NotifierProvider<CoordinatePickNotifier, CoordinatePickState>(
      CoordinatePickNotifier.new,
    );

// ---- 屏幕定位（拖动屏幕图标改坐标，参考录制与回放页） ----

/// 屏幕定位中的一个可拖拽点：拖拽结束后把坐标写回节点的 [keyX]/[keyY]
class LocatePointDef {
  final String keyX, keyY;

  /// 图标填充色（0xAARRGGBB；拖拽起点/终点用不同色，与录制页一致）
  final int color;
  const LocatePointDef(this.keyX, this.keyY, this.color);
}

/// 一次屏幕定位目标：同一节点上的一组点（拖拽为起点+终点，两点自动连线）
class ScreenLocateTarget {
  final String nodeId;
  final List<LocatePointDef> points;

  /// 悬浮条提示（「位置」「拖拽起点」…）
  final String label;
  const ScreenLocateTarget({
    required this.nodeId,
    required this.points,
    required this.label,
  });
}

/// 两个定位目标是否相同（同节点且点位一致）：用于按钮高亮与再次点击关闭
bool sameScreenLocateTarget(ScreenLocateTarget a, ScreenLocateTarget b) {
  if (a.nodeId != b.nodeId || a.points.length != b.points.length) return false;
  for (var i = 0; i < a.points.length; i++) {
    if (a.points[i].keyX != b.points[i].keyX ||
        a.points[i].keyY != b.points[i].keyY) {
      return false;
    }
  }
  return true;
}

class ScreenLocateState {
  final ScreenLocateTarget? target; // null = 空闲
  const ScreenLocateState({this.target});

  bool get active => target != null;
}

/// 屏幕定位：在屏幕上显示可拖拽的定位图标（复用录制页的 ScreenMarkerService），
/// 拖拽结束把新坐标写回节点；节点参数变化（输入框/撤销）时同步图标位置。
/// 目标节点删除、切换选中、参数不再适用（如动作从拖拽改为单击）时自动关闭。
class ScreenLocateNotifier extends Notifier<ScreenLocateState> {
  /// provider 被销毁后（离开编辑器页）异步回调不得再写 state
  bool _alive = true;

  late final ScreenMarkerService _marker;
  late final void Function() _listener = _onNodeChanged;
  fl.NodeEditorController? _controller;
  List<MarkerPoint> _lastPoints = const [];

  @override
  ScreenLocateState build() {
    _alive = true;
    _marker = ref.watch(screenMarkerProvider);
    // 销毁时直接收尾（Riverpod 3 在 dispose 阶段禁止再用 ref，故用 build 中捕获的引用）
    ref.onDispose(() {
      _alive = false;
      _detach();
      _marker.hide();
    });
    return const ScreenLocateState();
  }

  void _set(ScreenLocateState s) {
    if (_alive) state = s;
  }

  /// 切换定位：同一目标再次调用即关闭；切到另一目标则直接改定位。
  void toggle({
    required fl.NodeEditorController controller,
    required ScreenLocateTarget target,
  }) {
    if (!ref.read(automationProvider).isSupported) return;
    final cur = state.target;
    if (cur != null && sameScreenLocateTarget(cur, target)) {
      stop();
      return;
    }
    stop();
    // 拾取/框选与定位共用全局鼠标钩子（定位需要拖拽图标），互斥
    ref.read(coordinatePickProvider.notifier).cancel();
    ref.read(regionPickProvider.notifier).cancel();
    final node = controller.graph.nodes[target.nodeId];
    if (node == null) return;
    _controller = controller..addListener(_listener);
    _lastPoints = _pointsFor(node, target);
    _set(ScreenLocateState(target: target));
    _marker.show(_lastPoints, onDragEnd: _onDragEnd);
  }

  /// 关闭定位（UI 再次点击 / 页面销毁 / 目标失效）
  void stop() {
    if (!_alive) return;
    _detach();
    _marker.hide();
    _lastPoints = const [];
    if (state.target != null) state = const ScreenLocateState();
  }

  void _detach() {
    _controller?.removeListener(_listener);
    _controller = null;
  }

  /// 拖拽图标结束：把该点的新坐标写回节点（支持撤销/重做）
  void _onDragEnd(int index, int x, int y) {
    final t = state.target;
    final c = _controller;
    if (t == null || c == null || index < 0 || index >= t.points.length) {
      return;
    }
    if (!c.graph.nodes.containsKey(t.nodeId)) {
      stop();
      return;
    }
    final p = t.points[index];
    c.updateNode(t.nodeId, (n) => n.withData({p.keyX: x, p.keyY: y}));
  }

  /// 图/选中变化：目标仍有效则同步图标位置，失效则自动关闭
  void _onNodeChanged() {
    final t = state.target;
    final c = _controller;
    if (t == null || c == null) return;
    final node = c.graph.nodes[t.nodeId];
    if (node == null ||
        !c.selection.nodeIds.contains(t.nodeId) ||
        !_keysVisible(node, t)) {
      stop();
      return;
    }
    final pts = _pointsFor(node, t);
    if (_samePoints(pts, _lastPoints)) return;
    _lastPoints = pts;
    _marker.updatePoints(pts);
  }

  /// 定位用到的参数键是否仍属于节点当前可见参数（动作/模式切换后失效）
  bool _keysVisible(fl.GraphNode node, ScreenLocateTarget t) {
    final def = nodeDef(node.type);
    final data = <String, Object?>{
      for (final f in def.params) f.key: f.defaultValue,
    }..addAll(node.data);
    final keys = def.params
        .where((f) => f.visibleFor(data))
        .map((f) => f.key)
        .toSet();
    return t.points.every(
      (p) => keys.contains(p.keyX) && keys.contains(p.keyY),
    );
  }

  static List<MarkerPoint> _pointsFor(
    fl.GraphNode node,
    ScreenLocateTarget t,
  ) => [
    for (final p in t.points)
      MarkerPoint(_intOf(node, p.keyX), _intOf(node, p.keyY), p.color),
  ];

  /// 参数当前值；缺键时回落到节点定义的默认值（与属性面板一致）
  static int _intOf(fl.GraphNode node, String key) {
    final v = node.data[key];
    if (v is num) return v.toInt();
    final parsed = int.tryParse('${v ?? ''}');
    if (parsed != null) return parsed;
    for (final f in nodeDef(node.type).params) {
      if (f.key == key) {
        final d = f.defaultValue;
        if (d is num) return d.toInt();
        return int.tryParse('${d ?? ''}') ?? 0;
      }
    }
    return 0;
  }

  static bool _samePoints(List<MarkerPoint> a, List<MarkerPoint> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].x != b[i].x || a[i].y != b[i].y || a[i].color != b[i].color) {
        return false;
      }
    }
    return true;
  }
}

final screenLocateProvider =
    NotifierProvider<ScreenLocateNotifier, ScreenLocateState>(
      ScreenLocateNotifier.new,
    );

// ---- 全局区域框选 ----

/// 一次区域框选目标：确认后把矩形换算为两个角点写回节点参数
class RegionPickTarget {
  final String nodeId;

  /// 区域参数键（'left'/'top'/'right'/'bottom'）
  final String keyLeft, keyTop, keyRight, keyBottom;

  /// 悬浮提示标签（「框选区域」）
  final String label;
  const RegionPickTarget({
    required this.nodeId,
    required this.keyLeft,
    required this.keyTop,
    required this.keyRight,
    required this.keyBottom,
    required this.label,
  });
}

/// 框选进行中的状态
class RegionPickState {
  final RegionPickTarget? target; // null = 空闲
  const RegionPickState({this.target});

  bool get active => target != null;
}

class RegionPickNotifier extends Notifier<RegionPickState> {
  /// provider 被销毁后（离开编辑器页）异步恢复的代码不得再写 state
  bool _alive = true;

  @override
  RegionPickState build() {
    _alive = true;
    ref.onDispose(() => _alive = false);
    return const RegionPickState();
  }

  RegionPicker get _picker => ref.read(regionPickerProvider);

  void _set(RegionPickState s) {
    if (_alive) state = s;
  }

  /// 开始框选；确认后把矩形换算为两角点写回节点（left/top/right/bottom），
  /// 并自动勾选「仅指定区域」（useRegion=true），支持撤销/重做。
  Future<void> start({
    required fl.NodeEditorController controller,
    required RegionPickTarget target,
  }) async {
    if (state.active) return;
    if (!ref.read(automationProvider).isSupported) return;
    // 定位拖拽与框选共用全局鼠标钩子，框选开始前先收起定位图标
    ref.read(screenLocateProvider.notifier).stop();
    _set(RegionPickState(target: target));
    final result = await _picker.pickRegion();
    // 框选期间节点可能已被删除/切换
    if (result != null && controller.graph.nodes.containsKey(target.nodeId)) {
      controller.updateNode(
        target.nodeId,
        (n) => n.withData({
          target.keyLeft: result.x,
          target.keyTop: result.y,
          target.keyRight: result.x + result.w,
          target.keyBottom: result.y + result.h,
          'useRegion': true,
        }),
      );
    }
    _set(const RegionPickState());
  }

  /// UI 主动取消（页面卸载兜底；provider 已销毁时为 no-op）
  void cancel() {
    if (!_alive) return;
    _picker.cancel();
    _set(const RegionPickState());
  }
}

final regionPickerProvider = Provider<RegionPicker>((ref) => RegionPicker());

final regionPickProvider =
    NotifierProvider<RegionPickNotifier, RegionPickState>(
      RegionPickNotifier.new,
    );

// ---- 全局按键拾取 ----

/// 一次按键拾取目标：确认后把虚拟键码写入哪个节点的哪个参数
class KeyPickTarget {
  final String nodeId;

  /// 写入的参数键（'vkCode' 单键 / 'comboKeys' 组合键列表）
  final String paramKey;

  /// true = 追加到组合键列表；false = 覆盖单键
  final bool append;

  /// 悬浮提示标签（「拾取按键」…）
  final String label;
  const KeyPickTarget({
    required this.nodeId,
    required this.paramKey,
    this.append = false,
    required this.label,
  });
}

class KeyPickState {
  final KeyPickTarget? target; // null = 空闲
  final int? pressedVk; // 最近命中的键（UI 反馈用）
  const KeyPickState({this.target, this.pressedVk});

  bool get active => target != null;
}

class KeyPickNotifier extends Notifier<KeyPickState> {
  /// provider 被销毁后异步恢复的代码不得再写 state
  bool _alive = true;

  @override
  KeyPickState build() {
    _alive = true;
    ref.onDispose(() => _alive = false);
    return const KeyPickState();
  }

  KeyPicker get _picker => ref.read(keyPickerProvider);

  void _set(KeyPickState s) {
    if (_alive) state = s;
  }

  /// 开始拾取；确认后经 [controller] 写回节点（支持撤销/重做）。
  Future<void> start({
    required fl.NodeEditorController controller,
    required KeyPickTarget target,
  }) async {
    if (state.active) return;
    if (!ref.read(automationProvider).isSupported) return;
    _set(KeyPickState(target: target));
    final vk = await _picker.pickKey(
      onKey: (v) => _set(KeyPickState(target: target, pressedVk: v)),
    );
    if (vk != null && controller.graph.nodes.containsKey(target.nodeId)) {
      controller.updateNode(target.nodeId, (n) {
        if (target.append) {
          final keys = parseKeyList(n.data[target.paramKey]);
          if (!keys.contains(vk)) keys.add(vk);
          return n.withData({target.paramKey: keys});
        }
        return n.withData({target.paramKey: vk});
      });
    }
    _set(const KeyPickState());
  }

  /// UI 主动取消（页面卸载兜底；provider 已销毁时为 no-op）
  void cancel() {
    if (!_alive) return;
    _picker.cancel();
    _set(const KeyPickState());
  }
}

final keyPickerProvider = Provider<KeyPicker>((ref) => KeyPicker());

final keyPickProvider = NotifierProvider<KeyPickNotifier, KeyPickState>(
  KeyPickNotifier.new,
);

// ---- 蓝图运行状态 ----

class RunnerState {
  final bool running;
  final String? currentNodeId;
  final List<String> logs;
  const RunnerState({
    this.running = false,
    this.currentNodeId,
    this.logs = const [],
  });

  RunnerState copyWith({
    bool? running,
    String? currentNodeId,
    List<String>? logs,
  }) => RunnerState(
    running: running ?? this.running,
    currentNodeId: currentNodeId ?? this.currentNodeId,
    logs: logs ?? this.logs,
  );
}

/// 全局停止热键（F10）虚拟键码
const int _vkF10 = 0x79;

class RunnerNotifier extends Notifier<RunnerState> {
  BlueprintInterpreter? _engine;
  Timer? _stopHotkey;

  /// 引擎日志与节点高亮先入缓冲，再由 [_flush] 合并写入状态：
  /// 每步直接写状态会让编辑器整页（含画布）逐节点重建，循环中放大卡顿。
  /// 同一消息在本次窗口内只保留一行并计数：循环里「循环: … → 真」
  /// 「图像识别: 未命中 …」每轮完全相同，逐条追加会刷爆日志面板。
  final Map<String, _PendingLog> _pendingLogs = <String, _PendingLog>{};

  /// 单个 flush 窗口内允许保留的不同消息上限，超出部分丢弃并计数
  static const int _pendingLogLimit = 500;
  int _droppedLogs = 0;

  String? _pendingNodeId;
  bool _nodeDirty = false;
  Timer? _flushTimer;
  bool _alive = true;

  @override
  RunnerState build() {
    _alive = true;
    ref.onDispose(() {
      _alive = false;
      _flushTimer?.cancel();
      _flushTimer = null;
      _stopHotkey?.cancel();
      _stopHotkey = null;
    });
    return const RunnerState();
  }

  void start(BlueprintScript script) {
    if (state.running) return;
    final automation = ref.read(automationProvider);
    if (!automation.isSupported) {
      state = state.copyWith(
        logs: [...state.logs, '✗ ${automation.unsupportedReason}'],
        running: false,
      );
      return;
    }
    _pendingLogs.clear();
    _droppedLogs = 0;
    _nodeDirty = false;
    _flushTimer?.cancel();
    _flushTimer = null;
    final engine = BlueprintInterpreter(
      automation: automation,
      recognition: ref.read(recognitionProvider),
      hooks: EngineHooks(
        log: _appendLog,
        onNodeChange: _setCurrentNode,
        loadRecording: (id) => ref.read(recordingStorageProvider).loadById(id),
        // UI 层注入：快速空转的循环每帧让出一次，窗口最小化时由超时兜底
        yieldToFrame: waitForNextFrame,
      ),
    );
    _engine = engine;
    state = state.copyWith(
      running: true,
      logs: [...state.logs, '—— 启动 ${script.name} ——'],
    );
    // 全局停止热键：运行期间轮询检测 F10（不装钩子，避免拖慢目标窗口）
    _stopHotkey?.cancel();
    _stopHotkey = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (automation.isKeyDown(_vkF10)) {
        _stopHotkey?.cancel();
        _stopHotkey = null;
        _appendLog('检测到 F10，停止执行');
        stop();
      }
    });
    unawaited(
      engine.run(script).whenComplete(() {
        _stopHotkey?.cancel();
        _stopHotkey = null;
        if (!_alive) return;
        _flush(); // 把最后一批日志与高亮落定后再切换运行状态
        state = RunnerState(
          running: false,
          currentNodeId: null,
          logs: state.logs,
        );
        _engine = null;
      }),
    );
  }

  void stop() {
    _engine?.stop();
    _appendLog('停止请求已发送');
    _flush();
  }

  void clearLogs() {
    _pendingLogs.clear();
    _droppedLogs = 0;
    _flushTimer?.cancel();
    _flushTimer = null;
    state = RunnerState(
      running: state.running,
      currentNodeId: state.currentNodeId,
      logs: const [],
    );
  }

  /// 引擎日志：先入缓冲（相同的消息合并计数），由 [_flush] 批量写入状态
  void _appendLog(String m) {
    final existing = _pendingLogs[m];
    if (existing != null) {
      existing.count++;
    } else if (_pendingLogs.length < _pendingLogLimit) {
      _pendingLogs[m] = _PendingLog(TimeOfDayish.now());
    } else {
      _droppedLogs++;
    }
    _scheduleFlush();
  }

  /// 引擎节点高亮：值未变化时忽略（循环每轮都会回调同一节点）
  void _setCurrentNode(String? id) {
    if (!_alive || (!_nodeDirty && id == state.currentNodeId)) return;
    _pendingNodeId = id;
    _nodeDirty = true;
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(const Duration(milliseconds: 60), _flush);
  }

  /// 把缓冲的日志与高亮合并为一次状态写入
  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (!_alive || (!_nodeDirty && _pendingLogs.isEmpty)) return;
    final logs = _pendingLogs.isEmpty ? state.logs : _mergeLogs();
    final node = _nodeDirty ? _pendingNodeId : state.currentNodeId;
    _nodeDirty = false;
    state = RunnerState(
      running: state.running,
      currentNodeId: node,
      logs: logs,
    );
  }

  /// 合并缓冲日志并保留最近 500 条；重复消息只出一行并标注次数
  List<String> _mergeLogs() {
    final lines = <String>[
      for (final e in _pendingLogs.entries)
        '[${e.value.stamp}] ${e.key}${e.value.count > 1 ? '（×${e.value.count}）' : ''}',
    ];
    if (_droppedLogs > 0) {
      lines.add('…（日志过多，已省略 $_droppedLogs 条）');
      _droppedLogs = 0;
    }
    _pendingLogs.clear();
    if (lines.length >= 500) return lines.sublist(lines.length - 500);
    return [...state.logs.takeLast(500 - lines.length), ...lines];
  }
}

/// 缓冲中的一条日志：首次出现时间 + 本窗口内的重复次数
class _PendingLog {
  _PendingLog(this.stamp);
  final String stamp;
  int count = 1;
}

extension _TakeLast<T> on List<T> {
  List<T> takeLast(int n) => length <= n ? this : sublist(length - n);
}

class TimeOfDayish {
  static String now() {
    final t = DateTime.now();
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
  }
}

final runnerProvider = NotifierProvider<RunnerNotifier, RunnerState>(
  RunnerNotifier.new,
);
