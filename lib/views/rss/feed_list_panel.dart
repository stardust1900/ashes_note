import 'package:ashes_note/models/rss/rss_models.dart';
import 'package:ashes_note/utils/const.dart';
import 'package:flutter/material.dart';

/// 订阅源列表面板（左侧主区域）
class FeedListPanel extends StatelessWidget {
  final List<RssFeed> feeds;
  final String selectedId;
  final void Function(String) onSelect;
  final void Function(RssFeed) onEdit;
  final void Function(RssFeed) onDelete;
  final void Function(RssFeed) onMarkAllRead;
  final VoidCallback onRefresh;
  final VoidCallback onAddFeed;
  final VoidCallback onImport;
  final VoidCallback onExport;
  final bool isRefreshing;

  const FeedListPanel({
    super.key,
    required this.feeds,
    required this.selectedId,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
    required this.onMarkAllRead,
    required this.onRefresh,
    required this.onAddFeed,
    required this.onImport,
    required this.onExport,
    this.isRefreshing = false,
  });

  @override
  Widget build(BuildContext context) {
    final totalUnread = feeds.fold(0, (s, f) => s + f.unreadCount);
    final totalStarred = feeds.fold(0, (s, f) => s + f.starredCount);

    // 按分组归类
    final grouped = <String?, List<RssFeed>>{};
    for (final f in feeds) {
      grouped.putIfAbsent(f.category, () => []).add(f);
    }
    // 排序：未分组在前，其余按分组名排序
    final categories = grouped.keys.toList()
      ..sort((a, b) {
        if (a == null) return -1;
        if (b == null) return 1;
        return a.compareTo(b);
      });

    final children = <Widget>[];

    // 顶部操作栏：刷新 / 添加订阅 / 导入导出（位于“全部”之上）
    children.add(_buildActionBar(context));
    children.add(const Divider(height: 1));

    // 特殊视图
    children.add(_specialTile(
      context,
      icon: Icons.mark_as_unread,
      label: '未读',
      id: RssConstants.unreadFeedsId,
      badge: totalUnread,
    ));
    children.add(_specialTile(
      context,
      icon: Icons.star,
      label: '收藏',
      id: RssConstants.starredFeedsId,
      badge: totalStarred,
    ));
    children.add(const Divider(height: 1));

    for (final cat in categories) {
      if (cat != null) {
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
          child: Text(
            cat,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.grey),
          ),
        ));
      }
      for (final f in grouped[cat]!) {
        children.add(_feedTile(context, f));
      }
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: ListView(children: children),
    );
  }

  /// 顶部操作栏：刷新 / 添加订阅 / 导入导出
  Widget _buildActionBar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '刷新',
            icon: isRefreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 20),
            onPressed: isRefreshing ? null : onRefresh,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
          ),
          IconButton(
            tooltip: '添加订阅',
            icon: const Icon(Icons.add, size: 20),
            onPressed: onAddFeed,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
          ),
          PopupMenuButton<String>(
            tooltip: '导入 / 导出',
            icon: const Icon(Icons.swap_horiz, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'import',
                child: const Row(
                  children: [
                    Icon(Icons.file_download, size: 18),
                    SizedBox(width: 8),
                    Text('导入 OPML'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'export',
                child: const Row(
                  children: [
                    Icon(Icons.file_upload, size: 18),
                    SizedBox(width: 8),
                    Text('导出 OPML'),
                  ],
                ),
              ),
            ],
            onSelected: (v) {
              if (v == 'import') {
                onImport();
              } else if (v == 'export') {
                onExport();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _specialTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String id,
    required int badge,
    bool highlight = true,
  }) {
    final selected = selectedId == id;
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20),
      title: Text(label),
      trailing: badge > 0
          ? _badge(context, badge, highlight: highlight)
          : null,
      selected: selected,
      onTap: () => onSelect(id),
    );
  }

  Widget _feedTile(BuildContext context, RssFeed feed) {
    return _FeedTile(
      feed: feed,
      selected: selectedId == feed.id,
      onSelect: onSelect,
      onEdit: onEdit,
      onDelete: onDelete,
      onContextMenu: _showContextMenu,
      onLongPressMenu: _showMenu,
    );
  }

  /// 桌面端：在鼠标位置弹出右键上下文菜单
  Future<void> _showContextMenu(
    BuildContext context,
    RssFeed feed,
    Offset position,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'edit',
          child: Row(
            children: [
              Icon(Icons.edit, size: 18),
              SizedBox(width: 8),
              Text('编辑 / 分组'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'markAllRead',
          child: const Row(
            children: [
              Icon(Icons.done_all, size: 18),
              SizedBox(width: 8),
              Text('全部已读'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete, size: 18, color: Colors.red),
              SizedBox(width: 8),
              Text('删除', style: TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ],
    );
    if (value == 'edit') {
      onEdit(feed);
    } else if (value == 'markAllRead') {
      onMarkAllRead(feed);
    } else if (value == 'delete') {
      onDelete(feed);
    }
  }

  void _showMenu(BuildContext context, RssFeed feed) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('编辑 / 分组'),
              onTap: () {
                Navigator.pop(ctx);
                onEdit(feed);
              },
            ),
            ListTile(
              leading: const Icon(Icons.done_all),
              title: const Text('全部已读'),
              onTap: () {
                Navigator.pop(ctx);
                onMarkAllRead(feed);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('删除', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                onDelete(feed);
              },
            ),
          ],
        ),
      ),
    );
  }
}

