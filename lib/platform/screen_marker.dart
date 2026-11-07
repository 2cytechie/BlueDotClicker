import 'dart:async';
import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'win32/gdi32.dart' as gdi;
import 'win32/user32.dart' as u32;

/// 屏幕标记点：位置（物理像素）+ 填充色（Flutter 0xAARRGGBB）
class MarkerPoint {
  final int x, y;
  final int color;
  const MarkerPoint(this.x, this.y, this.color);
}

// ---- 纯逻辑（服务与单元测试共用；无窗口/钩子/DPI 依赖） ----

/// 预乘查找表：_pmLut[(a << 8) | c] == round(c * a / 255)
final Uint8List _pmLut = _buildPmLut();

Uint8List _buildPmLut() {
  final lut = Uint8List(256 * 256);
  for (var a = 0; a < 256; a++) {
    for (var c = 0; c < 256; c++) {
      // 与 round(c*a/255) 逐值恒等（half-up 取整）
      lut[(a << 8) | c] = (c * a * 2 + 255) ~/ 510;
    }
  }
  return lut;
}

/// RGBA（直通 Alpha）→ 预乘 BGRA（UpdateLayeredWindow 要求）。
/// [dst] 长度须与 [src] 相同；全量覆写（a=0 清零），可复用旧缓冲。
@visibleForTesting
void premultiplyRgbaToBgra(Uint8List src, Uint8List dst) {
  final lut = _pmLut;
  final n = src.length;
  for (var i = 0; i < n; i += 4) {
    final a = src[i + 3];
    if (a == 0) {
      dst[i] = 0;
      dst[i + 1] = 0;
      dst[i + 2] = 0;
      dst[i + 3] = 0;
      continue;
    }
    dst[i] = lut[(a << 8) | src[i + 2]]; // B
    dst[i + 1] = lut[(a << 8) | src[i + 1]]; // G
    dst[i + 2] = lut[(a << 8) | src[i]]; // R
    dst[i + 3] = a;
  }
}

/// 所有标记点 ± [margin] 的紧包围盒（物理像素，未做屏幕 clamp）。
/// 返回 (left, top, right, bottom)；要求 [points] 非空。
@visibleForTesting
(int, int, int, int) tightMarkerBox(List<MarkerPoint> points, int margin) {
  var left = 1 << 30, top = 1 << 30, right = -(1 << 30), bottom = -(1 << 30);
  for (final p in points) {
    left = left < (p.x - margin) ? left : p.x - margin;
    top = top < (p.y - margin) ? top : p.y - margin;
    right = right > (p.x + margin) ? right : p.x + margin;
    bottom = bottom > (p.y + margin) ? bottom : p.y + margin;
  }
  return (left, top, right, bottom);
}

/// 窗口位置 clamp：保持窗口位于可用区域内（窗口不小于该区域时锚定左上角）。
/// [originX]/[originY] 为可用区域左上角（虚拟桌面可为主屏左侧的负坐标）。
@visibleForTesting
(int, int) clampWindowPos(
  int x,
  int y,
  int w,
  int h,
  int sw,
  int sh, {
  int originX = 0,
  int originY = 0,
}) {
  final maxX = originX + (sw - w > 0 ? sw - w : 0);
  final maxY = originY + (sh - h > 0 ? sh - h : 0);
  final cx = x < originX ? originX : (x > maxX ? maxX : x);
  final cy = y < originY ? originY : (y > maxY ? maxY : y);
  return (cx, cy);
}

/// 命中测试：[radiusPx] 半径内返回点索引（重叠取小索引），未命中返回 -1
@visibleForTesting
int markerHitTest(List<MarkerPoint> points, int x, int y, int radiusPx) {
  final r2 = radiusPx * radiusPx;
  for (var i = 0; i < points.length; i++) {
    final dx = x - points[i].x;
    final dy = y - points[i].y;
    if (dx * dx + dy * dy <= r2) return i;
  }
  return -1;
}

