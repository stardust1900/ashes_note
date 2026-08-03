/// 关系图谱的力导向布局算法（纯 Dart，无 Flutter UI 依赖，便于单测）。
///
/// 采用简化的 Fruchterman–Reingold：
/// - 斥力 `k^2 / d`（所有节点两两之间）
/// - 引力 `d^2 / k`（有边相连的节点之间）
/// - 温度线性衰减，限制单步最大位移，保证收敛
library;

import 'dart:math' as math;

import 'package:ashes_note/models/notes/note_index_models.dart';
import 'package:ashes_note/utils/const.dart';

/// 二维向量（不依赖 Flutter 的 Offset）。
class Vec2 {
  double x;
  double y;
  Vec2(this.x, this.y);

  @override
  String toString() => '(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})';
}

class GraphLayout {
  final double width;
  final double height;

  /// nodeId -> 当前位置。
  final Map<String, Vec2> positions = {};

  /// 被用户拖拽固定的节点，不参与力的位移。
  final Set<String> pinned = {};

  List<GraphNode> _nodes = const [];
  List<GraphEdge> _edges = const [];

  /// 邻接表（无向），用于引力计算。
  final List<({int a, int b})> _edgeIndices = [];
  final Map<String, int> _indexOf = {};
  late List<Vec2> _displacement;

  double _temperature = 0;
  double _k = 1;
  int _iteration = 0;

  /// 布局版本号：每次位置变化自增，供 `shouldRepaint` 比较。
  int version = 0;

  GraphLayout({this.width = 1000, this.height = 800});

  /// 是否已收敛（温度耗尽或达到迭代上限）。
  bool get isSettled =>
      _iteration >= NoteIndexConstants.graphMaxIterations || _temperature <= 0.4;

  int get iteration => _iteration;

  List<GraphNode> get nodes => _nodes;
  List<GraphEdge> get edges => _edges;

  /// 载入图数据并初始化布局。
  ///
  /// 已存在的节点保留原位置，实现增量更新时的视觉连续性。
  void setGraph(NoteGraph graph, {bool preservePositions = true}) {
    _nodes = graph.nodes;
    _edges = graph.edges;

    _indexOf.clear();
    for (var i = 0; i < _nodes.length; i++) {
      _indexOf[_nodes[i].id] = i;
    }

    _edgeIndices.clear();
    for (final e in _edges) {
      final a = _indexOf[e.from];
      final b = _indexOf[e.to];
      if (a != null && b != null && a != b) {
        _edgeIndices.add((a: a, b: b));
      }
    }

    final old = preservePositions ? Map<String, Vec2>.from(positions) : {};
    positions.clear();

    // 初始位置按圆环均匀铺开，避免初始重叠导致斥力爆炸。
    final cx = width / 2;
    final cy = height / 2;
    final n = _nodes.length;
    // 节点数较少时缩小初始半径，让它们聚拢居中、整体完整可见。
    final baseRadius = math.min(width, height) * 0.35;
    final radius = n <= 1
        ? 0.0
        : (n <= 6 ? math.min(width, height) * 0.16 : baseRadius);
    _k = n == 0 ? 1 : math.sqrt(width * height / n) * 0.8;

    for (var i = 0; i < n; i++) {
      final id = _nodes[i].id;
      final kept = old[id];
      if (kept != null) {
        positions[id] = kept;
      } else {
        final angle = n <= 1 ? 0.0 : 2 * math.pi * i / n;
        positions[id] = Vec2(
          cx + radius * math.cos(angle),
          cy + radius * math.sin(angle),
        );
      }
    }

    pinned.removeWhere((id) => !positions.containsKey(id));

    _displacement = List.generate(n, (_) => Vec2(0, 0));
    _temperature = math.min(width, height) * 0.1;
    _iteration = 0;
    version++;
  }

  /// 推进若干步迭代。返回是否仍在变化。
  bool step([int iterations = 1]) {
    if (_nodes.isEmpty) return false;

    var moved = false;
    for (var s = 0; s < iterations && !isSettled; s++) {
      _stepOnce();
      moved = true;
    }
    if (moved) version++;
    return moved;
  }

