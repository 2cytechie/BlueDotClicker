import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';
import 'package:winrt_ocr_flutter/winrt_ocr_flutter.dart';

import 'opencv_matcher.dart';
import 'recognition.dart';
import 'template_match_dart.dart';

/// Windows 识别服务：OCR 用 Windows.Media.Ocr（winrt_ocr_flutter），
/// 模板匹配优先 OpenCV（opencv_dart，TM_CCOEFF_NORMED），
/// OpenCV 原生库不可用时自动回退纯 Dart 金字塔 NCC。
class WindowsRecognitionService implements RecognitionService {
  WindowsRecognitionService();

  /// OCR 位图相对输入图像的放大倍数（当前不做放大，词框直接为原图像素）。
  static const double ocrScaleFactor = 1.0;

  final DartTemplateMatcher _dartMatcher = const DartTemplateMatcher();
  final OpenCvMatcher _cvMatcher = const OpenCvMatcher();
  bool? _opencvAvailable;

  @override
  bool get isAvailable => Platform.isWindows;

  // ---- OCR ----

  @override
  Future<OcrResult> recognizeText(RawImage image, {int? regionX, int? regionY, int? regionW, int? regionH}) async {
    var img = image;
    var ox = regionX ?? 0;
    var oy = regionY ?? 0;
    if (regionW != null && regionH != null && (regionW < image.width || regionH < image.height)) {
      img = _crop(image, regionX ?? 0, regionY ?? 0, regionW, regionH);
      ox = 0;
      oy = 0;
    }
    final png = await _encodePng(img);
    final dir = await getTemporaryDirectory();
    // 必须用 Platform.pathSeparator 拼接：WinRT 的 GetFileFromPathAsync
    // 不接受混合分隔符路径（如 "C:\Temp/x.png"），会抛 0x80070002
    // 「系统找不到指定的文件」；而 Win32 写入端会自动规范化，导致
    // 写入成功但原生读取失败的隐蔽错误。
    final file = File(
        '${dir.path}${Platform.pathSeparator}bpc_ocr_${DateTime.now().microsecondsSinceEpoch}.png');
    await file.writeAsBytes(png);
    try {
      final boxes = await WinrtOcr.recognizeWithBoxes(file.path);
      // 原生词框基于传入位图像素；若将来对图像做放大，需除以放大倍数还原。
      final words = [
        for (final w in boxes.words)
          OcrWordBox(
            w.text,
            (w.x / ocrScaleFactor).round(),
            (w.y / ocrScaleFactor).round(),
            (w.w / ocrScaleFactor).round(),
            (w.h / ocrScaleFactor).round(),
          ),
      ];
      return OcrResult(boxes.text.trim(), x: ox, y: oy, words: words);
    } on WinrtOcrException {
      // 无 OCR 语言包等引擎级失败：按「未识别到文本」处理，不中断脚本
      return OcrResult('', x: ox, y: oy);
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  // ---- 模板匹配 ----

  @override
  Future<MatchResult> matchTemplate(RawImage image, RawImage template, {double threshold = 0.8}) async {
    if (_opencvAvailable ?? true) {
      try {
        final r = _cvMatcher.match(image, template, threshold: threshold);
        _opencvAvailable = true;
        return r;
      } catch (_) {
        _opencvAvailable = false;
      }
    }
    return _dartMatcher.match(image, template, threshold: threshold);
  }

  // ---- 辅助 ----

  RawImage _crop(RawImage img, int x, int y, int w, int h) {
    final cw = w.clamp(1, img.width - x);
    final ch = h.clamp(1, img.height - y);
    final out = Uint8List(cw * ch * 4);
    for (var row = 0; row < ch; row++) {
      final srcStart = ((y + row) * img.width + x) * 4;
      out.setRange(row * cw * 4, (row + 1) * cw * 4, img.bgra, srcStart);
    }
    return RawImage(cw, ch, out);
  }

  Future<Uint8List> _encodePng(RawImage img) => img.toPng();
}

/// 从模板图片文件加载 RawImage（BGRA）。
/// ui.instantiateImageCodec 解码 PNG/JPG/BMP，输出 RGBA，再转为 BGRA 语义。
Future<RawImage> loadTemplateFile(String path) async {
  final bytes = await File(path).readAsBytes();
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final rgba = data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    // RGBA → BGRA
    for (var i = 0; i < rgba.length; i += 4) {
      var t = rgba[i];
      rgba[i] = rgba[i + 2];
      rgba[i + 2] = t;
    }
    return RawImage(image.width, image.height, rgba);
  } finally {
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}