/// 分层小窗口封装：透明置顶点击穿透（WS_EX_LAYERED|WS_EX_TRANSPARENT|TOPMOST|TOOLWINDOW|NOACTIVATE），
/// 窗口内容 = 32bpp 预乘 BGRA 位图（UpdateLayeredWindow + DWM 合成）。
/// 无背景保存/恢复 → 无闪烁无残留；窗口销毁即彻底消失。
/// 尺寸采用"容量"策略：内容放得下就复用窗口（位置移动经 ULW/SetWindowPos 完成），
/// 放不下才销毁重建——避免拖拽中包围盒逐帧变化导致的重建闪烁与开销。
class _LayeredWindow {
  static bool _classRegistered = false;
  static const _className = 'BPC_MARKER_WND';

  int _hwnd = 0;
  int _memDC = 0;
  int _bitmap = 0;
  int _oldBmp = 0; // DIB 选入 DC 前的默认位图；销毁前先恢复旧选再删位图（GDI 规范：选入中对象的删除行为未在文档承诺）
  Pointer<Uint8> _bits = nullptr;
  int _w = 0, _h = 0;

  bool get isValid => _hwnd != 0;
  int get width => _w;
  int get height => _h;

  /// 现有窗口能否容纳 needW×needH 的内容（位置变化无需重建）
  bool fits(int needW, int needH) => isValid && _w >= needW && _h >= needH;

  void create(int x, int y, int w, int h) {
    destroy();
    if (!_classRegistered) {
      _classRegistered = u32.registerMarkerWindowClass(_className);
      if (!_classRegistered) return;
    }
    final exStyle = u32.wsExLayered |
        u32.wsExTransparent |
        u32.wsExToolwindow |
        u32.wsExTopmost |
        u32.wsExNoactivate;
    _hwnd = u32.createLayeredWindow(
      className: _className,
      exStyle: exStyle,
      x: x,
      y: y,
      w: w,
      h: h,
    );
    if (_hwnd == 0) return;
    _memDC = gdi.createCompatibleDC(0);
    final (bmp, bits) = gdi.createDIBSection(_memDC, w, h);
    if (bmp == 0) {
      destroy(); // DIB 创建失败（极端坐标导致超大窗口等）：回收半初始化资源
      return;
    }
    _bitmap = bmp;
    _bits = bits;
    _oldBmp = gdi.selectObject(_memDC, _bitmap);
    _w = w;
    _h = h;
  }

  /// 直通 RGBA 像素预乘转 BGRA 写入 DIB 并上屏（同时把窗口移到 (x, y)）。
  /// [rgba] 长度须为 w*h*4；返回是否成功。
  bool updateFromRgba(Uint8List rgba, int x, int y) {
    if (!isValid) return false;
    final n = _w * _h * 4;
    if (rgba.length != n) return false;
    premultiplyRgbaToBgra(rgba, _bits.asTypedList(n));
    return _present(x, y);
  }

  /// 仅移动窗口，内容不变（单点拖拽快路径用，零渲染）
  bool moveTo(int x, int y) {
    if (!isValid) return false;
    return u32.moveWindowPos(_hwnd, x, y);
  }

  /// UpdateLayeredWindow 上屏：DIB 内容 → 窗口层，pptDst 同时更新位置
  bool _present(int x, int y) {
    final pptDst = calloc<Int32>(2);
    final psize = calloc<Int32>(2);
    final pptSrc = calloc<Int32>(2);
    final pblend = calloc<Uint8>(4); // BLENDFUNCTION{AC_SRC_OVER,0,255,AC_SRC_ALPHA}
    try {
      pptDst[0] = x;
      pptDst[1] = y;
      psize[0] = _w;
      psize[1] = _h;
      pptSrc[0] = 0;
      pptSrc[1] = 0;
      pblend[0] = u32.acSrcOver;
      pblend[1] = 0;
      pblend[2] = 255;
      pblend[3] = u32.acSrcAlpha;
      final ok = u32.updateLayeredWindowContent(
        _hwnd,
        0, // hdcDst：ULW 不需要屏幕 DC
        pptDst,
        psize,
        _memDC,
        pptSrc,
        0, // crKey
        pblend,
        u32.ulwAlpha,
      );
      if (!ok) {
        debugPrint('ScreenMarker: UpdateLayeredWindow 失败（$_w×$_h @($x,$y)）');
        return false;
      }
      u32.showWindowNa(_hwnd);
      return true;
    } finally {
      calloc.free(pptDst);
      calloc.free(psize);
      calloc.free(pptSrc);
      calloc.free(pblend);
    }
  }

