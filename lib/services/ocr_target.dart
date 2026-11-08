import 'recognition.dart';

/// OCR 目标文本匹配的归一化：去除所有空白（含全角空格），英文转小写。
String normalizeOcrText(String text) =>
    text.replaceAll(RegExp(r'[\s\u3000]+'), '').toLowerCase();

/// 目标文本命中结果：命中字符覆盖词框并集的中心（相对输入图像像素）
class OcrTargetHit {
  final int x, y;
  const OcrTargetHit(this.x, this.y);
}

/// 在 OCR 词框中查找目标文本。
///
/// 词框按 OCR 行序（上→下）、行内字符序（左→右）拼接后做子串匹配，
/// 因此目标跨词、跨行时也可命中；多处命中取第一处。
/// [scale] 为 OCR 位图相对输入图像的放大倍数（词框坐标会除以它还原）。
/// 目标为空或词框为空时返回 null（由调用方按旧语义处理）。
OcrTargetHit? findOcrTarget(
  List<OcrWordBox> words,
  String target, {
  double scale = 1.0,
}) {
  final needle = normalizeOcrText(target);
  if (needle.isEmpty || words.isEmpty) return null;
  final factor = scale <= 0 ? 1.0 : scale;

  final chars = <int>[]; // 归一化后每个字符对应的词框下标
  final buffer = StringBuffer();
  for (var i = 0; i < words.length; i++) {
    final normalized = normalizeOcrText(words[i].text);
    for (var j = 0; j < normalized.length; j++) {
      buffer.write(normalized[j]);
      chars.add(i);
    }
  }
  final start = buffer.toString().indexOf(needle);
  if (start < 0) return null;

  final end = start + needle.length - 1;
  int? left, top, right, bottom;
  for (var i = start; i <= end; i++) {
    final w = words[chars[i]];
    final wx = (w.x / factor).round();
    final wy = (w.y / factor).round();
    final ww = (w.w / factor).round();
    final wh = (w.h / factor).round();
    left = left == null || wx < left ? wx : left;
    top = top == null || wy < top ? wy : top;
    final wordRight = wx + ww;
    final wordBottom = wy + wh;
    right = right == null || wordRight > right ? wordRight : right;
    bottom = bottom == null || wordBottom > bottom ? wordBottom : bottom;
  }
  if (left == null || top == null || right == null || bottom == null) {
    return null;
  }
  return OcrTargetHit((left + right) ~/ 2, (top + bottom) ~/ 2);
}
