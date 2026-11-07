import 'package:bluedot_clicker/platform/region_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeDragRect 拖拽矩形归一化', () {
    test('从左上到右下拖拽', () {
      expect(normalizeDragRect(0, 0, 400, 300), (0, 0, 400, 300));
    });

    test('从右下到左上拖拽（反向）→ 归一化为左上角 + 宽高', () {
      expect(normalizeDragRect(400, 300, 0, 0), (0, 0, 400, 300));
    });

    test('从右上到左下拖拽', () {
      expect(normalizeDragRect(400, 0, 100, 200), (100, 0, 300, 200));
    });

    test('从左下到右上拖拽', () {
      expect(normalizeDragRect(100, 200, 400, 0), (100, 0, 300, 200));
    });

    test('多屏负坐标（副屏在主屏左侧）拖拽', () {
      expect(normalizeDragRect(-1210, 386, -634, 488), (-1210, 386, 576, 102));
    });

    test('同点（零尺寸矩形）', () {
      expect(normalizeDragRect(50, 60, 50, 60), (50, 60, 0, 0));
    });
  });

  group('RegionPickResult', () {
    test('持有矩形字段', () {
      const r = RegionPickResult(-100, 50, 640, 480);
      expect(r.x, -100);
      expect(r.y, 50);
      expect(r.w, 640);
      expect(r.h, 480);
    });
  });
}
