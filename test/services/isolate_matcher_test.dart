import 'dart:typed_data';

import 'package:bluedot_clicker/services/isolate_matcher.dart';
import 'package:bluedot_clicker/services/opencv_matcher.dart';
import 'package:bluedot_clicker/services/recognition.dart';
import 'package:bluedot_clicker/services/template_match_dart.dart';
import 'package:flutter_test/flutter_test.dart';

void _fillRect(
  Uint8List img,
  int imgW,
  int x,
  int y,
  int w,
  int h,
  int b,
  int g,
  int r,
) {
  for (var yy = y; yy < y + h; yy++) {
    for (var xx = x; xx < x + w; xx++) {
      final p = (yy * imgW + xx) * 4;
      img[p] = b;
      img[p + 1] = g;
      img[p + 2] = r;
      img[p + 3] = 255;
    }
  }
}

/// 深色方块 + 白色背景，模板为方块本身
(RawImage, RawImage) _scene() {
  final img = RawImage(200, 150, Uint8List(200 * 150 * 4));
  _fillRect(img.bgra, 200, 0, 0, 200, 150, 255, 255, 255);
  _fillRect(img.bgra, 200, 80, 60, 40, 30, 20, 20, 20);
  final tpl = RawImage(40, 30, Uint8List(40 * 30 * 4));
  _fillRect(tpl.bgra, 40, 0, 0, 40, 30, 20, 20, 20);
  return (img, tpl);
}

/// 后台匹配 isolate：证明重活能离开 UI isolate 并返回一致结果。
void main() {
  test('后台 isolate 匹配结果与主线程 OpenCV 一致', () async {
    final matcher = IsolateTemplateMatcher();
    addTearDown(matcher.dispose);
    final (img, tpl) = _scene();

    final isolated = await matcher.tryMatch(img, tpl, threshold: 0.8);
    final inline = const OpenCvMatcher().match(img, tpl, threshold: 0.8);

    expect(isolated, isNotNull, reason: '后台 isolate 不应被禁用');
    expect(isolated!.found, inline.found);
    expect(isolated.x, inline.x);
    expect(isolated.y, inline.y);
    expect(isolated.score, closeTo(inline.score, 1e-6));
  });

  test('preferOpenCv=false：worker 内走纯 Dart 匹配', () async {
    final matcher = IsolateTemplateMatcher(preferOpenCv: false);
    addTearDown(matcher.dispose);
    final (img, tpl) = _scene();

    final isolated = await matcher.tryMatch(img, tpl, threshold: 0.8);
    final inline = const DartTemplateMatcher().match(img, tpl, threshold: 0.8);

    expect(isolated, isNotNull, reason: '后台 isolate 不应被禁用');
    expect(isolated!.found, inline.found);
    expect(isolated.x, inline.x);
    expect(isolated.y, inline.y);
    expect(isolated.score, closeTo(inline.score, 1e-6));
  });

  test('模板大于图像：返回未命中且不报错', () async {
    final matcher = IsolateTemplateMatcher();
    addTearDown(matcher.dispose);
    final img = RawImage(20, 20, Uint8List(20 * 20 * 4));
    final tpl = RawImage(40, 40, Uint8List(40 * 40 * 4));

    final r = await matcher.tryMatch(img, tpl);
    expect(r, isNotNull);
    expect(r!.found, isFalse);
  });

  test('dispose 后 tryMatch 返回 null（调用方回退内联匹配）', () async {
    final matcher = IsolateTemplateMatcher();
    matcher.dispose();
    final (img, tpl) = _scene();
    expect(await matcher.tryMatch(img, tpl), isNull);
  });
}
