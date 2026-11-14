import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:bluedot_clicker/models/blueprint.dart';
import 'package:bluedot_clicker/services/script_package.dart';
import 'package:bluedot_clicker/services/script_storage.dart';
import 'package:bluedot_clicker/services/template_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late ScriptStorage scripts;
  late RecordingStorage recordings;
  late TemplateStorage templates;
  late ScriptPackage pkg;

  void useDir(Directory dir) {
    ScriptStorage.overrideDir(dir);
    RecordingStorage.overrideDir(dir);
    TemplateStorage.overrideDir(dir);
    scripts = ScriptStorage();
    recordings = RecordingStorage();
    templates = TemplateStorage();
    pkg = ScriptPackage(
      recordings: recordings,
      templates: templates,
      scripts: scripts,
    );
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bpc_pkg_test');
    useDir(tmp);
  });

  tearDown(() async {
    ScriptStorage.overrideDir(Directory.systemTemp.parent);
    RecordingStorage.overrideDir(Directory.systemTemp.parent);
    TemplateStorage.overrideDir(Directory.systemTemp.parent);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Recording makeRecording(String id, {int x = 10}) => Recording(
    id: id,
    name: id,
    createdAt: DateTime(2026, 1, 1),
    actions: [RecClick(0, x, 20)],
  );

  Future<String> writeTemplate(String name, List<int> bytes) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  BlueprintScript scriptWith({
    List<String> recordingIds = const [],
    List<String> templatePaths = const [],
  }) {
    final s = BlueprintScript(name: '打包测试');
    var i = 0;
    for (final id in recordingIds) {
      i++;
      s.nodes['pr$i'] = BPNode(
        id: 'pr$i',
        type: 'playRecording',
        params: {'recordingId': id},
      );
    }
    for (final path in templatePaths) {
      i++;
      s.nodes['im$i'] = BPNode(
        id: 'im$i',
        type: 'imageMatch',
        params: {'templatePath': path},
      );
    }
    return s;
  }

  List<String> zipNames(Uint8List bytes) =>
      ZipDecoder().decodeBytes(bytes).files.map((f) => f.name).toList();

  Uint8List makeZip(Map<String, List<int>> files) {
    final archive = Archive();
    files.forEach((name, bytes) {
      archive.add(ArchiveFile.bytes(name, bytes));
    });
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  List<File> allFiles(Directory dir) => dir.existsSync()
      ? dir.listSync(recursive: true).whereType<File>().toList()
      : const [];

  group('导出', () {
    test('只打包被蓝图引用的录制', () async {
      await recordings.save(makeRecording('r1'));
      await recordings.save(makeRecording('r2'));
      await recordings.save(makeRecording('unused'));

      final result = await pkg.build(scriptWith(recordingIds: ['r1', 'r2']));
      final names = zipNames(result.bytes);
      expect(names, containsAll(['manifest.json', 'script.bpc.json']));
      expect(names, containsAll(['recordings/r1.json', 'recordings/r2.json']));
      expect(names, isNot(contains('recordings/unused.json')));
      expect(result.missing.isEmpty, isTrue);
    });

    test('缺失录制进入缺失清单，zip 中不含该录制', () async {
      final result = await pkg.build(scriptWith(recordingIds: ['ghost']));
      expect(result.missing.recordings, ['ghost']);
      expect(
        zipNames(result.bytes).any((n) => n.startsWith('recordings/')),
        isFalse,
      );
    });

    test('内容相同、路径不同的模板只打包一份', () async {
      final p1 = await writeTemplate('a.png', [1, 2, 3]);
      final p2 = await writeTemplate('b.png', [1, 2, 3]);
      final result = await pkg.build(scriptWith(templatePaths: [p1, p2]));
      final templateEntries = zipNames(
        result.bytes,
      ).where((n) => n.startsWith('templates/'));
      expect(templateEntries.length, 1);
      expect(result.missing.isEmpty, isTrue);
    });

    test('缺失模板进入缺失清单，引用原样保留', () async {
      final result = await pkg.build(
        scriptWith(templatePaths: ['${tmp.path}/no-such.png']),
      );
      expect(result.missing.templates, hasLength(1));
      expect(
        zipNames(result.bytes).any((n) => n.startsWith('templates/')),
        isFalse,
      );
    });
  });

  group('导入', () {
    test('往返：空机器导入后录制可加载、模板指向本机目录', () async {
      await recordings.save(makeRecording('r1'));
      final original = await writeTemplate('tpl.png', [9, 8, 7]);
      final tplPath = await templates.importFile(original);
      await File(original).delete();
      final result = await pkg.build(
        scriptWith(recordingIds: ['r1'], templatePaths: [tplPath]),
      );

      final target = await Directory.systemTemp.createTemp('bpc_pkg_target');
      addTearDown(() async {
        try {
          await target.delete(recursive: true);
        } catch (_) {}
      });
      useDir(target);
      final imported = await pkg.importZip(result.bytes);
      expect(imported.recordingsAdded, 1);
      expect(imported.templatesAdded, 1);

      final list = await scripts.listScripts();
      final s = list.single;
      final recordingId = s.nodes['pr1']!.params['recordingId'] as String;
      expect(await recordings.loadById(recordingId), isNotNull);

      final path = s.nodes['im2']!.params['templatePath'] as String;
      expect(path.startsWith((await templates.dirPath)), isTrue);
      expect(File(path).existsSync(), isTrue);
      expect(await File(path).readAsBytes(), [9, 8, 7]);
    });

    test('冲突复用：同 id 同 actions 不新增文件、引用不变', () async {
      await recordings.save(makeRecording('r1'));
      final result = await pkg.build(scriptWith(recordingIds: ['r1']));

      final target = await Directory.systemTemp.createTemp('bpc_pkg_reuse');
      addTearDown(() async {
        try {
          await target.delete(recursive: true);
        } catch (_) {}
      });
      useDir(target);
      await recordings.save(makeRecording('r1'));

      final imported = await pkg.importZip(result.bytes);
      expect(imported.recordingsAdded, 0);
      expect(imported.recordingsReused, 1);
      expect(imported.recordingsRemapped, 0);
      final list = await scripts.listScripts();
      expect(list.single.nodes['pr1']!.params['recordingId'], 'r1');
      final files = allFiles(Directory('${target.path}/recordings'));
      expect(files.length, 1);
    });

    test('冲突改写：同 id 不同 actions 新建 id 并改写节点引用', () async {
      await recordings.save(makeRecording('r1', x: 10));
      final result = await pkg.build(scriptWith(recordingIds: ['r1']));

      final target = await Directory.systemTemp.createTemp('bpc_pkg_remap');
      addTearDown(() async {
        try {
          await target.delete(recursive: true);
        } catch (_) {}
      });
      useDir(target);
      await recordings.save(makeRecording('r1', x: 999));

      final imported = await pkg.importZip(result.bytes);
      expect(imported.recordingsAdded, 1);
      expect(imported.recordingsRemapped, 1);

      final list = await scripts.listScripts();
      final newId = list.single.nodes['pr1']!.params['recordingId'] as String;
      expect(newId, isNot('r1'));
      final loaded = await recordings.loadById(newId);
      expect(loaded, isNotNull);
      expect((loaded!.actions.single as RecClick).x, 10);
      // 原录制内容不被覆盖
      final original = await recordings.loadById('r1');
      expect((original!.actions.single as RecClick).x, 999);
    });

    test('模板篡改：整体失败且不写任何文件', () async {
      final wrongHash = TemplateStorage.sha256Hex([1, 2, 3]);
      final zip = makeZip({
        'script.bpc.json': utf8.encode(
          jsonEncode(BlueprintScript(name: 'tamper').toJson()),
        ),
        'templates/$wrongHash.png': [9, 9, 9],
      });
      await expectLater(pkg.importZip(zip), throwsA(isA<PackageException>()));
      expect(allFiles(tmp), isEmpty);
    });

    test('安全：含 ../ 的条目被拒绝且不写文件', () async {
      final zip = makeZip({
        'script.bpc.json': utf8.encode(
          jsonEncode(BlueprintScript(name: 'evil').toJson()),
        ),
        '../evil.json': [1, 2],
      });
      await expectLater(pkg.importZip(zip), throwsA(isA<PackageException>()));
      expect(allFiles(tmp), isEmpty);
    });

    test('安全：绝对路径与反斜杠 .. 条目被拒绝且不写文件', () async {
      // 三种条目分别命中三个拒绝分支：
      // '/abs/evil.json' → 以 / 开头；'C:\evil.json' → 盘符正则（\ 归一为 / 后）；
      // '..\evil.json' → 反斜杠归一化后命中 .. 段
      const evilEntries = ['/abs/evil.json', 'C:\\evil.json', '..\\evil.json'];
      for (final evil in evilEntries) {
        final zip = makeZip({
          'script.bpc.json': utf8.encode(
            jsonEncode(BlueprintScript(name: 'evil-abs').toJson()),
          ),
          evil: [1, 2],
        });
        await expectLater(
          pkg.importZip(zip),
          throwsA(isA<PackageException>()),
          reason: '条目 "$evil" 应被拒绝',
        );
        expect(allFiles(tmp), isEmpty, reason: '条目 "$evil" 被拒绝后不应写盘');
      }
    });

    test('缺少 script.bpc.json 整体失败', () async {
      final zip = makeZip({
        'manifest.json': utf8.encode(
          jsonEncode({'format': 'bpcpack', 'version': 1, 'type': 'script'}),
        ),
      });
      await expectLater(pkg.importZip(zip), throwsA(isA<PackageException>()));
    });

    test('manifest 损坏整体失败', () async {
      final zip = makeZip({
        'manifest.json': utf8.encode('not-json'),
        'script.bpc.json': utf8.encode(
          jsonEncode(BlueprintScript(name: 'bad-manifest').toJson()),
        ),
      });
      await expectLater(pkg.importZip(zip), throwsA(isA<PackageException>()));
    });

    test('条目数超限整体失败', () async {
      final files = <String, List<int>>{
        'script.bpc.json': utf8.encode(
          jsonEncode(BlueprintScript(name: 'too-many').toJson()),
        ),
      };
      for (var i = 0; i <= ScriptPackage.maxEntries; i++) {
        files['recordings/r$i.json'] = utf8.encode('{}');
      }
      await expectLater(
        pkg.importZip(makeZip(files)),
        throwsA(isA<PackageException>()),
      );
      expect(allFiles(tmp), isEmpty);
    });

    test('纯 .bpc.json 导入仍可用，并报告悬空引用', () async {
      final script = scriptWith(recordingIds: ['ghost']);
      final result = await pkg.importJson(jsonEncode(script.toJson()));
      expect(result.scriptName, '打包测试');
      expect(result.danglingRecordings, ['ghost']);
      final list = await scripts.listScripts();
      expect(list.length, 1);
    });
  });
}
