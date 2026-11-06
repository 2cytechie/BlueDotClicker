import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'ui/editor/editor_localizations.dart';
import 'ui/shell.dart';

/// 应用根：主题与布局壳（左侧导航栏 + 右侧内容；编辑器全屏）
class BlueDotApp extends StatelessWidget {
  const BlueDotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '蓝点器',
      theme: buildAppTheme(),
      // 编辑器内置菜单/对话框的中文文案；Material/Widgets 默认委托由
      // MaterialApp 自动补齐（其文案固定英文，本应用界面文字均为自定义，
      // 不受影响）。不设 locale：避免声明 zh_CN 却缺少 Material 中文委托的告警。
      localizationsDelegates: const [AppNodeEditorLocalizations.delegate],
      home: const AppShell(),
    );
  }
}
