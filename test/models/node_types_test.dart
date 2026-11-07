import 'package:bluedot_clicker/models/node_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// 便捷构造：补齐默认值后覆盖指定字段（与属性面板 _effectiveData 一致）
Map<String, Object?> _data(NodeTypeDef def, Map<String, Object?> overrides) {
  final data = <String, Object?>{};
  for (final f in def.params) {
    data[f.key] = f.defaultValue;
  }
  data.addAll(overrides);
  return data;
}

Set<String> _visibleKeys(NodeTypeDef def, Map<String, Object?> overrides) =>
    def.params
        .where((f) => f.visibleFor(_data(def, overrides)))
        .map((f) => f.key)
        .toSet();

void main() {
  group('动作收敛（删除 按住/抬起/按下/抬起）', () {
    test('鼠标动作只剩 单击/双击/滑动/长按/滚轮/移动到', () {
      expect(
        kMouseActions.map((o) => o.value).toList(),
        ['click', 'doubleClick', 'swipe', 'longPress', 'scroll', 'move'],
      );
      expect(mouseActionLabel('press'), 'press'); // 旧值原样返回（不做兼容）
      expect(mouseActionLabel('release'), 'release');
    });

    test('键盘动作只剩 按键/组合键', () {
      expect(
        kKeyboardActions.map((o) => o.value).toList(),
        ['tap', 'combo'],
      );
      expect(keyboardActionLabel('down'), 'down');
      expect(keyboardActionLabel('up'), 'up');
    });

    test('节点说明不再提 按住/抬起', () {
      final mouse = nodeDef('mouse');
      final keyboard = nodeDef('keyboard');
      expect(mouse.description, isNot(contains('按住')));
      expect(mouse.description, isNot(contains('抬起')));
      expect(keyboard.description, isNot(contains('组合键/按下')));
      expect(keyboard.description, isNot(contains('需搭配')));
    });
  });

  group('鼠标参数排版', () {
    test('顺序为 动作 → 鼠标键 → X/Y', () {
      final keys = nodeDef('mouse').params.map((p) => p.key).toList();
      expect(keys.indexOf('action'), 0);
      expect(keys.indexOf('button'), 1);
      expect(keys.indexOf('x'), 2);
      expect(keys.indexOf('y'), 3);
    });

    test('各动作可见字段矩阵', () {
      expect(
        _visibleKeys(nodeDef('mouse'), {'action': 'click'}),
        {'action', 'button', 'x', 'y'},
      );
      expect(
        _visibleKeys(nodeDef('mouse'), {'action': 'scroll'}),
        {'action', 'x', 'y', 'dx', 'dy'},
      );
      expect(
        _visibleKeys(nodeDef('mouse'), {'action': 'move'}),
        {'action', 'x', 'y'},
      );
      expect(
        _visibleKeys(nodeDef('mouse'), {'action': 'longPress'}),
        {'action', 'button', 'x', 'y', 'holdMs'},
      );
      expect(
        _visibleKeys(nodeDef('mouse'), {'action': 'swipe'}),
        {'action', 'mode', 'startX', 'startY', 'endX', 'endY', 'durationMs'},
      );
      expect(
        _visibleKeys(nodeDef('mouse'), {
          'action': 'swipe',
          'mode': 'direction',
        }),
        {'action', 'mode', 'startX', 'startY', 'angle', 'distance', 'durationMs'},
      );
    });

    test('旧动作 press/release 不再显示任何坐标字段（仅剩动作下拉）', () {
      expect(_visibleKeys(nodeDef('mouse'), {'action': 'press'}), {'action'});
      expect(_visibleKeys(nodeDef('mouse'), {'action': 'release'}), {'action'});
    });
  });

  group('键盘参数', () {
    test('tap 显示单键，combo 显示组合键列表', () {
      expect(
        _visibleKeys(nodeDef('keyboard'), {'action': 'tap'}),
        {'action', 'vkCode', 'durationMs'},
      );
      expect(
        _visibleKeys(nodeDef('keyboard'), {'action': 'combo'}),
        {'action', 'comboKeys', 'durationMs'},
      );
    });

    test('旧动作 down/up 不再显示按键字段', () {
      expect(_visibleKeys(nodeDef('keyboard'), {'action': 'down'}), {'action'});
      expect(_visibleKeys(nodeDef('keyboard'), {'action': 'up'}), {'action'});
    });
  });

  group('第二轮节点定义变更', () {
    test('截图节点已删除 image 数据输入，保留执行流与 imageOut 输出', () {
      final def = nodeDef('screenshot');
      expect(def.inputs.any((p) => p.key == 'image'), isFalse);
      expect(def.inputs.where((p) => p.kind == PortKind.exec).length, 1);
      final imageOut = def.outputs.firstWhere((p) => p.key == 'imageOut');
      expect(imageOut.kind, PortKind.data);
      expect(imageOut.note, isNotNull);
    });

    test('条件判断参数顺序：左值组相邻、右值组相邻', () {
      final keys = nodeDef('condition').params.map((p) => p.key).toList();
      expect(keys, ['op', 'leftVar', 'leftConst', 'rightVar', 'rightConst']);
    });

    test('OCR 数据端口说明 4 条，x/y 描述的是区域原点而非文本位置', () {
      final def = nodeDef('ocr');
      final notes = [
        ...def.inputs.where((p) => p.note != null),
        ...def.outputs.where((p) => p.note != null),
      ];
      expect(notes.length, 4);
      // 执行流端口一律不写说明
      expect(
        [...def.inputs, ...def.outputs]
            .where((p) => p.kind == PortKind.exec)
            .every((p) => p.note == null),
        isTrue,
      );
      final x = def.outputs.firstWhere((p) => p.key == 'x');
      final y = def.outputs.firstWhere((p) => p.key == 'y');
      expect(x.note, contains('识别区域左上角'));
      expect(y.note, contains('识别区域左上角'));
      expect(x.note, isNot(contains('识别文本')));
    });

    test('图像识别数据端口说明 5 条，x/y 描述命中中心', () {
      final def = nodeDef('imageMatch');
      final notes = [
        ...def.inputs.where((p) => p.note != null),
        ...def.outputs.where((p) => p.note != null),
      ];
      expect(notes.length, 5);
      final x = def.outputs.firstWhere((p) => p.key == 'x');
      final y = def.outputs.firstWhere((p) => p.key == 'y');
      expect(x.note, contains('中心'));
      expect(y.note, contains('中心'));
      expect(x.note, contains('区域偏移'));
    });
  });
}
