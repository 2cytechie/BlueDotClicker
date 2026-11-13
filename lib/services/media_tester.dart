import 'dart:io';

import '../platform/platform_automation.dart';
import '../platform/win32/user32.dart' as u32;
import 'ocr_target.dart';
import 'recognition.dart';
import 'windows_recognition.dart' show loadTemplateFile;

/// 调试运行得到的测试输入：由 UI 层从引擎探针快照转换而来。
/// 传入后测试按真实执行路径取图（上游图像优先），而不是只按节点参数现场截屏。
class MediaTestInputs {
  /// 是否成功从「开始」运行到了目标节点之前
  final bool reached;

  /// 上游已产出的图像（连接了「输入图像」时非空）
  final RawImage? image;

  /// 上游图像的左上角屏幕坐标（虚拟桌面坐标，可为负）
  final (int, int) imageOrigin;

  /// 区域设置（连接输入图像时为 disabled）
  final RegionParse region;

  /// 运行时解析的目标文本（null = 使用节点参数）
  final String? targetText;

  /// 前置执行经过的节点数
  final int steps;

  /// 前置节点产生的日志
  final List<String> logs;

  const MediaTestInputs({
    required this.reached,
    this.image,
    this.imageOrigin = (0, 0),
    this.region = const RegionParse.disabled(),
    this.targetText,
    this.steps = 0,
    this.logs = const [],
  });
}

/// 媒体节点测试结果：文本行 + 可选原始预览图 + 可选命中框（相对预览图坐标）
class MediaTestResult {
  final bool ok;
  final String title;
  final List<String> lines;
  final RawImage? preview;

  /// 命中框 (x, y, w, h)，相对预览图左上角
  final (int, int, int, int)? marker;

