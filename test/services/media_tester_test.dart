import 'dart:typed_data';

import 'package:bluedot_clicker/platform/platform_automation.dart';
import 'package:bluedot_clicker/services/media_tester.dart';
import 'package:bluedot_clicker/services/recognition.dart';
import 'package:flutter_test/flutter_test.dart';

// ---- 测试替身 ----

class FakeAutomation implements PlatformAutomation {
  int captureCalls = 0;
  RectPx? lastRegion;

  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;
  @override
  (int, int) get screenSize => (200, 150);

  @override
  Future<ScreenCapture> capture({RectPx? region}) async {
    captureCalls++;
    lastRegion = region;
    final w = region?.w ?? 200;
    final h = region?.h ?? 150;
    return ScreenCapture(
      w,
      h,
      Uint8List(w * h * 4),
      x: region?.x ?? 0,
      y: region?.y ?? 0,
    );
  }

  @override
  Future<void> moveMouse(int x, int y) async {}
  @override
  Future<void> click(int x, int y, {MouseButton button = MouseButton.left, int count = 1}) async {}
  @override
  Future<void> swipe(int x1, int y1, int x2, int y2, {int durationMs = 300}) async {}
  @override
  Future<void> longPress(int x, int y, {int durationMs = 800, MouseButton button = MouseButton.left}) async {}
  @override
  Future<void> scrollWheel(int x, int y, {int dy = 0, int dx = 0}) async {}
  @override
  Future<void> keyTap(int vkCode, {int durationMs = 60, bool extended = false}) async {}
  @override
  Future<void> keyDown(int vkCode, {bool extended = false}) async {}
  @override
  Future<void> keyUp(int vkCode, {bool extended = false}) async {}
  @override
  (int, int) cursorPos() => (0, 0);
  @override
  (bool, bool, bool) buttonsDown() => (false, false, false);
  @override
  bool isKeyDown(int vkCode) => false;
}

class FakeRecognition implements RecognitionService {
  @override
  bool get isAvailable => true;
  @override
  Future<OcrResult> recognizeText(RawImage image,
          {int? regionX, int? regionY, int? regionW, int? regionH}) async =>
      const OcrResult('hello');
  @override
  Future<MatchResult> matchTemplate(RawImage image, RawImage template,
          {double threshold = 0.8}) async =>
      const MatchResult(true, 20, 30, 0.93);
}

/// 固定 40×30 模板，避免测试依赖真实图片文件
Future<RawImage> _fakeTemplate(String path) async =>
    RawImage(40, 30, Uint8List(40 * 30 * 4));

MediaTester _tester({FakeAutomation? automation, FakeRecognition? recognition}) => MediaTester(
      automation ?? FakeAutomation(),
      recognition ?? FakeRecognition(),
      minimizeSelf: false,
      loadTemplate: _fakeTemplate,
    );

void main() {
  group('媒体节点测试器', () {
    test('截图：返回全屏预览与尺寸', () async {
      final auto = FakeAutomation();
      final r = await _tester(automation: auto).runTest('screenshot', const {});
      expect(r.ok, isTrue);
      expect(r.title, '截图成功');
      expect(r.preview!.width, 200);
      expect(r.preview!.height, 150);
      expect(r.lines.join(), contains('200 × 150'));
      expect(r.lines.join(), contains('全屏'));
      expect(auto.lastRegion, isNull);
      expect(r.marker, isNull);
    });

    test('文字识别：识别文本进入结果', () async {
      final r = await _tester().runTest('ocr', const {'resultVar': 'ocrText'});
      expect(r.ok, isTrue);
      expect(r.lines.join(), contains('hello'));
      expect(r.lines.join(), contains('运行时将写入变量 ocrText'));
      expect(r.preview, isNotNull);
    });

    test('图像识别：未选择模板时提示且不采集', () async {
      final auto = FakeAutomation();
      final r = await _tester(automation: auto).runTest('imageMatch', const {'templatePath': ''});
      expect(r.ok, isFalse);
      expect(r.lines.join(), contains('未选择模板图片'));
      expect(auto.captureCalls, 0);
    });

    test('图像识别：命中时返回相似度与命中框', () async {
      final auto = FakeAutomation();
      final r = await _tester(automation: auto)
          .runTest('imageMatch', const {'templatePath': 'C:/tpl.png', 'threshold': 0.8});
      expect(r.ok, isTrue);
      expect(r.title, '命中');
      expect(r.lines.join(), contains('0.93'));
      expect(r.lines.join(), contains('命中中心 (20, 30)'));
      // MatchResult 是中心坐标，预览框应转换为左上角：中心 - 半模板尺寸
      expect(r.marker, (0, 15, 40, 30));
      expect(auto.lastRegion, isNull);
    });

    test('区域参数：按区域采集并把区域偏移计入命中坐标', () async {
      final auto = FakeAutomation();
      final r = await _tester(automation: auto).runTest('imageMatch', const {
        'templatePath': 'C:/tpl.png',
        'useRegion': true,
        'rx': 10,
        'ry': 10,
        'rw': 50,
        'rh': 40,
      });
      expect(auto.lastRegion, isNotNull);
      expect(auto.lastRegion!.x, 10);
      expect(auto.lastRegion!.w, 50);
      expect(r.preview!.width, 50);
      expect(r.preview!.height, 40);
      // 全屏坐标 = 区域偏移 (10,10) + 匹配坐标 (20,30)
      expect(r.lines.join(), contains('(30, 40)'));
    });

    test('负坐标区域：命中坐标叠加负的图像原点', () async {
      final auto = FakeAutomation();
      final r = await _tester(automation: auto).runTest('imageMatch', const {
        'templatePath': 'C:/tpl.png',
        'useRegion': true,
        'rx': -500,
        'ry': 100,
        'rw': 50,
        'rh': 40,
      });
      expect(auto.lastRegion!.x, -500);
      expect(r.preview!.width, 50);
      // 全屏坐标 = (-500,100) + (20,30)；副屏在主屏左侧时命中 X 为负
      expect(r.lines.join(), contains('(-480, 130)'));
    });

    test('非媒体节点类型给出不支持提示', () async {
      final r = await _tester().runTest('delay', const {});
      expect(r.ok, isFalse);
      expect(r.title, contains('不支持测试'));
      expect(r.lines.join(), contains('delay'));
    });
  });
}
