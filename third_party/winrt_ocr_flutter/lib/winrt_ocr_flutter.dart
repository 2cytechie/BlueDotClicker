/// Dart-facing API for the `winrt_ocr_flutter` Windows plugin.
///
/// This is the only file a consuming app is meant to import. Everything
/// else is the native C++/WinRT implementation behind it.
library winrt_ocr_flutter;

import 'package:flutter/services.dart';

/// Thrown when the native Windows OCR plugin reports a specific,
/// recoverable failure (e.g. the OCR engine has no language pack
/// installed). Callers should still treat this the same as "no text
/// recognized" — never let it crash the caller — but the message is kept
/// distinct from a plain empty result so it can be logged if useful.
class WinrtOcrException implements Exception {
  const WinrtOcrException(this.message);
  final String message;

  @override
  String toString() => 'WinrtOcrException: $message';
}

/// 单个 OCR 词框（像素坐标，基于传入位图；line 为 OCR 行序，从 0 开始）
class WinrtOcrWord {
  const WinrtOcrWord({
    required this.text,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.line,
  });

  final String text;
  final int x, y, w, h, line;
}

/// 带词框的 OCR 结果（text 与 recognizeText 完全一致）
class WinrtOcrBoxes {
  const WinrtOcrBoxes({required this.text, required this.words});
  final String text;
  final List<WinrtOcrWord> words;
}

class WinrtOcr {
  WinrtOcr._();

  static const MethodChannel _channel = MethodChannel('winrt_ocr_flutter');

  /// Recognizes text in the image at [imagePath] (a local file path — the
  /// caller owns the file's lifecycle; this plugin never reads, writes, or
  /// deletes any other path).
  ///
  /// Returns the recognized text with each `OcrLine` joined by `\n`,
  /// preserving the line order `Windows.Media.Ocr` returns. Returns `''`
  /// (never throws to the Flutter-side caller under normal operation) when
  /// the image has no recognizable text; throws [WinrtOcrException] only
  /// for engine-level failures (e.g. no OCR language installed) so a
  /// caller's own catch-all can turn that into `''` exactly like every
  /// other engine failure mode.
  static Future<String> recognizeText(String imagePath) async {
    try {
      final result = await _channel.invokeMethod<String>('recognizeText', {
        'imagePath': imagePath,
      });
      return result ?? '';
    } on PlatformException catch (e) {
      throw WinrtOcrException(e.message ?? e.code);
    }
  }

  /// 与 [recognizeText] 相同，但同时返回每个词的像素词框。
  static Future<WinrtOcrBoxes> recognizeWithBoxes(String imagePath) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'recognizeWithBoxes',
        {'imagePath': imagePath},
      );
      final map = (raw as Map?)?.cast<Object?, Object?>() ?? const {};
      final text = (map['text'] as String?) ?? '';
      final words = <WinrtOcrWord>[];
      final rawWords = (map['words'] as List?) ?? const [];
      for (final item in rawWords) {
        final w = (item as Map).cast<Object?, Object?>();
        words.add(
          WinrtOcrWord(
            text: (w['text'] as String?) ?? '',
            x: (w['x'] as num?)?.toInt() ?? 0,
            y: (w['y'] as num?)?.toInt() ?? 0,
            w: (w['w'] as num?)?.toInt() ?? 0,
            h: (w['h'] as num?)?.toInt() ?? 0,
            line: (w['line'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      return WinrtOcrBoxes(text: text, words: words);
    } on PlatformException catch (e) {
      throw WinrtOcrException(e.message ?? e.code);
    }
  }
}
