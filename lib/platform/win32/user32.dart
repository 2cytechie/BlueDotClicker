import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Win32 user32.dll FFI 绑定（鼠标模拟、光标/按键状态、屏幕尺寸）
final DynamicLibrary user32Lib = DynamicLibrary.open('user32.dll');

// ---- 常量 ----
const int inputMouse = 0;
const int inputKeyboard = 1;
const int mouseeventfMove = 0x0001;
const int mouseeventfLeftdown = 0x0002;
const int mouseeventfLeftup = 0x0004;
const int mouseeventfRightdown = 0x0008;
const int mouseeventfRightup = 0x0010;
const int mouseeventfMiddledown = 0x0020;
const int mouseeventfMiddleup = 0x0040;
const int mouseeventfWheel = 0x0800;
const int mouseeventfHwheel = 0x1000;
const int mouseeventfVirtualdesk = 0x4000; // 绝对坐标基于整个虚拟桌面（多屏/负坐标）
const int mouseeventfAbsolutemove = 0x8000;
const int keyeventfExtendedkey = 0x0001;
const int keyeventfKeyup = 0x0002;
const int mapvkVkToVsc = 0; // MapVirtualKey: VK → 扫描码
const int smCxscreen = 0;
const int smCyscreen = 1;
const int vkLbutton = 0x01;
const int vkRbutton = 0x02;
const int vkMbutton = 0x04;
// 低级鼠标钩子
const int whMouseLl = 14;
const int wmMousewheel = 0x020A;
const int wmMouseHwheel = 0x020E;
// 低级钩子中的鼠标键消息（坐标拾取用）
const int wmMousemove = 0x0200;
const int wmLbuttondown = 0x0201;
const int wmLbuttonup = 0x0202;
const int wmRbuttondown = 0x0204;
const int wmRbuttonup = 0x0205;
const int wmMbuttondown = 0x0207;
const int wmMbuttonup = 0x0208;
// MSLLHOOKSTRUCT.flags：注入事件标志（SendInput/回放产生的事件带此标志）
const int llkhfInjected = 0x00000001;

// ---- 常用虚拟键码 ----
const int vkCancel = 0x03;
const int vkBack = 0x08;
const int vkTab = 0x09;
const int vkReturn = 0x0D;
const int vkShift = 0x10;
const int vkControl = 0x11;
const int vkMenu = 0x12; // Alt
const int vkPause = 0x13;
const int vkCapital = 0x14;
const int vkEscape = 0x1B;
const int vkSpace = 0x20;
const int vkPrior = 0x21;
const int vkNext = 0x22;
const int vkEnd = 0x23;
const int vkHome = 0x24;
const int vkLeft = 0x25;
const int vkUp = 0x26;
const int vkRight = 0x27;
const int vkDown = 0x28;
const int vkInsert = 0x2D;
const int vkDelete = 0x2E;
const int vkLwin = 0x5B;
const int vkRwin = 0x5C;
const int vkApps = 0x5D;
const int vkF10 = 0x79;
const int vkNumlock = 0x90;
const int vkLcontrol = 0xA2;
const int vkRcontrol = 0xA3;
const int vkLmenu = 0xA4;
const int vkRmenu = 0xA5;

/// 回放时需要 KEYEVENTF_EXTENDEDKEY 标志的键
/// （非数字键盘区的方向/编辑键、右 Ctrl/右 Alt）
bool isExtendedKey(int vk) => const {
      vkPrior, vkNext, vkEnd, vkHome,
      vkLeft, vkUp, vkRight, vkDown,
      vkInsert, vkDelete,
      vkRcontrol, vkRmenu,
    }.contains(vk);

final class _MouseInput extends Struct {
  @Long() external int dx;
  @Long() external int dy;
  @Uint32() external int mouseData;
  @Uint32() external int dwFlags;
  @Uint32() external int time;
  external Pointer<Void> dwExtraInfo;
}

final class _KeyboardInput extends Struct {
  @Uint16() external int wVk;
  @Uint16() external int wScan;
  @Uint32() external int dwFlags;
  @Uint32() external int time;
  external Pointer<Void> dwExtraInfo;
}

final class _InputUnion extends Union {
  external _MouseInput mi;
  external _KeyboardInput ki;
}

final class _INPUT extends Struct {
  @Uint32() external int type;
  external _InputUnion u;
}

