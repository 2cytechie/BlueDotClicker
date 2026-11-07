import 'dart:typed_data';

/// 截屏结果（BGRA 原始像素）
class ScreenCapture {
  final int width;
  final int height;

  /// 采集区域左上角的屏幕坐标（虚拟桌面坐标；副屏在主屏左侧/上方时可为负）
  final int x;
  final int y;

  /// BGRA 顺序原始字节（Windows GDI 原生顺序）
  final Uint8List bgra;
  const ScreenCapture(
    this.width,
    this.height,
    this.bgra, {
    this.x = 0,
    this.y = 0,
  });

  /// 转为 RGBA
  Uint8List toRgba() {
    final rgba = Uint8List(bgra.length);
    for (var i = 0; i < bgra.length; i += 4) {
      rgba[i] = bgra[i + 2];
      rgba[i + 1] = bgra[i + 1];
      rgba[i + 2] = bgra[i];
      rgba[i + 3] = bgra[i + 3];
    }
    return rgba;
  }
}

class RectPx {
  final int x, y, w, h;
  const RectPx(this.x, this.y, this.w, this.h);
}

/// 鼠标按键
enum MouseButton { left, right, middle }

/// 平台自动化抽象接口。
/// UI 与执行引擎只依赖此接口；Windows 实现 Phase 1 提供，Android 为 Phase 2。
abstract interface class PlatformAutomation {
  bool get isSupported;
  String? get unsupportedReason;

  /// 屏幕物理分辨率
  (int, int) get screenSize;

  Future<void> moveMouse(int x, int y);
  Future<void> click(
    int x,
    int y, {
    MouseButton button = MouseButton.left,
    int count = 1,
  });
  Future<void> swipe(int x1, int y1, int x2, int y2, {int durationMs = 300});
  Future<void> longPress(
    int x,
    int y, {
    int durationMs = 800,
    MouseButton button = MouseButton.left,
  });

  /// 鼠标滚轮滚动（先移动到指定位置再滚动；dy 正=上滚、dx 正=右滚，120 为一格）
  Future<void> scrollWheel(int x, int y, {int dy = 0, int dx = 0});

  /// 按下并抬起虚拟键（模拟一次按键，按住 durationMs 毫秒）
  Future<void> keyTap(int vkCode, {int durationMs = 60, bool extended = false});

  /// 按下虚拟键不抬起（组合键回放用；必须与 [keyUp] 成对调用）
  Future<void> keyDown(int vkCode, {bool extended = false});

  /// 抬起虚拟键（与 [keyDown] 成对）
  Future<void> keyUp(int vkCode, {bool extended = false});

  /// 截屏（全屏或区域）
  Future<ScreenCapture> capture({RectPx? region});

  /// 当前鼠标物理坐标（录制用）
  (int, int) cursorPos();

  /// 鼠标左/中/右键是否按下（录制用）
  (bool left, bool middle, bool right) buttonsDown();

  /// 虚拟键当前是否物理按下（全局停止热键 F10 检测用）
  bool isKeyDown(int vkCode);
}

/// 未支持平台的降级实现：拒绝所有动作，给出提示，不崩溃。
class UnsupportedPlatformAutomation implements PlatformAutomation {
  const UnsupportedPlatformAutomation([this._reason = '当前平台暂不支持自动化']);
  final String _reason;
  @override
  bool get isSupported => false;
  @override
  String? get unsupportedReason => _reason;
  @override
  (int, int) get screenSize => (1280, 720);
  @override
  Future<void> moveMouse(int x, int y) => _deny();
  @override
  Future<void> click(
    int x,
    int y, {
    MouseButton button = MouseButton.left,
    int count = 1,
  }) => _deny();
  @override
  Future<void> swipe(int x1, int y1, int x2, int y2, {int durationMs = 300}) =>
      _deny();
  @override
  Future<void> longPress(
    int x,
    int y, {
    int durationMs = 800,
    MouseButton button = MouseButton.left,
  }) => _deny();
  @override
  Future<void> scrollWheel(int x, int y, {int dy = 0, int dx = 0}) => _deny();
  @override
  Future<void> keyTap(
    int vkCode, {
    int durationMs = 60,
    bool extended = false,
  }) => _deny();
  @override
  Future<void> keyDown(int vkCode, {bool extended = false}) => _deny();
  @override
  Future<void> keyUp(int vkCode, {bool extended = false}) => _deny();
  @override
  Future<ScreenCapture> capture({RectPx? region}) async {
    throw UnsupportedError(unsupportedReason!);
  }

  @override
  (int, int) cursorPos() => (0, 0);
  @override
  (bool, bool, bool) buttonsDown() => (false, false, false);
  @override
  bool isKeyDown(int vkCode) => false;
  Never _deny() => throw UnsupportedError(unsupportedReason!);
}
