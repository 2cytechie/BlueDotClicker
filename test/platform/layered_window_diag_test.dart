import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bluedot_clicker/platform/win32/gdi32.dart' as gdi;
import 'package:bluedot_clicker/platform/win32/user32.dart' as u32;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('分层窗口链路诊断：注册类 → 创建 → DIB → UpdateLayeredWindow', () {
    final className = 'BPC_DIAG_WND_${DateTime.now().millisecondsSinceEpoch}';
    final registered = u32.registerMarkerWindowClass(className);
    // 若已注册过同名类也算成功（ERROR_CLASS_ALREADY_EXISTS → atom==0）
    expect(registered, isTrue, reason: 'RegisterClassExW 失败，结构布局可能有误');

    final exStyle = u32.wsExLayered |
        u32.wsExTransparent |
        u32.wsExToolwindow |
        u32.wsExTopmost |
        u32.wsExNoactivate;
    final hwnd = u32.createLayeredWindow(
      className: className,
      exStyle: exStyle,
      x: 50,
      y: 50,
      w: 64,
      h: 64,
    );
    expect(hwnd, isNonZero, reason: 'CreateWindowExW 失败');

    final memDC = gdi.createCompatibleDC(0);
    final (bmp, bits) = gdi.createDIBSection(memDC, 64, 64);
    expect(bmp, isNonZero, reason: 'CreateDIBSection 失败');
    final old = gdi.selectObject(memDC, bmp);
    expect(old, isNonZero, reason: 'SelectObject 失败');

    // 填充：中央 32x32 不透明红色方块（预乘 BGRA）
    final px = bits.asTypedList(64 * 64 * 4);
    for (var y = 16; y < 48; y++) {
      for (var x = 16; x < 48; x++) {
        final i = (y * 64 + x) * 4;
        px[i] = 0; // B
        px[i + 1] = 0; // G
        px[i + 2] = 255; // R
        px[i + 3] = 255; // A
      }
    }

    final pptDst = calloc<Int32>(2);
    final psize = calloc<Int32>(2);
    final pptSrc = calloc<Int32>(2);
    final pblend = calloc<Uint8>(4);
    try {
      pptDst[0] = 50;
      pptDst[1] = 50;
      psize[0] = 64;
      psize[1] = 64;
      pptSrc[0] = 0;
      pptSrc[1] = 0;
      pblend[0] = u32.acSrcOver;
      pblend[1] = 0;
      pblend[2] = 255;
      pblend[3] = u32.acSrcAlpha;
      final ok = u32.updateLayeredWindowContent(
        hwnd,
        0,
        pptDst,
        psize,
        memDC,
        pptSrc,
        0,
        pblend,
        u32.ulwAlpha,
      );
      expect(ok, isTrue, reason: 'UpdateLayeredWindow 失败（返回 0）');

      // 窗口可见性检查（IsWindowVisible）
      // 不 ShowWindow，跳过可见性，仅验证 ULW 成功即可
    } finally {
      calloc.free(pptDst);
      calloc.free(psize);
      calloc.free(pptSrc);
      calloc.free(pblend);
      // 先恢复默认位图再删除（选入 DC 中的位图不可删除，否则泄漏）
      gdi.selectObject(memDC, old);
      expect(gdi.deleteObject(bmp), isTrue, reason: '清理：位图删除失败');
      gdi.deleteDC(memDC);
      expect(u32.destroyLayeredWindow(hwnd), isTrue);
      u32.unregisterMarkerWindowClass(className);
    }
  });

  test('GDI 清理模式：恢复旧选后位图可删除（destroy 的安全顺序）', () {
    final memDC = gdi.createCompatibleDC(0);
    final (bmp, _) = gdi.createDIBSection(memDC, 8, 8);
    expect(bmp, isNonZero, reason: 'CreateDIBSection 失败');
    final old = gdi.selectObject(memDC, bmp);
    expect(old, isNonZero, reason: 'SelectObject 失败');

    // Win11 实测：选入 DC 的位图 DeleteObject 亦返回 true——GDI 对选入中的
    // 位图做延迟销毁（待 DC 释放选择后才真正回收），原代码因此未实际泄漏；
    // 但该行为未在文档中承诺、跨版本不保证，生产代码须按 GDI 规范
    // "先恢复旧选、再删对象"。此处固化规范模式：
    gdi.selectObject(memDC, old);
    expect(gdi.deleteObject(bmp), isTrue, reason: '恢复旧选后位图应可删除');
    gdi.deleteDC(memDC);
  });

  test('分层窗口样式位与销毁验证', () {
    final className = 'BPC_DIAG2_WND_${DateTime.now().millisecondsSinceEpoch}';
    expect(u32.registerMarkerWindowClass(className), isTrue);

    final exStyle = u32.wsExLayered |
        u32.wsExTransparent |
        u32.wsExToolwindow |
        u32.wsExTopmost |
        u32.wsExNoactivate;
    final hwnd = u32.createLayeredWindow(
      className: className,
      exStyle: exStyle,
      x: 10,
      y: 10,
      w: 32,
      h: 32,
    );
    expect(hwnd, isNonZero, reason: 'CreateWindowExW 失败');

    // 扩展样式位逐项校验（透明穿透/置顶/工具窗/不抢焦点必须真实生效）
    final style = u32.getWindowLongPtr(hwnd, u32.gwlExStyle);
    expect(style & u32.wsExLayered, u32.wsExLayered,
        reason: '缺少 WS_EX_LAYERED（无逐像素透明）');
    expect(style & u32.wsExTransparent, u32.wsExTransparent,
        reason: '缺少 WS_EX_TRANSPARENT（无点击穿透）');
    expect(style & u32.wsExTopmost, u32.wsExTopmost, reason: '缺少 WS_EX_TOPMOST');
    expect(style & u32.wsExToolwindow, u32.wsExToolwindow,
        reason: '缺少 WS_EX_TOOLWINDOW');
    expect(style & u32.wsExNoactivate, u32.wsExNoactivate,
        reason: '缺少 WS_EX_NOACTIVATE');

    // ULW 上屏 → 仅改位置（pptDst）的二次 ULW 也应成功
    final memDC = gdi.createCompatibleDC(0);
    final (bmp, bits) = gdi.createDIBSection(memDC, 32, 32);
    final old = gdi.selectObject(memDC, bmp);
    final px = bits.asTypedList(32 * 32 * 4);
    for (var i = 0; i < px.length; i += 4) {
      px[i] = 255; // B
      px[i + 3] = 255; // A
    }

    final pptDst = calloc<Int32>(2);
    final psize = calloc<Int32>(2);
    final pptSrc = calloc<Int32>(2);
    final pblend = calloc<Uint8>(4);
    try {
      psize[0] = 32;
      psize[1] = 32;
      pptSrc[0] = 0;
      pptSrc[1] = 0;
      pblend[0] = u32.acSrcOver;
      pblend[1] = 0;
      pblend[2] = 255;
      pblend[3] = u32.acSrcAlpha;

      pptDst[0] = 10;
      pptDst[1] = 10;
      expect(
        u32.updateLayeredWindowContent(
            hwnd, 0, pptDst, psize, memDC, pptSrc, 0, pblend, u32.ulwAlpha),
        isTrue,
        reason: '首次 ULW 失败',
      );

      pptDst[0] = 40; // 仅移动窗口位置
      pptDst[1] = 40;
      expect(
        u32.updateLayeredWindowContent(
            hwnd, 0, pptDst, psize, memDC, pptSrc, 0, pblend, u32.ulwAlpha),
        isTrue,
        reason: '仅改 pptDst 的移动式 ULW 失败',
      );

      // 销毁验证：DestroyWindow 后窗口彻底消失（无残留的底层保证）
      expect(u32.destroyLayeredWindow(hwnd), isTrue);
      expect(u32.isWindow(hwnd), isFalse, reason: '销毁后 IsWindow 应为 false');
    } finally {
      calloc.free(pptDst);
      calloc.free(psize);
      calloc.free(pptSrc);
      calloc.free(pblend);
      gdi.selectObject(memDC, old);
      gdi.deleteObject(bmp);
      gdi.deleteDC(memDC);
      u32.unregisterMarkerWindowClass(className);
    }
  });
}