typedef _SendInputC = Int32 Function(Uint32 cInputs, Pointer<_INPUT> pInputs, Int32 cbSize);
typedef _SendInputDart = int Function(int cInputs, Pointer<_INPUT> pInputs, int cbSize);
final _sendInput = user32Lib.lookupFunction<_SendInputC, _SendInputDart>('SendInput');

typedef _GetSystemMetricsC = Int32 Function(Int32 nIndex);
typedef _GetSystemMetricsDart = int Function(int nIndex);
final _getSystemMetrics = user32Lib.lookupFunction<_GetSystemMetricsC, _GetSystemMetricsDart>('GetSystemMetrics');

typedef _SetCursorPosC = Int32 Function(Int32 x, Int32 y);
typedef _SetCursorPosDart = int Function(int x, int y);
final _setCursorPos = user32Lib.lookupFunction<_SetCursorPosC, _SetCursorPosDart>('SetCursorPos');

final class _POINT extends Struct {
  @Long() external int x;
  @Long() external int y;
}

typedef _GetCursorPosC = Int32 Function(Pointer<_POINT>);
typedef _GetCursorPosDart = int Function(Pointer<_POINT>);
final _getCursorPos = user32Lib.lookupFunction<_GetCursorPosC, _GetCursorPosDart>('GetCursorPos');

/// 复用的坐标缓冲：轮询光标位置时免去每次分配/释放
Pointer<_POINT>? _cursorBuf;

typedef _GetAsyncKeyStateC = Int16 Function(Int32 vKey);
typedef _GetAsyncKeyStateDart = int Function(int vKey);
final _getAsyncKeyState = user32Lib.lookupFunction<_GetAsyncKeyStateC, _GetAsyncKeyStateDart>('GetAsyncKeyState');

// VK → 扫描码转换（当前键盘布局；注入按键时填充 wScan 用）
typedef _MapVirtualKeyWC = Uint32 Function(Uint32 uCode, Uint32 uMapType);
typedef _MapVirtualKeyWDart = int Function(int uCode, int uMapType);
final _mapVirtualKeyW =
    user32Lib.lookupFunction<_MapVirtualKeyWC, _MapVirtualKeyWDart>('MapVirtualKeyW');

int screenW() => _getSystemMetrics(smCxscreen);
int screenH() => _getSystemMetrics(smCyscreen);

// 虚拟桌面（所有显示器的并集）：多屏/负坐标移动的归一化基准
const int smXvirtualscreen = 76; // 虚拟桌面左上角 X（副屏在主屏左侧时为负）
const int smYvirtualscreen = 77;
const int smCxvirtualscreen = 78; // 虚拟桌面总宽
const int smCyvirtualscreen = 79;

/// 虚拟桌面原点与尺寸 (x, y, w, h)
(int, int, int, int) virtualScreenRect() => (
      _getSystemMetrics(smXvirtualscreen),
      _getSystemMetrics(smYvirtualscreen),
      _getSystemMetrics(smCxvirtualscreen),
      _getSystemMetrics(smCyvirtualscreen),
    );

(int, int) cursorPos() {
  final p = _cursorBuf ??= calloc<_POINT>();
  _getCursorPos(p);
  return (p.ref.x, p.ref.y);
}

(bool, bool, bool) mouseButtonsDown() => (
      _getAsyncKeyState(vkLbutton) & 0x8000 != 0,
      _getAsyncKeyState(vkMbutton) & 0x8000 != 0,
      _getAsyncKeyState(vkRbutton) & 0x8000 != 0,
    );

void setCursorPos(int x, int y) => _setCursorPos(x, y);

void _sendMouse(int flags, int dxNorm, int dyNorm, int mouseData) {
  final p = calloc<_INPUT>();
  final inp = p.ref;
  inp.type = inputMouse;
  inp.u.mi.dx = dxNorm;
  inp.u.mi.dy = dyNorm;
  inp.u.mi.mouseData = mouseData;
  inp.u.mi.dwFlags = flags;
  inp.u.mi.time = 0;
  inp.u.mi.dwExtraInfo = nullptr;
  _sendInput(1, p, sizeOf<_INPUT>());
  calloc.free(p);
}

/// 像素坐标 → 绝对移动归一化值（0..65535）。[rect] 为虚拟桌面 (x, y, w, h)。
/// 单独抽出为纯函数：多屏/负原点边界无需真实多显示器环境即可测试。
@visibleForTesting
(int, int) normalizeVirtual(int x, int y, (int, int, int, int) rect) {
  final (vx, vy, vw, vh) = rect;
  // 必须四舍五入：截断会使部分坐标反向换算后少 1 像素（moveAbsolute 落点偏移）
  final nx = vw <= 1
      ? 0
      : ((x - vx) * 65535 / (vw - 1)).round().clamp(0, 65535);
  final ny = vh <= 1
      ? 0
      : ((y - vy) * 65535 / (vh - 1)).round().clamp(0, 65535);
  return (nx, ny);
}

