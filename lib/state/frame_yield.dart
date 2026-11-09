import 'dart:async';

import 'package:flutter/scheduler.dart';

/// 等待 Flutter 完成下一帧：触发一次重绘/布局，让输入事件与热键轮询先跑。
/// 窗口最小化/被隐藏或帧被禁用时不会来帧，用 [timeout] 兜底，
/// 保证执行引擎不会因此挂起。
Future<void> waitForNextFrame({
  Duration timeout = const Duration(milliseconds: 16),
}) {
  final completer = Completer<void>();
  final timer = Timer(timeout, () {
    if (!completer.isCompleted) completer.complete();
  });
  SchedulerBinding.instance.endOfFrame.then(
    (_) {
      if (!completer.isCompleted) completer.complete();
      timer.cancel();
    },
    onError: (_) {
      if (!completer.isCompleted) completer.complete();
      timer.cancel();
    },
  );
  return completer.future;
}
