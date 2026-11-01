import 'dart:convert';
import 'dart:io';

import 'package:bluedot_clicker/models/blueprint.dart';
import 'package:bluedot_clicker/services/script_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late ScriptStorage scripts;
  late RecordingStorage recordings;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bpc_storage_test');
    ScriptStorage.overrideDir(tmp);
    RecordingStorage.overrideDir(tmp);
    scripts = ScriptStorage();
    recordings = RecordingStorage();
  });

  tearDown(() async {
    ScriptStorage.overrideDir(Directory.systemTemp.parent);
    RecordingStorage.overrideDir(Directory.systemTemp.parent);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  BlueprintScript makeScript(String name) => BlueprintScript(name: name)
    ..nodes['n_start'] = BPNode(id: 'n_start', type: 'start', x: 0, y: 0);

  group('ScriptStorage.exists', () {
    test('未保存的名字不存在，保存后存在', () async {
      expect(await scripts.exists('A'), isFalse);
      await scripts.save(makeScript('A'));
      expect(await scripts.exists('A'), isTrue);
      expect(await scripts.exists('B'), isFalse);
    });

    test('非法字符按 _safeName 语义判定', () async {
      await scripts.save(makeScript('A/B'));
      // "A:B" 与 "A/B" 都会清洗为 "A_B"，属同一文件
      expect(await scripts.exists('A:B'), isTrue);
    });
  });

  group('ScriptStorage.listScripts', () {
    test('损坏文件跳过 + 按 updatedAt 降序', () async {
      final a = makeScript('older');
      await scripts.save(a);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await scripts.save(makeScript('newer'));
      // 写入一个损坏文件
      await File('${(await scripts.dir).path}/broken.bpc.json')
          .writeAsString('not-json');

      final list = await scripts.listScripts();
      expect(list.map((s) => s.name), ['newer', 'older']);
    });
  });

  group('ScriptStorage.importFromString 同名冲突', () {
    test('与已有脚本同名时自动加 " (2)" 后缀，不覆盖旧脚本', () async {
      await scripts.save(makeScript('导入')..variables['keep'] = 1);
      final importedJson = jsonEncode(makeScript('导入').toJson());
      final imported = await scripts.importFromString(importedJson);

      expect(imported.name, '导入 (2)');
      final list = await scripts.listScripts();
      expect(list.length, 2, reason: '两个脚本都应存在');
      expect(list.map((s) => s.name), containsAll(['导入', '导入 (2)']));
      // 原脚本内容未被覆盖
      final original = await scripts.load('导入');
      expect(original!.variables['keep'], 1);
    });

    test('多次导入同名依次递增后缀', () async {
      final json = jsonEncode(makeScript('X').toJson());
      await scripts.importFromString(json);
      final second = await scripts.importFromString(json);
      final third = await scripts.importFromString(json);
      expect(second.name, 'X (2)');
      expect(third.name, 'X (3)');
    });

    test('JSON 名称为空时使用 fallbackName', () async {
      final s = makeScript('');
      final json = jsonEncode(s.toJson());
      final imported = await scripts.importFromString(json, fallbackName: '文件名');
      expect(imported.name, '文件名');
    });
  });

  group('RecordingStorage.list 目录混入防护', () {
    test('目录下存在子目录时不抛 TypeError，仅返回合法录制', () async {
      final r = Recording(
        id: 'r1',
        name: '录制一',
        createdAt: DateTime(2026, 1, 1),
        actions: const [RecClick(0, 10, 20)],
      );
      await recordings.save(r);
      // 模拟用户把文件夹拖进 recordings/
      await Directory('${(await recordings.dir).path}/子目录').create();

      // 修复前：cast<File> 在迭代到 Directory 时抛 TypeError，整个列表报废
      final list = await recordings.list();
      expect(list.length, 1);
      expect(list.first.id, 'r1');
    });
  });
}
