import 'package:bluedot_clicker/models/key_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('键名映射', () {
    test('字母/数字/修饰键/功能键/方向键', () {
      expect(keyLabel(0x41), 'A');
      expect(keyLabel(0x5A), 'Z');
      expect(keyLabel(0x30), '0');
      expect(keyLabel(0x11), 'Ctrl');
      expect(keyLabel(0x10), 'Shift');
      expect(keyLabel(0x12), 'Alt');
      expect(keyLabel(0x70), 'F1');
      expect(keyLabel(0x7B), 'F12');
      expect(keyLabel(0x25), '←');
      expect(keyLabel(0x0D), 'Enter');
    });

    test('未设置与未知键', () {
      expect(keyLabel(0), '未设置');
      expect(keyLabel(0xFE), contains('0xFE'));
    });
  });

  group('扩展键判定', () {
    test('方向键/编辑键需要扩展标志', () {
      for (final vk in [0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E, 0x21, 0x22, 0x23, 0x24]) {
        expect(isExtendedKey(vk), isTrue, reason: 'VK 0x${vk.toRadixString(16)}');
      }
    });

    test('普通字母与通用修饰键不需要', () {
      expect(isExtendedKey(0x41), isFalse);
      expect(isExtendedKey(0x11), isFalse);
      expect(isExtendedKey(0x10), isFalse);
    });
  });

  group('组合键解析/格式化', () {
    test('List / 字符串 / null 三种输入', () {
      expect(parseKeyList([0x11, 0x43]), [0x11, 0x43]);
      expect(parseKeyList('17,67'), [0x11, 0x43]);
      expect(parseKeyList('17 + 67'), [0x11, 0x43]);
      expect(parseKeyList(null), isEmpty);
      expect(parseKeyList(''), isEmpty);
    });

    test('去重、过滤非法值', () {
      expect(parseKeyList([0x11, 0x11, 0x43]), [0x11, 0x43]);
      expect(parseKeyList([0, -1, 999, 0x41]), [0x41]);
    });

    test('格式化为可读文本', () {
      expect(formatKeyList([0x11, 0x43]), 'Ctrl + C');
      expect(formatKeyList([]), '');
    });
  });
}
