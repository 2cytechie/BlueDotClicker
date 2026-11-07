import 'package:bluedot_clicker/platform/screen_marker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScreenBorderService 画布/窗口容量', () {
    test('画布尺寸按 256 量化且不小于矩形+描边', () {
      final (w, h) = ScreenBorderService.canvasSize(400, 300);
      expect(w, 512);
      expect(h, 512);
      expect(w % 256, 0);
      expect(h % 256, 0);
      expect(w, greaterThanOrEqualTo(400 + 10));
      expect(h, greaterThanOrEqualTo(300 + 10));
    });

    test('整屏提示（3840×1080）画布尺寸', () {
      final (w, h) = ScreenBorderService.canvasSize(3840, 1080);
      expect(w, 4096);
      expect(h, 1280);
    });

    test('分层窗口容量与渲染画布严格一致，ULW 上屏成功', () async {
      final svc = ScreenBorderService();
      svc.showRect(0, 0, 400, 300);
      final ok = await svc.debugLastRender;
      final (cw, ch) = ScreenBorderService.canvasSize(400, 300);
      // updateFromRgba 要求像素长度 == 窗口宽×高×4；两者不一致时 ULW 永远失败
      expect(svc.debugWindowWidth, cw);
      expect(svc.debugWindowHeight, ch);
      expect(ok, isTrue);
      svc.hide();
      expect(svc.debugWindowWidth, 0);
    });

    test('同量化尺寸复用窗口，跨量化边界重建', () async {
      final svc = ScreenBorderService();
      svc.showRect(0, 0, 400, 300);
      expect(await svc.debugLastRender, isTrue);
      final w1 = svc.debugWindowWidth;

      svc.showRect(100, 100, 400, 300);
      expect(await svc.debugLastRender, isTrue);
      expect(svc.debugWindowWidth, w1, reason: '同量化尺寸应复用窗口');

      svc.showRect(0, 0, 800, 600);
      expect(await svc.debugLastRender, isTrue);
      expect(
        svc.debugWindowWidth,
        ScreenBorderService.canvasSize(800, 600).$1,
        reason: '尺寸跨量化边界应重建为精确容量（避免整屏窗口被小矩形复用）',
      );
      svc.hide();
    });
  });
}
