import 'dart:async';
import 'dart:ffi';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'screen_marker.dart';
import 'win32/user32.dart' as u32;

/// 拖拽矩形归一化（纯函数，可单测）：任意方向拖拽 → (左上角X, 左上角Y, 宽, 高)
@visibleForTesting
(int, int, int, int) normalizeDragRect(int sx, int sy, int ex, int ey) {
  final x = sx < ex ? sx : ex;
  final y = sy < ey ? sy : ey;
  return (x, y, (sx - ex).abs(), (sy - ey).abs());
}

/// 区域拾取结果：屏幕物理坐标矩形
class RegionPickResult {
  final int x, y, w, h;
  const RegionPickResult(this.x, this.y, this.w, this.h);
}

/// 全局区域框选器（模式同 CoordinatePicker）：进入后最小化本应用窗口，
/// 屏幕边缘显示绿色描边提示范围；左键按下拖出矩形（绿色描边实时跟随预览），
/// 松开确认并返回矩形；Esc 取消。右/中键不参与、放行。
class RegionPicker {
  NativeCallable<u32.HookProcC>? _proc;
  int _hookHandle = 0;
  Timer? _timer;
  Completer<RegionPickResult?>? _completer;

  /// 拖拽起点（左键 down 位置）；null = 尚未开始拖拽
  (int, int)? _dragStart;

  /// 已吞掉 down 的键 → 需吞掉对应 up（避免目标窗口收到孤儿抬起）
  final Set<int> _swallowUp = {};

  /// 实时预览的绿色边框（进入时提示虚拟桌面范围，拖拽中跟随当前矩形）
  final ScreenBorderService _border = ScreenBorderService();

  /// 最近一次已预览的矩形（无变化时跳过重渲染）
  (int, int, int, int)? _lastPreview;

  bool get isPicking => _completer != null;

  /// 框选一个屏幕区域。确认返回 [RegionPickResult]，取消（Esc/UI/未拖出矩形）返回 null。
  Future<RegionPickResult?> pickRegion() async {
    if (isPicking) return null;
    final completer = _completer = Completer<RegionPickResult?>();
    _dragStart = null;
    _swallowUp.clear();
    _lastPreview = null;

    // 低级钩子：拦截左键 down/up（吞掉事件，目标窗口无感）；右/中键放行
    final proc = _proc = NativeCallable<u32.HookProcC>.isolateLocal(
      (int nCode, int wParam, int lParam) {
        if (nCode >= 0 && _completer != null) {
          switch (wParam) {
            case u32.wmLbuttondown:
              if (_dragStart == null) {
                final info =
                    Pointer<u32.MSLLHOOKSTRUCT>.fromAddress(lParam).ref;
                _dragStart = (info.pt.x, info.pt.y);
                _swallowUp.add(u32.wmLbuttonup); // 吞 down 必须吞 up
                return 1; // 吞掉，目标窗口收不到
              }
            case u32.wmLbuttonup:
              if (_swallowUp.remove(u32.wmLbuttonup)) {
                final info =
                    Pointer<u32.MSLLHOOKSTRUCT>.fromAddress(lParam).ref;
                final start = _dragStart;
                if (start != null) {
                  final (x, y, w, h) =
                      normalizeDragRect(start.$1, start.$2, info.pt.x, info.pt.y);
                  // 同点松开（未拖出矩形）视为取消，避免误触产生 0 尺寸区域
                  _complete(
                      w == 0 || h == 0 ? null : RegionPickResult(x, y, w, h));
                }
                return 1;
              }
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

    // 本应用窗口最小化到后台，避免挡住需要框选的目标区域；结束后恢复
    final hwnd = u32.ownForegroundWindow();
    if (hwnd != 0) u32.minimizeWindow(hwnd);

    // 屏幕边缘绿色描边：提示可框选的虚拟桌面范围
    final (vx, vy, vw, vh) = u32.virtualScreenRect();
    _border.showRect(vx, vy, vw, vh);

    // 轮询：拖拽中按当前光标实时预览矩形；Esc 取消（钩子回调不做重活）
    var escWasDown = false;
    _timer = Timer.periodic(const Duration(milliseconds: 30), (_) {
      if (_completer == null) return;
      final escDown = u32.isKeyDown(u32.vkEscape);
      if (escDown && !escWasDown) {
        _complete(null);
        return;
      }
      escWasDown = escDown;
      final start = _dragStart;
      if (start == null) return;
      final (cx, cy) = u32.cursorPos();
      final rect = normalizeDragRect(start.$1, start.$2, cx, cy);
      if (rect != _lastPreview) {
        _lastPreview = rect;
        _border.showRect(rect.$1, rect.$2, rect.$3, rect.$4);
      }
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

  void _complete(RegionPickResult? result) {
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
    _dragStart = null;
    _swallowUp.clear();
    _lastPreview = null;
  }
}
