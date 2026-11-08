import 'package:flutter/material.dart';
import '../core/theme.dart';

/// 节点大类
enum NodeCategory { interaction, media, logic, data, script }

extension NodeCategoryX on NodeCategory {
  String get label => switch (this) {
    NodeCategory.interaction => '交互',
    NodeCategory.media => '媒体',
    NodeCategory.logic => '逻辑',
    NodeCategory.data => '数据',
    NodeCategory.script => '脚本',
  };
  Color get color => switch (this) {
    NodeCategory.interaction => AppColors.nodeInteraction,
    NodeCategory.media => AppColors.nodeMedia,
    NodeCategory.logic => AppColors.nodeLogic,
    NodeCategory.data => AppColors.nodeData,
    NodeCategory.script => AppColors.nodeScript,
  };
  IconData get icon => switch (this) {
    NodeCategory.interaction => Icons.touch_app_rounded,
    NodeCategory.media => Icons.photo_camera_outlined,
    NodeCategory.logic => Icons.account_tree_outlined,
    NodeCategory.data => Icons.dataset_outlined,
    NodeCategory.script => Icons.code_rounded,
  };
}

enum PortKind { exec, data }

enum PortDir { input, output }

/// 数据端口类型标签：执行流 / 图像 / 其余数据
const String kPortTypeExec = 'exec';
const String kPortTypeImage = 'image';
const String kPortTypeValue = 'value';

class PortDef {
  final String key;
  final PortKind kind;
  final PortDir dir;
  final String label;

  /// 属性面板「输入端口说明」中展示的详细说明（仅需解释的输入口填写）
  final String? note;

  /// 端口数据类型；两端都有类型且不同时禁止连线（null 为通配）。
  /// 所有数据端口都必须显式标类型，否则类型校验会失效。
  final String dataType;
  const PortDef(
    this.key,
    this.kind,
    this.dir,
    this.label, {
    this.note,
    String? dataType,
  }) : dataType = dataType ??
            (kind == PortKind.exec ? kPortTypeExec : kPortTypeValue);

  Map<String, dynamic> toJson() => {
    'key': key,
    'kind': kind.name,
    'dir': dir.name,
    'label': label,
    'dataType': dataType,
    if (note != null) 'note': note,
  };
}

/// 参数字段类型（驱动属性面板渲染）
enum ParamType {
  int,
  double,
  string,
  bool,
  enum_,
  varName,
  templateFile,
  recording,

  /// 单个虚拟键（VK 码），属性面板提供常用键下拉与全局按键拾取
  key,

  /// 有序虚拟键列表（组合键），属性面板提供逐键追加/删除
  keyList,
}

class EnumOption {
  final String value;
  final String label;
  const EnumOption(this.value, this.label);
}

class ParamFieldDef {
  final String key;
  final String label;
  final ParamType type;
  final Object? defaultValue;
  final List<EnumOption> options;
  final String? hint;

  /// 按其它参数取值决定本字段是否显示（全部命中才显示）。
  /// 键=参数名，值=允许的取值；如 `{'action': {'swipe'}, 'mode': {'coords'}}`。
  /// 空表表示始终显示。
  final Map<String, Set<String>> visibleWhen;

  /// 该参数被哪个数据输入端口接管（默认与参数同名的端口）。
  /// 连接后属性面板灰显只读、保留原值；执行时数据边优先。
  final String? lockedByPort;

  const ParamFieldDef(
    this.key,
    this.label,
    this.type, {
    this.defaultValue,
    this.options = const [],
    this.hint,
    this.visibleWhen = const {},
    this.lockedByPort,
  });

  /// [data] 应已补齐默认值（见属性面板/节点摘要的 _effectiveData）
  bool visibleFor(Map<String, Object?> data) {
    for (final entry in visibleWhen.entries) {
      final actual = data[entry.key];
      if (actual == null || !entry.value.contains('$actual')) return false;
    }
    return true;
  }
}

