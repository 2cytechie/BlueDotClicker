import 'package:flutter_test/flutter_test.dart';

import 'package:bluedot_clicker/services/paddle_ocr_engine.dart';

void main() {
  group('mapPpOcrQuadsToWordBoxes', () {
    test('乱序输入按上→下、同高按左→右排序并拼接文本', () {
      final boxes = mapPpOcrQuadsToWordBoxes([
        ['second', 10.0, 50.0, 100.0, 50.0, 100.0, 70.0, 10.0, 70.0],
        ['world', 60.0, 10.0, 120.0, 10.0, 120.0, 30.0, 60.0, 30.0],
        ['hello', 10.0, 10.0, 50.0, 10.0, 50.0, 30.0, 10.0, 30.0],
      ]);

      expect(boxes.map((b) => b.text).toList(), ['hello', 'world', 'second']);
      expect(boxes.map((b) => b.text).join('\n'), 'hello\nworld\nsecond');
      expect(boxes.first.x, 10);
      expect(boxes.first.y, 10);
      expect(boxes.first.w, 40);
      expect(boxes.first.h, 20);
    });

    test('倾斜四边形映射为最小外接矩形', () {
      final boxes = mapPpOcrQuadsToWordBoxes([
        ['tilt', 12.0, 14.0, 40.0, 10.0, 42.0, 28.0, 10.0, 32.0],
      ]);

      expect(boxes, hasLength(1));
      expect(boxes.single.x, 10);
      expect(boxes.single.y, 10);
      expect(boxes.single.w, 32);
      expect(boxes.single.h, 22);
    });

    test('空文本与非法项被过滤', () {
      final boxes = mapPpOcrQuadsToWordBoxes([
        ['   ', 0.0, 0.0, 10.0, 0.0, 10.0, 10.0, 0.0, 10.0],
        ['ok', 1.0, 2.0, 5.0, 2.0, 5.0, 6.0, 1.0, 6.0],
        ['short', 1.0, 2.0],
      ]);

      expect(boxes.map((b) => b.text).toList(), ['ok']);
    });

    test('退化框宽高至少为 1', () {
      final boxes = mapPpOcrQuadsToWordBoxes([
        ['dot', 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0],
      ]);

      expect(boxes, hasLength(1));
      expect(boxes.single.w, 1);
      expect(boxes.single.h, 1);
    });

    test('空输入返回空列表', () {
      expect(mapPpOcrQuadsToWordBoxes(const []), isEmpty);
    });
  });
}
