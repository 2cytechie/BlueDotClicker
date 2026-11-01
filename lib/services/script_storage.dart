import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/blueprint.dart';

/// 应用文档目录下的数据根目录（脚本、录制、数据存取共用）
const _appDirName = 'bluedot_clicker';

/// 旧版本使用的数据目录名，首次启动时自动迁移到 [_appDirName]
const _legacyAppDirName = 'blueprint_clicker';

Future<Directory> _appDataDir() async {
  final doc = await getApplicationDocumentsDirectory();
  final d = Directory('${doc.path}/$_appDirName');
  final legacy = Directory('${doc.path}/$_legacyAppDirName');
  if (!await d.exists() && await legacy.exists()) {
    try {
      await legacy.rename(d.path);
    } catch (_) {
      // 迁移失败时保留旧目录，后续在新目录重新开始
    }
  }
  return d;
}

/// 脚本 JSON 文件存储：应用文档目录/scripts/<名称>.bpc.json
class ScriptStorage {
  /// 测试注入：覆盖数据根目录（跳过 path_provider 插件）
  static Directory? _overrideDir;
  static void overrideDir(Directory dir) => _overrideDir = dir;

  Future<Directory> get dir async {
    final base = _overrideDir ?? await _appDataDir();
    final d = Directory('${base.path}/scripts');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<List<BlueprintScript>> listScripts() async {
    final d = await dir;
    final files = await d
        .list()
        .where((e) => e is File && e.path.endsWith('.bpc.json'))
        .cast<File>()
        .toList();
    final scripts = <BlueprintScript>[];
    for (final f in files) {
      try {
        final s = BlueprintScript.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
        scripts.add(s);
      } catch (_) {
        // 损坏文件跳过
      }
    }
    scripts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return scripts;
  }

  Future<void> save(BlueprintScript s) async {
    final d = await dir;
    s.updatedAt = DateTime.now();
    final f = File('${d.path}/${_safeName(s.name)}.bpc.json');
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()));
  }

  Future<void> rename(BlueprintScript s, String newName) async {
    final d = await dir;
    final old = File('${d.path}/${_safeName(s.name)}.bpc.json');
    s.name = newName;
    await save(s);
    if (old.path != '${d.path}/${_safeName(newName)}.bpc.json' && await old.exists()) {
      await old.delete();
    }
  }

  /// 是否已存在同名脚本（Windows 文件系统大小写不敏感，天然覆盖大小写冲突）
  Future<bool> exists(String name) async =>
      File('${(await dir).path}/${_safeName(name)}.bpc.json').exists();

  Future<void> delete(String name) async {
    final d = await dir;
    final f = File('${d.path}/${_safeName(name)}.bpc.json');
    if (await f.exists()) await f.delete();
  }

  Future<BlueprintScript?> load(String name) async {
    final d = await dir;
    final f = File('${d.path}/${_safeName(name)}.bpc.json');
    if (!await f.exists()) return null;
    return BlueprintScript.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
  }

  Future<BlueprintScript> duplicate(BlueprintScript s, String newName) async {
    final copy = s.copy()..name = newName;
    await save(copy);
    return copy;
  }

  /// 导出到用户选择的文件（file_selector 由 UI 层提供目标路径）
  Future<String> exportToString(BlueprintScript s) async =>
      const JsonEncoder.withIndent('  ').convert(s.toJson());

  Future<BlueprintScript> importFromString(String json, {String? fallbackName}) async {
    final s = BlueprintScript.fromJson(jsonDecode(json) as Map<String, dynamic>);
    var name = s.name.trim().isNotEmpty
        ? s.name
        : (fallbackName?.trim().isNotEmpty == true ? fallbackName! : '未命名');
    // 同名脚本自动加后缀，避免静默覆盖已有脚本
    if (await exists(name)) {
      var i = 2;
      while (await exists('$name ($i)')) {
        i++;
      }
      name = '$name ($i)';
    }
    s.name = name;
    await save(s);
    return s;
  }

  String _safeName(String name) {
    final n = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return n.isEmpty ? '未命名' : n;
  }
}

/// 录制会话持久化：应用文档目录/recordings/*.json
class RecordingStorage {
  /// 测试注入：覆盖数据根目录（跳过 path_provider 插件）
  static Directory? _overrideDir;
  static void overrideDir(Directory dir) => _overrideDir = dir;

  Future<Directory> get dir async {
    final base = _overrideDir ?? await _appDataDir();
    final d = Directory('${base.path}/recordings');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> save(Recording r) async {
    final d = await dir;
    final f = File('${d.path}/${r.id}.json');
    await f.writeAsString(jsonEncode(r.toJson()));
  }

  Future<Recording?> loadById(String id) async {
    final d = await dir;
    final f = File('${d.path}/$id.json');
    if (!await f.exists()) return null;
    try {
      return Recording.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<List<Recording>> list() async {
    final d = await dir;
    // 过滤非文件条目：目录混入会让 cast<File> 在迭代时抛 TypeError（列表整体报废）
    final files = await d.list().where((e) => e is File).cast<File>().toList();
    final out = <Recording>[];
    for (final f in files) {
      try {
        out.add(Recording.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>));
      } catch (_) {}
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<void> delete(String id) async {
    final d = await dir;
    final f = File('${d.path}/$id.json');
    if (await f.exists()) await f.delete();
  }

  /// 导出到用户选择的文件（file_selector 由 UI 层提供目标路径）
  Future<String> exportToString(Recording r) =>
      Future.value(const JsonEncoder.withIndent('  ').convert(r.toJson()));

  /// 从 JSON 字符串导入：重新生成 id 避免覆盖已有录制；名称为空用 [fallbackName]
  Future<Recording> importFromString(String json, {String? fallbackName}) async {
    final parsed = Recording.fromJson(jsonDecode(json) as Map<String, dynamic>);
    final name = parsed.name.trim().isNotEmpty
        ? parsed.name
        : (fallbackName ?? '').trim().isNotEmpty
        ? fallbackName!
        : '导入的录制';
    final r = Recording(
      id: 'r_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      createdAt: parsed.createdAt,
      actions: parsed.actions,
    );
    await save(r);
    return r;
  }
}

/// 数据存取节点的持久化 KV 存储：应用文档目录/data_store.json
class DataStore {
  static File? _file;
  static Directory? _overrideDir;

  /// 测试注入：覆盖存储目录（跳过 path_provider 插件）
  static void overrideDir(Directory dir) => _overrideDir = dir;

  static Future<File> get file async {
    if (_overrideDir != null) {
      final f = File('${_overrideDir!.path}/data_store.json');
      if (!await f.exists()) await f.create(recursive: true);
      return f;
    }
    if (_file != null) return _file!;
    final base = await _appDataDir();
    final f = File('${base.path}/data_store.json');
    if (!await f.exists()) await f.create(recursive: true);
    _file = f;
    return f;
  }

  static Future<Map<String, Object>> _readAll() async {
    final f = await file;
    if (!await f.exists() || (await f.length()) == 0) return {};
    try {
      return Map<String, Object>.from(jsonDecode(await f.readAsString()) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<void> set(String key, Object value) async {
    final all = await _readAll();
    all[key] = value;
    final f = await file;
    await f.writeAsString(jsonEncode(all));
  }

  static Future<Object?> get(String key) async => (await _readAll())[key];
}