Widget _favicon(RssFeed feed) {
  if (feed.faviconUrl != null && feed.faviconUrl!.isNotEmpty) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.network(
        feed.faviconUrl!,
        width: 20,
        height: 20,
        errorBuilder: (ctx, _, _) => const Icon(Icons.rss_feed, size: 20),
      ),
    );
  }
  return const Icon(Icons.rss_feed, size: 20);
}

Widget _badge(BuildContext context, int count, {bool highlight = true}) {
  final theme = Theme.of(context);
  final color = highlight ? theme.colorScheme.primary : theme.disabledColor;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: highlight ? color : color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      count > 999 ? '999+' : count.toString(),
      style: TextStyle(
        color: highlight ? Colors.white : color,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

/// 单个订阅源条目：鼠标悬停或选中时才显示删除图标（桌面端 hover）
class _FeedTile extends StatefulWidget {
  final RssFeed feed;
  final bool selected;
  final void Function(String) onSelect;
  final void Function(RssFeed) onEdit;
  final void Function(RssFeed) onDelete;
  final Future<void> Function(BuildContext, RssFeed, Offset) onContextMenu;
  final void Function(BuildContext, RssFeed) onLongPressMenu;

  const _FeedTile({
    required this.feed,
    required this.selected,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
    required this.onContextMenu,
    required this.onLongPressMenu,
  });

  @override
  State<_FeedTile> createState() => _FeedTileState();
}

class _FeedTileState extends State<_FeedTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final feed = widget.feed;
    final showActions = _hovering;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        // 桌面端：鼠标右键在点击位置弹出上下文菜单
        onSecondaryTapDown: (details) =>
            widget.onContextMenu(context, feed, details.globalPosition),
        child: ListTile(
          dense: true,
          leading: _favicon(feed),
          title: Text(
            feed.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: feed.fetchError != null
              ? Text(
                  feed.fetchError!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.red),
                )
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (feed.unreadCount > 0) _badge(context, feed.unreadCount),
              // 仅悬停/选中时显示删除入口
              if (showActions)
                IconButton(
                  tooltip: '删除订阅源',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  splashRadius: 18,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: () => widget.onDelete(feed),
                ),
            ],
          ),
          selected: widget.selected,
          onTap: () => widget.onSelect(feed.id),
          // 移动端：长按弹出底部菜单
          onLongPress: () => widget.onLongPressMenu(context, feed),
        ),
      ),
    );
  }
}
