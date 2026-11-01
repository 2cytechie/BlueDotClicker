/// 回放互斥（replayBusyProvider）单测：busy 拒绝、完成/异常复位。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bluedot_clicker/state/providers.dart';

void main() {
  test('回放互斥：busy 期间拒绝新请求，完成后复位可再次运行', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(replayBusyProvider.notifier);

    expect(container.read(replayBusyProvider), isFalse);

    final release = Completer<void>();
    var firstRan = false;
    final first = notifier.runGuarded(() async {
      firstRan = true;
      await release.future;
    });
    await Future<void>.delayed(Duration.zero); // 让首个 body 启动
    expect(firstRan, isTrue);
    expect(container.read(replayBusyProvider), isTrue, reason: '运行中应为 busy');

    var secondRan = false;
    final second = await notifier.runGuarded(() async {
      secondRan = true;
    });
    expect(second, isFalse, reason: 'busy 期间应拒绝');
    expect(secondRan, isFalse, reason: '被拒绝时不得执行 body');

    release.complete();
    expect(await first, isTrue);
    expect(container.read(replayBusyProvider), isFalse, reason: '结束后应复位');

    expect(
      await notifier.runGuarded(() async {}),
      isTrue,
      reason: '复位后可再次运行',
    );
  });

  test('回放互斥：body 抛异常也复位（finally 语义）', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(replayBusyProvider.notifier);

    await expectLater(
      notifier.runGuarded(() async => throw StateError('boom')),
      throwsStateError,
    );
    expect(container.read(replayBusyProvider), isFalse, reason: '异常后应复位');
    expect(await notifier.runGuarded(() async {}), isTrue);
  });
}