class NodeTypeDef {
  final String type;
  final String title;
  final NodeCategory category;
  final IconData icon;
  final List<PortDef> inputs;
  final List<PortDef> outputs;
  final List<ParamFieldDef> params;
  final String description;
  const NodeTypeDef({
    required this.type,
    required this.title,
    required this.category,
    required this.icon,
    required this.inputs,
    required this.outputs,
    required this.params,
    this.description = '',
  });
}

// ---- 端口定义快捷构造 ----
PortDef _inExec([String key = 'in', String label = '']) =>
    PortDef(key, PortKind.exec, PortDir.input, label);
PortDef _outExec([String key = 'out', String label = '']) =>
    PortDef(key, PortKind.exec, PortDir.output, label);
PortDef _inData(
  String key,
  String label, {
  String? note,
  String dataType = kPortTypeValue,
}) => PortDef(
  key,
  PortKind.data,
  PortDir.input,
  label,
  note: note,
  dataType: dataType,
);
PortDef _outData(
  String key,
  String label, {
  String? note,
  String dataType = kPortTypeValue,
}) => PortDef(
  key,
  PortKind.data,
  PortDir.output,
  label,
  note: note,
  dataType: dataType,
);

/// 媒体节点（截图/文字识别/图像识别）共用的两角点区域字段：
/// 宽 = right - left，高 = bottom - top；右下角不含边界。
const _cornerFields = [
  ParamFieldDef('useRegion', '仅指定区域', ParamType.bool, defaultValue: false),
  // 四个角点始终显示（便于随时框选/微调），仅在 useRegion=true 时参与执行
  ParamFieldDef('left', '左上角X', ParamType.int, defaultValue: 0),
  ParamFieldDef('top', '左上角Y', ParamType.int, defaultValue: 0),
  ParamFieldDef('right', '右下角X', ParamType.int, defaultValue: 400),
  ParamFieldDef('bottom', '右下角Y', ParamType.int, defaultValue: 300),
];

const _buttonOptions = [
  EnumOption('left', '左键'),
  EnumOption('right', '右键'),
  EnumOption('middle', '中键'),
];

/// 条件判断与循环共用的比较方式（含「不包含」）
const kCompareOptions = [
  EnumOption('==', '等于'),
  EnumOption('!=', '不等于'),
  EnumOption('>', '大于'),
  EnumOption('<', '小于'),
  EnumOption('>=', '大于等于'),
  EnumOption('<=', '小于等于'),
  EnumOption('contains', '包含'),
  EnumOption('notContains', '不包含'),
];

/// 鼠标动作（`mouse` 节点的 action 取值）
const kMouseActions = [
  EnumOption('click', '单击'),
  EnumOption('doubleClick', '双击'),
  EnumOption('swipe', '拖拽'),
  EnumOption('longPress', '长按'),
  EnumOption('scroll', '滚轮'),
  EnumOption('move', '移动到'),
];

/// 键盘动作（`keyboard` 节点的 action 取值）
const kKeyboardActions = [EnumOption('tap', '按键'), EnumOption('combo', '组合键')];

String _labelOf(List<EnumOption> options, Object? value) {
  for (final o in options) {
    if (o.value == '$value') return o.label;
  }
  return '${value ?? ''}';
}

/// 鼠标动作中文名（未知取值原样返回）
String mouseActionLabel(Object? action) => _labelOf(kMouseActions, action);

/// 键盘动作中文名（未知取值原样返回）
String keyboardActionLabel(Object? action) =>
    _labelOf(kKeyboardActions, action);

