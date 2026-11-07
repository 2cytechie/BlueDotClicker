import 'dart:typed_data';

import 'package:bluedot_clicker/models/blueprint.dart';
import 'package:bluedot_clicker/platform/platform_automation.dart';
import 'package:bluedot_clicker/platform/recording.dart' show replayActions;
import 'package:flutter_test/flutter_test.dart';

/// 只记录键事件的测试替身（其余动作不实现/不使用）
class _KeyLogAutomation implements PlatformAutomation {
  final List<String> calls = [];

  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;
  @override
  (int, int) get screenSize => (1920, 1080);
  @override
  Future<void> moveMouse(int x, int y) async {}
  @override
  Future<void> click(int x, int y,
      {MouseButton button = MouseButton.left, int count = 1}) async {
    calls.add('click($x,$y)');
  }
  @override
  Future<void> swipe(int x1, int y1, int x2, int y2, {int durationMs = 300}) async {}
  @override
  Future<void> longPress(int x, int y,
      {int durationMs = 800, MouseButton button = MouseButton.left}) async {}
  @override
  Future<void> scrollWheel(int x, int y, {int dy = 0, int dx = 0}) async {}
  @override
  Future<void> keyTap(int vkCode,
      {int durationMs = 60, bool extended = false}) async {}
  @override
  Future<void> keyDown(int vkCode, {bool extended = false}) async {
    calls.add('down($vkCode)');
  }
  @override
  Future<void> keyUp(int vkCode, {bool extended = false}) async {
    calls.add('up($vkCode)');
  }
  @override
  Future<ScreenCapture> capture({RectPx? region}) async =>
      ScreenCapture(1, 1, Uint8List(4));
  @override
  (int, int) cursorPos() => (0, 0);
  @override
  (bool, bool, bool) buttonsDown() => (false, false, false);
  @override
  bool isKeyDown(int vkCode) => false;
}

void main() {
  test('长按 Alt 连点 3 次 Tab（独立键序列）→ 事件流精确还原交错时序', () async {
    final auto = _KeyLogAutomation();
    await replayActions(auto, const [
      RecKey(0, 0x12, durationMs: 200), // Alt
      RecKey(30, 0x09, durationMs: 20), // Tab 1
      RecKey(90, 0x09, durationMs: 20), // Tab 2
      RecKey(150, 0x09, durationMs: 20), // Tab 3
    ]);
    expect(auto.calls, [
      'down(18)', // Alt 按下
      'down(9)', 'up(9)', // Tab 1
      'down(9)', 'up(9)', // Tab 2
      'down(9)', 'up(9)', // Tab 3
      'up(18)', // Alt 直到结束才抬起
    ]);
  });

  test('RecCombo 事件流：按下→按住→逆序抬起', () async {
    final auto = _KeyLogAutomation();
    await replayActions(auto, const [
      RecCombo(0, [0x11, 0x43], durationMs: 100), // Ctrl+C
    ]);
    expect(auto.calls, ['down(17)', 'down(67)', 'up(67)', 'up(17)']);
  });

  test('鼠标动作打断键段：键段先执行完毕，鼠标动作按偏移执行', () async {
    final auto = _KeyLogAutomation();
    await replayActions(auto, const [
      RecKey(0, 0x41, durationMs: 50), // A
      RecClick(100, 10, 20), // 鼠标点击打断
      RecKey(200, 0x42, durationMs: 50), // B
    ]);
    // A 的 down/up 先于点击完成，随后执行点击，最后 B
    final aIdx = auto.calls.indexOf('up(65)');
    final clickIdx = auto.calls.indexOf('click(10,20)');
    final bDownIdx = auto.calls.indexOf('down(66)');
    expect(aIdx, greaterThanOrEqualTo(0));
    expect(clickIdx, greaterThan(aIdx));
    expect(bDownIdx, greaterThan(clickIdx));
  });
}
