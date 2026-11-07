import 'dart:io';

import '../platform/platform_automation.dart';
import '../platform/win32/user32.dart' as u32;
import 'recognition.dart';
import 'windows_recognition.dart' show loadTemplateFile;

/// 媒体节点测试结果：文本行 + 可选原始预览图 + 可选命中框（相对预览图坐标）
class MediaTestResult {
  final bool ok;
  final String title;
  final List<String> lines;
  final RawImage? preview;

  /// 命中框 (x, y, w, h)，相对预览图左上角
  final (int, int, int, int)? marker;
  const MediaTestResult({
    required this.ok,
    required this.title,
    this.lines = const [],
    this.preview,
    this.marker,
  });
}

/// 媒体节点测试器：按节点当前参数执行一次采集/识别，供属性面板「测试」按钮调用。
/// 采集前最小化本应用窗口（否则截到的是编辑器自身），结束后恢复。
class MediaTester {
  MediaTester(
    this._automation,
    this._recognition, {
    this.minimizeSelf = true,
    Future<RawImage> Function(String path)? loadTemplate,
  }) : _loadTemplate = loadTemplate ?? loadTemplateFile;

  final PlatformAutomation _automation;
  final RecognitionService _recognition;

  /// 采集前是否最小化本应用窗口（单元测试传 false，避免影响真实桌面）
  final bool minimizeSelf;
  final Future<RawImage> Function(String path) _loadTemplate;

  /// 按节点类型与当前参数执行一次测试
  Future<MediaTestResult> runTest(String type, Map<String, Object?> data) async {
    if (!_automation.isSupported) {
      return MediaTestResult(
        ok: false,
        title: '当前平台不支持',
        lines: [_automation.unsupportedReason ?? '当前平台暂不支持自动化'],
      );
    }
    if (!_recognition.isAvailable) {
      return const MediaTestResult(
        ok: false,
        title: '识别服务不可用',
        lines: ['当前平台不支持文字/图像识别'],
      );
    }
    final region = _region(data);
    final hwnd = _minimizeSelf();
    try {
      // 等窗口离开屏幕后再采集
      if (hwnd != 0) await Future<void>.delayed(const Duration(milliseconds: 350));
      switch (type) {
        case 'screenshot':
          return await _testScreenshot(region);
        case 'ocr':
          return await _testOcr(data, region);
        case 'imageMatch':
          return await _testImageMatch(data, region);
        default:
          return MediaTestResult(
            ok: false,
            title: '该节点不支持测试',
            lines: ['节点类型：$type'],
          );
      }
    } catch (e) {
      return MediaTestResult(ok: false, title: '测试失败', lines: ['$e']);
    } finally {
      _restoreSelf(hwnd);
    }
  }

  // ---- 各节点测试 ----

  Future<MediaTestResult> _testScreenshot(RectPx? region) async {
    final img = await _capture(region);
    return MediaTestResult(
      ok: true,
      title: '截图成功',
      lines: [
        '尺寸 ${img.width} × ${img.height}',
        '范围：${_regionLabel(region)}',
      ],
      preview: img,
    );
  }

  Future<MediaTestResult> _testOcr(Map<String, Object?> data, RectPx? region) async {
    final img = await _capture(region);
    final text = (await _recognition.recognizeText(img)).text;
    final varName = ((data['resultVar'] as String?) ?? '').trim();
    return MediaTestResult(
      ok: text.isNotEmpty,
      title: text.isEmpty ? '未识别到文本' : '识别成功',
      lines: [
        '文本内容：${text.isEmpty ? '(空)' : text}',
        '文本长度 ${text.length}',
        '来源图像 ${img.width} × ${img.height}',
        if (varName.isNotEmpty) '运行时将写入变量 $varName',
      ],
      preview: img,
    );
  }

  Future<MediaTestResult> _testImageMatch(Map<String, Object?> data, RectPx? region) async {
    final tplPath = ((data['templatePath'] as String?) ?? '').trim();
    if (tplPath.isEmpty) {
      return const MediaTestResult(ok: false, title: '无法测试', lines: ['未选择模板图片']);
    }
    final RawImage tpl;
    try {
      tpl = await _loadTemplate(tplPath);
    } catch (e) {
      return MediaTestResult(ok: false, title: '模板加载失败', lines: ['$e']);
    }
    final threshold = _double(data, 'threshold', 0.8);
    final img = await _capture(region);
    final r = await _recognition.matchTemplate(img, tpl, threshold: threshold);
    final fullX = (region?.x ?? 0) + r.x;
    final fullY = (region?.y ?? 0) + r.y;
    return MediaTestResult(
      ok: r.found,
      title: r.found ? '命中' : '未命中',
      lines: [
        '相似度 ${r.score.toStringAsFixed(3)}（阈值 ${threshold.toStringAsFixed(2)}）',
        r.found ? '命中中心 ($fullX, $fullY)' : '最佳匹配位置 ($fullX, $fullY)（未达阈值）',
        '模板尺寸 ${tpl.width} × ${tpl.height}',
        '来源图像 ${img.width} × ${img.height}',
      ],
      preview: img,
      // MatchResult 是模板中心；预览框使用左上角，需减半个模板尺寸
      marker: r.found
          ? (r.x - tpl.width ~/ 2, r.y - tpl.height ~/ 2, tpl.width, tpl.height)
          : null,
    );
  }

  // ---- 辅助 ----

  Future<RawImage> _capture(RectPx? region) async {
    final cap = await _automation.capture(region: region);
    return RawImage(cap.width, cap.height, cap.bgra);
  }

  String _regionLabel(RectPx? region) => region == null
      ? '全屏'
      : '区域 (${region.x}, ${region.y}) ${region.w}×${region.h}';

  /// 采集前最小化本应用窗口，返回窗口句柄（0 = 未最小化）
  int _minimizeSelf() {
    if (!minimizeSelf || !Platform.isWindows) return 0;
    final hwnd = u32.ownForegroundWindow();
    if (hwnd == 0) return 0;
    u32.minimizeWindow(hwnd);
    return hwnd;
  }

  void _restoreSelf(int hwnd) {
    if (hwnd != 0) u32.restoreWindow(hwnd);
  }

  int _int(Map<String, Object?> data, String key, int fallback) {
    final v = data[key];
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? fallback;
  }

  double _double(Map<String, Object?> data, String key, double fallback) {
    final v = data[key];
    if (v is num) return v.toDouble();
    return double.tryParse('$v') ?? fallback;
  }

  /// 区域参数：useRegion 非 true 时视为全屏（与解释器取值语义一致）
  RectPx? _region(Map<String, Object?> data) {
    if (data['useRegion'] != true) return null;
    return RectPx(
      _int(data, 'rx', 0),
      _int(data, 'ry', 0),
      _int(data, 'rw', 400),
      _int(data, 'rh', 300),
    );
  }
}
