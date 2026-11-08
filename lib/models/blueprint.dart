import 'node_types.dart';

/// 蓝图节点实例
class BPNode {
  final String id;
  final String type;
  double x;
  double y;
  final Map<String, dynamic> params;

  BPNode({
    required this.id,
    required this.type,
    this.x = 0,
    this.y = 0,
    Map<String, dynamic>? params,
  }) : params = _migrateParams(type, params ?? _defaultParams(type));

  NodeTypeDef get def => nodeDef(type);
  String get title => def.title;

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'x': x,
    'y': y,
    'params': params,
  };

  factory BPNode.fromJson(Map<String, dynamic> j) => BPNode(
    id: j['id'] as String,
    type: j['type'] as String,
    x: (j['x'] as num).toDouble(),
    y: (j['y'] as num).toDouble(),
    params: Map<String, dynamic>.from(j['params'] as Map? ?? const {}),
  );

  BPNode copyWith({
    String? id,
    double? x,
    double? y,
    Map<String, dynamic>? params,
  }) => BPNode(
    id: id ?? this.id,
    type: type,
    x: x ?? this.x,
    y: y ?? this.y,
    params: params ?? Map.of(this.params),
  );

  /// 生成默认参数（按类型定义）
  static Map<String, dynamic> _defaultParams(String type) {
    final m = <String, dynamic>{};
    for (final f in nodeDef(type).params) {
      m[f.key] = f.defaultValue;
    }
    return m;
  }

  /// 旧脚本参数迁移：媒体节点区域从 rx/ry/rw/rh 换算为两角点。
  /// 新键已存在时以新键为准；换算后移除旧键，保存时写回新格式。
  static Map<String, dynamic> _migrateParams(
    String type,
    Map<String, dynamic> params,
  ) {
    if (type != 'screenshot' && type != 'ocr' && type != 'imageMatch') {
      return params;
    }
    const oldKeys = ['rx', 'ry', 'rw', 'rh'];
    if (!oldKeys.any(params.containsKey)) return params;
    int intOf(String key, int fallback) {
      final v = params[key];
      if (v is num) return v.toInt();
      return int.tryParse('${v ?? ''}') ?? fallback;
    }

    final left = intOf('rx', 0);
    final top = intOf('ry', 0);
    final right = left + intOf('rw', 400);
    final bottom = top + intOf('rh', 300);
    params.putIfAbsent('left', () => left);
    params.putIfAbsent('top', () => top);
    params.putIfAbsent('right', () => right);
    params.putIfAbsent('bottom', () => bottom);
    for (final k in oldKeys) {
      params.remove(k);
    }
    return params;
  }
}

class PortRef {
  final String nodeId;
  final String port;
  const PortRef({required this.nodeId, required this.port});

  Map<String, dynamic> toJson() => {'node': nodeId, 'port': port};
  factory PortRef.fromJson(Map<String, dynamic> j) =>
      PortRef(nodeId: j['node'] as String, port: j['port'] as String);

  @override
  bool operator ==(Object other) =>
      other is PortRef && other.nodeId == nodeId && other.port == port;
  @override
  int get hashCode => Object.hash(nodeId, port);
  @override
  String toString() => '$nodeId.$port';
}

enum EdgeKind { exec, data }

class BPEdge {
  final String id;
  final PortRef from;
  final PortRef to;
  final EdgeKind kind;
  const BPEdge({
    required this.id,
    required this.from,
    required this.to,
    required this.kind,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'from': from.toJson(),
    'to': to.toJson(),
    'kind': kind.name,
  };

  factory BPEdge.fromJson(Map<String, dynamic> j) => BPEdge(
    id: j['id'] as String,
    from: PortRef.fromJson(Map<String, dynamic>.from(j['from'] as Map)),
    to: PortRef.fromJson(Map<String, dynamic>.from(j['to'] as Map)),
    kind: j['kind'] == 'data' ? EdgeKind.data : EdgeKind.exec,
  );
}

/// 蓝图脚本
class BlueprintScript {
  String name;
  final Map<String, BPNode> nodes;
  final Map<String, BPEdge> edges;

  /// 脚本级初始变量表
  final Map<String, Object> variables;
  DateTime updatedAt;
  final DateTime createdAt;

  BlueprintScript({
    required this.name,
    Map<String, BPNode>? nodes,
    Map<String, BPEdge>? edges,
    Map<String, Object>? variables,
    DateTime? updatedAt,
    DateTime? createdAt,
  }) : nodes = nodes ?? {},
       edges = edges ?? {},
       variables = variables ?? {},
       updatedAt = updatedAt ?? DateTime.now(),
       createdAt = createdAt ?? DateTime.now();

  BPNode? findStart() =>
      nodes.values.where((n) => n.type == 'start').firstOrNull;

