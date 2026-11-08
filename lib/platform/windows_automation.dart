import 'dart:async';

import 'platform_automation.dart';
import 'win32/gdi32.dart' as gdi;
import 'win32/user32.dart' as u32;

/// PlatformAutomation 的 Windows 实现：SendInput 鼠标模拟 + GDI 截屏。
/// 所有坐标为屏幕物理像素。
class WindowsAutomation implements PlatformAutomation {
  const WindowsAutomation();

  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;

  @override
  (int, int) get screenSize => (u32.screenW(), u32.screenH());

  @override
  Future<void> moveMouse(
    int x,
    int y, {
    int durationMs = 0,
    bool Function()? cancelled,
  }) async {
    if (durationMs <= 0) {
      u32.moveAbsolute(x, y);
      return;
    }
    final (sx, sy) = u32.cursorPos();
    final steps = (durationMs / 12).clamp(4, 120).toInt();
    final dt = durationMs / steps;
    var stopped = false;
    for (var i = 1; i <= steps; i++) {
      if (cancelled?.call() ?? false) {
        stopped = true;
        break;
      }
      final t = i / steps;
      final e = t * t * (3 - 2 * t);
      u32.moveAbsolute(
        (sx + (x - sx) * e).round(),
        (sy + (y - sy) * e).round(),
      );
      await Future<void>.delayed(Duration(milliseconds: dt.round()));
    }
    if (!stopped) u32.moveAbsolute(x, y);
  }

  @override
  Future<void> click(int x, int y, {MouseButton button = MouseButton.left, int count = 1}) async {
    for (var i = 0; i < count.clamp(1, 20); i++) {
      _clickOnce(x, y, button);
      if (i < count - 1) await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  void _clickOnce(int x, int y, MouseButton button) {
    u32.moveAbsolute(x, y);
    u32.mouseDown(right: button == MouseButton.right, middle: button == MouseButton.middle);
    u32.mouseUp(right: button == MouseButton.right, middle: button == MouseButton.middle);
  }

  @override
  Future<void> swipe(
    int x1,
    int y1,
    int x2,
    int y2, {
    int durationMs = 300,
    MouseButton button = MouseButton.left,
    bool Function()? cancelled,
  }) async {
    u32.moveAbsolute(x1, y1);
    if (cancelled?.call() ?? false) return;
    final right = button == MouseButton.right;
    final middle = button == MouseButton.middle;
    u32.mouseDown(right: right, middle: middle);
    // 按下之后无论中止还是异常都必须抬键，避免系统残留按键按下状态
    try {
      final steps = (durationMs / 12).clamp(4, 120).toInt();
      final dt = durationMs / steps;
      for (var i = 1; i <= steps; i++) {
        if (cancelled?.call() ?? false) break;
        final t = i / steps;
        // 轻微缓动
        final e = t * t * (3 - 2 * t);
        u32.moveAbsolute(
          (x1 + (x2 - x1) * e).round(),
          (y1 + (y2 - y1) * e).round(),
        );
        await Future<void>.delayed(Duration(milliseconds: dt.round()));
      }
    } finally {
      u32.mouseUp(right: right, middle: middle);
    }
  }

  @override
  Future<void> longPress(int x, int y, {int durationMs = 800, MouseButton button = MouseButton.left}) async {
    u32.moveAbsolute(x, y);
    u32.mouseDown(right: button == MouseButton.right, middle: button == MouseButton.middle);
    await Future<void>.delayed(Duration(milliseconds: durationMs.clamp(1, 60000)));
    u32.mouseUp(right: button == MouseButton.right, middle: button == MouseButton.middle);
  }

  @override
  Future<void> scrollWheel(int x, int y, {int dy = 0, int dx = 0}) async {
    u32.moveAbsolute(x, y);
    // 一条 SendInput 的 mouseData 为 32 位有符号，按格（±120）分次滚动
    for (var d = dy; d != 0;) {
      final step = d.clamp(-120, 120);
      u32.wheelScroll(step);
      d -= step;
      if (d != 0) await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    for (var d = dx; d != 0;) {
      final step = d.clamp(-120, 120);
      u32.wheelScrollH(step);
      d -= step;
      if (d != 0) await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  @override
  Future<void> keyTap(int vkCode, {int durationMs = 60, bool extended = false}) async {
    final dur = durationMs.clamp(0, 60000);
    u32.keybdDown(vkCode, extended: extended);
    if (dur > 0) await Future<void>.delayed(Duration(milliseconds: dur));
    u32.keybdUp(vkCode, extended: extended);
  }

  @override
  Future<void> keyDown(int vkCode, {bool extended = false}) async {
    u32.keybdDown(vkCode, extended: extended);
  }

  @override
  Future<void> keyUp(int vkCode, {bool extended = false}) async {
    u32.keybdUp(vkCode, extended: extended);
  }

  @override
  Future<ScreenCapture> capture({RectPx? region}) async => gdi.captureScreen(region: region);

  @override
  (int, int) cursorPos() => u32.cursorPos();

  @override
  (bool, bool, bool) buttonsDown() => u32.mouseButtonsDown();

  @override
  bool isKeyDown(int vkCode) => u32.isKeyDown(vkCode);
}
