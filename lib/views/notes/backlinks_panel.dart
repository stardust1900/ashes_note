/// 反向链接面板：展示「被引用」「出链」「未解析链接」三段信息。
///
/// 桌面端嵌入笔记详情下方，移动端由底部抽屉承载。
library;

import 'package:flutter/material.dart';

import 'package:ashes_note/models/notes/note_index_models.dart';
import 'package:ashes_note/services/notes/note_link_index.dart';
import 'package:ashes_note/services/notes/notes_index_service.dart';

class BacklinksPanel extends StatefulWidget {
  /// 当前笔记 id。
  final String noteId;

  /// 打开某篇已存在笔记。
  final void Function(NoteRef ref)? onOpenNote;

  /// 点击未解析链接时回调（用于「一键创建」）。
  final void Function(String rawTarget)? onCreateNote;

  /// 是否默认展开「被引用」段。
  final bool initiallyExpanded;

  /// 紧凑模式（移动端抽屉内使用）。
  final bool dense;

  /// 外部滚动控制器。
  ///
  /// 传入时面板自行包一层 [SingleChildScrollView]，用于 [DraggableScrollableSheet]
  /// 这类需要把滚动位置交给外层手势的场景；不传则由父级负责滚动。
  final ScrollController? scrollController;

  const BacklinksPanel({
    super.key,
    required this.noteId,
    this.onOpenNote,
    this.onCreateNote,
    this.initiallyExpanded = true,
    this.dense = false,
    this.scrollController,
  });

  @override
  State<BacklinksPanel> createState() => _BacklinksPanelState();
}

class _BacklinksPanelState extends State<BacklinksPanel> {
  late bool _showBacklinks;
  bool _showOutlinks = false;
  bool _showUnresolved = false;

  @override
  void initState() {
    super.initState();
    _showBacklinks = widget.initiallyExpanded;
  }

  @override
  void didUpdateWidget(covariant BacklinksPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换笔记时收起次要分段，避免状态串页。
    if (oldWidget.noteId != widget.noteId) {
      _showBacklinks = widget.initiallyExpanded;
      _showOutlinks = false;
      _showUnresolved = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = NotesIndexService();

    return ListenableBuilder(
      listenable: index,
      builder: (context, _) {
        final backlinks = index.backlinksOf(widget.noteId);
        final outlinks = index
            .outlinksOf(widget.noteId)
            .where((o) => o.resolution is! LinkMissing)
            .toList();
        final unresolved = index.unresolvedOf(widget.noteId);

        final content = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSection(
              theme: theme,
              icon: Icons.call_received,
              title: '被引用',
              count: backlinks.length,
              expanded: _showBacklinks,
              onToggle: () => setState(() => _showBacklinks = !_showBacklinks),
              emptyHint: '还没有其他笔记引用这篇。',
              children: backlinks.map(_buildBacklinkTile).toList(),
            ),
            _buildSection(
              theme: theme,
              icon: Icons.call_made,
              title: '出链',
              count: outlinks.length,
              expanded: _showOutlinks,
              onToggle: () => setState(() => _showOutlinks = !_showOutlinks),
              emptyHint: '这篇笔记还没有引用其他笔记。',
              children: outlinks.map(_buildOutlinkTile).toList(),
            ),
            if (unresolved.isNotEmpty)
              _buildSection(
                theme: theme,
                icon: Icons.link_off,
                title: '未解析链接',
                count: unresolved.length,
                expanded: _showUnresolved,
                onToggle: () =>
                    setState(() => _showUnresolved = !_showUnresolved),
                emptyHint: '',
                children: unresolved.map(_buildUnresolvedTile).toList(),
              ),
          ],
        );

        final controller = widget.scrollController;
        if (controller == null) return content;
        return SingleChildScrollView(
          controller: controller,
          child: content,
        );
      },
    );
  }

  Widget _buildSection({
    required ThemeData theme,
    required IconData icon,
    required String title,
    required int count,
    required bool expanded,
    required VoidCallback onToggle,
    required String emptyHint,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: widget.dense ? 8 : 10,
            ),
            child: Row(
              children: [
                Icon(icon, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$count',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                const Spacer(),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: theme.hintColor,
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          if (children.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(36, 0, 12, 12),
              child: Text(
                emptyHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            )
          else
            ...children,
        Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.5)),
      ],
    );
  }

  Widget _buildBacklinkTile(Backlink backlink) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: () => widget.onOpenNote?.call(backlink.sourceRef),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(36, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    backlink.sourceRef.displayTitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (backlink.sourceRef.notebookName.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    backlink.sourceRef.notebookName,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ],
                if (backlink.matchCount > 1) ...[
                  const SizedBox(width: 6),
                  Text(
                    '×${backlink.matchCount}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 3),
            _buildHighlightedSnippet(theme, backlink),
          ],
        ),
      ),
    );
  }

  /// 把摘要按高亮区间拆成三段，中间一段加粗着色。
  Widget _buildHighlightedSnippet(ThemeData theme, Backlink backlink) {
    final base = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final snippet = backlink.snippet;

    final start = backlink.highlightStart.clamp(0, snippet.length);
    final end = (backlink.highlightStart + backlink.highlightLength)
        .clamp(start, snippet.length);

    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: base,
        children: [
          TextSpan(text: snippet.substring(0, start)),
          TextSpan(
            text: snippet.substring(start, end),
            style: base?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(text: snippet.substring(end)),
        ],
      ),
    );
  }

  Widget _buildOutlinkTile(OutLink out) {
    final theme = Theme.of(context);
    final resolution = out.resolution;

    final String label;
    final String? subtitle;
    NoteRef? ref;

    switch (resolution) {
      case LinkResolved(:final target):
        ref = target;
        label = target.displayTitle;
        subtitle = target.notebookName.isEmpty ? null : target.notebookName;
      case LinkAmbiguous(:final candidates):
        label = out.match.displayText;
        subtitle = '${candidates.length} 篇同名，点击选择';
      case LinkMissing():
        label = out.match.displayText;
        subtitle = null;
    }

    return InkWell(
      onTap: () {
        if (ref != null) {
          widget.onOpenNote?.call(ref);
        } else {
          widget.onCreateNote?.call(out.match.target);
        }
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(36, 7, 12, 7),
        child: Row(
          children: [
            Icon(Icons.north_east, size: 13, color: theme.hintColor),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  subtitle,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.hintColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildUnresolvedTile(OutLink out) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: () => widget.onCreateNote?.call(out.match.target),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(36, 7, 12, 7),
        child: Row(
          children: [
            Icon(Icons.add_circle_outline, size: 13, color: theme.hintColor),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                out.match.target,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.hintColor,
                  decoration: TextDecoration.underline,
                  decorationStyle: TextDecorationStyle.dashed,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '点击创建',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
