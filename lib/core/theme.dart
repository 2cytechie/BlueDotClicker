import 'package:flutter/material.dart';

/// 蓝点器设计系统 · 深海夜航（Deep Sea Night）
///
/// 配色逻辑沿用：深海夜蓝页面背景 + 柔空蓝主强调 + 白色按钮文字/图标。
/// 其余颜色均由该逻辑派生为语义令牌（背景层级 / 文字层级 / 描边 / 状态 /
/// 阴影 / 节点类别），页面与组件只引用令牌，不再写死色值。
abstract final class AppColors {
  // ── 背景层级（由深到浅）────────────────────────────────────────────
  static const abyss = Color(0xFF1B2338); // 最深：悬浮条/日志/遮罩
  static const canvasBg = Color(0xFF212942); // 画布与凹陷区
  static const ivory = Color(0xFF28314E); // 页面背景（深海夜蓝）
  static const moonWhite = Color(0xFF333D60); // 卡片/面板底色
  static const surfaceRaised = Color(0xFF3C4870); // 浮起层（悬停/表头）
  static const surfaceHover = Color(0xFF3A4569); // 列表悬停

  // ── 主强调（柔空蓝）───────────────────────────────────────────────
  static const peacock = Color(0xFF658AE4); // 主强调 / 按钮背景
  static const peacockHover = Color(0xFF7A9CF0); // 悬停
  static const peacockDark = Color(0xFF5471CF); // 按下
  static const peacockDeep = Color(0xFF46609F); // 深强调
  static const peacockSoft = Color(0xFF2E3B62); // 强调容器底（选中/提示）

  // ── 文字层级 ─────────────────────────────────────────────────────
  static const ink = Color(0xFFECF0FA); // 主文字
  static const inkSecondary = Color(0xFFA9B4D6); // 次级文字
  static const inkMuted = Color(0xFF7E8BB3); // 弱化文字/占位
  static const onAccent = Color(0xFFFFFFFF); // 强调底上的文字/图标
  static const onAccentMuted = Color(0xB8FFFFFF); // 强调底上的弱化文字

  // ── 描边 ─────────────────────────────────────────────────────────
  static const outline = Color(0xFF46527A); // 常规描边
  static const outlineSubtle = Color(0xFF3B466B); // 细分隔/卡片描边
  static const outlineStrong = Color(0xFF5C6B98); // 强调描边/滚动条

  // ── 状态 ─────────────────────────────────────────────────────────
  static const danger = Color(0xFFE0685A); // 危险
  static const dangerSoft = Color(0xFF4A2F35); // 危险容器底
  static const warning = Color(0xFFE7B75F); // 警告
  static const warningSoft = Color(0xFF463A26); // 警告容器底
  static const success = Color(0xFF4CC79A); // 成功
  static const successSoft = Color(0xFF24453C); // 成功容器底
  static const info = peacock; // 信息（复用主强调）

  // ── 阴影 ─────────────────────────────────────────────────────────
  static const shadow = Color(0x40000000); // 浮层投影
  static const shadowSoft = Color(0x1F000000); // 卡片投影

  // ── 五类节点辅助色（柔空蓝体系协调衍生，均配白色标题）──────────────
  static const nodeInteraction = Color(0xFF658AE4); // 交互：柔空蓝
  static const nodeMedia = Color(0xFF3FA0D6); // 媒体：海青
  static const nodeLogic = Color(0xFF7E93C2); // 逻辑：雾蓝
  static const nodeData = Color(0xFF2FA98A); // 数据：青玉
  static const nodeScript = Color(0xFF9A7ED8); // 脚本：岩紫

  // ── 连线 ─────────────────────────────────────────────────────────
  static const execWire = peacock; // 端口色：执行流（柔空蓝）
  static const dataWire = nodeData; // 端口色：数据流（青玉）
  static const imageWire = Color(0xFFE8B45C); // 端口色：图像数据（琥珀金）
  static const execWireLine = onAccent; // 画布连线：执行流（白）
  static const dataWireLine = success; // 画布连线：数据流（绿）
  static const imageWireLine = imageWire; // 画布连线：图像数据（与端口同色）
}

/// 8pt 体系间距令牌。
abstract final class AppSpacing {
  static const xxs = 4.0;
  static const xs = 6.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const huge = 32.0;

  /// 主页面统一内边距（左右 32 / 上下 28）。
  static const pagePadding = EdgeInsets.symmetric(
    horizontal: huge,
    vertical: 28,
  );
}

/// 统一圆角令牌。
abstract final class AppRadius {
  static const sm = 8.0;
  static const md = 10.0;
  static const lg = 12.0;
  static const xl = 14.0;
  static const xxl = 16.0;
  static const pill = 999.0;

  static const smAll = BorderRadius.all(Radius.circular(sm));
  static const mdAll = BorderRadius.all(Radius.circular(md));
  static const lgAll = BorderRadius.all(Radius.circular(lg));
  static const xlAll = BorderRadius.all(Radius.circular(xl));
  static const xxlAll = BorderRadius.all(Radius.circular(xxl));
  static const pillAll = BorderRadius.all(Radius.circular(pill));
}

