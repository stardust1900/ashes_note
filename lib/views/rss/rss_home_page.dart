import 'dart:async';

import 'package:ashes_note/models/rss/rss_models.dart';
import 'package:ashes_note/services/rss/rss_service.dart';
import 'package:ashes_note/services/rss/rss_storage_service.dart';
import 'package:ashes_note/utils/const.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:ashes_note/views/rss/add_feed_dialog.dart';
import 'package:ashes_note/views/rss/article_list_panel.dart';
import 'package:ashes_note/views/rss/article_view_page.dart';
import 'package:ashes_note/views/rss/feed_list_panel.dart';
import 'package:ashes_note/views/rss/opml_dialog.dart';
import 'package:flutter/material.dart';

/// RSS 阅读器主页（主从布局）
class RssHomePage extends StatefulWidget {
  const RssHomePage({super.key});

  @override
  State<RssHomePage> createState() => _RssHomePageState();
}

class _RssHomePageState extends State<RssHomePage> {
  final _storage = RssStorageService();
  List<RssFeed> _feeds = [];
  String _selectedId = RssConstants.allFeedsId;
  String _searchQuery = '';
  bool _isRefreshing = false;
  Timer? _refreshTimer;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _selectedId = SPUtil.get<String>(
        PrefKeys.rssLastSelectedFeedId, RssConstants.allFeedsId);
    _loadAndMaybeRefresh();
    _setupAutoRefresh();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadAndMaybeRefresh() async {
    final loaded = await _storage.loadFeeds();
    if (!mounted) return;
    setState(() => _feeds = loaded);
    if (loaded.isNotEmpty) _refreshAll();
  }

  void _setupAutoRefresh() {
    final minutes = SPUtil.get<int>(
        PrefKeys.rssRefreshInterval, RssConstants.defaultRefreshInterval);
    if (minutes <= 0) return;
    _refreshTimer = Timer.periodic(Duration(minutes: minutes), (_) {
      if (!_isRefreshing) _refreshAll();
    });
  }

  Future<void> _refreshAll() async {
    // 防重入：正在刷新或没有订阅源时直接返回，避免并发刷新改同一批对象
    if (_isRefreshing || _feeds.isEmpty) return;
    if (!mounted) return;
    setState(() => _isRefreshing = true);
    final updated = await RssService.refreshAll(_feeds);
    await _storage.saveFeeds(updated);
    if (!mounted) return;
    setState(() {
      _feeds = updated;
      _isRefreshing = false;
    });
  }

  Future<void> _persist() async {
    await _storage.saveFeeds(_feeds);
  }

  void _onSelect(String id) {
    SPUtil.set(PrefKeys.rssLastSelectedFeedId, id);
    setState(() {
      _selectedId = id;
      _selectedArticle = null; // 退出详情，返回所点源的文章列表
    });
  }

