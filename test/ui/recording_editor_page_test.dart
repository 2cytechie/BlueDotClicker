/// 录制编辑页回归测试：
/// - 返回（dispose）时屏幕定位图标必须隐藏（Riverpod 3 禁止 dispose 中用 ref 的回归）
/// - 页面销毁后仍在途的保存不得丢失
/// - 回放中屏幕定位入口被守卫拦截；录制中试运行被拒
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bluedot_clicker/models/blueprint.dart';
import 'package:bluedot_clicker/platform/recording.dart' show RecordingService;
import 'package:bluedot_clicker/services/script_storage.dart';
import 'package:bluedot_clicker/state/providers.dart';
import 'package:bluedot_clicker/ui/recording_editor_page.dart';

/// 可控录制存储：记录保存调用；可用 gate 阻塞保存以测试页面销毁后的执行
class _FakeStorage extends RecordingStorage {
  final List<Recording> saved = [];
  Completer<void>? gate;

  @override
  Future<void> save(Recording r) async {
    final g = gate;
    if (g != null) await g.future;
    saved.add(r);
  }

  @override
  Future<List<Recording>> list() async => List.of(saved);

  @override
  Future<void> delete(String id) async {}
}

/// 可控录制服务：[recording] 置初始状态
class _FakeRecordingService implements RecordingService {
  _FakeRecordingService([this.recording = false]);
  bool recording;

  @override
  bool get isRecording => recording;

  @override
  Stream<RecordedAction> get events => const Stream.empty();

  @override
  void start() => recording = true;

  @override
  List<RecordedAction> stop() {
    recording = false;
    return const [RecClick(0, 10, 10)];
  }
}

Recording _testRecording() => Recording(
      id: 'r_test',
      name: '测试录制',
      createdAt: DateTime(2026, 1, 1),
      actions: const [RecClick(0, 100, 200)],
    );

/// 打开编辑页（底页放按钮 push，返回后干净 pop）
Future<ProviderContainer> _pumpEditor(
  WidgetTester tester, {
  RecordingStorage? storage,
  RecordingService? recordingService,
}) async {
  final container = ProviderContainer(overrides: [
    recordingStorageProvider.overrideWith((ref) => storage ?? _FakeStorage()),
    recordingServiceProvider
        .overrideWith((ref) => recordingService ?? _FakeRecordingService()),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      RecordingEditorPage(recording: _testRecording()),
                ),
              ),
              child: const Text('打开编辑页'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('打开编辑页'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('返回时隐藏屏幕定位图标（dispose 中不得使用 ref）', (tester) async {
    final container = await _pumpEditor(tester);
    final marker = container.read(screenMarkerProvider);

    await tester.tap(find.byTooltip('编辑')); // 展开动作面板
    await tester.pumpAndSettle();
    await tester.tap(find.text('屏幕定位'));
    await tester.pumpAndSettle();
    expect(marker.isActive, isTrue, reason: '激活后标记应在屏');

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(marker.isActive, isFalse, reason: '返回后标记必须随页面销毁而隐藏');
    expect(tester.takeException(), isNull);
  });

  testWidgets('退出前触发的保存在页面销毁后仍完成（不丢失）', (tester) async {
    final storage = _FakeStorage()..gate = Completer<void>();
    await _pumpEditor(tester, storage: storage);

    await tester.tap(find.byTooltip('删除')); // 删除动作 → 触发保存
    await tester.pumpAndSettle();
    expect(storage.saved, isEmpty, reason: '保存应阻塞在 gate 上');

    await tester.tap(find.byTooltip('返回')); // 页面销毁时保存仍在途
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    storage.gate!.complete(); // 模拟慢速落盘在销毁后完成
    await tester.pumpAndSettle();
    expect(storage.saved.length, 1, reason: '退出前触发的保存不得丢失');
    expect(storage.saved.single.actions, isEmpty, reason: '保存的应是删除后的快照');
  });

  testWidgets('回放中屏幕定位入口被守卫拦截，结束后恢复', (tester) async {
    final container = await _pumpEditor(tester);
    final marker = container.read(screenMarkerProvider);
    await tester.tap(find.byTooltip('编辑'));
    await tester.pumpAndSettle();

    container.read(replayBusyProvider.notifier).state = true;
    await tester.tap(find.text('屏幕定位'));
    await tester.pumpAndSettle();
    expect(marker.isActive, isFalse, reason: '回放中不得激活屏幕定位');

    container.read(replayBusyProvider.notifier).state = false;
    await tester.tap(find.text('屏幕定位'));
    await tester.pumpAndSettle();
    expect(marker.isActive, isTrue, reason: '回放结束后应恢复可用');
    marker.hide(); // 清理真实钩子/窗口
  });

  testWidgets('录制进行中试运行被拒（不执行真实回放）', (tester) async {
    final container = await _pumpEditor(
      tester,
      recordingService: _FakeRecordingService(true),
    );

    await tester.tap(find.text('试运行'));
    await tester.pumpAndSettle();
    expect(find.text('录制进行中，无法回放'), findsOneWidget);
    expect(container.read(replayBusyProvider), isFalse, reason: '被拒时不得占用回放互斥');
  });
}
