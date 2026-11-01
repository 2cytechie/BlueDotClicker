import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../platform/platform_automation.dart';
import 'user32.dart' as u32;

/// Win32 gdi32.dll FFI 绑定：屏幕区域截屏（BitBlt + GetDIBits）
final DynamicLibrary _gdi32 = DynamicLibrary.open('gdi32.dll');

const int srccopy = 0x00CC0020;
const int captureblt = 0x40000000;
const int biRgb = 0;

final class _BITMAPINFOHEADER extends Struct {
  @Uint32() external int biSize;
  @Long() external int biWidth;
  @Long() external int biHeight;
  @Uint16() external int biPlanes;
  @Uint16() external int biBitCount;
  @Uint32() external int biCompression;
  @Uint32() external int biSizeImage;
  @Long() external int biXPelsPerMeter;
  @Long() external int biYPelsPerMeter;
  @Uint32() external int biClrUsed;
  @Uint32() external int biClrImportant;
}

final class _BITMAPINFO extends Struct {
  external _BITMAPINFOHEADER bmiHeader;
  @Uint32() external int bmiColors;
}

final _getDC = u32.user32Lib.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GetDC');
final _releaseDC =
    u32.user32Lib.lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>('ReleaseDC');
final _createCompatibleDC = _gdi32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('CreateCompatibleDC');
final _deleteDC = _gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC');
final _createCompatibleBitmap =
    _gdi32.lookupFunction<IntPtr Function(IntPtr, Int32, Int32), int Function(int, int, int)>(
        'CreateCompatibleBitmap');
final _deleteObject = _gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteObject');
final _selectObject =
    _gdi32.lookupFunction<IntPtr Function(IntPtr, IntPtr), int Function(int, int)>('SelectObject');
final _bitBlt = _gdi32.lookupFunction<
    Int32 Function(IntPtr, Int32, Int32, Int32, Int32, IntPtr, Int32, Int32, Uint32),
    int Function(int, int, int, int, int, int, int, int, int)>('BitBlt');
final _getDIBits = _gdi32.lookupFunction<
    Int32 Function(IntPtr, IntPtr, Uint32, Uint32, Pointer<Uint8>, Pointer<_BITMAPINFO>, Uint32),
    int Function(int, int, int, int, Pointer<Uint8>, Pointer<_BITMAPINFO>, int)>('GetDIBits');

// ---- 屏幕标记分层窗口用：32bpp DIB（UpdateLayeredWindow 的内容位图）----

final _createDIBSection = _gdi32.lookupFunction<
    IntPtr Function(IntPtr, Pointer<_BITMAPINFO>, Uint32,
        Pointer<Pointer<Uint8>>, IntPtr, Uint32),
    int Function(int, Pointer<_BITMAPINFO>, int, Pointer<Pointer<Uint8>>,
        int, int)>('CreateDIBSection');

/// 公开的 DC 原语（分层窗口创建 DIB 用；captureScreen 走私有绑定不受影响）
int createCompatibleDC(int hdc) => _createCompatibleDC(hdc);
void deleteDC(int hdc) => _deleteDC(hdc);

/// 删除 GDI 对象；返回是否成功。
/// 规范要求：仍选入 DC 的对象须先 SelectObject 恢复旧选再删除
/// （Win11 对选入中的位图做延迟销毁，但该行为未在文档承诺，勿依赖）。
bool deleteObject(int obj) => _deleteObject(obj) != 0;

int selectObject(int hdc, int obj) => _selectObject(hdc, obj);

/// 创建 32bpp 自顶向下 DIB；返回 (hbitmap, 像素内存指针)。
/// 调用方负责 DeleteObject(hbitmap)；像素内存随位图释放，用完前不得先删。
(int, Pointer<Uint8>) createDIBSection(int hdc, int w, int h) {
  final bmi = calloc<_BITMAPINFO>();
  final hd = bmi.ref.bmiHeader;
  hd.biSize = sizeOf<_BITMAPINFOHEADER>();
  hd.biWidth = w;
  hd.biHeight = -h; // 负值 = 自顶向下
  hd.biPlanes = 1;
  hd.biBitCount = 32;
  hd.biCompression = biRgb;
  final ppv = calloc<Pointer<Uint8>>();
  final hbm = _createDIBSection(hdc, bmi, 0 /*DIB_RGB_COLORS*/, ppv, nullptr.address, 0);
  final bits = ppv.value;
  calloc.free(ppv);
  calloc.free(bmi);
  return (hbm, bits);
}

/// 截取屏幕指定区域（物理像素），返回 BGRA 自顶向下像素。
/// [region] 为空时截取全屏。
ScreenCapture captureScreen({RectPx? region}) {
  final sw = u32.screenW();
  final sh = u32.screenH();
  final x = region?.x ?? 0;
  final y = region?.y ?? 0;
  final w = region?.w ?? sw;
  final h = region?.h ?? sh;
  final cw = w.clamp(1, sw - x);
  final ch = h.clamp(1, sh - y);

  final hdcScreen = _getDC(0);
  final hdcMem = _createCompatibleDC(hdcScreen);
  final hbm = _createCompatibleBitmap(hdcScreen, cw, ch);
  final old = _selectObject(hdcMem, hbm);
  _bitBlt(hdcMem, 0, 0, cw, ch, hdcScreen, x, y, srccopy | captureblt);

  final bmi = calloc<_BITMAPINFO>();
  final header = bmi.ref.bmiHeader;
  header.biSize = sizeOf<_BITMAPINFOHEADER>();
  header.biWidth = cw;
  header.biHeight = -ch; // 负值 = 自顶向下
  header.biPlanes = 1;
  header.biBitCount = 32;
  header.biCompression = biRgb;

  final buf = calloc<Uint8>(cw * ch * 4);
  _getDIBits(hdcMem, hbm, 0, ch, buf, bmi, 0); // 0 = DIB_RGB_COLORS

  final bytes = Uint8List.fromList(buf.asTypedList(cw * ch * 4));

  calloc.free(buf);
  calloc.free(bmi);
  _selectObject(hdcMem, old);
  _deleteObject(hbm);
  _deleteDC(hdcMem);
  _releaseDC(0, hdcScreen);

  return ScreenCapture(cw, ch, bytes);
}
