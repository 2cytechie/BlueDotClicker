import 'package:bluedot_clicker/platform/screen_marker.dart';
import 'package:bluedot_clicker/state/providers.dart';
import 'package:bluedot_clicker/ui/editor/node_bridge.dart';
import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录调用的假标记服务：不创建分层窗口/钩子，只验证状态层行为
class _FakeMarker extends ScreenMarkerService {
  List<MarkerPoint> points = const [];
  void Function(int index, int x, int y)? onDragEnd;
  int shows = 0;

  @override
  bool get isActive => points.isNotEmpty;

  @override
  void show(
    List<MarkerPoint> points, {
    required void Function(int index, int x, int y) onDragEnd,
  }) {
    shows++;
    this.points = List.of(points);
    this.onDragEnd = onDragEnd;
  }

  @override
  void updatePoints(List<MarkerPoint> points) {
    this.points = List.of(points);
  }

  @override
  void hide() {
    points = const [];
    onDragEnd = null;
  }
}

void main() {
  late fl.NodeEditorController controller;

  setUp(() {
    controller = fl.NodeEditorController(definitions: blueprintNodeRegistry);
    controller.addNode(
      blueprintNodeRegistry.instantiate(
        'mouse',
        id: 'm1',
        position: Offset.zero,
      ),
    );
    controller.selection.selectNode('m1');
  });

  tearDown(() => controller.dispose());

  ProviderContainer containerWith(ScreenMarkerService marker) {
    final container = ProviderContainer(
      overrides: [screenMarkerProvider.overrideWithValue(marker)],
    );
    addTearDown(container.dispose);
    return container;
  }

  Map<String, dynamic> data() => controller.graph.nodes['m1']!.data;

  ScreenLocateTarget xyTarget() => const ScreenLocateTarget(
    nodeId: 'm1',
    label: '位置',
    points: [LocatePointDef('x', 'y', 0xFF658AE4)],
  );

  test('开启定位：按当前坐标显示图标，拖拽结束写回 x/y', () {
    controller.updateNode('m1', (n) => n.withData(const {'x': 10, 'y': 20}));
    final marker = _FakeMarker();
    final container = containerWith(marker);

    container.read(screenLocateProvider.notifier).toggle(
      controller: controller,
      target: xyTarget(),
    );

    expect(marker.shows, 1);
    expect(marker.points.single.x, 10);
    expect(marker.points.single.y, 20);
    expect(container.read(screenLocateProvider).active, isTrue);

    marker.onDragEnd!(0, 300, 400);
    expect(data()['x'], 300);
    expect(data()['y'], 400);
  });

  test('再次点击同一目标即关闭定位', () {
    final marker = _FakeMarker();
    final container = containerWith(marker);
    final notifier = container.read(screenLocateProvider.notifier);

    notifier.toggle(controller: controller, target: xyTarget());
    expect(container.read(screenLocateProvider).active, isTrue);

    notifier.toggle(controller: controller, target: xyTarget());
    expect(container.read(screenLocateProvider).active, isFalse);
    expect(marker.isActive, isFalse);
  });

  test('切换选中节点后自动关闭定位', () {
    final marker = _FakeMarker();
    final container = containerWith(marker);

    container.read(screenLocateProvider.notifier).toggle(
      controller: controller,
      target: xyTarget(),
    );
    controller.addNode(
      blueprintNodeRegistry.instantiate(
        'mouse',
        id: 'm2',
        position: Offset.zero,
      ),
    );
    controller.selection.selectNode('m2');

    expect(container.read(screenLocateProvider).active, isFalse);
    expect(marker.isActive, isFalse);
  });

  test('动作切换后坐标不再适用时自动关闭定位', () {
    final marker = _FakeMarker();
    final container = containerWith(marker);

    container.read(screenLocateProvider.notifier).toggle(
      controller: controller,
      target: xyTarget(),
    );
    // 切换为拖拽：x/y 不再是可见参数（改为起点/终点）
    controller.updateNode('m1', (n) => n.withData(const {'action': 'swipe'}));

    expect(container.read(screenLocateProvider).active, isFalse);
  });

  test('输入框改写坐标时同步屏幕图标位置', () {
    final marker = _FakeMarker();
    final container = containerWith(marker);

    container.read(screenLocateProvider.notifier).toggle(
      controller: controller,
      target: xyTarget(),
    );
    controller.updateNode('m1', (n) => n.withData(const {'x': 500, 'y': 600}));

    expect(marker.points.single.x, 500);
    expect(marker.points.single.y, 600);
  });

  test('拖拽定位拖动终点只回写 endX/endY', () {
    controller.updateNode(
      'm1',
      (n) => n.withData(const {
        'action': 'swipe',
        'startX': 10,
        'startY': 20,
        'endX': 30,
        'endY': 40,
      }),
    );
    final marker = _FakeMarker();
    final container = containerWith(marker);

    container.read(screenLocateProvider.notifier).toggle(
      controller: controller,
      target: const ScreenLocateTarget(
        nodeId: 'm1',
        label: '拖拽起点',
        points: [
          LocatePointDef('startX', 'startY', 0xFF658AE4),
          LocatePointDef('endX', 'endY', 0xFF3FA0D6),
        ],
      ),
    );
    expect(marker.points.length, 2);

    marker.onDragEnd!(1, 700, 800);
    expect(data()['startX'], 10);
    expect(data()['startY'], 20);
    expect(data()['endX'], 700);
    expect(data()['endY'], 800);
  });
}
