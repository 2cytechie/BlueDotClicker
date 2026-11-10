import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'isolate_matcher.dart';
import 'opencv_matcher.dart';
import 'paddle_ocr_engine.dart';
import 'recognition.dart';
import 'template_match_dart.dart';

/// Windows 识别服务：OCR 用 pp_ocr（PaddleOCR PP-OCRv6 + ONNX Runtime），
/// 模板匹配优先 OpenCV（opencv_dart，TM_CCOEFF_NORMED），
/// OpenCV 原生库不可用时自动回退纯 Dart 金字塔 NCC。
///
/// OCR 与模板匹配都放到后台 isolate：两者一次调用可能占用几十到几百毫秒，
/// 放在 UI 线程会直接卡住帧渲染。后台不可用时回退：OCR 返回空结果（按
/// 「未识别到文本」处理），模板匹配回退主线程。
class WindowsRecognitionService implements RecognitionService {
  WindowsRecognitionService({void Function(String message)? log})
    : _log = log,
      _isolateMatcher = IsolateTemplateMatcher(
        onDisabled: log == null
            ? null
            : (reason) => log('图像识别后台 isolate 不可用，已回退主线程：$reason'),
      ),
      _ocr = IsolatePaddleOcr(
        onDisabled: log == null ? null : (reason) => log('OCR 不可用：$reason'),
      );

  /// OCR 位图相对输入图像的放大倍数（当前不做放大，词框直接为原图像素）。
  static const double ocrScaleFactor = 1.0;

  final void Function(String message)? _log;
  final IsolateTemplateMatcher _isolateMatcher;
  final IsolatePaddleOcr _ocr;
  final DartTemplateMatcher _dartMatcher = const DartTemplateMatcher();
  final OpenCvMatcher _cvMatcher = const OpenCvMatcher();
  bool? _opencvAvailable;
  Future<PpOcrModelPaths>? _models;
  bool _modelErrorLogged = false;

  /// 释放后台匹配/OCR isolate（幂等）
  void dispose() {
    _ocr.dispose();
    _isolateMatcher.dispose();
  }

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
    try {
      final png = await _encodePng(img);
      final models = await (_models ??= ensurePpOcrModels());
      final raw = await _ocr.tryRecognize(models, png);
      if (raw == null) {
        // 引擎不可用 / 超时：按「未识别到文本」处理，不中断脚本
        return OcrResult('', x: ox, y: oy);
      }
      // pp_ocr 返回行级四角框，映射为轴对齐词框；坐标基于传入位图像素。
      final words = mapPpOcrQuadsToWordBoxes(raw);
      final text = words.map((w) => w.text).join('\n').trim();
      return OcrResult(text, x: ox, y: oy, words: words);
    } catch (e) {
      // 模型释放失败等主 isolate 侧异常：同样降级为空结果
      if (!_modelErrorLogged) {
        _modelErrorLogged = true;
        _log?.call('OCR 模型/引擎初始化失败：$e');
      }
      return OcrResult('', x: ox, y: oy);
    }
  }

  // ---- 模板匹配 ----

  @override
  Future<MatchResult> matchTemplate(RawImage image, RawImage template, {double threshold = 0.8}) async {
    // 1) 后台 isolate：OpenCV → 纯 Dart 的降级链在 worker 内部完成
    final offloaded =
        await _isolateMatcher.tryMatch(image, template, threshold: threshold);
    if (offloaded != null) return offloaded;
    // 2) 后台不可用：保持原语义（主线程 OpenCV → 纯 Dart，失败结果已缓存）
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