/// 绝对坐标移动：基于整个虚拟桌面归一化（MOUSEEVENTF_VIRTUALDESK），
/// 支持副屏与负坐标（副屏在主屏左侧时虚拟桌面原点为负）。
void _moveToNorm(int x, int y) {
  final rect = virtualScreenRect();
  if (rect.$3 <= 1 || rect.$4 <= 1) return;
  final (nx, ny) = normalizeVirtual(x, y, rect);
  _sendMouse(
    mouseeventfMove | mouseeventfAbsolutemove | mouseeventfVirtualdesk,
    nx,
    ny,
    0,
  );
}

void moveTo(int x, int y) => _moveToNorm(x, y);

void mouseDown({bool right = false, bool middle = false}) => _sendMouse(
      middle
          ? mouseeventfMiddledown
          : (right ? mouseeventfRightdown : mouseeventfLeftdown),
      0, 0, 0,
    );

void mouseUp({bool right = false, bool middle = false}) => _sendMouse(
      middle
          ? mouseeventfMiddleup
          : (right ? mouseeventfRightup : mouseeventfLeftup),
      0, 0, 0,
    );

/// 绝对坐标单击（先移动再按下抬起）
void clickAt(int x, int y, {bool right = false, bool middle = false}) {
  _moveToNorm(x, y);
  mouseDown(right: right, middle: middle);
  mouseUp(right: right, middle: middle);
}

/// 供拖拽/长按使用：移动到位置
void moveAbsolute(int x, int y) => _moveToNorm(x, y);

/// 垂直滚轮滚动（dy 正=上滚，120 为一格）
void wheelScroll(int dy) => _sendMouse(mouseeventfWheel, 0, 0, dy);

/// 水平滚轮滚动（dx 正=右滚，120 为一格）
void wheelScrollH(int dx) => _sendMouse(mouseeventfHwheel, 0, 0, dx);

/// 键盘虚拟键按下/抬起
void keybdDown(int vk, {bool extended = false}) => _sendKey(vk, extended ? keyeventfExtendedkey : 0);

void keybdUp(int vk, {bool extended = false}) =>
    _sendKey(vk, keyeventfKeyup | (extended ? keyeventfExtendedkey : 0));

void _sendKey(int vk, int flags) {
  final p = calloc<_INPUT>();
  final inp = p.ref;
  inp.type = inputKeyboard;
  inp.u.ki.wVk = vk;
  // 扫描码必填（AutoHotkey 同款做法）：SDL2/DirectInput/RAW Input 类目标按
  // lParam/RawInput 里的扫描码识别按键，wScan=0 时这些引擎完全收不到
  // 字母/数字/Enter 等键（方向键恰好有 VK 兜底所以能生效）。
  inp.u.ki.wScan = _mapVirtualKeyW(vk, mapvkVkToVsc);
  inp.u.ki.dwFlags = flags;
  inp.u.ki.time = 0;
  inp.u.ki.dwExtraInfo = nullptr;
  _sendInput(1, p, sizeOf<_INPUT>());
  calloc.free(p);
}

/// 录制轮询用：虚拟键当前是否物理按下
bool isKeyDown(int vk) => _getAsyncKeyState(vk) & 0x8000 != 0;

/// 录制过滤用：调用线程（平台线程）当前活动窗口句柄；
/// 返回非 0 表示焦点在本应用窗口（此时输入不记录），切到目标窗口后返回 0。
int getActiveWindow() => _getActiveWindow();

typedef _GetActiveWindowC = IntPtr Function();
typedef _GetActiveWindowDart = int Function();
final _getActiveWindow = user32Lib.lookupFunction<_GetActiveWindowC, _GetActiveWindowDart>('GetActiveWindow');

// ---- 窗口显示状态（坐标拾取期间最小化本应用 / 结束后恢复） ----

const int swMinimize = 6;
const int swRestore = 9;

/// kernel32 绑定（仅需进程 id，用于识别前台窗口归属）
final DynamicLibrary kernel32Lib = DynamicLibrary.open('kernel32.dll');