  void destroy() {
    if (_oldBmp != 0 && _memDC != 0) {
      gdi.selectObject(_memDC, _oldBmp); // 先恢复默认位图再删位图（GDI 规范模式）
      _oldBmp = 0;
    }
    if (_bitmap != 0) {
      gdi.deleteObject(_bitmap);
      _bitmap = 0;
    }
    if (_memDC != 0) {
      gdi.deleteDC(_memDC);
      _memDC = 0;
    }
    if (_hwnd != 0) {
      u32.destroyLayeredWindow(_hwnd);
      _hwnd = 0;
    }
    _bits = nullptr;
    _w = 0;
    _h = 0;
  }
}

/// 屏幕置顶标记服务：分层透明小窗口绘制"圆形+白色加号"定位图标
/// （"+"中心精确对准坐标点，只显示图标不显示坐标文字），支持鼠标直接拖拽图标修改坐标。
/// 图标由 Flutter 离屏渲染（PictureRecorder → toImage，随 DPI 缩放、抗锯齿、逐像素透明）。
/// 拖拽由 WH_MOUSE_LL 钩子实现（窗口本身点击穿透，不干扰其他应用操作）；
/// 单点拖拽走"仅移动窗口"快路径（内容不变零渲染），多点拖拽按需重渲染。
class ScreenMarkerService {
  static const _radiusLogic = 13.0; // 图标半径（逻辑像素，随 DPI 放大渲染）
  static const _hitRadiusLogic = 20.0; // 拖拽命中半径（逻辑像素）
  static const _shadowMarginLogic = 12.0; // 阴影余量（逻辑像素；drawShadow elevation=4 模糊约 10-12）
  static const _quantum = 64; // 窗口容量量化粒度（物理像素）：拖拽中重建仅在跨粒度时发生
  static const _colorWhite = 0xFFFFFFFF;
  static const _colorLine = 0xFF8A94B8;

  List<MarkerPoint> _points = [];
  void Function(int index, int x, int y)? _onDragEnd;
  Timer? _timer;
  int _renderSeq = 0; // 渲染版本号：hide/重渲染后丢弃过期异步结果
  final _LayeredWindow _window = _LayeredWindow();

  bool _needsRender = true; // 内容脏标志：静止跳过与单点快路径的前提
  (int, int)? _cursorApplied; // 拖拽点上次已应用到屏幕的位置
  bool _fastReady = false; // 单点内容是否以"未 clamp 紧原点"渲染（图标局部偏移恒为 margin）

  NativeCallable<u32.HookProcC>? _proc;
  int _hookHandle = 0;
  final Set<int> _swallowUp = {};

  // 拖拽状态
  int _dragIndex = -1;
  int _dragOrigX = 0, _dragOrigY = 0;
  (int, int)? _lastCursor;
  (int, int, int)? _pendingDragEnd;

  bool get isActive => _points.isNotEmpty;

  double get _dpr =>
      ui.PlatformDispatcher.instance.views.first.devicePixelRatio;

  int _marginPx() => ((_radiusLogic + _shadowMarginLogic) * _dpr).round();

