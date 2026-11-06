/// 虚拟键（VK）码与中文名的映射，以及组合键的解析/格式化工具。
///
/// 纯 Dart 实现（不依赖 Flutter/Win32），便于在任意平台单测。
library;

/// 常用键下拉表（顺序即展示顺序）：修饰键 → 编辑键 → 方向键 → 功能键 → 字母 → 数字
final List<(int, String)> kCommonKeys = [
  (0x11, 'Ctrl'),
  (0x10, 'Shift'),
  (0x12, 'Alt'),
  (0x5B, 'Win'),
  (0x0D, 'Enter'),
  (0x1B, 'Esc'),
  (0x09, 'Tab'),
  (0x20, '空格'),
  (0x08, '退格'),
  (0x2D, 'Insert'),
  (0x2E, 'Delete'),
  (0x24, 'Home'),
  (0x23, 'End'),
  (0x21, 'PageUp'),
  (0x22, 'PageDown'),
  (0x25, '←'),
  (0x26, '↑'),
  (0x27, '→'),
  (0x28, '↓'),
  (0x70, 'F1'),
  (0x71, 'F2'),
  (0x72, 'F3'),
  (0x73, 'F4'),
  (0x74, 'F5'),
  (0x75, 'F6'),
  (0x76, 'F7'),
  (0x77, 'F8'),
  (0x78, 'F9'),
  (0x79, 'F10'),
  (0x7A, 'F11'),
  (0x7B, 'F12'),
  for (var i = 0; i < 26; i++) (0x41 + i, String.fromCharCode(0x41 + i)),
  for (var i = 0; i < 10; i++) (0x30 + i, '$i'),
];

/// 需要 KEYEVENTF_EXTENDEDKEY 标志的键（方向键/编辑键区、右 Ctrl/Alt、Win 等）。
/// 与 `platform/win32/user32.dart` 的判定保持一致并补充 Win/NumLock/PrintScreen。
const Set<int> kExtendedKeys = {
  0x21, // PageUp
  0x22, // PageDown
  0x23, // End
  0x24, // Home
  0x25, // ←
  0x26, // ↑
  0x27, // →
  0x28, // ↓
  0x2D, // Insert
  0x2E, // Delete
  0x2C, // PrintScreen
  0x5B, // 左 Win
  0x5C, // 右 Win
  0x5D, // Menu
  0x6F, // 数字键盘 /
  0x90, // NumLock
  0xA3, // 右 Ctrl
  0xA5, // 右 Alt
};

bool isExtendedKey(int vk) => kExtendedKeys.contains(vk);

final Map<int, String> _kKeyNames = {
  for (final (vk, name) in kCommonKeys) vk: name,
  0x03: 'Cancel',
  0x13: 'Pause',
  0x14: 'CapsLock',
  0xAD: '静音',
  0xAE: '音量-',
  0xAF: '音量+',
};

/// 键位显示名；未知 VK 显示十六进制，便于排查
String keyLabel(int vk) {
  if (vk <= 0) return '未设置';
  final name = _kKeyNames[vk];
  if (name != null) return name;
  return 'VK 0x${vk.toRadixString(16).toUpperCase()}';
}

/// 组合键显示：Ctrl + C
String formatKeyList(Iterable<int> keys, {String separator = ' + '}) =>
    keys.map(keyLabel).join(separator);

/// 组合键参数解析：兼容 List（正常存储）、逗号/加号分隔字符串（手工编辑/旧数据）
List<int> parseKeyList(Object? raw) {
  if (raw == null) return const [];
  Iterable<Object?> items;
  if (raw is List) {
    items = raw;
  } else if (raw is String) {
    items = raw.split(RegExp(r'[,，+\s]+')).where((e) => e.isNotEmpty);
  } else if (raw is num) {
    items = [raw];
  } else {
    return const [];
  }
  final out = <int>[];
  for (final item in items) {
    final vk = item is num ? item.toInt() : int.tryParse('$item'.trim());
    if (vk != null && vk > 0 && vk <= 0xFF && !out.contains(vk)) out.add(vk);
  }
  return out;
}
