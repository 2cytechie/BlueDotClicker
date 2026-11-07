import 'dart:io';
import 'dart:typed_data';

import 'package:bluedot_clicker/services/file_saver.dart';
import 'package:bluedot_clicker/services/recognition.dart';
import 'package:flutter_test/flutter_test.dart';

/// SaveFileService 直接单测：验证数据保存节点的落盘链路
/// （保存位置 = <基目录>/save、同名加序号、文件名安全化）
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bpc_file_saver_test');
    SaveFileService.overrideDir(tmp);
  });

  tearDown(() async {
    SaveFileService.overrideDir(Directory.systemTemp.parent);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('保存目录为 <基目录>/save 且自动创建', () async {
    final dir = await SaveFileService().dir;
    // 实现用 '/' 拼接（dart:io 在 Windows 会规范化），按规范路径断言
    expect(dir.path, '${tmp.path}/save');
    expect(dir.existsSync(), isTrue);
  });

  test('saveText 写入 .txt 文件且内容正确', () async {
    final path = await SaveFileService().saveText('note', 'hello 世界');
    final f = File(path);
    expect(path, endsWith('note.txt'));
    expect(f.existsSync(), isTrue);
    expect(await f.readAsString(), 'hello 世界');
  });

  test('同名文件自动加序号，不覆盖', () async {
    final saver = SaveFileService();
    final p1 = await saver.saveText('note', 'v1');
    final p2 = await saver.saveText('note', 'v2');
    expect(p2, isNot(p1), reason: '同名必须生成新文件');
    expect(p2, endsWith('note-1.txt'));
    expect(await File(p1).readAsString(), 'v1', reason: '原文件不被覆盖');
    final p3 = await saver.saveText('note', 'v3');
    expect(p3, endsWith('note-2.txt'));
  });

  test('文件名非法字符替换、空名回退', () async {
    final saver = SaveFileService();
    final p1 = await saver.saveText('a/b:c*d', 'x');
    expect(p1, endsWith('a_b_c_d.txt'));
    final p2 = await saver.saveText('   ', 'x');
    expect(p2, endsWith('未命名.txt'));
  });

  test('savePng 写入合法 PNG 文件（魔数校验）', () async {
    // 2x2 纯蓝 BGRA
    final bgra = Uint8List.fromList([
      0xFF, 0x00, 0x00, 255, //
      0xFF, 0x00, 0x00, 255,
      0xFF, 0x00, 0x00, 255,
      0xFF, 0x00, 0x00, 255,
    ]);
    final path = await SaveFileService().savePng('shot', RawImage(2, 2, bgra));
    final f = File(path);
    expect(path, endsWith('shot.png'));
    expect(f.existsSync(), isTrue);
    final bytes = await f.readAsBytes();
    // PNG 魔数：89 50 4E 47
    expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  });
}