typedef _GetCurrentProcessIdC = Uint32 Function();
typedef _GetCurrentProcessIdDart = int Function();
final _getCurrentProcessId =
    kernel32Lib.lookupFunction<_GetCurrentProcessIdC, _GetCurrentProcessIdDart>('GetCurrentProcessId');

typedef _GetForegroundWindowC = IntPtr Function();
typedef _GetForegroundWindowDart = int Function();
final _getForegroundWindow =
    user32Lib.lookupFunction<_GetForegroundWindowC, _GetForegroundWindowDart>('GetForegroundWindow');

typedef _ShowWindowC = Int32 Function(IntPtr hWnd, Int32 nCmdShow);
typedef _ShowWindowDart = int Function(int hWnd, int nCmdShow);
final _showWindow = user32Lib.lookupFunction<_ShowWindowC, _ShowWindowDart>('ShowWindow');

typedef _SetForegroundWindowC = Int32 Function(IntPtr hWnd);
typedef _SetForegroundWindowDart = int Function(int hWnd);
final _setForegroundWindow =
    user32Lib.lookupFunction<_SetForegroundWindowC, _SetForegroundWindowDart>('SetForegroundWindow');

typedef _BringWindowToTopC = Int32 Function(IntPtr hWnd);
typedef _BringWindowToTopDart = int Function(int hWnd);
final _bringWindowToTop =
    user32Lib.lookupFunction<_BringWindowToTopC, _BringWindowToTopDart>('BringWindowToTop');

typedef _GetWindowThreadProcessIdC = Uint32 Function(IntPtr hWnd, Pointer<Uint32> lpdwProcessId);
typedef _GetWindowThreadProcessIdDart = int Function(int hWnd, Pointer<Uint32> lpdwProcessId);
final _getWindowThreadProcessId = user32Lib
    .lookupFunction<_GetWindowThreadProcessIdC, _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId');

/// 前台窗口属于本进程时返回其句柄，否则返回 0（避免误操作其他程序的窗口）
int ownForegroundWindow() {
  final hwnd = _getForegroundWindow();
  if (hwnd == 0) return 0;
  final pidPtr = calloc<Uint32>();
  _getWindowThreadProcessId(hwnd, pidPtr);
  final pid = pidPtr.value;
  calloc.free(pidPtr);
  return pid == _getCurrentProcessId() ? hwnd : 0;
}

/// 最小化（切到后台，避免遮挡目标区域）
void minimizeWindow(int hwnd) => _showWindow(hwnd, swMinimize);

/// 恢复显示并尝试置前激活
void restoreWindow(int hwnd) {
  _showWindow(hwnd, swRestore);
  _setForegroundWindow(hwnd);
  _bringWindowToTop(hwnd);
}

// ---- 低级鼠标钩子（WH_MOUSE_LL，捕获滚轮事件） ----

final class POINTAPI extends Struct {
  @Long() external int x;
  @Long() external int y;
}

final class MSLLHOOKSTRUCT extends Struct {
  external POINTAPI pt;
  @Uint32() external int mouseData;
  @Uint32() external int flags;
  @Uint32() external int time;
  external Pointer<Void> dwExtraInfo;
}

typedef HookProcC = IntPtr Function(Int32 nCode, IntPtr wParam, IntPtr lParam);
typedef HookProcDart = int Function(int nCode, int wParam, int lParam);

typedef _SetWindowsHookExCW = IntPtr Function(
    Int32 idHook, Pointer<NativeFunction<HookProcC>> lpfn, IntPtr hMod, Uint32 dwThreadId);
typedef _SetWindowsHookExDart = int Function(
    int idHook, Pointer<NativeFunction<HookProcC>> lpfn, int hMod, int dwThreadId);
final _setWindowsHookEx =
    user32Lib.lookupFunction<_SetWindowsHookExCW, _SetWindowsHookExDart>('SetWindowsHookExW');

typedef _UnhookWindowsHookExC = Int32 Function(IntPtr hhk);
typedef _UnhookWindowsHookExDart = int Function(int hhk);
final _unhookWindowsHookEx =
    user32Lib.lookupFunction<_UnhookWindowsHookExC, _UnhookWindowsHookExDart>('UnhookWindowsHookEx');

typedef _CallNextHookExC = IntPtr Function(
    IntPtr hhk, Int32 nCode, IntPtr wParam, IntPtr lParam);
typedef _CallNextHookExDart = int Function(
    int hhk, int nCode, int wParam, int lParam);
