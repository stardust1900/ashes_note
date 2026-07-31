/// 笔记关系图谱：以 CustomPainter 自绘节点与有向边，力导向布局按帧推进。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:ashes_note/models/notes/note_index_models.dart';
import 'package:ashes_note/services/notes/notes_index_service.dart';
import 'package:ashes_note/utils/const.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:ashes_note/views/notes/graph_layout.dart';
import 'package:ashes_note/views/notes/tag_editor_bar.dart';

/// 节点着色依据。
enum GraphColorMode { notebook, tag }

class NoteGraphView extends StatefulWidget {
  /// 打开图谱时聚焦的笔记（可空）。
  final String? focusNoteId;

  /// 点击节点跳转。
  final void Function(NoteRef ref)? onOpenNote;

  const NoteGraphView({super.key, this.focusNoteId, this.onOpenNote});

  /// 以全屏对话框形式打开图谱。
  static Future<void> show(
    BuildContext context, {
    String? focusNoteId,
    void Function(NoteRef ref)? onOpenNote,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: MediaQuery.of(ctx).size.width * 0.9,
          height: MediaQuery.of(ctx).size.height * 0.85,
          child: NoteGraphView(
            focusNoteId: focusNoteId,
            onOpenNote: onOpenNote,
          ),
        ),
      ),
    );
  }

  @override
  State<NoteGraphView> createState() => _NoteGraphViewState();
}

