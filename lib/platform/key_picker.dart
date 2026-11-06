import 'dart:async';

import 'win32/user32.dart' as u32;

/// 全局按键拾取器：30ms 轮询 `GetAsyncKeyState`，返回第一个"新按下"的虚拟键。
///
/// 与坐标拾取同风格：进入时最小化本应用窗口（避免按键焦点留在编辑器里），
/// 结束时恢复；Esc 取消。不做键盘钩子——轮询不干扰目标窗口，且 Ctrl/Shift
/// 等修饰键先按的逻辑天然由"按顺序优先"满足。
class KeyPicker {
  Timer? _timer;
  Completer<int?>? _completer;

  bool get isPicking => _completer != null;

  /// 拾取一个按键；[onKey] 用于 UI 实时反馈（目前仅在命中时回调一次）。
  /// 取消（Esc/UI）返回 null。
  Future<int?> pickKey({void Function(int vk)? onKey}) async {
    if (isPicking) return null;
    final completer = _completer = Completer<int?>();

    // 基线：开始时已按住的键不算"新按下"（松开再按仍可拾取）
    var previous = _snapshot();
    final hwnd = u32.ownForegroundWindow();
    if (hwnd != 0) u32.minimizeWindow(hwnd);

    _timer = Timer.periodic(const Duration(milliseconds: 30), (_) {
      if (_completer == null) return;
      final down = _snapshot();
      final newly = down.difference(previous);
      previous = down;
      if (newly.isEmpty) return;
      if (newly.contains(u32.vkEscape)) {
        _complete(null);
        return;
      }
      for (final vk in _candidates()) {
        if (newly.contains(vk)) {
          onKey?.call(vk);
          _complete(vk);
          return;
        }
      }
    });

    try {
      return await completer.future;
    } finally {
      _timer?.cancel();
      _timer = null;
      if (hwnd != 0) u32.restoreWindow(hwnd);
    }
  }

  /// UI 主动取消兜底（页面关闭/切换等）
  void cancel() => _complete(null);

  void _complete(int? vk) {
    final c = _completer;
    if (c == null || c.isCompleted) return;
    _completer = null;
    c.complete(vk);
  }

  /// 鼠标键不是按键拾取的目标
  static const Set<int> _mouseVks = {
    u32.vkLbutton,
    u32.vkRbutton,
    u32.vkMbutton,
    0x05, // XBUTTON1
    0x06, // XBUTTON2
  };

  /// 修饰键优先，其余按 VK 升序（同一轮询周期内同时按下时结果稳定）
  static const List<int> _modifierFirst = [
    u32.vkControl,
    u32.vkShift,
    u32.vkMenu,
    u32.vkLwin,
    u32.vkRwin,
  ];

  static Iterable<int> _candidates() sync* {
    yield* _modifierFirst;
    for (var vk = 0x03; vk <= 0xFE; vk++) {
      if (_mouseVks.contains(vk)) continue;
      if (_modifierFirst.contains(vk)) continue;
      yield vk;
    }
  }

  static Set<int> _snapshot() {
    final down = <int>{};
    for (var vk = 0x01; vk <= 0xFE; vk++) {
      if (_mouseVks.contains(vk)) continue;
      if (u32.isKeyDown(vk)) down.add(vk);
    }
    return down;
  }
}
