import 'dart:io';

import 'recognition.dart';
import 'script_storage.dart' show appDataDir;

/// 数据保存节点的落盘服务：应用数据目录/save 下的 `.txt` / `.png` 文件。
/// 同名文件自动加序号（`name-1.ext`、`name-2.ext`…），不会覆盖已有文件。
class SaveFileService {
  /// 测试注入：覆盖保存目录（跳过 path_provider 插件）
  static Directory? _overrideDir;

  static void overrideDir(Directory dir) => _overrideDir = dir;

  Future<Directory> get dir async {
    final base = _overrideDir ?? await appDataDir();
    final d = Directory('${base.path}/save');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 文本保存为 `<fileName>.txt`，返回实际路径
  Future<String> saveText(String fileName, String content) async {
    final f = _unique(File('${(await dir).path}/${_safeName(fileName)}.txt'));
    await f.writeAsString(content);
    return f.path;
  }

  /// 图像编码为 PNG 保存为 `<fileName>.png`，返回实际路径
  Future<String> savePng(String fileName, RawImage img) async {
    final f = _unique(File('${(await dir).path}/${_safeName(fileName)}.png'));
    await f.writeAsBytes(await img.toPng());
    return f.path;
  }

  /// 目标已存在时依次尝试 name-1.ext、name-2.ext…（防覆盖）
  File _unique(File f) {
    if (!f.existsSync()) return f;
    final dot = f.path.lastIndexOf('.');
    final stem = dot < 0 ? f.path : f.path.substring(0, dot);
    final ext = dot < 0 ? '' : f.path.substring(dot);
    for (var i = 1;; i++) {
      final candidate = File('$stem-$i$ext');
      if (!candidate.existsSync()) return candidate;
    }
  }

  /// 文件名安全化：替换 Windows 非法字符，空名回退「未命名」
  String _safeName(String name) {
    final n = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return n.isEmpty ? '未命名' : n;
  }
}