  void _onSearchChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(RssConstants.searchDebounce, () {
      if (mounted) setState(() => _searchQuery = q.trim());
    });
  }

  RssArticle? _selectedArticle;
  List<RssArticle> _articleContext = []; // 打开详情时的文章列表快照，用于上一篇/下一篇

  List<RssArticle> _currentArticles() {
    List<RssArticle> list;
    switch (_selectedId) {
      case RssConstants.allFeedsId:
        list = _feeds.expand((f) => f.articles).toList();
        break;
      case RssConstants.unreadFeedsId:
        list = _feeds
            .expand((f) => f.articles)
            .where((a) => !a.isRead)
            .toList();
        break;
      case RssConstants.starredFeedsId:
        list = _feeds
            .expand((f) => f.articles)
            .where((a) => a.isStarred)
            .toList();
        break;
      default:
        final feed = _feeds.where((f) => f.id == _selectedId).firstOrNull;
        list = feed?.articles ?? [];
    }
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list
          .where((a) =>
              '${a.title} ${a.summary ?? ''} ${a.content ?? ''}'
                  .toLowerCase()
                  .contains(q))
          .toList();
    }
    list.sort((x, y) {
      final xp = x.published;
      final yp = y.published;
      if (xp == null && yp == null) return 0;
      if (xp == null) return 1;
      if (yp == null) return -1;
      return yp.compareTo(xp);
    });
    return list;
  }

  Map<String, String> _feedTitleMap() =>
      {for (final f in _feeds) f.id: f.title};

  void _openArticle(RssArticle article) {
    // 就地展示详情：在右侧区域替换列表，并保存当前列表用于上一篇/下一篇
    setState(() {
      _selectedArticle = article;
      _articleContext = _currentArticles();
    });
  }

  void _backToList() {
    setState(() => _selectedArticle = null);
  }

  void _navigateArticle(int delta) {
    final current = _selectedArticle;
    if (current == null || _articleContext.isEmpty) return;
    final idx = _articleContext.indexWhere((a) => a.id == current.id);
    if (idx < 0) return;
    final newIdx = idx + delta;
    if (newIdx < 0 || newIdx >= _articleContext.length) return;
    setState(() => _selectedArticle = _articleContext[newIdx]);
  }

  void _toggleStar(RssArticle article) {
    article.isStarred = !article.isStarred;
    _persist();
    setState(() {});
  }

  Future<void> _addFeed() async {
    final result = await showDialog<RssFeed?>(
      context: context,
      builder: (_) => const AddFeedDialog(),
    );
    if (result != null) {
      setState(() => _feeds.add(result));
      await _persist();
      _refreshAll();
    }
  }

  Future<void> _editFeed(RssFeed feed) async {
    final updated = await showDialog<RssFeed?>(
      context: context,
      builder: (_) => AddFeedDialog(feed: feed),
    );
    if (updated != null) {
      await _persist();
      setState(() {});
      _refreshAll();
    }
  }

  void _markAllRead(RssFeed feed) {
    for (final a in feed.articles) {
      a.isRead = true;
    }
    _persist();
    setState(() {});
  }

  Future<void> _deleteFeed(RssFeed feed) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除订阅源'),
        content: Text('确定删除「${feed.title}」？已缓存的文章也会移除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      setState(() => _feeds.removeWhere((f) => f.id == feed.id));
      await _persist();
    }
  }

  Future<void> _openOpml() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => OpmlDialog(feeds: _feeds),
    );
    if (changed == true) {
      final loaded = await _storage.loadFeeds();
      setState(() => _feeds = loaded);
      _refreshAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSmall = MediaQuery.of(context).size.width < 600;
    final articles = _currentArticles();
    final feedPanelWidth = isSmall ? 160.0 : 280.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('RSS 阅读器'),
      ),
      body: Row(
        children: [
          SizedBox(
            width: feedPanelWidth,
            child: FeedListPanel(
              feeds: _feeds,
              selectedId: _selectedId,
              onSelect: _onSelect,
              onEdit: _editFeed,
              onDelete: _deleteFeed,
              onMarkAllRead: _markAllRead,
              onRefresh: _refreshAll,
              onAddFeed: _addFeed,
              onImport: _openOpml,
              onExport: _openOpml,
              isRefreshing: _isRefreshing,
            ),
          ),
          Expanded(
            child: _selectedArticle == null
                ? Column(
                    children: [
                      _buildSearchBar(),
                      Expanded(
                        child: ArticleListPanel(
                          articles: articles,
                          feedTitleById: _feedTitleMap(),
                          onOpen: _openArticle,
                          onToggleStar: _toggleStar,
                        ),
                      ),
                    ],
                  )
                : _buildArticleDetail(),
          ),
        ],
      ),
    );
  }

  Widget _buildArticleDetail() {
    final article = _selectedArticle!;
    final idx = _articleContext.indexWhere((a) => a.id == article.id);
    final hasPrev = idx > 0;
    final hasNext = idx >= 0 && idx < _articleContext.length - 1;
    return ArticleViewPage(
      // 用文章 id 作为 key，切换上一篇/下一篇时重建以重新触发标记已读
      key: Key(article.id),
      article: article,
      feedTitle: _feeds
          .where((f) => f.id == article.feedId)
          .firstOrNull
          ?.title,
      onUpdated: () {
        _persist();
        setState(() {});
      },
      onBack: _backToList,
      onPrev: hasPrev ? () => _navigateArticle(-1) : null,
      onNext: hasNext ? () => _navigateArticle(1) : null,
      hasPrev: hasPrev,
      hasNext: hasNext,
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        decoration: InputDecoration(
          hintText: '搜索文章…',
          prefixIcon: const Icon(Icons.search, size: 20),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Theme.of(context).dividerColor),
          ),
          filled: true,
          fillColor: Theme.of(context).colorScheme.surface,
        ),
        onChanged: _onSearchChanged,
      ),
    );
  }
}