  /// 显示一组可拖拽图标；恰好 2 个点时自动画连线（滑动起终点）
  void show(
    List<MarkerPoint> points, {
    required void Function(int index, int x, int y) onDragEnd,
  }) {
    hide();
    _points = List.of(points);
    _onDragEnd = onDragEnd;
    _installHook();
    _timer = Timer.periodic(
      const Duration(milliseconds: 33),
      (_) => _onTick(),
    );
    _renderGuarded();
  }

  /// 渲染 + 上屏；异常不再静默（debugPrint 到控制台便于排查）
  void _renderGuarded() {
    _render().catchError((e, st) {
      debugPrint('ScreenMarker render failed: $e\n$st');
    });
  }

  /// 编辑面板中坐标参数变化时同步图标位置（拖拽中的点以拖拽为准）
  void updatePoints(List<MarkerPoint> points) {
    if (!isActive) return;
    _points = List.of(points);
    final cur = _lastCursor;
    if (_dragIndex >= 0 && cur != null) {
      _points[_dragIndex] = _copy(_points[_dragIndex], cur.$1, cur.$2);
    }
    _needsRender = true;
    _fastReady = false;
    _renderGuarded();
  }

  /// 隐藏图标：销毁分层窗口（窗口即内容，销毁即彻底消失，无任何屏幕恢复动作）
  void hide() {
    _timer?.cancel();
    _timer = null;
    _renderSeq++;
    _window.destroy();
    _dragIndex = -1;
    _pendingDragEnd = null;
    _lastCursor = null;
    _swallowUp.clear();
    _needsRender = true;
    _cursorApplied = null;
    _fastReady = false;
    if (_hookHandle != 0) {
      u32.uninstallMouseHook(_hookHandle);
      _hookHandle = 0;
    }
    _proc?.close();
    _proc = null;
    _points = [];
    _onDragEnd = null;
  }

  MarkerPoint _copy(MarkerPoint p, int x, int y) =>
      MarkerPoint(x, y, p.color);

  // ---- 轮询驱动：拖拽位置更新 / Esc 取消 / 完成回调 ----

  void _onTick() {
    // Esc 取消拖拽：恢复拖拽起点的原坐标
    if (_dragIndex >= 0 && u32.isKeyDown(u32.vkEscape)) {
      final i = _dragIndex;
      _points[i] = _copy(_points[i], _dragOrigX, _dragOrigY);
      _dragIndex = -1;
      _needsRender = true;
      _cursorApplied = null;
      _renderGuarded();
    }
    // 完成拖拽：钩子 up 事件记录的结果在此回调（保证在 Timer 上下文执行）
    final pending = _pendingDragEnd;
    if (pending != null) {
      _pendingDragEnd = null;
      _dragIndex = -1;
      _cursorApplied = null;
      _onDragEnd?.call(pending.$1, pending.$2, pending.$3);
    } else if (_dragIndex >= 0) {
      final cur = _lastCursor;
      if (cur != null) {
        // 静止跳过：内容干净且拖拽点位置未变 → 无事可做（不再每秒重渲染 30 帧）
        if (!_needsRender && cur == _cursorApplied) return;
        _points[_dragIndex] = _copy(_points[_dragIndex], cur.$1, cur.$2);
        if (_tryFastMove()) return; // 单点快路径：仅移动窗口，零渲染
        _renderGuarded();
      }
    }
  }

  /// 单点拖拽快路径：图标位图内容不变（颜色/形状/DPR 恒定），仅窗口位置在动，
  /// 直接 SetWindowPos 移动窗口即可，省去整帧离屏渲染与像素回读。
  /// 前提：内容上次以未 clamp 的紧原点渲染（图标在窗口内偏移恒为 margin），
  /// 且目标位置同样无需 clamp；命中屏幕边缘则退回全渲染路径。
  bool _tryFastMove() {
    if (_points.length != 1 || _needsRender || !_fastReady) return false;
    final p = _points[0];
    final margin = _marginPx();
    final x = p.x - margin;
    final y = p.y - margin;
    final (vx, vy, vw, vh) = _virtualRect();
    if (x < vx ||
        y < vy ||
        x + _window.width > vx + vw ||
        y + _window.height > vy + vh) {
      return false; // 需 clamp → 窗口内局部偏移要重算 → 全渲染
    }
    if (!_window.fits(2 * margin, 2 * margin)) return false;
    if (!_window.moveTo(x, y)) return false;
    _cursorApplied = (p.x, p.y);
    return true;
  }

