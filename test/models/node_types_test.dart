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
    test('鼠标动作只剩 单击/双击/拖拽/长按/滚轮/移动到', () {
      expect(
        kMouseActions.map((o) => o.value).toList(),
        ['click', 'doubleClick', 'swipe', 'longPress', 'scroll', 'move'],
      );
      expect(mouseActionLabel('swipe'), '拖拽', reason: '枚举值不变，仅显示文案改为拖拽');
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
        {'action', 'x', 'y', 'moveDurationMs'},
      );
      expect(
        _visibleKeys(nodeDef('mouse'), {'action': 'longPress'}),
        {'action', 'button', 'x', 'y', 'holdMs'},
      );
      expect(
        _visibleKeys(nodeDef('mouse'), {'action': 'swipe'}),
        {
          'action',
          'button',
          'mode',
          'startX',
          'startY',
          'endX',
          'endY',
          'durationMs',
        },
      );
      expect(
        _visibleKeys(nodeDef('mouse'), {
          'action': 'swipe',
          'mode': 'direction',
        }),
        {
          'action',
          'button',
          'mode',
          'startX',
          'startY',
          'angle',
          'distance',
          'durationMs',
        },
      );
    });

    test('旧动作 press/release 不再显示任何坐标字段（仅剩动作下拉）', () {
      expect(_visibleKeys(nodeDef('mouse'), {'action': 'press'}), {'action'});
      expect(_visibleKeys(nodeDef('mouse'), {'action': 'release'}), {'action'});
    });
  });

  group('鼠标坐标数据输入', () {
    test('鼠标节点提供可选 X/Y 数据输入端口（保留执行流入口）', () {
      final def = nodeDef('mouse');
      final execIns = def.inputs.where((p) => p.kind == PortKind.exec).toList();
      expect(execIns.length, 1, reason: '执行流入口保留');
      final dataIns = def.inputs.where((p) => p.kind == PortKind.data).toList();
      expect(dataIns.map((p) => p.key), [
        'x',
        'y',
        'startX',
        'startY',
        'endX',
        'endY',
      ]);
      expect(dataIns.every((p) => p.dir == PortDir.input), isTrue);
      // 每个数据端口都有用法说明，便于用户在端口说明区理解
      expect(dataIns.every((p) => p.note != null && p.note!.isNotEmpty), isTrue);
    });

    test('X/Y 参数仍保留默认值（未接输入时使用）', () {
      final keys = nodeDef('mouse').params.map((p) => p.key).toList();
      expect(keys.contains('x'), isTrue);
      expect(keys.contains('y'), isTrue);
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

    test('条件判断参数只有比较方式与左右常量', () {
      final keys = nodeDef('condition').params.map((p) => p.key).toList();
      expect(keys, ['op', 'leftConst', 'rightConst']);
      expect(
        nodeDef('condition').params.map((p) => p.label).toList(),
        ['比较方式', '左值(无连接时)', '右值(无连接时)'],
      );
    });

    test('OCR 数据端口说明齐全，x/y 描述目标文字坐标', () {
      final def = nodeDef('ocr');
      final notes = [
        ...def.inputs.where((p) => p.note != null),
        ...def.outputs.where((p) => p.note != null),
      ];
      expect(
        notes.length,
        7,
        reason: '图像/目标文本 2 输入 + 文本/是否命中/坐标X/坐标Y/成功 5 输出',
      );
      // 执行流端口一律不写说明
      expect(
        [...def.inputs, ...def.outputs]
            .where((p) => p.kind == PortKind.exec)
            .every((p) => p.note == null),
        isTrue,
      );
      final x = def.outputs.firstWhere((p) => p.key == 'x');
      final y = def.outputs.firstWhere((p) => p.key == 'y');
      expect(x.note, contains('目标文字中心'));
      expect(y.note, contains('目标文字中心'));
    });

    test('图像识别数据端口说明 6 条，x/y 描述命中中心', () {
      final def = nodeDef('imageMatch');
      final notes = [
        ...def.inputs.where((p) => p.note != null),
        ...def.outputs.where((p) => p.note != null),
      ];
      expect(notes.length, 6);
      final x = def.outputs.firstWhere((p) => p.key == 'x');
      final y = def.outputs.firstWhere((p) => p.key == 'y');
      expect(x.note, contains('中心'));
      expect(y.note, contains('中心'));
      expect(x.note, contains('区域偏移'));
    });
  });

  group('第四轮节点定义变更', () {
    test('storage 已移除，getVar / saveData 取代', () {
      expect(isKnownNodeType('storage'), isFalse);
      expect(isKnownNodeType('getVar'), isTrue);
      expect(isKnownNodeType('saveData'), isTrue);
    });

    test('获取变量：纯数据节点，无任何输入，仅一个数据输出（value）', () {
      final def = nodeDef('getVar');
      expect(def.inputs, isEmpty, reason: '获取变量不参与执行流，也没有数据输入');
      final dataOuts = def.outputs.where((p) => p.kind == PortKind.data).toList();
      expect(dataOuts.map((p) => p.key), ['value']);
      expect(dataOuts.single.note, isNotNull, reason: '输出端口带用法说明');
    });

    test('数据保存：文本/图像双数据输入 + 文本/图像/成功输出，带说明', () {
      final def = nodeDef('saveData');
      final dataIns = def.inputs.where((p) => p.kind == PortKind.data).toList();
      expect(dataIns.map((p) => p.key), ['text', 'image']);
      final dataOuts = def.outputs.where((p) => p.kind == PortKind.data).toList();
      expect(dataOuts.map((p) => p.key), ['textOut', 'imageOut', 'success']);
      // 数据端口全部带说明（端口即文档）
      expect(
        [...dataIns, ...dataOuts].every((p) => p.note != null && p.note!.isNotEmpty),
        isTrue,
      );
      // 执行流端口不写说明
      expect(
        [...def.inputs, ...def.outputs]
            .where((p) => p.kind == PortKind.exec)
            .every((p) => p.note == null),
        isTrue,
      );
      expect(def.params.map((f) => f.key), ['fileName']);
    });
  });

  group('第五轮节点定义变更', () {
    test('OCR：resultVar 已删除，改为「目标文本」参数与同名数据输入', () {
      final def = nodeDef('ocr');
      expect(def.params.any((f) => f.key == 'resultVar'), isFalse,
          reason: 'OCR 不再负责写变量');
      expect(def.inputs.any((p) => p.key == 'resultVar'), isFalse);
      final f = def.params.firstWhere((f) => f.key == 'targetText');
      expect(f.label, '目标文本');
      expect(f.type, ParamType.string, reason: 'string 类型不出现已有变量下拉');
      final input = def.inputs.firstWhere((p) => p.key == 'targetText');
      expect(input.kind, PortKind.data);
      expect(input.note, isNotNull, reason: '输入端口带用法说明');
    });

    test('OCR 数据输出为 文本/是否命中/坐标X/坐标Y/成功', () {
      final def = nodeDef('ocr');
      final dataOuts = def.outputs.where((p) => p.kind == PortKind.data).toList();
      expect(dataOuts.map((p) => p.key), ['text', 'found', 'x', 'y', 'success']);
      final found = dataOuts[1];
      expect(found.label, '是否命中');
      expect(found.note, contains('目标文本'));
      expect(dataOuts[2].label, '坐标X');
      expect(dataOuts[3].label, '坐标Y');
      expect(dataOuts[4].label, '成功');
    });

    test('imageMatch：模板/阈值 + 两角点区域参数，输出含成功', () {
      final def = nodeDef('imageMatch');
      expect(def.params.map((f) => f.key), [
        'templatePath',
        'threshold',
        'useRegion',
        'left',
        'top',
        'right',
        'bottom',
      ]);
      final dataOuts = def.outputs.where((p) => p.kind == PortKind.data).toList();
      expect(dataOuts.map((p) => p.key), ['found', 'x', 'y', 'score', 'success']);
      final x = dataOuts.firstWhere((p) => p.key == 'x');
      final y = dataOuts.firstWhere((p) => p.key == 'y');
      expect(x.label, '坐标X');
      expect(y.label, '坐标Y');
    });
  });

  group('条件循环与算术节点', () {
    test('循环：单执行输入 + 左右数据输入 + 真/假双输出', () {
      final def = nodeDef('loop');
      expect(def.inputs.where((p) => p.kind == PortKind.exec).map((p) => p.key), ['in']);
      expect(
        def.inputs.where((p) => p.kind == PortKind.data).map((p) => p.key),
        ['left', 'right'],
      );
      expect(def.outputs.map((p) => p.key), ['true', 'false']);
      expect(def.params.map((f) => f.key),
          ['op', 'leftConst', 'rightConst', 'maxIterations']);
      expect(
        def.params.firstWhere((f) => f.key == 'op').options.map((o) => o.value),
        contains('notContains'),
      );
    });

    test('加法/减法：数据分类，执行流 + A/B 输入 + 结果输出', () {
      for (final type in ['add', 'subtract']) {
        final def = nodeDef(type);
        expect(def.category, NodeCategory.data);
        expect(def.inputs.map((p) => p.key), ['in', 'a', 'b']);
        expect(def.outputs.map((p) => p.key), ['out', 'result']);
        expect(def.params.map((f) => f.key), ['a', 'b']);
      }
    });

    test('setVar 的 const 参数声明由 value 端口接管', () {
      final f = nodeDef('setVar').params.firstWhere((f) => f.key == 'const');
      expect(f.lockedByPort, 'value');
    });

    test('媒体节点区域字段统一为两角点', () {
      for (final type in ['screenshot', 'ocr', 'imageMatch']) {
        final keys = nodeDef(type).params.map((f) => f.key).toList();
        expect(keys, containsAll(['useRegion', 'left', 'top', 'right', 'bottom']));
        expect(keys, isNot(contains('rx')));
        expect(keys, isNot(contains('rw')));
      }
    });
  });
}
