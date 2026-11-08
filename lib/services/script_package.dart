import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/blueprint.dart';
import 'script_storage.dart';
import 'template_storage.dart';

/// 脚本包（.bpc.zip）相关错误：消息可直接展示给用户
class PackageException implements Exception {
  const PackageException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 导出时缺失的引用（弹确认框列出）
class PackageMissing {
  final List<String> recordings;
  final List<String> templates;
  const PackageMissing({
    this.recordings = const [],
    this.templates = const [],
  });

  bool get isEmpty => recordings.isEmpty && templates.isEmpty;
}

class PackageBuildResult {
  final Uint8List bytes;
  final PackageMissing missing;
  const PackageBuildResult(this.bytes, this.missing);
}

/// 导入结果摘要
class PackageImportResult {
  final String scriptName;
  final int recordingsAdded;
  final int recordingsReused;
  final int recordingsRemapped;
  final int templatesAdded;
  final int templatesReused;
  final List<String> danglingRecordings;
  final List<String> danglingTemplates;

  const PackageImportResult({
    required this.scriptName,
    this.recordingsAdded = 0,
    this.recordingsReused = 0,
    this.recordingsRemapped = 0,
    this.templatesAdded = 0,
    this.templatesReused = 0,
    this.danglingRecordings = const [],
    this.danglingTemplates = const [],
  });

  bool get hasDangling =>
      danglingRecordings.isNotEmpty || danglingTemplates.isNotEmpty;
}

/// 蓝图脚本 ZIP 包：内嵌被引用的录制与模板图片。
///
/// 包结构：
/// ```
/// <脚本名>.bpc.zip
/// ├─ manifest.json
/// ├─ script.bpc.json
/// ├─ recordings/<recordingId>.json
/// └─ templates/<sha256>.<ext>
/// ```
class ScriptPackage {
  ScriptPackage({
    RecordingStorage? recordings,
    TemplateStorage? templates,
    ScriptStorage? scripts,
  }) : _recordings = recordings ?? RecordingStorage(),
       _templates = templates ?? TemplateStorage(),
       _scripts = scripts ?? ScriptStorage();

  final RecordingStorage _recordings;
  final TemplateStorage _templates;
  final ScriptStorage _scripts;

  static const String manifestFormat = 'bpcpack';
  static const int manifestVersion = 1;
  static const int maxEntries = 300;
  static const int maxEntryBytes = 10 * 1024 * 1024;
  static const int maxTotalBytes = 100 * 1024 * 1024;
  static const String _scriptEntry = 'script.bpc.json';
  static const String _manifestEntry = 'manifest.json';