  /// 虚拟桌面范围（多屏并集；副屏在主屏左侧/上方时为负原点）
  static (int, int, int, int) _virtualRect() {
    final (vx, vy, vw, vh) = u32.virtualScreenRect();
    if (vw <= 0 || vh <= 0) return (0, 0, u32.screenW(), u32.screenH());
    return (vx, vy, vw, vh);
  }

  // ---- Flutter 离屏渲染 → 分层窗口 ----

  Future<void> _render() async {
    if (_points.isEmpty) return;
    final seq = ++_renderSeq;
    final dpr = _dpr;
    final radius = _radiusLogic * dpr;
    final margin = _marginPx(); // 阴影/描边余量（物理像素）

    final (left, top, right, bottom) = tightMarkerBox(_points, margin);
    // clamp 基准用虚拟桌面而非主屏：负坐标（副屏）图标不再被拽回主屏
    final (vx, vy, vw, vh) = _virtualRect();

    // 容量窗口：现有窗口放得下就复用（位置随后由 ULW 移动），
    // 放不下才按 64px 粒度量化重建——拖 swipe 图标时包围盒逐 tick 变化也不再逐帧销毁重建
    if (!_window.fits(right - left, bottom - top)) {
      _fastReady = false;
      final w = (right - left + _quantum - 1) & ~(_quantum - 1);
      final h = (bottom - top + _quantum - 1) & ~(_quantum - 1);
      final (cx, cy) = clampWindowPos(
        left,
        top,
        w,
        h,
        vw,
        vh,
        originX: vx,
        originY: vy,
      );
      _window.create(cx, cy, w, h);
      if (!_window.isValid) return;
    }
    final winW = _window.width;
    final winH = _window.height;
    final (winX, winY) = clampWindowPos(
      left,
      top,
      winW,
      winH,
      vw,
      vh,
      originX: vx,
      originY: vy,
    );

    // 绘制（画布 = 窗口区域，坐标 = 物理像素 - 窗口原点）
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    ui.Offset local(MarkerPoint p) =>
        ui.Offset((p.x - winX).toDouble(), (p.y - winY).toDouble());

    // 连线（滑动起终点；两点间灰白线 + 终点方向箭头）
    if (_points.length == 2) {
      final a = local(_points[0]);
      final b = local(_points[1]);
      canvas.drawLine(a, b, ui.Paint()
        ..color = const ui.Color(0x66000000)
        ..strokeWidth = 5 * dpr
        ..strokeCap = ui.StrokeCap.round
        ..isAntiAlias = true);
      canvas.drawLine(a, b, ui.Paint()
        ..color = const ui.Color(_colorLine)
        ..strokeWidth = 2.5 * dpr
        ..strokeCap = ui.StrokeCap.round
        ..isAntiAlias = true);
      // 方向箭头：终点图标外侧指向滑动方向（距离足够时绘制）
      final delta = b - a;
      final dist = delta.distance;
      if (dist > 4 * radius) {
        final dir = delta / dist;
        final perp = ui.Offset(-dir.dy, dir.dx);
        final tip = b - dir * (radius + 6 * dpr); // 箭头顶点
        final back = tip - dir * (11 * dpr); // 箭头底部中心
        final w1 = back + perp * (7 * dpr);
        final w2 = back - perp * (7 * dpr);
        final arrow = ui.Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(w1.dx, w1.dy)
          ..lineTo(w2.dx, w2.dy)
          ..close();
        canvas.drawPath(arrow, ui.Paint()
          ..color = const ui.Color(0x66000000)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 5 * dpr
          ..isAntiAlias = true);
        canvas.drawPath(arrow, ui.Paint()
          ..color = const ui.Color(_colorLine)
          ..isAntiAlias = true);
      }
    }

    for (final p in _points) {
      final c = local(p);
      // 阴影（浮起感）
      final shadowPath = ui.Path()
        ..addOval(ui.Rect.fromCircle(
          center: c + ui.Offset(0, 2 * dpr),
          radius: radius,
        ));
      canvas.drawShadow(shadowPath, const ui.Color(0xFF000000), 4, false);
      // 主体圆（类型色填充）
      canvas.drawCircle(c, radius, ui.Paint()
        ..color = ui.Color(p.color)
        ..isAntiAlias = true);
      // 白描边
      canvas.drawCircle(c, radius, ui.Paint()
        ..color = const ui.Color(_colorWhite)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 2 * dpr
        ..isAntiAlias = true);
      // 白色加号（"+"中心 = 坐标点）
      final half = radius * 0.55;
      final plus = ui.Paint()
        ..color = const ui.Color(_colorWhite)
        ..strokeWidth = 2.5 * dpr
        ..strokeCap = ui.StrokeCap.round
        ..isAntiAlias = true;
      canvas.drawLine(c - ui.Offset(half, 0), c + ui.Offset(half, 0), plus);
      canvas.drawLine(c - ui.Offset(0, half), c + ui.Offset(0, half), plus);
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(winW, winH);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    picture.dispose();
    image.dispose();
    if (seq != _renderSeq) return; // 过期渲染（已 hide/重新渲染）
    if (data == null) return;

    // 直通 RGBA → 预乘 BGRA 直写 DIB（LUT，免每帧双份全尺寸缓冲）→ ULW 上屏
    final ok = _window.updateFromRgba(data.buffer.asUint8List(), winX, winY);
    if (!ok) return;
    _needsRender = false;
    final di = _dragIndex;
    if (di >= 0) {
      _cursorApplied = (_points[di].x, _points[di].y);
    }
    // 单点且本次未 clamp → 图标局部偏移恒为 margin，后续拖拽可走快路径
    _fastReady = _points.length == 1 && winX == left && winY == top;
  }

  // ---- 鼠标钩子：命中图标则开始拖拽（其余事件放行） ----

  void _installHook() {
    final proc = _proc = NativeCallable<u32.HookProcC>.isolateLocal(
      (int nCode, int wParam, int lParam) {
        if (nCode >= 0 && isActive) {
          switch (wParam) {
            case u32.wmLbuttondown:
              final info = Pointer<u32.MSLLHOOKSTRUCT>.fromAddress(lParam).ref;
              // 注入事件（试运行/回放/自动化）不参与拖拽，直接放行——
              // 否则回放注入到标记坐标的点击会被本钩子吞掉
              if (info.flags & u32.llkhfInjected != 0) {
                return u32.callNextHook(nCode, wParam, lParam);
              }
              final hit = _hitTest(info.pt.x, info.pt.y);
              if (hit >= 0) {
                _dragIndex = hit;
                _dragOrigX = _points[hit].x;
                _dragOrigY = _points[hit].y;
                _cursorApplied = null; // 新拖拽从零开始跟踪
                _swallowUp.add(u32.wmLbuttonup); // 吞 down 必须吞 up
                return 1; // 吞掉，目标窗口收不到
              }
            case u32.wmLbuttonup:
              if (_swallowUp.remove(u32.wmLbuttonup)) {
                final info =
                    Pointer<u32.MSLLHOOKSTRUCT>.fromAddress(lParam).ref;
                if (_dragIndex >= 0) {
                  _pendingDragEnd = (_dragIndex, info.pt.x, info.pt.y);
                }
                return 1;
              }
            case u32.wmMousemove:
              final info =
                  Pointer<u32.MSLLHOOKSTRUCT>.fromAddress(lParam).ref;
              if (info.flags & u32.llkhfInjected != 0) {
                return u32.callNextHook(nCode, wParam, lParam); // 注入移动不跟踪
              }
              _lastCursor = (info.pt.x, info.pt.y);
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
      return;
    }
    _hookHandle = handle;
  }

  int _hitTest(int x, int y) =>
      markerHitTest(_points, x, y, (_hitRadiusLogic * _dpr).round());
}

/// 屏幕绿色边框服务：分层置顶穿透窗口绘制绿色矩形描边。
/// 用途：坐标拾取时提示虚拟桌面范围；区域框选时实时预览当前拖拽矩形。
/// 渲染复用 _LayeredWindow（容量策略：窗口按 256px 粒度增长优先复用，
/// 拖拽中矩形增长不再频繁销毁重建）。
class ScreenBorderService {
  static const _strokePx = 5; // 描边宽度（物理像素）
  static const _green = 0xFF4CC79A; // AppColors.success
  static const _quantum = 256; // 窗口容量量化粒度（物理像素）

  final _LayeredWindow _window = _LayeredWindow();
  int _renderSeq = 0;
  Future<bool>? _lastRender;

  /// 画布尺寸（含描边溢出，向上量化到 [_quantum]）。
  /// 必须与分层窗口容量保持一致：`updateFromRgba` 要求像素长度 == 窗口宽×高×4。
  @visibleForTesting
  static (int, int) canvasSize(int w, int h) => (
        (w + 2 * _strokePx + _quantum - 1) & ~(_quantum - 1),
        (h + 2 * _strokePx + _quantum - 1) & ~(_quantum - 1),
      );

  /// 最近一次渲染是否成功（测试用）
  @visibleForTesting
  Future<bool> get debugLastRender => _lastRender ?? Future.value(false);

  @visibleForTesting
  int get debugWindowWidth => _window.width;

  @visibleForTesting
  int get debugWindowHeight => _window.height;

  /// 在矩形 (x,y,w,h) 边缘绘制绿色描边；矩形 = 整个虚拟桌面时即"屏幕边缘提示"。
  /// 窗口覆盖矩形外扩一个描边宽度（描边中心对齐矩形边缘）。
  void showRect(int x, int y, int w, int h) {
    if (w <= 0 || h <= 0) return;
    final s = _strokePx;
    final (cw, ch) = canvasSize(w, h);
    // 容量必须与渲染画布严格一致（不能用"能装下就复用"：
    // 1) 尺寸不一致时 updateFromRgba 会因像素数不符直接失败；
    // 2) 全屏提示窗口被拖拽预览复用会每帧渲染整屏，开销过大）
    if (!_window.isValid || _window.width != cw || _window.height != ch) {
      _window.create(x - s, y - s, cw, ch);
      if (!_window.isValid) return;
    }
    _lastRender = _render(x - s, y - s, cw, ch, w, h);
  }

  /// 隐藏边框：销毁分层窗口（窗口即内容，销毁即彻底消失）
  void hide() {
    _renderSeq++;
    _window.destroy();
  }

  /// 离屏渲染绿色描边并上屏；[canvasW]/[canvasH] 为窗口容量，
  /// [rectW]/[rectH] 为需要描边的矩形尺寸（在画布内偏移一个描边宽）。
  Future<bool> _render(
    int winX,
    int winY,
    int canvasW,
    int canvasH,
    int rectW,
    int rectH,
  ) async {
    final seq = ++_renderSeq;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final s = _strokePx.toDouble();
    // 描边中心对齐矩形边缘：矩形在画布内偏移一个描边宽
    canvas.drawRect(
      ui.Rect.fromLTWH(s, s, rectW.toDouble(), rectH.toDouble()),
      ui.Paint()
        ..color = const ui.Color(_green)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = s
        ..isAntiAlias = true,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(canvasW, canvasH);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    picture.dispose();
    image.dispose();
    if (seq != _renderSeq || data == null) return false; // 过期渲染（已 hide/重绘）
    return _window.updateFromRgba(data.buffer.asUint8List(), winX, winY);
  }
}
