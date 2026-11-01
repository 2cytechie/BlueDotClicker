import 'package:bluedot_clicker/models/blueprint.dart';
import 'package:bluedot_clicker/services/script_storage.dart';
import 'package:bluedot_clicker/state/providers.dart';
import 'package:bluedot_clicker/ui/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存假存储：testWidgets 的 FakeAsync 环境下真实文件 IO 无法完成
/// （磁盘行为已由 test/services/script_storage_test.dart 覆盖），
/// UI 逻辑测试只关心拦截/引用关闭等行为。
class _FakeScriptStorage extends ScriptStorage {
  final Map<String, BlueprintScript> files = {};
  final List<String> saveCalls = [];

  @override
  Future<List<BlueprintScript>> listScripts() async {
    final list = files.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  @override
  Future<void> save(BlueprintScript s) async {
    saveCalls.add(s.name);
    files[s.name] = s;
  }

  @override
  Future<bool> exists(String name) async => files.containsKey(name);

  @override
  Future<BlueprintScript?> load(String name) async => files[name];

  @override
  Future<void> rename(BlueprintScript s, String newName) async {
    files.remove(s.name);
    s.name = newName;
    files[newName] = s;
  }

  @override
  Future<void> delete(String name) async => files.remove(name);
}

void main() {
  late _FakeScriptStorage storage;
  late ProviderContainer container;

  setUp(() {
    storage = _FakeScriptStorage();
    container = ProviderContainer(overrides: [
      scriptStorageProvider.overrideWith((_) => storage),
    ]);
  });

  tearDown(() {
    container.dispose();
  });

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: HomePage()),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> inputName(WidgetTester tester, String name) async {
    await tester.enterText(find.byType(TextField), name);
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();
  }

  BlueprintScript makeScript(String name) => BlueprintScript(name: name)
    ..nodes['n_start'] = BPNode(id: 'n_start', type: 'start', x: 0, y: 0);

  group('脚本名冲突防护', () {
    testWidgets('新建同名脚本被拦截：SnackBar 提示且不落盘', (tester) async {
      await storage.save(makeScript('Dup'));
      await pumpHome(tester);

      await tester.tap(find.widgetWithText(FilledButton, '新建'));
      await tester.pumpAndSettle();
      await inputName(tester, 'Dup');

      expect(find.text('已存在同名脚本，请换一个名称'), findsOneWidget);
      expect(storage.saveCalls, ['Dup'], reason: '拦截后不应再次保存');
      expect(container.read(appNavProvider), AppTab.home, reason: '不应跳转编辑器');
      // 推进 SnackBar 自动关闭计时器，避免测试结束时残留 pending timer
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('重命名为已有名被拦截：不覆盖目标脚本', (tester) async {
      final a = makeScript('Alpha')..variables['orig'] = 1;
      final b = makeScript('Beta')..variables['beta'] = 2;
      await storage.save(a);
      await storage.save(b);
      await pumpHome(tester);

      await tester.tap(find.byTooltip('重命名').first);
      await tester.pumpAndSettle();
      await inputName(tester, 'Beta');

      expect(find.text('已存在同名脚本，请换一个名称'), findsOneWidget);
      // Beta 的内容未被覆盖
      expect(storage.files['Beta']!.variables['beta'], 2);
      expect(storage.files.containsKey('Alpha'), isTrue, reason: 'Alpha 不应被改名');
      // 推进 SnackBar 自动关闭计时器，避免测试结束时残留 pending timer
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('删除当前打开的脚本', () {
    testWidgets('删除后 currentScript 关闭（防止侧边栏蓝图页复活已删脚本）', (tester) async {
      final a = makeScript('ToDelete');
      await storage.save(a);
      container.read(currentScriptProvider.notifier).open(a);
      await pumpHome(tester);

      expect(container.read(currentScriptProvider), isNotNull);
      await tester.tap(find.byTooltip('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();

      expect(container.read(currentScriptProvider), isNull, reason: '已删脚本应从当前脚本槽位移除');
      expect(storage.files.containsKey('ToDelete'), isFalse);
    });
  });
}
