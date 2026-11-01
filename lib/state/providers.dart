import 'dart:async';

import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/interpreter.dart';
import '../models/blueprint.dart';
import '../platform/automation_factory.dart';
import '../platform/coordinate_picker.dart';
import '../platform/platform_automation.dart';
import '../platform/recording.dart';
import '../services/media_tester.dart';
import '../services/recognition.dart';
import '../services/script_storage.dart';
import '../services/windows_recognition.dart';
import '../platform/screen_marker.dart';

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

final recognitionProvider = Provider<RecognitionService>(
  (ref) => WindowsRecognitionService(),
);

/// 媒体节点测试器（属性面板「测试」按钮使用）
final mediaTesterProvider = Provider<MediaTester>(
  (ref) => MediaTester(
    ref.watch(automationProvider),
    ref.watch(recognitionProvider),
  ),
);

final scriptStorageProvider = Provider<ScriptStorage>((ref) => ScriptStorage());

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

// ---- 全局坐标拾取 ----

/// 一次拾取目标：确认后写回哪个节点的哪些参数
class PickTarget {
  final String nodeId;

  /// 坐标写入的参数键（如 'x'/'y'、'startX'/'startY'）
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
    _set(CoordinatePickState(target: target, cursor: null));
    final result = await _picker.pickPoint(
      onCursorMove: (pos) {
        if (state.active) _set(CoordinatePickState(target: target, cursor: pos));
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

final coordinatePickerProvider = Provider<CoordinatePicker>((ref) => CoordinatePicker());

final coordinatePickProvider =
    NotifierProvider<CoordinatePickNotifier, CoordinatePickState>(
      CoordinatePickNotifier.new,
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

  @override
  RunnerState build() => const RunnerState();

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
    final engine = BlueprintInterpreter(
      automation: automation,
      recognition: ref.read(recognitionProvider),
      hooks: EngineHooks(
        log: (m) => _appendLog(m),
        onNodeChange: (id) => state = state.copyWith(currentNodeId: id),
        loadScript: (name) => ref.read(scriptStorageProvider).load(name),
        loadRecording: (id) => ref.read(recordingStorageProvider).loadById(id),
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
        state = state.copyWith(running: false, currentNodeId: null);
        _engine = null;
      }),
    );
  }

  void stop() {
    _engine?.stop();
    _appendLog('停止请求已发送');
  }

  void clearLogs() => state = state.copyWith(logs: []);

  void _appendLog(String m) {
    final now = TimeOfDayish.now();
    state = state.copyWith(logs: [...state.logs.takeLast(499), '[$now] $m']);
  }
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
