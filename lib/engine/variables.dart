/// 脚本级变量表：支持数字/字符串/布尔
class VariableTable {
  final Map<String, Object> _vars;

  VariableTable([Map<String, Object>? initial]) : _vars = Map.of(initial ?? {});

  Object? operator [](String name) => _vars[name];

  void operator []=(String name, Object value) => _vars[name] = value;

  void remove(String name) => _vars.remove(name);

  bool contains(String name) => _vars.containsKey(name);

  Map<String, Object> snapshot() => Map.of(_vars);

  /// 尝试解析字面量为强类型（int/double/bool），否则原样字符串
  static Object parseLiteral(String raw) {
    final s = raw.trim();
    if (s == 'true') return true;
    if (s == 'false') return false;
    final i = int.tryParse(s);
    if (i != null) return i;
    final d = double.tryParse(s);
    if (d != null) return d;
    return raw;
  }
}

/// 值比较（条件判断节点）
bool compareValues(Object? left, Object? right, String op) {
  final l = left ?? '';
  final r = right ?? '';
  switch (op) {
    case 'contains':
      return l.toString().contains(r.toString());
    case 'notContains':
      return !l.toString().contains(r.toString());
    case '==':
      return _eq(l, r);
    case '!=':
      return !_eq(l, r);
  }
  // 数值比较优先
  final ln = num.tryParse(l.toString());
  final rn = num.tryParse(r.toString());
  final cmp = (ln != null && rn != null)
      ? ln.compareTo(rn)
      : l.toString().compareTo(r.toString());
  return switch (op) {
    '>' => cmp > 0,
    '<' => cmp < 0,
    '>=' => cmp >= 0,
    '<=' => cmp <= 0,
    _ => false,
  };
}

bool _eq(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  final ab = _asBool(a);
  final bb = _asBool(b);
  if (ab != null && bb != null) return ab == bb;
  return a.toString() == b.toString();
}

bool? _asBool(Object? v) {
  if (v is bool) return v;
  if (v == 'true') return true;
  if (v == 'false') return false;
  if (v is num) return v != 0;
  return null;
}
