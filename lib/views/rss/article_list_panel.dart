import 'package:ashes_note/models/rss/rss_models.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// 文章列表面板（右侧主区域）
class ArticleListPanel extends StatelessWidget {
  final List<RssArticle> articles;
  final Map<String, String> feedTitleById;
  final void Function(RssArticle) onOpen;
  final void Function(RssArticle) onToggleStar;

  const ArticleListPanel({
    super.key,
    required this.articles,
    required this.feedTitleById,
    required this.onOpen,
    required this.onToggleStar,
  });

  String _relativeTime(DateTime? dt) {
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return DateFormat.yMMMd().format(dt);
  }

  @override
  Widget build(BuildContext context) {
    if (articles.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.article_outlined,
                size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text('暂无文章', style: TextStyle(color: Colors.grey.shade500)),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: articles.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final a = articles[index];
        final feedName = feedTitleById[a.feedId] ?? '';
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onOpen(a),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!a.isRead)
                    Container(
                      margin: const EdgeInsets.only(top: 6, right: 8),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                    )
                  else
                    const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          a.title,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: a.isRead
                                ? FontWeight.normal
                                : FontWeight.w700,
                            color: a.isRead
                                ? Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.6)
                                : Theme.of(context).colorScheme.onSurface,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            if (feedName.isNotEmpty)
                              Expanded(
                                child: Text(
                                  feedName,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.5),
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            Text(
                              _relativeTime(a.published),
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      a.isStarred ? Icons.star : Icons.star_border,
                      color: a.isStarred ? Colors.amber : Colors.grey,
                      size: 20,
                    ),
                    onPressed: () => onToggleStar(a),
                    tooltip: a.isStarred ? '取消收藏' : '收藏',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
