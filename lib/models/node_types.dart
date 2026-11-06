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

class PortDef {
  final String key;
  final PortKind kind;
  final PortDir dir;
  final String label;

  /// 属性面板「输入端口说明」中展示的详细说明（仅需解释的输入口填写）
  final String? note;
  const PortDef(this.key, this.kind, this.dir, this.label, {this.note});
  Map<String, dynamic> toJson() => {
    'key': key,
    'kind': kind.name,
    'dir': dir.name,
    'label': label,
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

  const ParamFieldDef(
    this.key,
    this.label,
    this.type, {
    this.defaultValue,
    this.options = const [],
    this.hint,
    this.visibleWhen = const {},
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
PortDef _inData(String key, String label, {String? note}) =>
    PortDef(key, PortKind.data, PortDir.input, label, note: note);
PortDef _outData(String key, String label) =>
    PortDef(key, PortKind.data, PortDir.output, label);

const _regionFields = [
  ParamFieldDef('useRegion', '仅指定区域', ParamType.bool, defaultValue: false),
  ParamFieldDef('rx', '区域X', ParamType.int, defaultValue: 0),
  ParamFieldDef('ry', '区域Y', ParamType.int, defaultValue: 0),
  ParamFieldDef('rw', '区域宽', ParamType.int, defaultValue: 400),
  ParamFieldDef('rh', '区域高', ParamType.int, defaultValue: 300),
];

const _buttonOptions = [
  EnumOption('left', '左键'),
  EnumOption('right', '右键'),
  EnumOption('middle', '中键'),
];

/// 鼠标动作（`mouse` 节点的 action 取值）
const kMouseActions = [
  EnumOption('click', '单击'),
  EnumOption('doubleClick', '双击'),
  EnumOption('swipe', '滑动'),
  EnumOption('longPress', '长按'),
  EnumOption('scroll', '滚轮'),
  EnumOption('move', '移动到'),
  EnumOption('press', '按住'),
  EnumOption('release', '抬起'),
];

/// 键盘动作（`keyboard` 节点的 action 取值）
const kKeyboardActions = [
  EnumOption('tap', '按键'),
  EnumOption('combo', '组合键'),
  EnumOption('down', '按下'),
  EnumOption('up', '抬起'),
];

String _labelOf(List<EnumOption> options, Object? value) {
  for (final o in options) {
    if (o.value == '$value') return o.label;
  }
  return '${value ?? ''}';
}

/// 鼠标动作中文名（未知取值原样返回）
String mouseActionLabel(Object? action) => _labelOf(kMouseActions, action);

/// 键盘动作中文名（未知取值原样返回）
String keyboardActionLabel(Object? action) => _labelOf(kKeyboardActions, action);

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
        '按所选动作操作鼠标：单击/双击/滑动/长按/滚轮/移动到/按住/抬起。'
        '「按住」不自动抬起，需搭配「抬起」或依赖脚本停止时的自动释放。',
    inputs: [_inExec()],
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
        'x',
        'X 坐标',
        ParamType.int,
        defaultValue: 100,
        visibleWhen: const {
          'action': {'click', 'doubleClick', 'longPress', 'scroll', 'move', 'press'},
        },
      ),
      ParamFieldDef(
        'y',
        'Y 坐标',
        ParamType.int,
        defaultValue: 100,
        visibleWhen: const {
          'action': {'click', 'doubleClick', 'longPress', 'scroll', 'move', 'press'},
        },
      ),
      ParamFieldDef(
        'button',
        '鼠标键',
        ParamType.enum_,
        defaultValue: 'left',
        options: _buttonOptions,
        visibleWhen: const {
          'action': {'click', 'doubleClick', 'longPress', 'press', 'release'},
        },
      ),
      ParamFieldDef(
        'mode',
        '滑动模式',
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
        'startX',
        '起点X',
        ParamType.int,
        defaultValue: 400,
        visibleWhen: const {
          'action': {'swipe'},
        },
      ),
      ParamFieldDef(
        'startY',
        '起点Y',
        ParamType.int,
        defaultValue: 300,
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
        '滑动时长(ms)',
        ParamType.int,
        defaultValue: 300,
        visibleWhen: const {
          'action': {'swipe'},
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
        '滚轮水平(120=一格,正=右)',
        ParamType.int,
        defaultValue: 0,
        visibleWhen: const {
          'action': {'scroll'},
        },
      ),
      ParamFieldDef(
        'dy',
        '滚轮垂直(120=一格,正=上)',
        ParamType.int,
        defaultValue: 120,
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
        '按所选动作操作键盘：按键/组合键/按下/抬起。'
        '键位可从常用键下拉选择，或点「拾取」后按下实际按键。「按下」需搭配「抬起」。',
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
          'action': {'tap', 'down', 'up'},
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
    description: '回放选中的录制动作序列（点击/滑动/长按/滚轮/按键按录制时序依次执行）',
    inputs: [_inExec()],
    outputs: [_outExec()],
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
    description: '截取全屏或指定区域，供后续识别节点使用',
    inputs: [
      _inExec(),
      _inData(
        'image',
        '输入图像(可空)',
        note: '本节点不读取该输入——截图始终现场采集（全屏或上方设定的区域）；此端口保留以与其他媒体节点保持一致。',
      ),
    ],
    outputs: [_outExec(), _outData('imageOut', '图像')],
    params: _regionFields,
  ),
  NodeTypeDef(
    type: 'ocr',
    title: '文字识别',
    category: NodeCategory.media,
    icon: Icons.text_fields_rounded,
    description: '对图像/屏幕区域进行 OCR，文本写入变量',
    inputs: [
      _inExec(),
      _inData(
        'image',
        '输入图像(可空)',
        note:
            '可选数据输入。连接上游「截图」节点的「图像」输出时，直接识别该图像、不再重新截屏；不连接时自动现场截屏（或截取上方设定的区域）。'
            '注意：在编辑器里点「测试识别」取不到上游图像，会现场截屏。',
      ),
    ],
    outputs: [
      _outExec(),
      _outData('text', '文本'),
      _outData('x', '区域X'),
      _outData('y', '区域Y'),
    ],
    params: [
      ..._regionFields,
      ParamFieldDef(
        'resultVar',
        '文本存入变量',
        ParamType.varName,
        defaultValue: 'ocrText',
      ),
    ],
  ),
  NodeTypeDef(
    type: 'imageMatch',
    title: '图像识别',
    category: NodeCategory.media,
    icon: Icons.image_search_rounded,
    description: '在屏幕/图像中匹配模板图（游戏UI元素），命中结果写入变量',
    inputs: [
      _inExec(),
      _inData(
        'image',
        '输入图像(可空)',
        note: '可选数据输入。连接上游图像时在该图像内匹配模板；不连接时自动现场截屏（或截取上方设定的区域）。',
      ),
    ],
    outputs: [
      _outExec(),
      _outData('found', '是否命中'),
      _outData('x', '命中X'),
      _outData('y', '命中Y'),
      _outData('score', '相似度'),
    ],
    params: [
      ParamFieldDef(
        'templatePath',
        '模板图片',
        ParamType.templateFile,
        defaultValue: '',
      ),
      ParamFieldDef('threshold', '相似度阈值', ParamType.double, defaultValue: 0.8),
      ..._regionFields,
      ParamFieldDef(
        'foundVar',
        '命中标志存入变量',
        ParamType.varName,
        defaultValue: 'found',
      ),
      ParamFieldDef(
        'posXVar',
        '命中X存入变量',
        ParamType.varName,
        defaultValue: 'matchX',
      ),
      ParamFieldDef(
        'posYVar',
        '命中Y存入变量',
        ParamType.varName,
        defaultValue: 'matchY',
      ),
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
        options: [
          EnumOption('==', '等于'),
          EnumOption('!=', '不等于'),
          EnumOption('>', '大于'),
          EnumOption('<', '小于'),
          EnumOption('>=', '大于等于'),
          EnumOption('<=', '小于等于'),
          EnumOption('contains', '包含'),
        ],
      ),
      ParamFieldDef(
        'leftVar',
        '左值变量名(可空)',
        ParamType.varName,
        defaultValue: '',
      ),
      ParamFieldDef(
        'rightVar',
        '右值变量名(可空)',
        ParamType.varName,
        defaultValue: '',
      ),
      ParamFieldDef(
        'leftConst',
        '左值常量(无连接/变量时)',
        ParamType.string,
        defaultValue: '',
      ),
      ParamFieldDef(
        'rightConst',
        '右值常量(无连接/变量时)',
        ParamType.string,
        defaultValue: '',
      ),
    ],
  ),
  NodeTypeDef(
    type: 'loop',
    title: '循环',
    category: NodeCategory.logic,
    icon: Icons.loop_rounded,
    description: '循环执行 body 分支，次数为 0 表示无限循环；体内最后节点连回 continue 输入',
    inputs: [_inExec('enter', '进入'), _inExec('continue', '体返回')],
    outputs: [
      PortDef('body', PortKind.exec, PortDir.output, '循环体'),
      PortDef('done', PortKind.exec, PortDir.output, '完成'),
    ],
    params: [
      ParamFieldDef('count', '循环次数(0=无限)', ParamType.int, defaultValue: 3),
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
    outputs: [_outExec(), _outData('valueOut', '值')],
    params: [
      ParamFieldDef('name', '变量名', ParamType.varName, defaultValue: 'myVar'),
      ParamFieldDef('const', '常量值(无连接时)', ParamType.string, defaultValue: ''),
    ],
  ),
  NodeTypeDef(
    type: 'storage',
    title: '数据存取',
    category: NodeCategory.data,
    icon: Icons.save_outlined,
    description: '将变量持久化保存到磁盘，或从磁盘读取（键值对 JSON 数据文件）',
    inputs: [_inExec(), _inData('value', '保存值')],
    outputs: [_outExec(), _outData('valueOut', '读取值')],
    params: [
      ParamFieldDef(
        'action',
        '操作',
        ParamType.enum_,
        defaultValue: 'save',
        options: [EnumOption('save', '保存'), EnumOption('load', '读取')],
      ),
      ParamFieldDef('key', '存储键', ParamType.string, defaultValue: 'myKey'),
      ParamFieldDef('name', '关联变量名', ParamType.varName, defaultValue: 'myVar'),
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