  List<BPEdge> outEdges(String nodeId, String port, {EdgeKind? kind}) => edges
      .values
      .where(
        (e) =>
            e.from.nodeId == nodeId &&
            e.from.port == port &&
            (kind == null || e.kind == kind),
      )
      .toList();

  List<BPEdge> inEdges(String nodeId, String port, {EdgeKind? kind}) => edges
      .values
      .where(
        (e) =>
            e.to.nodeId == nodeId &&
            e.to.port == port &&
            (kind == null || e.kind == kind),
      )
      .toList();

  void removeNode(String nodeId) {
    nodes.remove(nodeId);
    edges.removeWhere(
      (k, e) => e.from.nodeId == nodeId || e.to.nodeId == nodeId,
    );
  }

  Map<String, dynamic> toJson() => {
    'format': 'bpc',
    'version': 1,
    'name': name,
    'updatedAt': updatedAt.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'variables': variables,
    'nodes': nodes.values.map((n) => n.toJson()).toList(),
    'edges': edges.values.map((e) => e.toJson()).toList(),
  };

  factory BlueprintScript.fromJson(Map<String, dynamic> j) => BlueprintScript(
    name: (j['name'] as String?) ?? '未命名',
    updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
    createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
    variables: Map<String, Object>.from(j['variables'] as Map? ?? const {}),
    nodes: {
      for (final n in (j['nodes'] as List? ?? []))
        (n as Map<String, dynamic>)['id'] as String: BPNode.fromJson(
          Map<String, dynamic>.from(n),
        ),
    },
    edges: {
      for (final e in (j['edges'] as List? ?? []))
        (e as Map<String, dynamic>)['id'] as String: BPEdge.fromJson(
          Map<String, dynamic>.from(e),
        ),
    },
  );

  BlueprintScript copy() => BlueprintScript.fromJson(toJson());
}

/// 录制生成的操作序列（可回放、可转为蓝图节点）
sealed class RecordedAction {
  final int offsetMs;
  const RecordedAction(this.offsetMs);
  Map<String, dynamic> toJson() => {
    'kind': runtimeType.toString(),
    'offsetMs': offsetMs,
  };
}

class RecClick extends RecordedAction {
  final int x, y, count;
  final String button;
  const RecClick(
    super.offsetMs,
    this.x,
    this.y, {
    this.count = 1,
    this.button = 'left',
  });
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'x': x,
    'y': y,
    'count': count,
    'button': button,
  };
}

class RecSwipe extends RecordedAction {
  final int x1, y1, x2, y2, durationMs;
  const RecSwipe(
    super.offsetMs,
    this.x1,
    this.y1,
    this.x2,
    this.y2,
    this.durationMs,
  );
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'x1': x1,
    'y1': y1,
    'x2': x2,
    'y2': y2,
    'durationMs': durationMs,
  };
}

class RecLongPress extends RecordedAction {
  final int x, y, durationMs;
  const RecLongPress(super.offsetMs, this.x, this.y, this.durationMs);
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'x': x,
    'y': y,
    'durationMs': durationMs,
  };
}

/// 鼠标滚轮滚动（dy 正=上滚，120 为一格；一次事件只在一维上有 delta）
class RecScroll extends RecordedAction {
  final int x, y, dx, dy;
  const RecScroll(super.offsetMs, this.x, this.y, {this.dx = 0, this.dy = 0});
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'x': x,
    'y': y,
    'dx': dx,
    'dy': dy,
  };
}

/// 键盘按键（一次按下+抬起，durationMs 为按住时长）
class RecKey extends RecordedAction {
  final int vkCode, durationMs;
  final bool extended;
  const RecKey(
    super.offsetMs,
    this.vkCode, {
    this.durationMs = 60,
    this.extended = false,
  });
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'vkCode': vkCode,
    'durationMs': durationMs,
    'extended': extended,
  };
}

/// 组合键（多个键按下时间重叠形成，如 Ctrl+C；vkCodes 按按下顺序，最后一个为主键）
class RecCombo extends RecordedAction {
  final List<int> vkCodes;
  final List<bool> extendeds; // 与 vkCodes 对齐，不足补 false
  final int durationMs; // 整组跨度：首个键按下 → 最后一个键抬起
  const RecCombo(
    super.offsetMs,
    this.vkCodes, {
    this.extendeds = const [],
    this.durationMs = 60,
  });
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'vkCodes': vkCodes,
    'extendeds': extendeds,
    'durationMs': durationMs,
  };
}