  /// 调试运行的前置节点日志（仅「运行到本节点」模式）
  final List<String> debugLogs;
  const MediaTestResult({
    required this.ok,
    required this.title,
    this.lines = const [],
    this.preview,
    this.marker,
    this.debugLogs = const [],
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

  /// 按节点类型执行一次测试。
  /// 传入 [inputs]（来自「运行到本节点」的调试探针）时按真实执行路径取图：
  /// 有上游图像就直接用该图像，否则按运行时解析出的区域现场截屏。
  Future<MediaTestResult> runTest(
    String type,
    Map<String, Object?> data, {
    MediaTestInputs? inputs,
  }) async {
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
    final debug = inputs != null && inputs.reached;
    final region = debug ? inputs.region : _region(data);
    if (region.enabled && !region.valid) {
      return const MediaTestResult(
        ok: false,
        title: '区域无效',
        lines: ['区域的宽或高为 0，请检查左上角/右下角坐标'],
      );
    }
    // 已有上游图像时不需要现场截屏，也就不必最小化本窗口
    final hwnd = debug && inputs.image != null ? 0 : _minimizeSelf();
    try {
      // 等窗口离开屏幕后再采集
      if (hwnd != 0) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
      final MediaTestResult result;
      switch (type) {
        case 'screenshot':
          result = await _testScreenshot(region.rect, inputs);
        case 'ocr':
          result = await _testOcr(data, region.rect, inputs);
        case 'imageMatch':
          result = await _testImageMatch(data, region.rect, inputs);
        default:
          result = MediaTestResult(
            ok: false,
            title: '该节点不支持测试',
            lines: ['节点类型：$type'],
          );
      }
      return _withDebugInfo(result, inputs);
    } catch (e) {
      return MediaTestResult(ok: false, title: '测试失败', lines: ['$e']);
    } finally {
      _restoreSelf(hwnd);
    }
  }

  /// 在结果前补充调试运行信息（前置节点数、是否使用了上游图像）
  MediaTestResult _withDebugInfo(MediaTestResult r, MediaTestInputs? inputs) {
    if (inputs == null) return r;
    final extra = <String>[
      inputs.reached
          ? '调试运行：前置节点已执行 ${inputs.steps} 个'
          : '调试运行：未能从「开始」运行到本节点（可能没有连线），已按节点参数直接测试',
      if (inputs.image != null)
        '使用上游图像 ${inputs.image!.width}×${inputs.image!.height}',
    ];
    return MediaTestResult(
      ok: r.ok,
      title: r.title,
      lines: [...extra, ...r.lines],
      preview: r.preview,
      marker: r.marker,
      debugLogs: inputs.logs,
    );
  }

  // ---- 各节点测试 ----

  Future<MediaTestResult> _testScreenshot(
    RectPx? region,
    MediaTestInputs? inputs,
  ) async {
    final (img, imgX, imgY) = await _source(region, inputs);
    return MediaTestResult(
      ok: true,
      title: '截图成功',
      lines: [
        '尺寸 ${img.width} × ${img.height}',
        if (inputs?.image == null) '范围：${_regionLabel(region)}',
        if (inputs?.image != null) '图像原点：($imgX, $imgY)（上游图像）',
      ],
      preview: img,
    );
  }

  Future<MediaTestResult> _testOcr(
    Map<String, Object?> data,
    RectPx? region,
    MediaTestInputs? inputs,
  ) async {
    final (img, imgX, imgY) = await _source(region, inputs);
    final res = await _recognition.recognizeText(img);
    final target = (inputs?.targetText ?? (data['targetText'] as String?) ?? '')
        .toString();
    var found = res.text.isNotEmpty;
    // 以图像自身原点换算中心：区域被屏幕边界钳制、或直接使用上游图像时不产生偏移
    var cx = imgX + img.width ~/ 2;
    var cy = imgY + img.height ~/ 2;
    if (target.trim().isNotEmpty) {
      final hit = findOcrTarget(res.words, target);
      if (hit != null) {
        found = true;
        cx = imgX + hit.x;
        cy = imgY + hit.y;
      } else if (res.words.isEmpty &&
          normalizeOcrText(res.text).contains(normalizeOcrText(target))) {
        found = true;
      } else {
        found = false;
        cx = -1;
        cy = -1;
      }
    }
    return MediaTestResult(
      ok: found,
      title: target.trim().isEmpty
          ? (res.text.isEmpty ? '未识别到文本' : '识别成功')
          : (found ? '命中目标文本' : '未命中目标文本'),
      lines: [
        '文本内容：${res.text.isEmpty ? '(空)' : res.text}',
        '文本长度 ${res.text.length}',
        '来源图像 ${img.width} × ${img.height}',
        if (target.trim().isNotEmpty) ...[
          '目标文本：$target',
          '是否命中：$found',
          found ? '目标坐标：($cx, $cy)' : '目标坐标：(-1, -1)',
        ] else
          '区域中心：($cx, $cy)',
      ],
      preview: img,
    );
  }

  Future<MediaTestResult> _testImageMatch(
    Map<String, Object?> data,
    RectPx? region,
    MediaTestInputs? inputs,
  ) async {
    final tplPath = ((data['templatePath'] as String?) ?? '').trim();
    if (tplPath.isEmpty) {
      return const MediaTestResult(
        ok: false,
        title: '无法测试',
        lines: ['未选择模板图片'],
      );
    }
    final RawImage tpl;
    try {
      tpl = await _loadTemplate(tplPath);
    } catch (e) {
      return MediaTestResult(ok: false, title: '模板加载失败', lines: ['$e']);
    }
    final threshold = _double(data, 'threshold', 0.8);
    final (img, imgX, imgY) = await _source(region, inputs);
    final r = await _recognition.matchTemplate(img, tpl, threshold: threshold);
    // 图像原点可能为负（副屏在主屏左侧），命中坐标需叠回屏幕坐标
    final fullX = imgX + r.x;
    final fullY = imgY + r.y;
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

  /// 测试用的源图像：调试运行有上游图像时直接使用（图像优先），否则现场截屏。
  Future<(RawImage, int, int)> _source(
    RectPx? region,
    MediaTestInputs? inputs,
  ) async {
    final image = inputs?.image;
    if (image != null) {
      final origin = inputs!.imageOrigin;
      return (image, origin.$1, origin.$2);
    }
    return _capture(region);
  }

  /// 采集图像并返回其左上角的屏幕坐标（区域采集时即区域原点，可为负）
  Future<(RawImage, int, int)> _capture(RectPx? region) async {
    final cap = await _automation.capture(region: region);
    return (RawImage(cap.width, cap.height, cap.bgra), cap.x, cap.y);
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

  double _double(Map<String, Object?> data, String key, double fallback) {
    final v = data[key];
    if (v is num) return v.toDouble();
    return double.tryParse('$v') ?? fallback;
  }

  /// 区域参数：useRegion 非 true 时视为全屏（与解释器取值语义一致）
  RegionParse _region(Map<String, Object?> data) {
    if (data['useRegion'] != true) return const RegionParse.disabled();
    return resolveRegion(data);
  }
}
