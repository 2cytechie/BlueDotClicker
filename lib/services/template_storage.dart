import 'dart:io';

import 'package:crypto/crypto.dart';

import 'script_storage.dart' show appDataDir;

/// 模板图片存储：应用文档目录/templates/`<sha256>.<ext>`
class TemplateStorage {
  /// 测试注入：覆盖数据根目录（跳过 path_provider 插件）
  static Directory? _overrideDir;
  static void overrideDir(Directory dir) => _overrideDir = dir;

  /// 允许的模板图片扩展名
  static const Set<String> allowedExtensions = {'png', 'jpg', 'jpeg', 'bmp'};

  static String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  /// 从路径提取允许的扩展名（小写）；不支持的扩展名返回 null
  static String? extensionOf(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return null;
    final ext = name.substring(dot + 1).toLowerCase();
    return allowedExtensions.contains(ext) ? ext : null;
  }

  /// 模板目录路径（不创建目录）
  Future<String> get dirPath async {
    final base = _overrideDir ?? await appDataDir();
    return '${base.path}${Platform.pathSeparator}templates';
  }

  /// 模板文件路径（不创建目录）
  Future<String> pathFor(String hash, String ext) async =>
      '${await dirPath}${Platform.pathSeparator}$hash.$ext';

  /// 将外部图片保存到应用模板目录；节点只在成功后引用返回的路径。
  Future<String> importFile(String sourcePath) async {
    final ext = extensionOf(sourcePath);
    if (ext == null) throw const FormatException('不支持的图片格式');
    final bytes = await File(sourcePath).readAsBytes();
    return ensure(hash: sha256Hex(bytes), ext: ext, bytes: bytes);
  }

  /// 写入模板（已存在则复用），返回绝对路径
  Future<String> ensure({
    required String hash,
    required String ext,
    required List<int> bytes,
  }) async {
    final dir = Directory(await dirPath);
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$hash.$ext');
    if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
