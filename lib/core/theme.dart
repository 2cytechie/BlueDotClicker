import 'package:flutter/material.dart';

/// 应用配色方案（取自用户提供的色卡 · 深海夜蓝暗色主题）
/// 深海夜蓝 #28314E 页面背景 | 柔空蓝 #658AE4 按钮背景/主强调 | 薄荷冰青 #A1FEEF 高亮色
abstract final class AppColors {
  static const ivory = Color(0xFF28314E); // 页面背景（深海夜蓝）
  static const moonWhite = Color(0xFF333D60); // 卡片/面板底色（夜蓝提亮一档）
  static const peacock = Color(0xFF658AE4); // 主强调色（柔空蓝 · 按钮背景）
  static const peacockDark = Color(0xFF5471CF); // 悬停/按下（柔空蓝加深）
  static const peacockDeep = Color(0xFF46609F); // 深强调（柔空蓝再加深）
  static const ink = Color(0xFFECF0FA); // 主文字（浅）
  static const inkSecondary = Color(0xFFA9B4D6); // 次级文字
  static const outline = Color(0xFF46527A); // 描边
  static const canvasBg = Color(0xFF212942); // 画布/日志背景（夜蓝加深一档）
  static const danger = Color(0xFFE0685A); // 危险操作（珊瑚红提亮适配暗底）
  static const success = Color(0xFF4CC79A); // 成功状态（青绿提亮适配暗底）

  /// 五类节点辅助色（深海夜蓝色系协调衍生，均配白色节点标题文字）
  static const nodeInteraction = Color(0xFF658AE4); // 交互：柔空蓝
  static const nodeMedia = Color(0xFF3FA0D6); // 媒体：海青
  static const nodeLogic = Color(0xFF7E93C2); // 逻辑：雾蓝
  static const nodeData = Color(0xFF2FA98A); // 数据：青玉
  static const nodeScript = Color(0xFF9A7ED8); // 脚本：岩紫

  /// 执行流连线（柔空蓝）与数据连线（青玉虚线）
  static const execWire = peacock;
  static const dataWire = nodeData;
}

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'MiSans',
    fontFamilyFallback: const [
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Segoe UI',
    ],
    colorScheme: ColorScheme.dark(
      primary: AppColors.peacock,
      onPrimary: Colors.white,
      primaryContainer: Colors.white,
      onPrimaryContainer: AppColors.ivory,
      secondary: AppColors.nodeData,
      onSecondary: Colors.white,
      surface: AppColors.ivory,
      onSurface: AppColors.ink,
      surfaceContainerHighest: AppColors.moonWhite,
      onSurfaceVariant: AppColors.inkSecondary,
      outline: AppColors.outline,
      error: AppColors.danger,
    ),
    scaffoldBackgroundColor: AppColors.ivory,
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.ivory,
      foregroundColor: AppColors.ink,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: AppColors.moonWhite,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.peacock, // 按钮背景：柔空蓝
        foregroundColor: Colors.white, // 按钮内字体/图标：白色
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: AppColors.peacock),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 106, vertical: 12),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.ivory,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.peacock, width: 2),
      ),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.outline,
      thickness: 1,
      space: 1,
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: AppColors.peacock,
      thumbColor: AppColors.peacockDeep,
      inactiveTrackColor: AppColors.outline,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.peacockDeep,
      contentTextStyle: TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