/// 全部节点类型定义表（编辑器 / 属性面板 / 执行引擎共用）
final List<NodeTypeDef> kNodeTypes = [
  NodeTypeDef(
    type: 'start',
    title: '开始',
    category: NodeCategory.script,
    icon: Icons.play_arrow_rounded,
    description: '脚本执行入口；执行次数为 0 表示一直执行，运行中按 F10 停止',
    inputs: [],
    outputs: [_outExec()],
    params: [
      ParamFieldDef('count', '执行次数(0=一直执行)', ParamType.int, defaultValue: 1),
    ],
  ),
  NodeTypeDef(
    type: 'mouse',
    title: '鼠标操作',
    category: NodeCategory.interaction,
    icon: Icons.mouse_rounded,
    description:
        '按所选动作操作鼠标：单击/双击/拖拽/长按/滚轮/移动到。'
        'X/Y 坐标可选接入上游数据（如识别结果），接入后坐标参数自动锁定；'
        '拖拽时起点复用 X/Y，终点使用「拖拽终点X/Y」参数。'
        '补充：滚轮滚动距离（120=一格）。滚轮水平滚动（正=右）。滚轮垂直滚动（正=上）。',
    inputs: [
      _inExec(),
      _inData(
        'x',
        'X 坐标',
        note: '可选。单击/双击/长按/滚轮/移动的目标 X；动作=拖拽时为拖拽起点 X。连接上游数据后对应参数锁定为只读；不连接时使用参数值。',
      ),
      _inData(
        'y',
        'Y 坐标',
        note: '可选。单击/双击/长按/滚轮/移动的目标 Y；动作=拖拽时为拖拽起点 Y。连接上游数据后对应参数锁定为只读；不连接时使用参数值。',
      ),
      _inData(
        'endX',
        '拖拽终点X',
        note: '可选。仅在动作=拖拽且模式=起点终点时生效；方向距离模式忽略终点输入。',
      ),
      _inData(
        'endY',
        '拖拽终点Y',
        note: '可选。仅在动作=拖拽且模式=起点终点时生效；方向距离模式忽略终点输入。',
      ),
    ],
    outputs: [_outExec()],
    params: [
      ParamFieldDef(
        'action',
        '动作',
        ParamType.enum_,
        defaultValue: 'click',
        options: kMouseActions,
      ),
      ParamFieldDef(
        'button',
        '鼠标键',
        ParamType.enum_,
        defaultValue: 'left',
        options: _buttonOptions,
        visibleWhen: const {
          'action': {'click', 'doubleClick', 'longPress', 'swipe'},
        },
      ),
      ParamFieldDef(
        'x',
        'X 坐标',
        ParamType.int,
        defaultValue: 100,
        visibleWhen: const {
          'action': {'click', 'doubleClick', 'swipe', 'longPress', 'scroll', 'move'},
        },
      ),
      ParamFieldDef(
        'y',
        'Y 坐标',
        ParamType.int,
        defaultValue: 100,
        visibleWhen: const {
          'action': {'click', 'doubleClick', 'swipe', 'longPress', 'scroll', 'move'},
        },
      ),
      ParamFieldDef(
        'mode',
        '拖拽模式',
        ParamType.enum_,
        defaultValue: 'coords',
        options: [
          EnumOption('coords', '起点终点'),
          EnumOption('direction', '方向距离'),
        ],
        visibleWhen: const {
          'action': {'swipe'},
        },
      ),
      ParamFieldDef(
        'endX',
        '终点X',
        ParamType.int,
        defaultValue: 600,
        visibleWhen: const {
          'action': {'swipe'},
          'mode': {'coords'},
        },
      ),
      ParamFieldDef(
        'endY',
        '终点Y',
        ParamType.int,
        defaultValue: 300,
        visibleWhen: const {
          'action': {'swipe'},
          'mode': {'coords'},
        },
      ),
      ParamFieldDef(
        'angle',
        '方向角(度,0=右,逆时针)',
        ParamType.double,
        defaultValue: 0,
        visibleWhen: const {
          'action': {'swipe'},
          'mode': {'direction'},
        },
      ),
      ParamFieldDef(
        'distance',
        '距离(px)',
        ParamType.int,
        defaultValue: 200,
        visibleWhen: const {
          'action': {'swipe'},
          'mode': {'direction'},
        },
      ),
      ParamFieldDef(
        'durationMs',
        '拖拽时长(ms)',
        ParamType.int,
        defaultValue: 300,
        visibleWhen: const {
          'action': {'swipe'},
        },
      ),
      ParamFieldDef(
        'moveDurationMs',
        '移动时长(ms)',
        ParamType.int,
        defaultValue: 0,
        hint: '0=瞬间移动；大于 0 时按缓动曲线平滑移动',
        visibleWhen: const {
          'action': {'move'},
        },
      ),
      ParamFieldDef(
        'holdMs',
        '按住时长(ms)',
        ParamType.int,
        defaultValue: 800,
        visibleWhen: const {
          'action': {'longPress'},
        },
      ),
      ParamFieldDef(
        'dx',
        '滚轮水平滚动',
        ParamType.int,
        defaultValue: 0,
        visibleWhen: const {
          'action': {'scroll'},
        },
      ),
      ParamFieldDef(
        'dy',
        '滚轮垂直滚动',
        ParamType.int,
        defaultValue: 0,
        visibleWhen: const {
          'action': {'scroll'},
        },
      ),
    ],
  ),
  NodeTypeDef(
    type: 'keyboard',
    title: '键盘操作',
    category: NodeCategory.interaction,
    icon: Icons.keyboard_rounded,
    description:
        '按所选动作操作键盘：按键/组合键。'
        '键位可从常用键下拉选择，或点「拾取」后按下实际按键。',
    inputs: [_inExec()],
    outputs: [_outExec()],
    params: [
      ParamFieldDef(
        'action',
        '动作',
        ParamType.enum_,
        defaultValue: 'tap',
        options: kKeyboardActions,
      ),
      ParamFieldDef(
        'vkCode',
        '按键',
        ParamType.key,
        defaultValue: 0,
        visibleWhen: const {
          'action': {'tap'},
        },
      ),
      ParamFieldDef(
        'comboKeys',
        '组合键(按顺序)',
        ParamType.keyList,
        defaultValue: const <int>[],
        visibleWhen: const {
          'action': {'combo'},
        },
      ),
      ParamFieldDef(
        'durationMs',
        '按住时长(ms)',
        ParamType.int,
        defaultValue: 60,
        visibleWhen: const {
          'action': {'tap', 'combo'},
        },
      ),
    ],
  ),
  NodeTypeDef(
    type: 'playRecording',
    title: '执行录制',
    category: NodeCategory.interaction,
    icon: Icons.smart_button_rounded,
    description: '回放选中的录制动作序列（点击/拖拽/长按/滚轮/按键按录制时序依次执行）',
    inputs: [_inExec()],
    outputs: [
      _outExec(),
      _outData('success', '成功', note: '正常回放完成输出 true；未选择录制/找不到录制/被 F10 中止输出 false'),
    ],
    params: [
      ParamFieldDef(
        'recordingId',
        '选择录制',
        ParamType.recording,
        defaultValue: '',
      ),
    ],
  ),
  NodeTypeDef(
    type: 'screenshot',
    title: '截图',
    category: NodeCategory.media,
    icon: Icons.screenshot_monitor_rounded,
    description: '截取全屏或指定区域（区域可用屏幕框选），供后续识别节点使用',
    inputs: [
      _inExec(),
      _inData('left', '左上角X', note: '可选。仅勾选「仅指定区域」时生效；连接后对应参数锁定只读。'),
      _inData('top', '左上角Y', note: '可选。仅勾选「仅指定区域」时生效；连接后对应参数锁定只读。'),
      _inData('right', '右下角X', note: '可选。仅勾选「仅指定区域」时生效；右下角不含边界。'),
      _inData('bottom', '右下角Y', note: '可选。仅勾选「仅指定区域」时生效；右下角不含边界。'),
    ],
    outputs: [
      _outExec(),
      _outData(
        'imageOut',
        '图像',
        dataType: kPortTypeImage,
        note: '截取的屏幕图像，可连接「文字识别/图像识别」的图像输入',
      ),
      _outData('success', '成功', note: '截屏成功输出 true；区域无效或截屏失败输出 false'),
    ],
    params: _cornerFields,
  ),
  NodeTypeDef(
    type: 'ocr',
    title: '文字识别',
    category: NodeCategory.media,
    icon: Icons.text_fields_rounded,
    description:
        '对图像/屏幕区域进行文字识别（OCR）。「文本」输出完整识别结果；'
        '填写「目标文本」后，是否命中表示识别文本是否包含目标，坐标输出为目标文字的中心；'
        '目标文本留空时坐标为识别区域中心。',
    inputs: [
      _inExec(),
      _inData(
        'image',
        '输入图像(可空)',
        dataType: kPortTypeImage,
        note:
            '可选数据输入。连接上游「截图」节点的「图像」输出时，直接识别该图像、不再重新截屏；不连接时自动现场截屏（或截取上方设定的区域）。'
            '注意：在编辑器里点「测试识别」取不到上游图像，会现场截屏。',
      ),
      _inData(
        'targetText',
        '目标文本',
        note: '可选。连接后「目标文本」参数锁定；识别文本包含该文本时「是否命中」为 true，坐标输出为目标文字中心。',
      ),
    ],
    outputs: [
      _outExec(),
      _outData('text', '文本', note: '识别出的完整文本（字符串），可连接下游节点的数据输入'),
      _outData('found', '是否命中', note: '识别文本是否包含「目标文本」；目标文本为空时 = 识别文本非空'),
      _outData('x', '坐标X', note: '目标文字中心 X；目标文本为空时为区域中心；未命中目标时为 -1'),
      _outData('y', '坐标Y', note: '目标文字中心 Y；目标文本为空时为区域中心；未命中目标时为 -1'),
      _outData('success', '成功', note: '正常完成识别输出 true；无可用图像或区域无效输出 false'),
    ],
    params: [
      ..._cornerFields,
      ParamFieldDef(
        'targetText',
        '目标文本',
        ParamType.string,
        defaultValue: '',
        hint: '留空 = 任意文本模式（坐标为区域中心）',
      ),
    ],
  ),
  NodeTypeDef(
    type: 'imageMatch',
    title: '图像识别',
    category: NodeCategory.media,
    icon: Icons.image_search_rounded,
    description:
        '在屏幕/图像中匹配模板图（游戏UI元素），命中结果'
        '（是否命中/坐标X/坐标Y/相似度）从输出端口连线给下游节点使用',
    inputs: [
      _inExec(),
      _inData(
        'image',
        '输入图像(可空)',
        dataType: kPortTypeImage,
        note: '可选数据输入。连接上游图像时在该图像内匹配模板；不连接时自动现场截屏（或截取上方设定的区域）。',
      ),
    ],
    outputs: [
      _outExec(),
      _outData('found', '是否命中', note: '是否命中（true/false），可连接「条件判断」节点的数据输入'),
      _outData('x', '坐标X', note: '命中区域中心在屏幕上的 X 坐标（未命中时为最佳匹配位置；区域模式时含区域偏移）'),
      _outData('y', '坐标Y', note: '命中区域中心在屏幕上的 Y 坐标（未命中时为最佳匹配位置；区域模式时含区域偏移）'),
      _outData('score', '相似度', note: '相似度得分（0.0~1.0，越接近 1 越相似）'),
      _outData('success', '成功', note: '正常完成匹配输出 true；未选择模板/模板加载失败/无可用图像/区域无效输出 false'),
    ],
    params: [
      ParamFieldDef(
        'templatePath',
        '模板图片',
        ParamType.templateFile,
        defaultValue: '',
      ),
      ParamFieldDef('threshold', '相似度阈值', ParamType.double, defaultValue: 0.8),
      ..._cornerFields,
    ],
  ),
  NodeTypeDef(
    type: 'condition',
    title: '条件判断',
    category: NodeCategory.logic,
    icon: Icons.call_split_rounded,
    description: '比较两个值，执行流走向 true 或 false 出口',
    inputs: [_inExec(), _inData('left', '左值'), _inData('right', '右值')],
    outputs: [
      PortDef('true', PortKind.exec, PortDir.output, '真'),
      PortDef('false', PortKind.exec, PortDir.output, '假'),
    ],
    params: [
      ParamFieldDef(
        'op',
        '比较方式',
        ParamType.enum_,
        defaultValue: '==',
        options: kCompareOptions,
      ),
      ParamFieldDef(
        'leftConst',
        '左值(无连接时)',
        ParamType.string,
        defaultValue: '',
        lockedByPort: 'left',
      ),
      ParamFieldDef(
        'rightConst',
        '右值(无连接时)',
        ParamType.string,
        defaultValue: '',
        lockedByPort: 'right',
      ),
    ],
  ),
  NodeTypeDef(
    type: 'loop',
    title: '循环',
    category: NodeCategory.logic,
    icon: Icons.loop_rounded,
    description:
        '条件循环：每次进入重新比较左右值，成立走「真（循环体）」，不成立走「假（结束循环）」；'
        '循环体最后节点必须连回本节点输入。',
    inputs: [
      _inExec('in', '进入 / 循环返回'),
      _inData('left', '左值'),
      _inData('right', '右值'),
    ],
    outputs: [
      PortDef('true', PortKind.exec, PortDir.output, '真（循环体）'),
      PortDef('false', PortKind.exec, PortDir.output, '假（结束循环）'),
    ],
    params: [
      ParamFieldDef(
        'op',
        '比较方式',
        ParamType.enum_,
        defaultValue: '==',
        options: kCompareOptions,
      ),
      ParamFieldDef(
        'leftConst',
        '左值(无连接时)',
        ParamType.string,
        defaultValue: '',
        lockedByPort: 'left',
      ),
      ParamFieldDef(
        'rightConst',
        '右值(无连接时)',
        ParamType.string,
        defaultValue: '',
        lockedByPort: 'right',
      ),
      ParamFieldDef(
        'maxIterations',
        '最大循环次数(0=不限制)',
        ParamType.int,
        defaultValue: 0,
        hint: '0 或负数 = 不限制；正数 = 最多进入循环体的次数',
      ),
    ],
  ),
  NodeTypeDef(
    type: 'delay',
    title: '延时',
    category: NodeCategory.logic,
    icon: Icons.timer_outlined,
    description: '等待指定毫秒后继续执行',
    inputs: [_inExec()],
    outputs: [_outExec()],
    params: [ParamFieldDef('ms', '等待毫秒', ParamType.int, defaultValue: 500)],
  ),
  NodeTypeDef(
    type: 'setVar',
    title: '设置变量',
    category: NodeCategory.data,
    icon: Icons.calculate_rounded,
    description: '新建或修改变量（数字/字符串/布尔自动推断）',
    inputs: [_inExec(), _inData('value', '值')],
    outputs: [
      _outExec(),
      _outData('valueOut', '值'),
      _outData('success', '成功', note: '变量名非空并成功写入输出 true；变量名为空输出 false'),
    ],
    params: [
      ParamFieldDef('name', '变量名', ParamType.varName, defaultValue: 'myVar'),
      ParamFieldDef(
        'const',
        '常量值(无连接时)',
        ParamType.string,
        defaultValue: '',
        lockedByPort: 'value',
      ),
    ],
  ),
  NodeTypeDef(
    type: 'getVar',
    title: '获取变量',
    category: NodeCategory.data,
    icon: Icons.data_object_rounded,
    description:
        '纯数据节点：下游消费「值」端口时读取变量当前值，不参与执行流；'
        '变量名可在属性面板下拉选择（或从节点库「变量」分类点击变量创建）',
    inputs: const [],
    outputs: [
      _outData('value', '值', note: '所选变量当前的值（数字/字符串/布尔），可连接任意数据输入端口'),
    ],
    params: [ParamFieldDef('name', '变量名', ParamType.varName, defaultValue: '')],
  ),
  NodeTypeDef(
    type: 'add',
    title: '加法',
    category: NodeCategory.data,
    icon: Icons.add_rounded,
    description: '计算 A + B，结果从「结果」端口输出（整数结果输出 int）',
    inputs: [_inExec(), _inData('a', 'A'), _inData('b', 'B')],
    outputs: [_outExec(), _outData('result', '结果')],
    params: [
      ParamFieldDef('a', 'A(无连接时)', ParamType.double, defaultValue: 0),
      ParamFieldDef('b', 'B(无连接时)', ParamType.double, defaultValue: 0),
    ],
  ),
  NodeTypeDef(
    type: 'subtract',
    title: '减法',
    category: NodeCategory.data,
    icon: Icons.remove_rounded,
    description: '计算 A − B，结果从「结果」端口输出（整数结果输出 int）',
    inputs: [_inExec(), _inData('a', 'A'), _inData('b', 'B')],
    outputs: [_outExec(), _outData('result', '结果')],
    params: [
      ParamFieldDef('a', 'A(无连接时)', ParamType.double, defaultValue: 0),
      ParamFieldDef('b', 'B(无连接时)', ParamType.double, defaultValue: 0),
    ],
  ),
  NodeTypeDef(
    type: 'saveData',
    title: '数据保存',
    category: NodeCategory.data,
    icon: Icons.save_as_outlined,
    description:
        '把上游数据保存为文件：文本存为 .txt，图像存为 .png，'
        '保存到「我的文档\\bluedot_clicker\\save\\」文件夹下，同名文件自动加序号；'
        '保存的数据从「文本」「图像」输出端口继续输出，可连线给下游使用（运行日志中也会显示保存路径）',
    inputs: [
      _inExec(),
      _inData('text', '文本', note: '可选。连接文本类输出（如「文字识别」的「文本」），保存为 .txt 文件'),
      _inData(
        'image',
        '图像',
        dataType: kPortTypeImage,
        note: '可选。连接「截图」节点的「图像」输出，保存为 .png 图片',
      ),
    ],
    outputs: [
      _outExec(),
      _outData('textOut', '文本', note: '透传所连接的「文本」输入数据，保存后可继续连线给下游节点'),
      _outData(
        'imageOut',
        '图像',
        dataType: kPortTypeImage,
        note: '透传所连接的「图像」输入数据，保存后可继续连线给下游节点',
      ),
      _outData('success', '成功', note: '成功保存至少一个文件输出 true；文件名为空或未连接文本/图像输入输出 false'),
    ],
    params: [
      ParamFieldDef(
        'fileName',
        '保存文件名',
        ParamType.string,
        defaultValue: 'result',
        hint: '不含扩展名',
      ),
    ],
  ),
];

final Map<String, NodeTypeDef> kNodeTypesById = {
  for (final t in kNodeTypes) t.type: t,
};

/// 未知/已移除节点类型的占位定义：无端口、无参数，属性面板只给删除入口。
/// （旧版 click/doubleClick/swipe/longPress/subScript 节点加载后会落到这里）
const NodeTypeDef kUnknownNodeDef = NodeTypeDef(
  type: '__unknown__',
  title: '未知节点',
  category: NodeCategory.logic,
  icon: Icons.help_outline_rounded,
  description: '该节点类型已移除或来自更新版本，无法编辑与执行；请删除后重建。',
  inputs: [],
  outputs: [],
  params: [],
);

/// 是否为当前版本支持的节点类型
bool isKnownNodeType(String type) => kNodeTypesById.containsKey(type);

/// 节点类型定义；未知类型返回 [kUnknownNodeDef]（不再是静默回退到延时）
NodeTypeDef nodeDef(String type) => kNodeTypesById[type] ?? kUnknownNodeDef;
