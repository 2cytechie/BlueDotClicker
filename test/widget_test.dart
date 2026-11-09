import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bluedot_clicker/app.dart';

void main() {
  testWidgets('应用启动冒烟：首页渲染脚本区域', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: BlueDotApp()));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // 脚本管理区域与操作入口存在
    expect(find.text('我的脚本'), findsWidgets);
    expect(find.text('导入'), findsWidgets);
    expect(find.text('新建'), findsWidgets);
    expect(find.textContaining('脚本'), findsWidgets);
    // 左侧导航保留蓝图与录制入口
    expect(find.text('蓝图'), findsWidgets);
    expect(find.text('录制'), findsWidgets);
  });

  testWidgets('录制回放页可打开且控件渲染', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: BlueDotApp()));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('录制').first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // 录制操作区状态徽章与历史记录区存在
    expect(find.textContaining('待机'), findsWidgets);
    expect(find.textContaining('历史记录'), findsWidgets);
  });
}