/// 阴影令牌。
abstract final class AppShadows {
  static const card = [
    BoxShadow(color: AppColors.shadowSoft, blurRadius: 8, offset: Offset(0, 2)),
  ];
  static const floating = [
    BoxShadow(color: AppColors.shadow, blurRadius: 16, offset: Offset(0, 6)),
  ];
  static const accentGlow = [
    BoxShadow(color: Color(0x59658AE4), blurRadius: 12),
  ];
  static const successGlow = [
    BoxShadow(color: Color(0x594CC79A), blurRadius: 12),
  ];
}

/// 排版令牌：页面标题 / 区块标题 / 条目标题 / 正文 / 说明 / 弱化 / 标签。
abstract final class AppTextStyles {
  static const pageTitle = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
    letterSpacing: 0.2,
    height: 1.25,
  );
  static const subTitle = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: AppColors.ink,
    height: 1.3,
  );
  static const sectionTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    color: AppColors.ink,
    height: 1.3,
  );
  static const itemTitle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: AppColors.ink,
    height: 1.35,
  );
  static const body = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    color: AppColors.ink,
    height: 1.5,
  );
  static const caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.inkSecondary,
    height: 1.5,
  );
  static const captionMuted = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: AppColors.inkMuted,
    height: 1.4,
  );
  static const label = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    color: AppColors.inkSecondary,
  );
  static const eyebrow = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: AppColors.inkSecondary,
    letterSpacing: 0.6,
  );
}

/// 面板装饰令牌：所有卡片/凹陷区共用同一套「底色 + 描边 + 投影」。
abstract final class AppDecor {
  static final panel = BoxDecoration(
    color: AppColors.moonWhite,
    borderRadius: BorderRadius.circular(AppRadius.xl),
    border: Border.all(color: AppColors.outlineSubtle),
    boxShadow: AppShadows.card,
  );

  static final sunken = BoxDecoration(
    color: AppColors.canvasBg,
    borderRadius: BorderRadius.circular(AppRadius.md),
    border: Border.all(color: AppColors.outlineSubtle),
  );
}

/// 下拉弹出层统一圆角。
/// 注意：`ThemeData.dropdownMenuTheme` 只作用于 `DropdownMenu` 组件；
/// `DropdownButtonFormField`（内部是 `DropdownButton`）的弹出层不读取该主题，
/// 颜色/圆角必须在每处控件上显式传入（dropdownColor / borderRadius）。
const BorderRadius kDropdownMenuRadius = BorderRadius.all(Radius.circular(12));

