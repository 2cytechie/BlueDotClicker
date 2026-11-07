import 'dart:async';
import 'dart:ffi';

import 'platform_automation.dart';
import 'screen_marker.dart';
import 'win32/user32.dart' as u32;

/// 一次拾取的结果：屏幕物理坐标 + 确认所用的鼠标键
class PickResult {
  final int x;
  final int y;
  final MouseButton button;
  const PickResult(this.x, this.y, this.button);
}

/// 全局坐标拾取器：进入拾取后最小化本应用窗口（避免遮挡目标区域），
/// 安装 WH_MOUSE_LL 钩子拦截左/右/中键点击（吞掉事件，目标窗口无感），
/// 同时轮询 GetCursorPos 报告实时坐标。左/右/中键任意一键确认；Esc 取消。
class CoordinatePicker {
  NativeCallable<u32.HookProcC>? _proc;
  int _hookHandle = 0;
  Timer? _timer;
  Completer<PickResult?>? _completer;

  /// 已吞掉 down 的键 → 需吞掉对应 up（避免目标窗口收到孤儿抬起）
  final Set<int> _swallowUp = {};

  /// 最近一次已上报的光标位置（无变化时不刷新 UI，降低开销）
  (int, int)? _lastCursor;

  /// 拾取期间的绿色边缘提示（虚拟桌面范围）
  final ScreenBorderService _border = ScreenBorderService();

  bool get isPicking => _completer != null;

  /// 拾取单个屏幕坐标。确认返回 [PickResult]，取消（Esc/UI）返回 null。
  /// [onCursorMove] 仅在光标移动时回调。
  Future<PickResult?> pickPoint({void Function((int, int) pos)? onCursorMove}) async {
    if (isPicking) return null;
    final completer = _completer = Completer<PickResult?>();
    _swallowUp.clear();
    _lastCursor = null;

    // 低级钩子：拦截按键消息（回调保持轻量，仅记录结果）
    final proc = _proc = NativeCallable<u32.HookProcC>.isolateLocal(
      (int nCode, int wParam, int lParam) {
        if (nCode >= 0 && _completer != null) {
          switch (wParam) {
            case u32.wmLbuttondown:
            case u32.wmRbuttondown:
            case u32.wmMbuttondown:
              final info = Pointer<u32.MSLLHOOKSTRUCT>.fromAddress(lParam).ref;
              final button = switch (wParam) {
                u32.wmRbuttondown => MouseButton.right,
                u32.wmMbuttondown => MouseButton.middle,
                _ => MouseButton.left,
              };
              _swallowUp.add(wParam + 1); // down+1 即对应 up 消息值
              _complete(PickResult(info.pt.x, info.pt.y, button));
              return 1; // 吞掉，目标窗口收不到
            case u32.wmLbuttonup:
            case u32.wmRbuttonup:
            case u32.wmMbuttonup:
              if (_swallowUp.remove(wParam)) return 1;
          }
        }
        return u32.callNextHook(nCode, wParam, lParam);
      },
      exceptionalReturn: 0, // 异常时放行事件
    );

    final handle = u32.installMouseHook(proc.nativeFunction);
    if (handle == 0) {
      proc.close();
      _proc = null;
      _completer = null;
      return null;
    }
    _hookHandle = handle;

    // 本应用窗口最小化到后台，避免挡住需要点击的目标区域；拾取结束后恢复
    final hwnd = u32.ownForegroundWindow();
    if (hwnd != 0) u32.minimizeWindow(hwnd);

    // 屏幕边缘绿色描边：提示可拾取的虚拟桌面范围
    final (vx, vy, vw, vh) = u32.virtualScreenRect();
    _border.showRect(vx, vy, vw, vh);

    // 轮询：实时坐标（仅变化时上报）+ Esc 取消（钩子回调不做重活）
    var escWasDown = false;
    _timer = Timer.periodic(const Duration(milliseconds: 30), (_) {
      if (_completer == null) return;
      final pos = u32.cursorPos();
      if (pos != _lastCursor) {
        _lastCursor = pos;
        onCursorMove?.call(pos);
      }
      final escDown = u32.isKeyDown(u32.vkEscape);
      if (escDown && !escWasDown) _complete(null);
      escWasDown = escDown;
    });

    try {
      return await completer.future;
    } finally {
      _teardown();
      _border.hide();
      if (hwnd != 0) u32.restoreWindow(hwnd);
    }
  }

  /// UI 主动取消兜底（页面关闭/切换等）
  void cancel() => _complete(null);

  void _complete(PickResult? result) {
    final c = _completer;
    if (c == null || c.isCompleted) return;
    _completer = null;
    c.complete(result);
  }

  void _teardown() {
    _timer?.cancel();
    _timer = null;
    if (_hookHandle != 0) {
      u32.uninstallMouseHook(_hookHandle);
      _hookHandle = 0;
    }
    _proc?.close();
    _proc = null;
    _swallowUp.clear();
    _lastCursor = null;
  }
}
