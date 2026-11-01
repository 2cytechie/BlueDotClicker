/// 录制页回归测试：
/// - 停止录制命名对话框：「取消」= 放弃本次录制；留空「确定」= 默认名保存一次
/// - 回放互斥接线：busy 时历史条目「回放」禁用；录制中回放被拒
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bluedot_clicker/models/blueprint.dart';
import 'package:bluedot_clicker/platform/recording.dart' show RecordingService;
import 'package:bluedot_clicker/services/script_storage.dart';
import 'package:bluedot_clicker/state/providers.dart';
import 'package:bluedot_clicker/ui/recording_page.dart';

class _FakeStorage extends RecordingStorage {
  final List<Recording> saved = [];
  List<Recording> preset = const [];

  @override
  Future<void> save(Recording r) async => saved.add(r);

  @override
  Future<List<Recording>> list() async => List.of(preset);

  @override
  Future<void> delete(String id) async {}
}

class _FakeRecordingService implements RecordingService {
  bool _recording = false;

  @override
  bool get isRecording => _recording;

  @override
  Stream<RecordedAction> get events => const Stream.empty();

  @override
  void start() => _recording = true;

  @override
  List<RecordedAction> stop() {
    _recording = false;
    return const [RecClick(0, 10, 10)];
  }
}

Future<ProviderContainer> _pumpPage(
  WidgetTester tester, {
  _FakeStorage? storage,
  _FakeRecordingService? service,
}) async {
  final container = ProviderContainer(overrides: [
    recordingStorageProvider.overrideWith((ref) => storage ?? _FakeStorage()),
    recordingServiceProvider
        .overrideWith((ref) => service ?? _FakeRecordingService()),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: RecordingPage()),
  ));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('停止录制：点「取消」放弃本次录制，不保存', (tester) async {
    final storage = _FakeStorage();
    await _pumpPage(tester, storage: storage);

    await tester.tap(find.text('开始录制'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停止录制'));
    await tester.pumpAndSettle();
    expect(find.text('保存录制'), findsOneWidget);

    await tester.tap(find.text('取消'));
    // 前一个「录制已开始」SnackBar 未到期会把新提示排队：先让队列推进
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(storage.saved, isEmpty, reason: '取消应放弃本次录制');
    expect(find.text('已放弃本次录制'), findsOneWidget);
  });

  testWidgets('停止录制：清空名称点「确定」按默认名保存一次', (tester) async {
    final storage = _FakeStorage();
    await _pumpPage(tester, storage: storage);

    await tester.tap(find.text('开始录制'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停止录制'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), ''); // 清空默认名
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(storage.saved.length, 1, reason: '确定应保存一次');
    expect(storage.saved.single.name, startsWith('录制 '),
        reason: '空名应回退默认名');
    expect(storage.saved.single.actions.length, 1);
  });

  testWidgets('互斥接线：busy 时「回放」禁用；录制中回放被拒', (tester) async {
    final storage = _FakeStorage()
      ..preset = [
        Recording(
          id: 'r_hist',
          name: '历史录制',
          createdAt: DateTime(2026, 1, 1),
          actions: const [RecClick(0, 5, 5)],
        ),
      ];
    final service = _FakeRecordingService();
    final container =
        await _pumpPage(tester, storage: storage, service: service);

    // busy → 历史条目「回放」按钮禁用（byTooltip 命中的是 Tooltip，IconButton 是其祖先）
    container.read(replayBusyProvider.notifier).state = true;
    await tester.pump();
    final replayBtn = tester.widget<IconButton>(
      find
          .ancestor(
              of: find.byTooltip('回放'), matching: find.byType(IconButton))
          .first,
    );
    expect(replayBtn.onPressed, isNull, reason: '回放进行中按钮应禁用');
    container.read(replayBusyProvider.notifier).state = false;
    await tester.pump();

    // 录制中 → 点「回放」被拒且不占用互斥（不执行真实回放）
    service._recording = true;
    await tester.tap(find.byTooltip('回放'));
    await tester.pumpAndSettle();
    expect(find.text('录制进行中，无法回放'), findsOneWidget);
    expect(container.read(replayBusyProvider), isFalse);
  });
}