/// 操作记录（录制会话）
class Recording {
  final String id;
  String name;
  final DateTime createdAt;
  final List<RecordedAction> actions;
  Recording({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.actions,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'actions': actions.map((a) => a.toJson()).toList(),
  };

  factory Recording.fromJson(Map<String, dynamic> j) => Recording(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '录制',
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
    // 旧版本录制把组合键存成多个独立 RecKey，加载时合并修复（幂等）
    actions: mergeKeyCombos(
      (j['actions'] as List? ?? [])
          .map((a) => _actionFromJson(Map<String, dynamic>.from(a as Map)))
          .whereType<RecordedAction>()
          .toList(),
    ),
  );

  static RecordedAction? _actionFromJson(Map<String, dynamic> j) {
    final offset = (j['offsetMs'] as num).toInt();
    switch (j['kind']) {
      case 'RecClick':
        return RecClick(
          offset,
          (j['x'] as num).toInt(),
          (j['y'] as num).toInt(),
          count: (j['count'] as num?)?.toInt() ?? 1,
          button: j['button'] as String? ?? 'left',
        );
      case 'RecSwipe':
        return RecSwipe(
          offset,
          (j['x1'] as num).toInt(),
          (j['y1'] as num).toInt(),
          (j['x2'] as num).toInt(),
          (j['y2'] as num).toInt(),
          (j['durationMs'] as num).toInt(),
        );
      case 'RecLongPress':
        return RecLongPress(
          offset,
          (j['x'] as num).toInt(),
          (j['y'] as num).toInt(),
          (j['durationMs'] as num).toInt(),
        );
      case 'RecScroll':
        return RecScroll(
          offset,
          (j['x'] as num).toInt(),
          (j['y'] as num).toInt(),
          dx: (j['dx'] as num?)?.toInt() ?? 0,
          dy: (j['dy'] as num?)?.toInt() ?? 0,
        );
      case 'RecKey':
        return RecKey(
          offset,
          (j['vkCode'] as num).toInt(),
          durationMs: (j['durationMs'] as num?)?.toInt() ?? 60,
          extended: j['extended'] as bool? ?? false,
        );
      case 'RecCombo':
        return RecCombo(
          offset,
          ((j['vkCodes'] as List?) ?? const [])
              .map((e) => (e as num).toInt())
              .toList(),
          extendeds: ((j['extendeds'] as List?) ?? const [])
              .map((e) => e as bool)
              .toList(),
          durationMs: (j['durationMs'] as num?)?.toInt() ?? 60,
        );
    }
    return null;
  }
}

/// 把时间上重叠的按键簇合并为 RecCombo（组合键）。
///
/// 分簇规则：新键与簇中【任意成员】的按下区间 [offset, offset+duration] 相交 → 同簇。
/// （长按修饰键期间连点其他键——如 Alt+Tab 切换窗口——整簇相连，不会被中途切断。）
///
/// 簇可合并条件（嵌套判据）：按下时刻升序后，所有 down_i < down_j 均满足
/// up_i >= up_j（先按下的键持续到后按下的键抬起之后）。
/// - 嵌套簇（Ctrl+C、Ctrl+Shift+A）→ RecCombo：按下→按住→逆序抬起可精确表达；
/// - 交错簇（长按 Alt 连点 Tab：前一个 Tab 早于后一个 Tab 抬起）→ 保持独立
///   RecKey 序列——RecCombo 模型表达不了交错，独立键交给回放端事件流精确还原。
/// 非 RecKey 动作打断簇保持原位；已是 RecCombo 的动作原样保留（幂等）。
List<RecordedAction> mergeKeyCombos(List<RecordedAction> actions) {
  final out = <RecordedAction>[];
  var cluster = <RecKey>[];

  bool overlapsAny(RecKey k) {
    for (final c in cluster) {
      if (k.offsetMs >= c.offsetMs && k.offsetMs <= c.offsetMs + c.durationMs) {
        return true;
      }
    }
    return false;
  }

  void flush() {
    if (cluster.isEmpty) return;
    if (cluster.length > 1) {
      final sorted = List.of(cluster)
        ..sort((a, b) => a.offsetMs.compareTo(b.offsetMs));
      var nested = true;
      outerLoop:
      for (var i = 0; i < sorted.length; i++) {
        final upI = sorted[i].offsetMs + sorted[i].durationMs;
        for (var j = i + 1; j < sorted.length; j++) {
          final upJ = sorted[j].offsetMs + sorted[j].durationMs;
          if (upI < upJ) {
            nested = false;
            break outerLoop;
          }
        }
      }
      if (nested) {
        final start = sorted.first.offsetMs;
        var end = 0;
        for (final k in sorted) {
          final e = k.offsetMs + k.durationMs;
          if (e > end) end = e;
        }
        out.add(RecCombo(
          start,
          sorted.map((k) => k.vkCode).toList(),
          extendeds: sorted.map((k) => k.extended).toList(),
          durationMs: (end - start).clamp(1, 60000),
        ));
        cluster = [];
        return;
      }
    }
    out.addAll(cluster); // 单键簇或交错簇 → 原样（保持录制顺序）
    cluster = [];
  }

  for (final a in actions) {
    if (a is RecKey) {
      if (cluster.isNotEmpty && overlapsAny(a)) {
        cluster.add(a);
      } else {
        flush();
        cluster.add(a);
      }
    } else {
      flush();
      out.add(a);
    }
  }
  flush();
  return out;
}