ThemeData buildAppTheme() {
  final scheme = ColorScheme.dark(
    primary: AppColors.peacock,
    onPrimary: AppColors.onAccent,
    primaryContainer: AppColors.peacockSoft,
    onPrimaryContainer: AppColors.ink,
    secondary: AppColors.nodeData,
    onSecondary: AppColors.onAccent,
    secondaryContainer: AppColors.successSoft,
    onSecondaryContainer: AppColors.success,
    tertiary: AppColors.nodeScript,
    onTertiary: AppColors.onAccent,
    surface: AppColors.ivory,
    onSurface: AppColors.ink,
    surfaceContainerHighest: AppColors.surfaceRaised,
    onSurfaceVariant: AppColors.inkSecondary,
    surfaceTint: Colors.transparent,
    outline: AppColors.outline,
    outlineVariant: AppColors.outlineSubtle,
    error: AppColors.danger,
    onError: AppColors.onAccent,
    errorContainer: AppColors.dangerSoft,
    onErrorContainer: AppColors.danger,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'MiSans',
    fontFamilyFallback: const [
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Segoe UI',
    ],
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.ivory,
    canvasColor: AppColors.moonWhite,
    dividerColor: AppColors.outlineSubtle,
    disabledColor: AppColors.inkMuted,
    splashColor: AppColors.peacock.withValues(alpha: 0.12),
    highlightColor: AppColors.peacock.withValues(alpha: 0.08),
    hoverColor: AppColors.peacock.withValues(alpha: 0.06),
    focusColor: AppColors.peacock.withValues(alpha: 0.12),
  );
  return base.copyWith(
    // 下拉菜单与按钮等宽对齐：非对齐模式下 SDK 会让菜单矩形左右各扩
    // 16/24px（_kUnalignedMenuMargin），导致菜单比按钮宽且左缘错位；
    // alignedDropdown = true 时菜单宽度=按钮宽度并与左缘对齐。
    buttonTheme: const ButtonThemeData(alignedDropdown: true),
    iconTheme: const IconThemeData(color: AppColors.inkSecondary, size: 20),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.ivory,
      foregroundColor: AppColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: AppColors.moonWhite,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        side: const BorderSide(color: AppColors.outlineSubtle),
      ),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.peacock, // 按钮背景：柔空蓝
        foregroundColor: AppColors.onAccent, // 按钮文字/图标：白色
        disabledBackgroundColor: AppColors.peacockDeep.withValues(alpha: 0.4),
        disabledForegroundColor: AppColors.onAccentMuted,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.onAccent,
        disabledForegroundColor: AppColors.inkMuted,
        side: const BorderSide(color: AppColors.outline),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.peacock,
        disabledForegroundColor: AppColors.inkMuted,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: const WidgetStatePropertyAll(AppColors.inkSecondary),
        overlayColor: WidgetStatePropertyAll(
          AppColors.peacock.withValues(alpha: 0.12),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
        ),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: AppColors.peacock,
      foregroundColor: AppColors.onAccent,
      elevation: 2,
      highlightElevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.canvasBg,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.outlineSubtle),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.outlineSubtle),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.outlineSubtle),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.peacock, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.danger, width: 1.6),
      ),
      labelStyle: const TextStyle(fontSize: 13, color: AppColors.inkSecondary),
      hintStyle: const TextStyle(fontSize: 13, color: AppColors.inkMuted),
      floatingLabelStyle: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: AppColors.peacock,
      ),
      prefixIconColor: AppColors.inkSecondary,
      suffixIconColor: AppColors.inkSecondary,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.moonWhite,
      surfaceTintColor: Colors.transparent,
      elevation: 16,
      shadowColor: AppColors.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xxl),
        side: const BorderSide(color: AppColors.outlineSubtle),
      ),
      titleTextStyle: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
      ),
      contentTextStyle: const TextStyle(
        fontSize: 13,
        height: 1.6,
        color: AppColors.inkSecondary,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.moonWhite,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: AppColors.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: const BorderSide(color: AppColors.outlineSubtle),
      ),
      textStyle: const TextStyle(fontSize: 13, color: AppColors.ink),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(AppColors.moonWhite),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(12),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            side: const BorderSide(color: AppColors.outlineSubtle),
          ),
        ),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: const TextStyle(fontSize: 13, color: AppColors.ink),
      menuStyle: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(AppColors.moonWhite),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            side: const BorderSide(color: AppColors.outlineSubtle),
          ),
        ),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.abyss,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.outlineSubtle),
      ),
      textStyle: const TextStyle(fontSize: 12, color: AppColors.ink),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.outlineSubtle,
      thickness: 1,
      space: 1,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: AppColors.peacock,
      thumbColor: AppColors.peacockHover,
      inactiveTrackColor: AppColors.canvasBg,
      overlayColor: AppColors.peacock.withValues(alpha: 0.12),
      valueIndicatorColor: AppColors.peacockDeep,
      valueIndicatorTextStyle: const TextStyle(color: AppColors.onAccent),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.peacock,
      linearTrackColor: AppColors.canvasBg,
      circularTrackColor: AppColors.outlineSubtle,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.abyss,
      contentTextStyle: const TextStyle(fontSize: 13, color: AppColors.ink),
      actionTextColor: AppColors.peacockHover,
      behavior: SnackBarBehavior.floating,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: const BorderSide(color: AppColors.outlineSubtle),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.moonWhite,
      modalBackgroundColor: AppColors.moonWhite,
      surfaceTintColor: Colors.transparent,
      modalElevation: 0,
      elevation: 0,
      dragHandleColor: AppColors.outlineStrong,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.xxl),
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      textColor: AppColors.ink,
      iconColor: AppColors.inkSecondary,
      titleTextStyle: AppTextStyles.itemTitle,
      subtitleTextStyle: AppTextStyles.captionMuted,
      selectedColor: AppColors.peacock,
      selectedTileColor: AppColors.peacockSoft,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      textColor: AppColors.ink,
      iconColor: AppColors.peacock,
      collapsedTextColor: AppColors.ink,
      collapsedIconColor: AppColors.inkSecondary,
      tilePadding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      childrenPadding: EdgeInsets.only(bottom: AppSpacing.xxs),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.moonWhite,
      selectedColor: AppColors.peacockSoft,
      disabledColor: AppColors.canvasBg,
      labelStyle: const TextStyle(fontSize: 12, color: AppColors.ink),
      secondaryLabelStyle: const TextStyle(
        fontSize: 12,
        color: AppColors.inkSecondary,
      ),
      side: const BorderSide(color: AppColors.outlineSubtle),
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      checkmarkColor: AppColors.onAccent,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppColors.onAccent
            : AppColors.inkSecondary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppColors.peacock
            : AppColors.canvasBg,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppColors.peacock
            : AppColors.outlineStrong,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppColors.peacock
            : Colors.transparent,
      ),
      checkColor: const WidgetStatePropertyAll(AppColors.onAccent),
      side: const BorderSide(color: AppColors.outlineStrong, width: 1.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppColors.peacock
            : AppColors.outlineStrong,
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered)
            ? AppColors.peacock
            : AppColors.outlineStrong,
      ),
      trackColor: const WidgetStatePropertyAll(Colors.transparent),
      radius: const Radius.circular(AppRadius.pill),
      thickness: const WidgetStatePropertyAll(6),
      crossAxisMargin: 2,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: AppColors.peacock,
      selectionColor: AppColors.peacock.withValues(alpha: 0.32),
      selectionHandleColor: AppColors.peacock,
    ),
  );
}
