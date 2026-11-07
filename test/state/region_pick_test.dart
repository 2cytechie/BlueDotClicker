import 'package:bluedot_clicker/platform/region_picker.dart';
import 'package:bluedot_clicker/state/providers.dart';
import 'package:bluedot_clicker/ui/editor/node_bridge.dart';
import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRegionPicker extends RegionPicker {
  _FakeRegionPicker(this.result);

  final RegionPickResult? result;
  int calls = 0;

  @override
  Future<RegionPickResult?> pickRegion() async {
    calls++;
    return result;
  }
}

const _target = RegionPickTarget(
  nodeId: 's1',
  keyX: 'rx',
  keyY: 'ry',
  keyW: 'rw',
  keyH: 'rh',
  label: '框选区域',
);

void main() {
  late fl.NodeEditorController controller;

  setUp(() {
    controller = fl.NodeEditorController(definitions: blueprintNodeRegistry);
    controller.addNode(
      blueprintNodeRegistry.instantiate(
        'screenshot',
        id: 's1',
        position: Offset.zero,
      ),
    );
  });

  tearDown(() => controller.dispose());

  ProviderContainer containerWith(RegionPicker picker) {
    final container = ProviderContainer(
      overrides: [regionPickerProvider.overrideWithValue(picker)],
    );
    addTearDown(container.dispose);
    return container;
  }

  Map<String, dynamic> data() => controller.graph.nodes['s1']!.data;

  test('框选确认：写回 rx/ry/rw/rh 并自动勾选 useRegion', () async {
    final picker = _FakeRegionPicker(const RegionPickResult(10, 20, 30, 40));
    final container = containerWith(picker);

    await container.read(regionPickProvider.notifier).start(
          controller: controller,
          target: _target,
        );

    expect(picker.calls, 1);
    expect(data()['rx'], 10);
    expect(data()['ry'], 20);
    expect(data()['rw'], 30);
    expect(data()['rh'], 40);
    expect(data()['useRegion'], isTrue, reason: '框选确认后应自动勾选仅指定区域');
    expect(container.read(regionPickProvider).active, isFalse);
  });

  test('取消（null）：不修改节点，也不改动 useRegion', () async {
    controller.updateNode(
      's1',
      (n) => n.withData(const {
        'useRegion': false,
        'rx': 1,
        'ry': 2,
        'rw': 3,
        'rh': 4,
      }),
    );
    final picker = _FakeRegionPicker(null);
    final container = containerWith(picker);

    await container.read(regionPickProvider.notifier).start(
          controller: controller,
          target: _target,
        );

    expect(picker.calls, 1);
    expect(data()['rx'], 1);
    expect(data()['ry'], 2);
    expect(data()['rw'], 3);
    expect(data()['rh'], 4);
    expect(data()['useRegion'], isFalse);
  });
}