final _callNextHookEx =
    user32Lib.lookupFunction<_CallNextHookExC, _CallNextHookExDart>('CallNextHookEx');

/// 安装 WH_MOUSE_LL 钩子；[callback] 为 Dart 回调（须持有返回的 NativeCallable 防 GC）。
/// 返回钩子句柄，失败返回 0。低级钩子回调依赖安装线程消息循环（Flutter 平台线程满足）。
int installMouseHook(Pointer<NativeFunction<HookProcC>> callback) =>
    _setWindowsHookEx(whMouseLl, callback, 0, 0);

bool uninstallMouseHook(int handle) => _unhookWindowsHookEx(handle) != 0;

int callNextHook(int nCode, int wParam, int lParam) =>
    _callNextHookEx(0, nCode, wParam, lParam);

// ---- 分层窗口（屏幕标记图标用：透明置顶点击穿透）----

const int wsPopup = 0x80000000;
const int wsExLayered = 0x00080000;
const int wsExTransparent = 0x00000020; // 点击穿透
const int wsExToolwindow = 0x00000080; // 不进任务栏/Alt+Tab
const int wsExTopmost = 0x00000008;
const int wsExNoactivate = 0x08000000; // 不抢焦点
const int ulwAlpha = 2;
const int acSrcOver = 0;
const int acSrcAlpha = 1; // 逐像素 Alpha
const int swShowNa = 8; // 显示但不激活
const int swpNoSize = 0x0001;
const int swpNoActivate = 0x0010;
const int dibRgbColors = 0;
const int gwlExStyle = -20;

final class WNDCLASSEXW extends Struct {
  @Uint32() external int cbSize;
  @Uint32() external int style;
  external Pointer<NativeFunction<IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr)>> lpfnWndProc;
  @Int32() external int cbClsExtra;
  @Int32() external int cbWndExtra;
  @IntPtr() external int hInstance;
  @IntPtr() external int hIcon;
  @IntPtr() external int hCursor;
  @IntPtr() external int hbrBackground;
  external Pointer<Utf16> lpszMenuName;
  external Pointer<Utf16> lpszClassName;
  @IntPtr() external int hIconSm; // HICON 小图标（0 = 默认）
}

typedef _RegisterClassExWC = Uint16 Function(Pointer<WNDCLASSEXW>);
typedef _RegisterClassExWDart = int Function(Pointer<WNDCLASSEXW>);
final _registerClassEx =
    user32Lib.lookupFunction<_RegisterClassExWC, _RegisterClassExWDart>('RegisterClassExW');

typedef _UnregisterClassWC = Int32 Function(Pointer<Utf16>, IntPtr);
typedef _UnregisterClassWDart = int Function(Pointer<Utf16>, int);
final _unregisterClass =
    user32Lib.lookupFunction<_UnregisterClassWC, _UnregisterClassWDart>('UnregisterClassW');

/// DefWindowProcW 函数地址（作窗口类默认 WNDPROC）
final Pointer<NativeFunction<IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr)>> defWindowProcPtr =
    user32Lib.lookup<NativeFunction<IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr)>>(
        'DefWindowProcW');

typedef _CreateWindowExWC = IntPtr Function(
    Uint32, Pointer<Utf16>, Pointer<Utf16>, Uint32,
    Int32, Int32, Int32, Int32,
    IntPtr, IntPtr, IntPtr, IntPtr);
typedef _CreateWindowExWDart = int Function(
    int, Pointer<Utf16>, Pointer<Utf16>, int,
    int, int, int, int,
    int, int, int, int);
final _createWindowEx =
    user32Lib.lookupFunction<_CreateWindowExWC, _CreateWindowExWDart>('CreateWindowExW');

typedef _DestroyWindowC = Int32 Function(IntPtr);
typedef _DestroyWindowDart = int Function(int);
final _destroyWindow =
    user32Lib.lookupFunction<_DestroyWindowC, _DestroyWindowDart>('DestroyWindow');

typedef _SetWindowPosC = Int32 Function(IntPtr, IntPtr,
    Int32, Int32, Int32, Int32, Uint32);
typedef _SetWindowPosDart = int Function(int, int, int, int, int, int, int);
final _setWindowPos =
    user32Lib.lookupFunction<_SetWindowPosC, _SetWindowPosDart>('SetWindowPos');

typedef _GetModuleHandleWC = IntPtr Function(Pointer<Utf16>);
typedef _GetModuleHandleWDart = int Function(Pointer<Utf16>);
// GetModuleHandleW 属于 kernel32.dll（不是 user32）
final _getModuleHandle = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<_GetModuleHandleWC, _GetModuleHandleWDart>('GetModuleHandleW');

