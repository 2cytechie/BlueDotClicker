import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// OCR 词框：文本 + 相对输入图像的像素矩形（左上角 x/y，宽高 w/h）
class OcrWordBox {
  final String text;
  final int x, y, w, h;
  const OcrWordBox(this.text, this.x, this.y, this.w, this.h);
}

/// OCR 识别结果
class OcrResult {
  final String text;
  final int x;
  final int y;

  /// 按 OCR 行序、行内从左到右排列的词框（可能为空：引擎不支持词框时）
  final List<OcrWordBox> words;
  const OcrResult(
    this.text, {
    this.x = 0,
    this.y = 0,
    this.words = const [],
  });
}

/// 模板匹配结果
class MatchResult {
  final bool found;
  final int x;
  final int y;
  final double score;
  const MatchResult(this.found, this.x, this.y, this.score);
}

/// 屏幕图像（BGRA 原始字节）的通用封装，识别服务输入。
class RawImage {
  final int width;
  final int height;
  final Uint8List bgra;
  const RawImage(this.width, this.height, this.bgra);

  /// 灰度化（Rec.601：Y = 0.299R + 0.587G + 0.114B；字节序为 BGRA）
  Uint8List toGray() {
    final g = Uint8List(width * height);
    for (var i = 0, p = 0; i < g.length; i++, p += 4) {
      g[i] = (bgra[p] * 114 + bgra[p + 1] * 587 + bgra[p + 2] * 299) ~/ 1000;
    }
    return g;
  }

  /// 解码为 dart:ui Image（RGBA）
  Future<ui.Image> toImage() async {
    final buf = await ui.ImmutableBuffer.fromUint8List(_rgba());
    final descriptor =
        ui.ImageDescriptor.raw(buf, width: width, height: height, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buf.dispose();
    return frame.image;
  }

  /// 编码为 PNG（供属性面板预览展示）
  Future<Uint8List> toPng() async {
    final image = await toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  }

  Uint8List _rgba() {
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

/// 识别服务抽象接口（OCR / 模板匹配）。Windows 实现 Phase 1，Android 为 Phase 2。
abstract interface class RecognitionService {
  bool get isAvailable;

  /// 对图像执行 OCR。region 为空则对整图。
  Future<OcrResult> recognizeText(RawImage image, {int? regionX, int? regionY, int? regionW, int? regionH});

  /// 在图像中匹配模板（灰度字节），返回是否命中及中心坐标（相对 image）。
  Future<MatchResult> matchTemplate(RawImage image, RawImage template, {double threshold = 0.8});
}
