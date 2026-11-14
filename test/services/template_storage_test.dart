import 'dart:io';

import 'package:bluedot_clicker/services/template_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late TemplateStorage storage;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bpc_template_test');
    TemplateStorage.overrideDir(tmp);
    storage = TemplateStorage();
  });
  tearDown(() async {
    TemplateStorage.overrideDir(Directory.systemTemp.parent);
    await tmp.delete(recursive: true);
  });

  for (final ext in ['PNG', 'jpg', 'jpeg', 'bmp']) {
    test('保存 $ext 副本，删除原图后内容保留，重复导入复用', () async {
      final source = File('${tmp.path}/source.$ext');
      const bytes = [1, 2, 3, 4];
      await source.writeAsBytes(bytes);
      final path = await storage.importFile(source.path);
      expect(
        path,
        await storage.pathFor(
          TemplateStorage.sha256Hex(bytes),
          ext.toLowerCase(),
        ),
      );
      expect(await storage.importFile(source.path), path);
      // 已在模板目录的文件也可再次选择，不会截断自身。
      expect(await storage.importFile(path), path);
      await source.delete();
      expect(await File(path).readAsBytes(), bytes);
      expect(await Directory(await storage.dirPath).list().length, 1);
    });
  }

  test('不支持的格式不创建模板', () async {
    await expectLater(
      storage.importFile('${tmp.path}/a.gif'),
      throwsFormatException,
    );
    expect(await Directory(await storage.dirPath).exists(), isFalse);
  });

  test('源文件不存在时不创建模板', () async {
    await expectLater(
      storage.importFile('${tmp.path}/missing.png'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await Directory(await storage.dirPath).exists(), isFalse);
  });

  test('目标目录不可写入时抛出错误，保留原图', () async {
    final source = File('${tmp.path}/source.png');
    await source.writeAsBytes([1, 2, 3]);
    // 用同名文件阻止 templates 目录创建，避免依赖机器的权限设置。
    await File(await storage.dirPath).writeAsString('blocked');
    await expectLater(
      storage.importFile(source.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(await source.readAsBytes(), [1, 2, 3]);
  });
}
