/// 标签聚合与筛选面板。
///
/// 桌面端作为左侧栏「标签」页签内容，移动端作为底部抽屉内容。
library;

import 'package:flutter/material.dart';

import 'package:ashes_note/models/notes/note_index_models.dart';
import 'package:ashes_note/services/notes/notes_index_service.dart';
import 'package:ashes_note/utils/const.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:ashes_note/views/notes/tag_editor_bar.dart';

class TagFilterPanel extends StatefulWidget {
  /// 当前选中的标签集合。
  final Set<String> selectedTags;

  /// 是否要求同时满足全部选中标签。
  final bool matchAll;

  /// 选中集合变化时回调。
  final void Function(Set<String> tags) onSelectionChanged;

  /// 匹配模式变化时回调。
  final void Function(bool matchAll)? onMatchModeChanged;

  /// 是否允许管理标签（重命名/改色/删除）。
  final bool allowManage;

  const TagFilterPanel({
    super.key,
    required this.selectedTags,
    required this.onSelectionChanged,
    this.matchAll = false,
    this.onMatchModeChanged,
    this.allowManage = true,
  });

  @override
  State<TagFilterPanel> createState() => _TagFilterPanelState();
}

class _TagFilterPanelState extends State<TagFilterPanel> {
  bool _sortByName = false;

  @override
  void initState() {
    super.initState();
    _sortByName =
        SPUtil.get<String>(PrefKeys.noteTagSortMode, 'count') == 'name';
  }

  void _toggleSort() {
    setState(() => _sortByName = !_sortByName);
    SPUtil.set<String>(
      PrefKeys.noteTagSortMode,
      _sortByName ? 'name' : 'count',
    );
  }

  void _toggleTag(String tag) {
    final next = Set<String>.from(widget.selectedTags);
    if (!next.remove(tag)) next.add(tag);
    widget.onSelectionChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = NotesIndexService();

    return ListenableBuilder(
      listenable: index,
      builder: (context, _) {
        final tags = index.allTagsWithCount(sortByName: _sortByName);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(theme, tags.length),
            if (widget.selectedTags.isNotEmpty) _buildActiveFilterBar(theme),
            Expanded(
              child: tags.isEmpty
                  ? _buildEmpty(theme)
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: tags.length,
                      itemBuilder: (context, i) => _buildTagTile(theme, tags[i]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(ThemeData theme, int total) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 6),
      child: Row(
        children: [
          Icon(Icons.local_offer_outlined,
              size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            '标签',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Text('$total', style: theme.textTheme.labelSmall?.copyWith(
            color: theme.hintColor,
          )),
          const Spacer(),
          IconButton(
            icon: Icon(
              _sortByName ? Icons.sort_by_alpha : Icons.filter_list,
              size: 16,
            ),
            tooltip: _sortByName ? '按名称排序' : '按数量排序',
            visualDensity: VisualDensity.compact,
            onPressed: _toggleSort,
          ),
        ],
      ),
    );
  }

  Widget _buildActiveFilterBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      color: theme.colorScheme.primary.withValues(alpha: 0.06),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '已选 ${widget.selectedTags.length} 个标签',
              style: theme.textTheme.labelSmall,
            ),
          ),
          if (widget.selectedTags.length > 1 &&
              widget.onMatchModeChanged != null)
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              onPressed: () => widget.onMatchModeChanged!(!widget.matchAll),
              child: Text(
                widget.matchAll ? '全部满足' : '任一满足',
                style: theme.textTheme.labelSmall,
              ),
            ),
          IconButton(
            icon: const Icon(Icons.clear, size: 15),
            tooltip: '清空筛选',
            visualDensity: VisualDensity.compact,
            onPressed: () => widget.onSelectionChanged(<String>{}),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.local_offer_outlined, size: 32, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(
              '还没有标签',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.hintColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '在笔记详情顶部为笔记添加标签',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTagTile(ThemeData theme, TagEntry entry) {
    final selected = widget.selectedTags.contains(entry.name);
    final color = resolveTagColor(entry.name, theme);

    return InkWell(
      onTap: () => _toggleTag(entry.name),
      onSecondaryTapDown: widget.allowManage
          ? (d) => _showManageMenu(d.globalPosition, entry)
          : null,
      onLongPress: widget.allowManage
          ? () => _showManageMenu(null, entry)
          : null,
      child: Container(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.1)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                entry.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? theme.colorScheme.primary : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '${entry.count}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 6),
              Icon(Icons.check, size: 14, color: theme.colorScheme.primary),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _showManageMenu(Offset? position, TagEntry entry) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final pos = position ?? overlay.size.center(Offset.zero);

    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy,
        overlay.size.width - pos.dx,
        overlay.size.height - pos.dy,
      ),
      items: const [
        PopupMenuItem(value: 'rename', child: Text('重命名')),
        PopupMenuItem(value: 'color', child: Text('设置颜色')),
        PopupMenuItem(value: 'delete', child: Text('删除标签')),
      ],
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'rename':
        await _renameTag(entry);
      case 'color':
        await _pickColor(entry);
      case 'delete':
        await _deleteTag(entry);
    }
  }

  Future<void> _renameTag(TagEntry entry) async {
    final controller = TextEditingController(text: entry.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名标签'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '标签名'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();

    final trimmed = normalizeTagName(newName ?? '');
    if (trimmed.isEmpty || trimmed == entry.name) return;

    await NotesIndexService().renameTag(entry.name, trimmed);

    // 同步更新外部的选中集合，避免筛选条件指向已不存在的标签。
    if (widget.selectedTags.contains(entry.name)) {
      final next = Set<String>.from(widget.selectedTags)
        ..remove(entry.name)
        ..add(trimmed);
      widget.onSelectionChanged(next);
    }
  }

  Future<void> _pickColor(TagEntry entry) async {
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

    final picked = await showDialog<int?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('「${entry.name}」的颜色'),
        content: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            ...palette.map(
              (c) => InkWell(
                onTap: () => Navigator.pop(ctx, c),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: entry.color == c
                        ? Border.all(width: 3, color: Colors.white70)
                        : null,
                  ),
                ),
              ),
            ),
            InkWell(
              onTap: () => Navigator.pop(ctx, -1),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Theme.of(ctx).dividerColor),
                ),
                child: const Icon(Icons.restart_alt, size: 16),
              ),
            ),
          ],
        ),
      ),
    );

    if (picked == null) return;
    await NotesIndexService().setTagColor(
      entry.name,
      picked == -1 ? null : picked,
    );
  }

  Future<void> _deleteTag(TagEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除标签'),
        content: Text(
          '将从 ${entry.count} 篇笔记中移除「${entry.name}」，笔记本身不会被删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await NotesIndexService().deleteTag(entry.name);

    if (widget.selectedTags.contains(entry.name)) {
      widget.onSelectionChanged(
        Set<String>.from(widget.selectedTags)..remove(entry.name),
      );
    }
  }
}