  void _stepOnce() {
    final n = _nodes.length;
    for (var i = 0; i < n; i++) {
      _displacement[i].x = 0;
      _displacement[i].y = 0;
    }

    // 斥力：O(N^2)。节点数已在上层限制在 graphMaxNodes 以内。
    for (var i = 0; i < n; i++) {
      final pi = positions[_nodes[i].id]!;
      for (var j = i + 1; j < n; j++) {
        final pj = positions[_nodes[j].id]!;
        var dx = pi.x - pj.x;
        var dy = pi.y - pj.y;
        var dist = math.sqrt(dx * dx + dy * dy);

        // 完全重合时给一个确定性的微小扰动，避免除零与随机抖动。
        if (dist < 0.01) {
          dx = (i - j).toDouble() * 0.01 + 0.01;
          dy = (i + j).toDouble() * 0.01 + 0.01;
          dist = math.sqrt(dx * dx + dy * dy);
        }

        final force = _k * _k / dist;
        final fx = dx / dist * force;
        final fy = dy / dist * force;

        _displacement[i].x += fx;
        _displacement[i].y += fy;
        _displacement[j].x -= fx;
        _displacement[j].y -= fy;
      }
    }

    // 引力：仅作用于相连节点。
    for (final e in _edgeIndices) {
      final pa = positions[_nodes[e.a].id]!;
      final pb = positions[_nodes[e.b].id]!;
      final dx = pa.x - pb.x;
      final dy = pa.y - pb.y;
      final dist = math.max(math.sqrt(dx * dx + dy * dy), 0.01);

      final force = dist * dist / _k;
      final fx = dx / dist * force;
      final fy = dy / dist * force;

      _displacement[e.a].x -= fx;
      _displacement[e.a].y -= fy;
      _displacement[e.b].x += fx;
      _displacement[e.b].y += fy;
    }

    // 应用位移，限制单步最大移动量为当前温度。
    for (var i = 0; i < n; i++) {
      final id = _nodes[i].id;
      if (pinned.contains(id)) continue;

      final d = _displacement[i];
      final len = math.max(math.sqrt(d.x * d.x + d.y * d.y), 0.01);
      final limited = math.min(len, _temperature);

      final p = positions[id]!;
      p.x += d.x / len * limited;
      p.y += d.y / len * limited;

      // 约束在画布范围内，留出节点半径的余量。
      p.x = p.x.clamp(30.0, width - 30);
      p.y = p.y.clamp(30.0, height - 30);
    }

    _iteration++;
    // 线性退火。
    _temperature =
        math.min(width, height) *
        0.1 *
        (1 - _iteration / NoteIndexConstants.graphMaxIterations);
    if (_temperature < 0) _temperature = 0;
  }

  /// 一次性跑完布局（用于测试或需要立即出结果的场景）。
  void runToSettle() {
    while (!isSettled) {
      _stepOnce();
    }
    version++;
  }

  /// 手动移动某个节点（拖拽），并固定它。
  void moveNode(String id, double x, double y) {
    final p = positions[id];
    if (p == null) return;
    p.x = x.clamp(0.0, width);
    p.y = y.clamp(0.0, height);
    pinned.add(id);
    version++;
  }

  /// 解除节点固定。
  void unpin(String id) {
    if (pinned.remove(id)) version++;
  }

  /// 重新加热，让布局继续运动（拖拽结束后调用）。
  void reheat() {
    _iteration = (_iteration - 60).clamp(
      0,
      NoteIndexConstants.graphMaxIterations,
    );
    _temperature = math.min(width, height) * 0.04;
    version++;
  }

  /// 取节点位置，不存在时返回 null。
  Vec2? positionOf(String id) => positions[id];

  /// 命中测试：返回距离 [x],[y] 最近且在 [radius] 内的节点 id。
  String? hitTest(double x, double y, double radius) {
    String? best;
    var bestDist = radius * radius;

    for (final entry in positions.entries) {
      final dx = entry.value.x - x;
      final dy = entry.value.y - y;
      final d2 = dx * dx + dy * dy;
      if (d2 <= bestDist) {
        bestDist = d2;
        best = entry.key;
      }
    }
    return best;
  }
}