class _NoteGraphViewState extends State<NoteGraphView>
    with SingleTickerProviderStateMixin {
  static const double _canvasWidth = 2000;
  static const double _canvasHeight = 1600;

  final GraphLayout _layout = GraphLayout(
    width: _canvasWidth,
    height: _canvasHeight,
  );
  final TransformationController _viewer = TransformationController();

  Ticker? _ticker;
  String? _hoveredId;
  String? _draggingId;
  String? _focusId;
  bool _neighborhoodMode = false;
  bool _showIsolated = true;
  bool _forcedNeighborhood = false;
  GraphColorMode _colorMode = GraphColorMode.notebook;

  /// 一度邻居集合，用于悬停高亮。
  Set<String> _highlighted = const {};

  @override
  void initState() {
    super.initState();

    _focusId = widget.focusNoteId;
    _neighborhoodMode = widget.focusNoteId != null;
    _showIsolated = SPUtil.get<bool>(PrefKeys.graphShowIsolated, true);
    _colorMode =
        SPUtil.get<String>(PrefKeys.graphColorMode, 'notebook') == 'tag'
        ? GraphColorMode.tag
        : GraphColorMode.notebook;

    _rebuildGraph();

    _ticker = createTicker((_) {
      if (_layout.isSettled) {
        _ticker?.stop();
        return;
      }
      _layout.step(2);
      setState(() {});
    })..start();

    NotesIndexService().addListener(_onIndexChanged);
  }

  @override
  void dispose() {
    NotesIndexService().removeListener(_onIndexChanged);
    _ticker?.dispose();
    _viewer.dispose();
    super.dispose();
  }

  void _onIndexChanged() {
    if (!mounted) return;
    _rebuildGraph();
    _restartTicker();
  }

  void _restartTicker() {
    _layout.reheat();
    if (_ticker != null && !_ticker!.isActive) _ticker!.start();
    if (mounted) setState(() {});
  }

  void _rebuildGraph() {
    final index = NotesIndexService();

    var graph = index.buildGraph(
      focusId: _neighborhoodMode ? _focusId : null,
      includeIsolated: _showIsolated,
    );

    // 节点过多时强制降级为邻域模式，避免 O(N^2) 布局卡顿。
    _forcedNeighborhood = false;
    if (graph.nodes.length > NoteIndexConstants.graphMaxNodes) {
      final fallbackFocus = _focusId ??
          (graph.nodes.isNotEmpty
              ? (graph.nodes.toList()
                    ..sort((a, b) => b.degree.compareTo(a.degree)))
                  .first
                  .id
              : null);
      if (fallbackFocus != null) {
        _forcedNeighborhood = true;
        _neighborhoodMode = true;
        _focusId = fallbackFocus;
        graph = index.buildGraph(
          focusId: fallbackFocus,
          includeIsolated: _showIsolated,
        );
      }
    }

    _layout.setGraph(graph);
  }

  void _updateHighlight(String? nodeId) {
    if (nodeId == null) {
      if (_highlighted.isEmpty && _hoveredId == null) return;
      setState(() {
        _hoveredId = null;
        _highlighted = const {};
      });
      return;
    }

    final neighbors = <String>{nodeId};
    for (final e in _layout.edges) {
      if (e.from == nodeId) neighbors.add(e.to);
      if (e.to == nodeId) neighbors.add(e.from);
    }

    setState(() {
      _hoveredId = nodeId;
      _highlighted = neighbors;
    });
  }

  /// 把组件本地坐标换算为画布坐标（撤销 InteractiveViewer 的缩放与平移）。
  Offset _toCanvas(Offset local) {
    final m = Matrix4.inverted(_viewer.value);
    // 仿射变换只涉及缩放与平移，直接用矩阵元素换算即可，
    // 无需引入 vector_math 的 Vector3。
    final x = m.storage[0] * local.dx + m.storage[4] * local.dy + m.storage[12];
    final y = m.storage[1] * local.dx + m.storage[5] * local.dy + m.storage[13];
    return Offset(x, y);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        _buildToolbar(theme),
        if (_forcedNeighborhood) _buildNotice(theme),
        Expanded(
          child: _layout.nodes.isEmpty
              ? _buildEmpty(theme)
              : _buildCanvas(theme),
        ),
      ],
    );
  }

  Widget _buildToolbar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Icon(Icons.hub_outlined, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            '关系图谱',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${_layout.nodes.length} 节点 · ${_layout.edges.length} 连接',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
          ),
          const Spacer(),
          if (_focusId != null)
            _buildToggle(
              theme,
              label: '仅当前邻域',
              value: _neighborhoodMode,
              onChanged: (v) {
                setState(() => _neighborhoodMode = v);
                _rebuildGraph();
                _restartTicker();
              },
            ),
          _buildToggle(
            theme,
            label: '显示孤立节点',
            value: _showIsolated,
            onChanged: (v) {
              setState(() => _showIsolated = v);
              SPUtil.set<bool>(PrefKeys.graphShowIsolated, v);
              _rebuildGraph();
              _restartTicker();
            },
          ),
          const SizedBox(width: 8),
          SegmentedButton<GraphColorMode>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(
                value: GraphColorMode.notebook,
                label: Text('按笔记本'),
              ),
              ButtonSegment(value: GraphColorMode.tag, label: Text('按标签')),
            ],
            selected: {_colorMode},
            onSelectionChanged: (s) {
              setState(() => _colorMode = s.first);
              SPUtil.set<String>(
                PrefKeys.graphColorMode,
                s.first == GraphColorMode.tag ? 'tag' : 'notebook',
              );
            },
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.center_focus_strong, size: 18),
            tooltip: '重置视图',
            onPressed: () {
              _viewer.value = Matrix4.identity();
              _layout.pinned.clear();
              _rebuildGraph();
              _restartTicker();
            },
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _buildToggle(
    ThemeData theme, {
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          Switch(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }

  Widget _buildNotice(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5),
      child: Text(
        '笔记数量较多，已自动切换为邻域视图以保证流畅度。',
        style: theme.textTheme.labelSmall,
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hub_outlined, size: 40, color: theme.hintColor),
          const SizedBox(height: 12),
          Text(
            '还没有可展示的笔记',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 4),
          Text(
            '用 [[笔记标题]] 在笔记之间建立链接',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas(ThemeData theme) {
    final colors = _buildColorMap(theme);

    return MouseRegion(
      onHover: (event) {
        final p = _toCanvas(event.localPosition);
        final hit = _layout.hitTest(p.dx, p.dy, 26);
        if (hit != _hoveredId) _updateHighlight(hit);
      },
      onExit: (_) => _updateHighlight(null),
      child: GestureDetector(
        onTapUp: (details) {
          final p = _toCanvas(details.localPosition);
          final hit = _layout.hitTest(p.dx, p.dy, 26);
          if (hit != null) _openNote(hit);
        },
        onPanStart: (details) {
          final p = _toCanvas(details.localPosition);
          _draggingId = _layout.hitTest(p.dx, p.dy, 26);
        },
        onPanUpdate: (details) {
          final id = _draggingId;
          if (id == null) return;
          final p = _toCanvas(details.localPosition);
          setState(() => _layout.moveNode(id, p.dx, p.dy));
        },
        onPanEnd: (_) {
          if (_draggingId != null) {
            _draggingId = null;
            _restartTicker();
          }
        },
        child: InteractiveViewer(
          transformationController: _viewer,
          minScale: 0.2,
          maxScale: 4,
          constrained: false,
          // 拖拽节点时禁用画布平移，避免手势冲突。
          panEnabled: _draggingId == null,
          boundaryMargin: const EdgeInsets.all(200),
          child: SizedBox(
            width: _canvasWidth,
            height: _canvasHeight,
            child: CustomPaint(
              painter: _GraphPainter(
                layout: _layout,
                theme: theme,
                colorOf: colors,
                hoveredId: _hoveredId,
                highlighted: _highlighted,
                focusId: _neighborhoodMode ? _focusId : null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 依当前着色模式为每个节点算出颜色。
  Map<String, Color> _buildColorMap(ThemeData theme) {
    final result = <String, Color>{};

    if (_colorMode == GraphColorMode.tag) {
      for (final n in _layout.nodes) {
        result[n.id] = n.tags.isEmpty
            ? theme.hintColor
            : resolveTagColor(n.tags.first, theme);
      }
      return result;
    }

    // 按笔记本着色：用稳定的调色板。
    const palette = <int>[
      0xFF4C8DF6,
      0xFF27AE60,
      0xFFE67E22,
      0xFF8E44AD,
      0xFF16A085,
      0xFFD35400,
      0xFF2980B9,
      0xFFC0392B,
    ];
    for (final n in _layout.nodes) {
      var hash = 0;
      for (final u in n.notebookName.codeUnits) {
        hash = (hash * 31 + u) & 0x7FFFFFFF;
      }
      result[n.id] = Color(palette[hash % palette.length]);
    }
    return result;
  }

  void _openNote(String nodeId) {
    if (!NotesIndexService().containsNote(nodeId)) return;
    widget.onOpenNote?.call(NoteRef.fromId(nodeId));
  }
}

class _GraphPainter extends CustomPainter {
  final GraphLayout layout;
  final ThemeData theme;
  final Map<String, Color> colorOf;
  final String? hoveredId;
  final Set<String> highlighted;
  final String? focusId;

  /// 记录绘制时的布局版本，用于 shouldRepaint 判断。
  final int layoutVersion;

  _GraphPainter({
    required this.layout,
    required this.theme,
    required this.colorOf,
    required this.hoveredId,
    required this.highlighted,
    required this.focusId,
  }) : layoutVersion = layout.version;

  bool get _dimOthers => highlighted.isNotEmpty;

  @override
  void paint(Canvas canvas, Size size) {
    _paintEdges(canvas);
    _paintNodes(canvas);
  }

  void _paintEdges(Canvas canvas) {
    final basePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = theme.dividerColor;

    for (final edge in layout.edges) {
      final from = layout.positionOf(edge.from);
      final to = layout.positionOf(edge.to);
      if (from == null || to == null) continue;

      final active =
          _dimOthers &&
          highlighted.contains(edge.from) &&
          highlighted.contains(edge.to);

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 1.8 : basePaint.strokeWidth
        ..color = active
            ? theme.colorScheme.primary.withValues(alpha: 0.8)
            : theme.dividerColor.withValues(alpha: _dimOthers ? 0.25 : 0.7);

      final start = Offset(from.x, from.y);
      final end = Offset(to.x, to.y);

      // 边的终点缩到目标节点边缘，让箭头不被节点盖住。
      final targetRadius = _radiusOf(edge.to);
      final dx = end.dx - start.dx;
      final dy = end.dy - start.dy;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist < 1) continue;
      final shrunk = Offset(
        end.dx - dx / dist * (targetRadius + 2),
        end.dy - dy / dist * (targetRadius + 2),
      );

      canvas.drawLine(start, shrunk, paint);
      _paintArrow(canvas, start, shrunk, paint);
    }
  }

  void _paintArrow(Canvas canvas, Offset start, Offset end, Paint paint) {
    const arrowSize = 6.0;
    final angle = math.atan2(end.dy - start.dy, end.dx - start.dx);

    final p1 = Offset(
      end.dx - arrowSize * math.cos(angle - math.pi / 7),
      end.dy - arrowSize * math.sin(angle - math.pi / 7),
    );
    final p2 = Offset(
      end.dx - arrowSize * math.cos(angle + math.pi / 7),
      end.dy - arrowSize * math.sin(angle + math.pi / 7),
    );

    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = paint.color;

    canvas.drawPath(
      Path()
        ..moveTo(end.dx, end.dy)
        ..lineTo(p1.dx, p1.dy)
        ..lineTo(p2.dx, p2.dy)
        ..close(),
      fill,
    );
  }

  double _radiusOf(String nodeId) {
    final node = layout.nodes.where((n) => n.id == nodeId).firstOrNull;
    if (node == null) return 8;
    // 入链越多，节点越大。
    return (8 + math.sqrt(node.inDegree.toDouble()) * 4).clamp(8.0, 26.0);
  }

  void _paintNodes(Canvas canvas) {
    for (final node in layout.nodes) {
      final pos = layout.positionOf(node.id);
      if (pos == null) continue;

      final center = Offset(pos.x, pos.y);
      final radius = _radiusOf(node.id);
      final isFocus = node.id == focusId;
      final isHovered = node.id == hoveredId;
      final dimmed = _dimOthers && !highlighted.contains(node.id);

      final baseColor = colorOf[node.id] ?? theme.colorScheme.primary;
      final color = dimmed ? baseColor.withValues(alpha: 0.2) : baseColor;

      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.fill
          ..color = color.withValues(alpha: dimmed ? 0.15 : 0.85),
      );

      if (isFocus || isHovered) {
        canvas.drawCircle(
          center,
          radius + 3,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = isFocus ? 2.5 : 1.5
            ..color = theme.colorScheme.primary,
        );
      }

      _paintLabel(canvas, node, center, radius, dimmed);
    }
  }

  void _paintLabel(
    Canvas canvas,
    GraphNode node,
    Offset center,
    double radius,
    bool dimmed,
  ) {
    final style = theme.textTheme.labelSmall?.copyWith(
      color: (theme.textTheme.labelSmall?.color ?? theme.hintColor).withValues(
        alpha: dimmed ? 0.25 : 1,
      ),
      fontWeight: node.id == hoveredId ? FontWeight.w600 : FontWeight.normal,
    );

    final painter = TextPainter(
      text: TextSpan(text: node.label, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 110);

    painter.paint(
      canvas,
      Offset(center.dx - painter.width / 2, center.dy + radius + 3),
    );
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) {
    return old.layoutVersion != layoutVersion ||
        old.hoveredId != hoveredId ||
        old.focusId != focusId ||
        old.highlighted.length != highlighted.length ||
        old.theme.brightness != theme.brightness;
  }
}
