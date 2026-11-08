import 'package:bluedot_clicker/services/ocr_target.dart';
import 'package:bluedot_clicker/services/recognition.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OCR 目标文本匹配', () {
    test('归一化：去空白（含全角空格）并转小写', () {
      expect(normalizeOcrText(' 开始\u3000Game\t'), '开始game');
    });

    test('跨词、含空格与大小写差异时命中，坐标为词框并集中心', () {
      final words = [
        const OcrWordBox('Start', 10, 20, 40, 20),
        const OcrWordBox('GAME', 60, 20, 50, 20),
      ];
      final hit = findOcrTarget(words, 'start game');
      expect(hit, isNotNull);
      // 并集 (10,20)-(110,40)，中心 (60,30)
      expect((hit!.x, hit.y), (60, 30));
    });

    test('跨行目标也能命中', () {
      final words = [
        const OcrWordBox('点击', 0, 0, 20, 10),
        const OcrWordBox('开始', 0, 30, 20, 10),
      ];
      final hit = findOcrTarget(words, '击开');
      expect(hit, isNotNull);
      // 并集 (0,0)-(20,40)，中心 (10,20)
      expect((hit!.x, hit.y), (10, 20));
    });

    test('多处命中取第一处', () {
      final words = [
        const OcrWordBox('开始', 0, 0, 20, 10),
        const OcrWordBox('开始', 100, 100, 20, 10),
      ];
      final hit = findOcrTarget(words, '开始');
      expect((hit!.x, hit.y), (10, 5));
    });

    test('未命中返回 null；空目标返回 null', () {
      final words = [const OcrWordBox('开始', 0, 0, 20, 10)];
      expect(findOcrTarget(words, '结束'), isNull);
      expect(findOcrTarget(words, '  '), isNull);
      expect(findOcrTarget(const [], '开始'), isNull);
    });

    test('放大 2/3 倍时坐标按 scale 还原', () {
      // 2 倍放大位图上的词框：(200,100,40,20) → 原图 (100,50,20,10)
      final twice = [const OcrWordBox('abc', 200, 100, 40, 20)];
      final hit2 = findOcrTarget(twice, 'abc', scale: 2);
      expect((hit2!.x, hit2.y), (110, 55));

      // 3 倍放大：(300,150,60,30) → 原图 (100,50,20,10)
      final thrice = [const OcrWordBox('abc', 300, 150, 60, 30)];
      final hit3 = findOcrTarget(thrice, 'abc', scale: 3);
      expect((hit3!.x, hit3.y), (110, 55));
    });
  });
}
