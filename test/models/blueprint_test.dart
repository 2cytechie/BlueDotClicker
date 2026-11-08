import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:bluedot_clicker/models/blueprint.dart';

void main() {
  group('蓝图序列化往返', () {
    test('节点/连接/参数/变量完整还原', () {
      final s = BlueprintScript(name: '测试脚本')
        ..variables['found'] = true
        ..variables['score'] = 3.14
        ..variables['label'] = 'hello';
      s.nodes['n1'] = BPNode(
        id: 'n1',
        type: 'start',
        x: 10,
        y: 20,
        params: {},
      );
      s.nodes['n2'] = BPNode(id: 'n2', type: 'mouse', x: 200, y: 120)
        ..params['x'] = 500
        ..params['y'] = 300
        ..params['fingers'] = 3
        ..params['button'] = 'right';
      s.nodes['n3'] = BPNode(id: 'n3', type: 'condition', x: 400, y: 200)
        ..params['op'] = '>=';
      s.edges['e1'] = BPEdge(
        id: 'e1',
        from: const PortRef(nodeId: 'n1', port: 'out'),
        to: const PortRef(nodeId: 'n2', port: 'in'),
        kind: EdgeKind.exec,
      );
      s.edges['e2'] = BPEdge(
        id: 'e2',
        from: const PortRef(nodeId: 'n2', port: 'found'),
        to: const PortRef(nodeId: 'n3', port: 'left'),
        kind: EdgeKind.data,
      );

      final json = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
      final restored = BlueprintScript.fromJson(json);

      expect(restored.name, '测试脚本');
      expect(restored.variables['found'], true);
      expect(restored.variables['score'], 3.14);
      expect(restored.variables['label'], 'hello');
      expect(restored.nodes.length, 3);
      expect(restored.edges.length, 2);

      final n2 = restored.nodes['n2']!;
      expect(n2.params['x'], 500);
      expect(n2.params['fingers'], 3);
      expect(n2.params['button'], 'right');
      expect(n2.x, 200);
      expect(n2.y, 120);

      final e2 = restored.edges['e2']!;
      expect(e2.kind, EdgeKind.data);
      expect(e2.from.nodeId, 'n2');
      expect(e2.to.port, 'left');
    });

    test('JSON 字符串直接解析（导出格式）', () {
      const raw = '''
{
  "format": "bpc",
  "version": 1,
  "name": "导入测试",
  "updatedAt": "2026-01-01T10:00:00.000",
  "createdAt": "2026-01-01T09:00:00.000",
  "variables": {"a": 1},
  "nodes": [
    {"id": "x1", "type": "start", "x": 0.0, "y": 0.0, "params": {}},
    {"id": "x2", "type": "delay", "x": 300.0, "y": 0.0, "params": {"ms": 100}}
  ],
  "edges": [
    {"id": "xe", "from": {"node": "x1", "port": "out"}, "to": {"node": "x2", "port": "in"}, "kind": "exec"}
  ]
}
''';
      final s = BlueprintScript.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(s.nodes.length, 2);
      expect(s.findStart()!.id, 'x1');
      expect(s.nodes['x2']!.params['ms'], 100);
      // 二次序列化保持一致
      final again = BlueprintScript.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(again.toJson()['nodes'].toString(), s.toJson()['nodes'].toString());
    });

    test('录制动作序列化：含滚轮/按键的新动作 round-trip', () {
      final rec = Recording(
        id: 'r1',
        name: '测试录制',
        createdAt: DateTime(2026, 1, 1),
        actions: const [
          RecClick(0, 100, 200, count: 2),
          RecScroll(120, 300, 400, dy: 240),
          RecScroll(240, 300, 400, dx: -120),
          RecKey(360, 0x43, durationMs: 80),
          RecKey(480, 0x26, durationMs: 500, extended: true),
        ],
      );
      final json = jsonEncode(rec.toJson());
      final restored = Recording.fromJson(jsonDecode(json) as Map<String, dynamic>);
      expect(restored.id, 'r1');
      expect(restored.name, '测试录制');
      expect(restored.actions.length, 5);
      final s1 = restored.actions[1] as RecScroll;
      expect(s1.x, 300);
      expect(s1.y, 400);
      expect(s1.dy, 240);
      expect(s1.dx, 0);
      final s2 = restored.actions[2] as RecScroll;
      expect(s2.dx, -120);
      final k1 = restored.actions[3] as RecKey;
      expect(k1.vkCode, 0x43);
      expect(k1.durationMs, 80);
      expect(k1.extended, isFalse);
      final k2 = restored.actions[4] as RecKey;
      expect(k2.vkCode, 0x26);
      expect(k2.extended, isTrue);
    });

    test('录制名称可修改并持久化到 JSON', () {
      final rec = Recording(
        id: 'r1',
        name: '旧名称',
        createdAt: DateTime(2026, 1, 1),
        actions: const [RecClick(0, 1, 2)],
      );
      rec.name = '新名称';
      final restored = Recording.fromJson(
          jsonDecode(jsonEncode(rec.toJson())) as Map<String, dynamic>);
      expect(restored.name, '新名称');
    });

    test('旧媒体节点区域参数 rx/ry/rw/rh 加载时换算为两角点', () {
      final s = BlueprintScript.fromJson({
        'name': '旧区域',
        'nodes': [
          {
            'id': 'o1',
            'type': 'ocr',
            'x': 0.0,
            'y': 0.0,
            'params': {
              'useRegion': true,
              'rx': 100,
              'ry': 200,
              'rw': 300,
              'rh': 400,
            },
          },
        ],
        'edges': [],
      });
      final p = s.nodes['o1']!.params;
      expect(p['left'], 100);
      expect(p['top'], 200);
      expect(p['right'], 400);
      expect(p['bottom'], 600);
      expect(p.containsKey('rx'), isFalse);
      expect(p.containsKey('rw'), isFalse);
    });

    test('删除节点时级联删除连接', () {
      final s = BlueprintScript(name: 's');
      s.nodes['a'] = BPNode(id: 'a', type: 'start');
      s.nodes['b'] = BPNode(id: 'b', type: 'delay');
      s.edges['e'] = BPEdge(
          id: 'e',
          from: const PortRef(nodeId: 'a', port: 'out'),
          to: const PortRef(nodeId: 'b', port: 'in'),
          kind: EdgeKind.exec);
      s.removeNode('b');
      expect(s.edges, isEmpty);
    });

    test('组合键 RecCombo 序列化 round-trip', () {
      final rec = Recording(
        id: 'r2',
        name: '组合键录制',
        createdAt: DateTime(2026, 1, 1),
        actions: const [
          RecCombo(0, [0x11, 0x43],
              extendeds: [false, false], durationMs: 500),
        ],
      );
      final json = jsonEncode(rec.toJson());
      final restored = Recording.fromJson(jsonDecode(json) as Map<String, dynamic>);
      expect(restored.actions.length, 1);
      final combo = restored.actions.single as RecCombo;
      expect(combo.vkCodes, [0x11, 0x43]);
      expect(combo.durationMs, 500);
      expect(combo.offsetMs, 0);
    });

    test('旧格式（重叠独立 RecKey）加载时自动合并为 RecCombo', () {
      const raw = '''
{
  "id": "r3",
  "name": "旧录制",
  "createdAt": "2026-01-01T10:00:00.000",
  "actions": [
    {"kind": "RecKey", "offsetMs": 0, "vkCode": 17, "durationMs": 500, "extended": false},
    {"kind": "RecKey", "offsetMs": 100, "vkCode": 67, "durationMs": 60, "extended": false},
    {"kind": "RecClick", "offsetMs": 800, "x": 10, "y": 20, "count": 1, "button": "left"}
  ]
}
''';
      final restored =
          Recording.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(restored.actions.length, 2);
      final combo = restored.actions[0] as RecCombo;
      expect(combo.vkCodes, [17, 67]); // Ctrl + C
      expect(combo.offsetMs, 0);
      expect(combo.durationMs, 500); // 0+500 与 100+60 取最大
      expect(restored.actions[1], isA<RecClick>());
    });
  });
}