  /// 是否为 zip 文件头（PK\x03\x04）
  static bool isZipBytes(List<int> bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04;

  // ---- 导出 ----

  Future<PackageBuildResult> build(BlueprintScript script) async {
    final recordingIds = <String>{};
    final templatePaths = <String>{};
    for (final n in script.nodes.values) {
      if (n.type == 'playRecording') {
        final id = ((n.params['recordingId'] as String?) ?? '').trim();
        if (id.isNotEmpty) recordingIds.add(id);
      } else if (n.type == 'imageMatch') {
        final path = ((n.params['templatePath'] as String?) ?? '').trim();
        if (path.isNotEmpty) templatePaths.add(path);
      }
    }

    final missingRecordings = <String>[];
    final recordingFiles = <String, Uint8List>{};
    for (final id in recordingIds) {
      final rec = await _recordings.loadById(id);
      if (rec == null) {
        missingRecordings.add(id);
        continue;
      }
      recordingFiles[id] = Uint8List.fromList(
        utf8.encode(jsonEncode(rec.toJson())),
      );
    }

    final missingTemplates = <String>[];
    final templateFiles = <String, Uint8List>{};
    final pathToEntry = <String, String>{};
    for (final path in templatePaths) {
      final ext = TemplateStorage.extensionOf(path);
      if (ext == null) {
        missingTemplates.add(path);
        continue;
      }
      try {
        final bytes = await File(path).readAsBytes();
        final hash = TemplateStorage.sha256Hex(bytes);
        final name = '$hash.$ext';
        templateFiles.putIfAbsent(name, () => bytes);
        pathToEntry[path] = name;
      } catch (_) {
        missingTemplates.add(path);
      }
    }

    // 打包用脚本副本：已存在模板的路径改为包内相对路径，导入时再改写为本机绝对路径
    final packed = script.copy();
    for (final n in packed.nodes.values) {
      if (n.type != 'imageMatch') continue;
      final path = ((n.params['templatePath'] as String?) ?? '').trim();
      final entry = pathToEntry[path];
      if (entry != null) n.params['templatePath'] = 'templates/$entry';
    }

    final manifest = <String, Object?>{
      'format': manifestFormat,
      'version': manifestVersion,
      'type': 'script',
      'scriptName': script.name,
      'recordingIds': recordingFiles.keys.toList(),
      'templates': templateFiles.keys.toList(),
      'createdAt': DateTime.now().toIso8601String(),
    };

    // 脚本 JSON 统一走 ScriptStorage.exportToString，与纯 JSON 导出共用一条序列化路径
    final scriptJson = await _scripts.exportToString(packed);
    final archive = Archive()
      ..add(
        ArchiveFile.string(
          _manifestEntry,
          const JsonEncoder.withIndent('  ').convert(manifest),
        ),
      )
      ..add(ArchiveFile.string(_scriptEntry, scriptJson));
    recordingFiles.forEach((id, bytes) {
      archive.add(ArchiveFile.bytes('recordings/$id.json', bytes));
    });
    templateFiles.forEach((name, bytes) {
      archive.add(ArchiveFile.bytes('templates/$name', bytes));
    });

    final zip = Uint8List.fromList(ZipEncoder().encode(archive));
    return PackageBuildResult(
      zip,
      PackageMissing(
        recordings: missingRecordings,
        templates: missingTemplates,
      ),
    );
  }

  // ---- 导入 ----

  Future<PackageImportResult> importZip(
    Uint8List bytes, {
    String? fallbackName,
  }) async {
    final entries = _decodeAndValidate(bytes);
    final scriptBytes = entries[_scriptEntry];
    if (scriptBytes == null) {
      throw const PackageException('压缩包内缺少 script.bpc.json');
    }
    final script = BlueprintScript.fromJson(_jsonMap(scriptBytes, _scriptEntry));

    Map<String, Object?>? manifest;
    final manifestBytes = entries[_manifestEntry];
    if (manifestBytes != null) {
      manifest = _jsonMap(manifestBytes, _manifestEntry);
      if (manifest['format'] != manifestFormat ||
          manifest['version'] != manifestVersion ||
          manifest['type'] != 'script') {
        throw const PackageException('manifest.json 格式不支持');
      }
    }

    // 1. 模板完整性先全部校验（任何篡改都在写盘前整体失败）
    final templates = <String, (String hash, String ext, Uint8List bytes)>{};
    for (final entry in entries.entries) {
      final name = entry.key;
      if (!name.startsWith('templates/')) continue;
      final file = name.substring('templates/'.length);
      final dot = file.lastIndexOf('.');
      final hash = file.substring(0, dot);
      final ext = file.substring(dot + 1).toLowerCase();
      final actual = TemplateStorage.sha256Hex(entry.value);
      if (actual != hash) {
        throw PackageException('模板校验失败：$name（内容与文件名哈希不一致）');
      }
      templates[name] = (hash, ext, entry.value);
    }

    // 2. 录制解析（仅接受 recordings/<id>.json）
    final incoming = <String, Recording>{};
    for (final entry in entries.entries) {
      final name = entry.key;
      if (!name.startsWith('recordings/')) continue;
      final id = name.substring('recordings/'.length, name.length - '.json'.length);
      final map = _jsonMap(entry.value, name);
      final Recording parsed;
      try {
        parsed = Recording.fromJson(map);
      } catch (_) {
        throw PackageException('录制文件损坏：$name');
      }
      incoming[id] = Recording(
        id: id,
        name: parsed.name,
        createdAt: parsed.createdAt,
        actions: parsed.actions,
      );
    }

    // 3. 冲突判定与 id 重映射（全部只读，不写盘）
    final remap = <String, String>{};
    final toWrite = <Recording>[];
    final usedIds = <String>{...incoming.keys};
    var added = 0;
    var reused = 0;
    for (final entry in incoming.entries) {
      final id = entry.key;
      final rec = entry.value;
      final local = await _recordings.loadById(id);
      if (local == null) {
        toWrite.add(rec);
        added++;
      } else if (_sameActions(local, rec)) {
        reused++;
      } else {
        var seq = 0;
        String newId;
        do {
          newId = 'r_${DateTime.now().millisecondsSinceEpoch}_$seq';
          seq++;
        } while (usedIds.contains(newId) ||
            await _recordings.loadById(newId) != null);
        usedIds.add(newId);
        remap[id] = newId;
        toWrite.add(
          Recording(
            id: newId,
            name: rec.name,
            createdAt: rec.createdAt,
            actions: rec.actions,
          ),
        );
        added++;
      }
    }

    // 4. 模板写盘计划（已存在复用）
    final templateWrites = <(String hash, String ext, Uint8List bytes)>[];
    var templatesAdded = 0;
    var templatesReused = 0;
    for (final t in templates.values) {
      final path = await _templates.pathFor(t.$1, t.$2);
      if (await File(path).exists()) {
        templatesReused++;
      } else {
        templatesAdded++;
        templateWrites.add(t);
      }
    }

    // 5. 改写脚本引用：录制 id 映射 + 包内模板相对路径 → 本机绝对路径
    for (final n in script.nodes.values) {
      if (n.type == 'playRecording') {
        final id = ((n.params['recordingId'] as String?) ?? '').trim();
        final mapped = remap[id];
        if (mapped != null) n.params['recordingId'] = mapped;
      } else if (n.type == 'imageMatch') {
        final path = ((n.params['templatePath'] as String?) ?? '').trim();
        if (path.startsWith('templates/')) {
          final file = path.substring('templates/'.length);
          final dot = file.lastIndexOf('.');
          if (dot > 0) {
            final hash = file.substring(0, dot);
            final ext = file.substring(dot + 1).toLowerCase();
            n.params['templatePath'] = await _templates.pathFor(hash, ext);
          }
        }
      }
    }

    var scriptName = script.name.trim();
    if (scriptName.isEmpty) {
      final fromManifest = (manifest?['scriptName'] as String?)?.trim() ?? '';
      scriptName = fromManifest.isNotEmpty
          ? fromManifest
          : (fallbackName?.trim().isNotEmpty == true
                ? fallbackName!.trim()
                : '未命名');
    }
    script.name = scriptName;

    // 6. 全部解析/校验/改写完成，开始写盘：先录制与模板，最后脚本
    for (final rec in toWrite) {
      await _recordings.save(rec);
    }
    for (final t in templateWrites) {
      await _templates.ensure(hash: t.$1, ext: t.$2, bytes: t.$3);
    }
    final saved = await _scripts.importFromString(
      await _scripts.exportToString(script),
      fallbackName: scriptName,
    );

    final dangling = await danglingReferences(saved);
    return PackageImportResult(
      scriptName: saved.name,
      recordingsAdded: added,
      recordingsReused: reused,
      recordingsRemapped: remap.length,
      templatesAdded: templatesAdded,
      templatesReused: templatesReused,
      danglingRecordings: dangling.$1,
      danglingTemplates: dangling.$2,
    );
  }

  /// 导入纯 .bpc.json（兼容旧格式），并报告悬空引用
  Future<PackageImportResult> importJson(
    String json, {
    String? fallbackName,
  }) async {
    final saved = await _scripts.importFromString(
      json,
      fallbackName: fallbackName,
    );
    final dangling = await danglingReferences(saved);
    return PackageImportResult(
      scriptName: saved.name,
      danglingRecordings: dangling.$1,
      danglingTemplates: dangling.$2,
    );
  }

  /// 找出本机找不到的录制/模板引用
  Future<(List<String>, List<String>)> danglingReferences(
    BlueprintScript script,
  ) async {
    final recordings = <String>{};
    final templates = <String>{};
    for (final n in script.nodes.values) {
      if (n.type == 'playRecording') {
        final id = ((n.params['recordingId'] as String?) ?? '').trim();
        if (id.isNotEmpty && await _recordings.loadById(id) == null) {
          recordings.add(id);
        }
      } else if (n.type == 'imageMatch') {
        final path = ((n.params['templatePath'] as String?) ?? '').trim();
        if (path.isEmpty) continue;
        if (path.startsWith('templates/') ||
            !await File(path).exists()) {
          templates.add(path);
        }
      }
    }
    return (recordings.toList(), templates.toList());
  }

  // ---- 内部 ----

  static bool _sameActions(Recording a, Recording b) =>
      jsonEncode(a.actions.map((x) => x.toJson()).toList()) ==
      jsonEncode(b.actions.map((x) => x.toJson()).toList());

  Map<String, dynamic> _jsonMap(Uint8List bytes, String name) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) throw const FormatException();
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      throw PackageException('$name 不是有效的 JSON');
    }
  }

  /// 解压并校验条目：只接受固定四类条目，拒绝绝对路径/.. /目录/未知条目。
  Map<String, Uint8List> _decodeAndValidate(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const PackageException('不是有效的 ZIP 文件');
    }
    if (archive.files.length > maxEntries) {
      throw const PackageException('压缩包条目过多（上限 $maxEntries）');
    }
    final out = <String, Uint8List>{};
    var total = 0;
    for (final entry in archive.files) {
      if (!entry.isFile) {
        throw const PackageException('压缩包内不允许目录条目');
      }
      final name = entry.name.replaceAll('\\', '/');
      if (name.isEmpty || name.endsWith('/')) {
        throw const PackageException('压缩包内存在无效条目');
      }
      if (name.startsWith('/') ||
          RegExp(r'^[A-Za-z]:').hasMatch(name) ||
          name.split('/').contains('..')) {
        throw PackageException('压缩包内存在非法路径：$name');
      }
      if (!_isAllowedEntry(name)) {
        throw PackageException('压缩包内存在未知条目：$name');
      }
      if (out.containsKey(name)) {
        throw PackageException('压缩包内条目重复：$name');
      }
      if (entry.size > maxEntryBytes) {
        throw PackageException('条目过大：$name');
      }
      if (entry.size > 0) {
        total += entry.size;
        if (total > maxTotalBytes) {
          throw const PackageException('解压总量超限');
        }
      }
      final data = entry.readBytes();
      if (data == null) {
        throw PackageException('无法读取条目：$name');
      }
      if (data.length > maxEntryBytes) {
        throw PackageException('条目过大：$name');
      }
      out[name] = data;
    }
    return out;
  }

  static bool _isAllowedEntry(String name) {
    if (name == _manifestEntry || name == _scriptEntry) return true;
    if (name.startsWith('recordings/')) {
      final rest = name.substring('recordings/'.length);
      return rest.isNotEmpty &&
          !rest.contains('/') &&
          rest.endsWith('.json') &&
          rest.length > '.json'.length;
    }
    if (name.startsWith('templates/')) {
      final rest = name.substring('templates/'.length);
      if (rest.contains('/')) return false;
      final dot = rest.lastIndexOf('.');
      if (dot <= 0) return false;
      final hash = rest.substring(0, dot);
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) return false;
      final ext = rest.substring(dot + 1).toLowerCase();
      return TemplateStorage.allowedExtensions.contains(ext);
    }
    return false;
  }
}
