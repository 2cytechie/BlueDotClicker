/// 屏幕标记纯逻辑单测：预乘转换 / 包围盒 / 位置 clamp / 命中测试。
/// 无窗口、无钩子、无 DPI 依赖，Windows 环境稳定运行。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bluedot_clicker/platform/screen_marker.dart';

void main() {
  group('premultiplyRgbaToBgra', () {
    test('透明像素清零（预乘后 RGB 必须为 0，且可覆写旧缓冲残留）', () {
      final dst = Uint8List(8)..[0] = 9; // 故意留脏数据，验证全量覆写
      premultiplyRgbaToBgra(
          Uint8List.fromList([1, 2, 3, 0, 255, 255, 255, 0]), dst);
      expect(dst, Uint8List(8)); // 全零
    });

    test('不透明像素：白色不变，纯红通道序交换（RGBA→BGRA）', () {
      final dst = Uint8List(8);
      premultiplyRgbaToBgra(
          Uint8List.fromList([255, 255, 255, 255, 255, 0, 0, 255]), dst);
      expect(dst.sublist(0, 4), [255, 255, 255, 255]); // 白
      expect(dst.sublist(4, 8), [0, 0, 255, 255]); // 红 RGBA → BGRA
    });

    test('半透明预乘：(R200,G100,B50,A128) → BGRA(25,50,100,128)', () {
      final dst = Uint8List(4);
      premultiplyRgbaToBgra(Uint8List.fromList([200, 100, 50, 128]), dst);
      expect(dst.toList(), [25, 50, 100, 128]);
    });

    test('LUT 与 round(c*a/255) 逐值恒等（随机采样）', () {
      final rng = math.Random(7);
      for (var i = 0; i < 1000; i++) {
        final c = rng.nextInt(256);
        final a = rng.nextInt(256);
        final dst = Uint8List(4);
        premultiplyRgbaToBgra(Uint8List.fromList([c, c, c, a]), dst);
        expect(dst[2], (c * a / 255).round(), reason: 'c=$c a=$a'); // R 通道
      }
    });

    test('长度不一致时不越界（防御：函数按 src 长度写入）', () {
      final dst = Uint8List(4);
      premultiplyRgbaToBgra(Uint8List.fromList([1, 2, 3, 255]), dst);
      expect(dst.length, 4);
      expect(dst[3], 255);
    });
  });

  group('tightMarkerBox', () {
    test('单点对称包围盒', () {
      final box = tightMarkerBox([const MarkerPoint(1000, 500, 0)], 26);
      expect(box, (974, 474, 1026, 526));
    });

    test('两点取并集', () {
      final box = tightMarkerBox(
        [const MarkerPoint(100, 100, 0), const MarkerPoint(300, 200, 0)],
        26,
      );
      expect(box, (74, 74, 326, 226));
    });

    test('屏外/负坐标不做 clamp（由 clampWindowPos 负责）', () {
      final box = tightMarkerBox([const MarkerPoint(-500, 2000, 0)], 26);
      expect(box, (-526, 1974, -474, 2026));
    });
  });

  group('clampWindowPos', () {
    test('左上越界钳到 0', () {
      expect(clampWindowPos(-50, -50, 100, 100, 1920, 1080), (0, 0));
    });

    test('右下越界钳到屏幕内', () {
      expect(clampWindowPos(1900, 1050, 100, 100, 1920, 1080), (1820, 980));
    });

    test('窗口不小于屏幕时锚定 (0,0)', () {
      expect(clampWindowPos(500, 500, 4000, 4000, 1920, 1080), (0, 0));
    });

    test('位置合法则原样返回', () {
      expect(clampWindowPos(100, 200, 100, 100, 1920, 1080), (100, 200));
    });

    test('虚拟桌面为负原点（副屏在主屏左侧）：负坐标图标不被拽回主屏', () {
      // 虚拟桌面 (-1920,0,3840,1080)：副屏坐标 -1210 应原样保留
      expect(
        clampWindowPos(-1236, 360, 128, 128, 3840, 1080, originX: -1920),
        (-1236, 360),
      );
      // 左边界越界钳到虚拟桌面左上角，而不是 0
      expect(
        clampWindowPos(-2000, 100, 128, 128, 3840, 1080, originX: -1920),
        (-1920, 100),
      );
    });
  });

  group('markerHitTest', () {
    final points = [
      const MarkerPoint(100, 100, 0),
      const MarkerPoint(300, 100, 0),
    ];

    test('圆内命中对应索引', () {
      expect(markerHitTest(points, 90, 100, 20), 0);
      expect(markerHitTest(points, 295, 100, 20), 1);
    });

    test('圆外返回 -1', () {
      expect(markerHitTest(points, 200, 100, 20), -1);
    });

    test('恰在半径上命中（边界含等号）', () {
      expect(markerHitTest(points, 120, 100, 20), 0); // dx=20 → 400 ≤ 400
      expect(markerHitTest(points, 121, 100, 20), -1);
    });

    test('两点重叠取小索引', () {
      final near = [
        const MarkerPoint(100, 100, 0),
        const MarkerPoint(110, 100, 0),
      ];
      expect(markerHitTest(near, 105, 100, 20), 0);
    });
  });
}