typedef _UpdateLayeredWindowC = Int32 Function(
    IntPtr, IntPtr, Pointer<Int32>, Pointer<Int32>,
    IntPtr, Pointer<Int32>, Int32, Pointer<Uint8>, Uint32);
typedef _UpdateLayeredWindowDart = int Function(
    int, int, Pointer<Int32>, Pointer<Int32>,
    int, Pointer<Int32>, int, Pointer<Uint8>, int);
final _updateLayeredWindow = user32Lib
    .lookupFunction<_UpdateLayeredWindowC, _UpdateLayeredWindowDart>('UpdateLayeredWindow');

/// 进程实例句柄（注册窗口类用）
int getModuleHandle() => _getModuleHandle(nullptr);

/// 注册窗口类（进程内一般只调一次）；返回是否成功。
/// WNDPROC 固定为 DefWindowProcW——分层窗口跳过 WM_PAINT，无需自定义消息处理。
bool registerMarkerWindowClass(String className) {
  final name = className.toNativeUtf16();
  final wc = calloc<WNDCLASSEXW>();
  wc.ref.cbSize = sizeOf<WNDCLASSEXW>();
  wc.ref.lpfnWndProc = defWindowProcPtr;
  wc.ref.hInstance = getModuleHandle();
  wc.ref.lpszClassName = name;
  final atom = _registerClassEx(wc);
  calloc.free(wc);
  calloc.free(name);
  return atom != 0;
}

void unregisterMarkerWindowClass(String className) {
  final name = className.toNativeUtf16();
  _unregisterClass(name, getModuleHandle());
  calloc.free(name);
}

/// 创建分层置顶穿透小窗口；返回 hwnd（失败 0）。
int createLayeredWindow({
  required String className,
  required int exStyle,
  required int x,
  required int y,
  required int w,
  required int h,
}) {
  final cls = className.toNativeUtf16();
  final title = ''.toNativeUtf16();
  final hwnd = _createWindowEx(
    exStyle, cls, title, wsPopup,
    x, y, w, h,
    0, // hWndParent = 0（顶层窗口）
    0, // hMenu
    getModuleHandle(),
    0, // lpParam
  );
  calloc.free(cls);
  calloc.free(title);
  return hwnd;
}

bool destroyLayeredWindow(int hwnd) => _destroyWindow(hwnd) != 0;
void showWindowNa(int hwnd) => _showWindow(hwnd, swShowNa);
bool moveWindowPos(int hwnd, int x, int y) =>
    _setWindowPos(hwnd, 0, x, y, 0, 0, swpNoSize | swpNoActivate) != 0;

typedef _GetWindowLongPtrWC = IntPtr Function(IntPtr, Int32);
typedef _GetWindowLongPtrWDart = int Function(int, int);
final _getWindowLongPtr = user32Lib
    .lookupFunction<_GetWindowLongPtrWC, _GetWindowLongPtrWDart>('GetWindowLongPtrW');

/// 窗口属性查询（GWL_EXSTYLE 等；诊断/测试用）
int getWindowLongPtr(int hwnd, int index) => _getWindowLongPtr(hwnd, index);

typedef _IsWindowC = Int32 Function(IntPtr);
typedef _IsWindowDart = int Function(int);
final _isWindow = user32Lib.lookupFunction<_IsWindowC, _IsWindowDart>('IsWindow');

/// 窗口是否仍存在（销毁验证用）
bool isWindow(int hwnd) => _isWindow(hwnd) != 0;

/// UpdateLayeredWindow：把预乘 BGRA 位图设为窗口内容（32bpp、逐像素 Alpha）。
/// [pptDst]/[psize] 为新窗口位置/尺寸；[hdcSrc] 已选入 [hbmp]；[pblend] 由 [blendAlpha] 构造。
bool updateLayeredWindowContent(
  int hwnd,
  int hdcScreen, // 传 0 即可（ULW 不需要屏幕 DC）
  Pointer<Int32> pptDst,
  Pointer<Int32> psize,
  int hdcSrc,
  Pointer<Int32> pptSrc,
  int crKey,
  Pointer<Uint8> pblend,
  int dwFlags,
) {
  return _updateLayeredWindow(hwnd, hdcScreen, pptDst, psize, hdcSrc, pptSrc,
          crKey, pblend, dwFlags) != 0;
}
