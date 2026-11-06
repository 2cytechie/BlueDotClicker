import 'package:fl_nodes_v2/fl_nodes_v2.dart' as fl;
import 'package:flutter/material.dart' show Color, Offset;

import '../../core/theme.dart';
import '../../models/blueprint.dart';
import '../../models/node_types.dart';

/// BlueprintScript（权威存储模型）与 fl_nodes_v2 图模型的双向桥接。
///
/// 存储格式不变（.bpc.json 为 BlueprintScript），fl_nodes 仅作编辑器视图层：
/// - 节点：BPNode.type → GraphNode.type；BPNode.params → GraphNode.data
/// - 连接：执行流边 ↔ control 端口连线，数据边 ↔ data 端口连线（端口 id 即 PortDef.key）
/// - 端口由 NodeDefinition resolution 派生，GraphNode 无需携带 ports

/// 数据端口统一类型标签；执行流端口用 'exec'（成对约束）
const String _kExecType = 'exec';

/// fl.NodePort 颜色（执行流=孔雀蓝，数据=青玉）
Color _portColor(bool isExec) => isExec ? AppColors.execWire : AppColors.dataWire;

fl.NodePort _toFlPort(PortDef p) {
  final isExec = p.kind == PortKind.exec;
  return p.dir == PortDir.input
      ? fl.NodePort.input(
          id: p.key,
          label: p.label.isEmpty ? null : p.label,
          kind: isExec ? fl.PortKind.control : fl.PortKind.data,
          dataType: isExec ? _kExecType : null,
          color: _portColor(isExec),
          maxConnections: isExec ? 1 : (p.dir == PortDir.input ? 1 : null),
        )
      : fl.NodePort.output(
          id: p.key,
          label: p.label.isEmpty ? null : p.label,
          kind: isExec ? fl.PortKind.control : fl.PortKind.data,
          dataType: isExec ? _kExecType : null,
          color: _portColor(isExec),
        );
}

/// 全部节点定义，由 kNodeTypes 生成
List<fl.NodeDefinition> buildNodeDefinitions() => [
      for (final def in kNodeTypes)
        fl.NodeDefinition(
          type: def.type,
          label: def.title,
          icon: def.icon,
          category: def.category.label,
          description: def.description,
          defaultWidth: 200,
          fields: [
            fl.StaticFieldFamily(
              id: 'params',
              fields: [
                for (final f in def.params)
                  fl.NodeField(key: f.key, defaultValue: f.defaultValue, label: f.label),
              ],
            ),
          ],
          ports: [
            fl.StaticPortFamily(id: 'ports', ports: [
              for (final p in def.inputs) _toFlPort(p),
              for (final p in def.outputs) _toFlPort(p),
            ]),
          ],
        ),
    ];

final fl.NodeDefinitionRegistry blueprintNodeRegistry =
    fl.NodeDefinitionRegistry(buildNodeDefinitions());

/// BlueprintScript → 编辑器图模型。
///
/// 已移除/未知类型的节点会原样保留（属性面板显示为「未知节点」，参数不丢），
/// 但它们没有端口，连同其连线一并过滤——否则会留下指向不存在端口的悬空引用。
fl.NodeGraph blueprintToGraph(BlueprintScript script) => fl.NodeGraph(
      nodes: [
        for (final n in script.nodes.values)
          fl.GraphNode(
            id: n.id,
            type: n.type,
            position: Offset(n.x, n.y),
            width: 200,
            data: Map<String, Object?>.of(n.params),
          ),
      ],
      connections: [
        for (final e in script.edges.values)
          if (_edgeEndpointsKnown(script, e))
            fl.NodeConnection(
              id: e.id,
              from: fl.PortRef(e.from.nodeId, e.from.port),
              to: fl.PortRef(e.to.nodeId, e.to.port),
            ),
      ],
    );

/// 连线两端都存在且都是当前版本支持的节点类型
bool _edgeEndpointsKnown(BlueprintScript script, BPEdge e) {
  final from = script.nodes[e.from.nodeId];
  final to = script.nodes[e.to.nodeId];
  return from != null &&
      to != null &&
      isKnownNodeType(from.type) &&
      isKnownNodeType(to.type);
}

/// 编辑器图模型 → BlueprintScript（保存/运行前调用）。
/// [variables] 必须透传：graph 中不承载脚本级初始变量，缺省会在保存时静默清空。
BlueprintScript graphToBlueprint(
  fl.NodeGraph graph, {
  required String name,
  DateTime? createdAt,
  Map<String, Object>? variables,
}) {
  final script = BlueprintScript(
    name: name,
    createdAt: createdAt,
    variables: variables,
  );
  for (final n in graph.nodes.values) {
    BPNode? def;
    try {
      def = BPNode(id: n.id, type: n.type, x: n.position.dx, y: n.position.dy);
    } catch (_) {
      continue;
    }
    // 已有参数覆盖默认值（保留未知键）
    def.params.addAll(Map<String, Object?>.of(n.data));
    script.nodes[n.id] = def;
  }
  for (final c in graph.connections.values) {
    final fromNode = script.nodes[c.from.nodeId];
    final toNode = script.nodes[c.to.nodeId];
    if (fromNode == null || toNode == null) continue;
    // 依据 from 端口的 kind 判定边类型
    final fromPort = fromNode.def.outputs.where((p) => p.key == c.from.portId).firstOrNull;
    if (fromPort == null) continue;
    script.edges[c.id] = BPEdge(
      id: c.id,
      from: PortRef(nodeId: c.from.nodeId, port: c.from.portId),
      to: PortRef(nodeId: c.to.nodeId, port: c.to.portId),
      kind: fromPort.kind == PortKind.exec ? EdgeKind.exec : EdgeKind.data,
    );
  }
  return script;
}

/// 连线校验：执行流输出口仅允许一条出边。
///
/// 引擎沿首条执行流边走（其余边被静默忽略），必须在源头拒绝，
/// 防止用户画出"看似并行、实则丢分支"的图；数据端口不受此限。
bool blueprintConnectionValidator(fl.ConnectionCheck check) {
  if (!check.allowedByDefault) return false;
  if (check.fromPort.kind == fl.PortKind.control) {
    for (final c in check.graph.connectionsOf(check.from.nodeId)) {
      if (c.from == check.from) return false;
    }
  }
  return true;
}
