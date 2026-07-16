import 'package:uuid/uuid.dart';

/// RSS 文章模型
class RssArticle {
  final String id;
  final String feedId;
  String title;
  String? link;
  String? author;
  DateTime? published;
  String? summary; // 摘要（可能是纯文本或 HTML 片段）
  String? content; // 正文 HTML
  bool isRead;
  bool isStarred;
  final String? guid; // 源站唯一标识，用于去重

  RssArticle({
    String? id,
    required this.feedId,
    required this.title,
    this.link,
    this.author,
    this.published,
    this.summary,
    this.content,
    this.isRead = false,
    this.isStarred = false,
    this.guid,
  }) : id = id ?? const Uuid().v4();

  Map<String, dynamic> toJson() => {
        'id': id,
        'feedId': feedId,
        'title': title,
        'link': link,
        'author': author,
        'published': published?.toIso8601String(),
        'summary': summary,
        'content': content,
        'isRead': isRead,
        'isStarred': isStarred,
        'guid': guid,
      };

  factory RssArticle.fromJson(Map<String, dynamic> json) => RssArticle(
        id: json['id'] as String,
        feedId: json['feedId'] as String,
        title: json['title'] as String,
        link: json['link'] as String?,
        author: json['author'] as String?,
        published: json['published'] == null
            ? null
            : DateTime.tryParse(json['published'] as String),
        summary: json['summary'] as String?,
        content: json['content'] as String?,
        isRead: json['isRead'] as bool? ?? false,
        isStarred: json['isStarred'] as bool? ?? false,
        guid: json['guid'] as String?,
      );

  /// 用于去重的稳定键（优先 guid，其次 link，最后标题）
  String get dedupeKey => (guid?.isNotEmpty == true)
      ? guid!
      : (link?.isNotEmpty == true ? link! : title);
}

/// RSS 订阅源模型
class RssFeed {
  final String id;
  String title;
  String url;
  String? category; // 分组/分类名称，null 表示未分组
  String? description;
  String? faviconUrl;
  String? siteUrl;
  DateTime? lastUpdated; // 源内容最后更新时间
  DateTime? lastFetched; // 最近一次成功抓取时间
  String? etag; // 条件请求 ETag
  String? lastModified; // 条件请求 Last-Modified
  String? fetchError; // 最近一次抓取错误（null 表示正常）
  List<RssArticle> articles;

  RssFeed({
    String? id,
    required this.title,
    required this.url,
    this.category,
    this.description,
    this.faviconUrl,
    this.siteUrl,
    this.lastUpdated,
    this.lastFetched,
    this.etag,
    this.lastModified,
    this.fetchError,
    List<RssArticle>? articles,
  })  : id = id ?? const Uuid().v4(),
        articles = articles ?? [];

  /// 未读数（实时计算，避免冗余存储）
  int get unreadCount => articles.where((a) => !a.isRead).length;

  /// 收藏数
  int get starredCount => articles.where((a) => a.isStarred).length;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'url': url,
        'category': category,
        'description': description,
        'faviconUrl': faviconUrl,
        'siteUrl': siteUrl,
        'lastUpdated': lastUpdated?.toIso8601String(),
        'lastFetched': lastFetched?.toIso8601String(),
        'etag': etag,
        'lastModified': lastModified,
        'fetchError': fetchError,
        'articles': articles.map((a) => a.toJson()).toList(),
      };

  factory RssFeed.fromJson(Map<String, dynamic> json) => RssFeed(
        id: json['id'] as String,
        title: json['title'] as String,
        url: json['url'] as String,
        category: json['category'] as String?,
        description: json['description'] as String?,
        faviconUrl: json['faviconUrl'] as String?,
        siteUrl: json['siteUrl'] as String?,
        lastUpdated: json['lastUpdated'] == null
            ? null
            : DateTime.tryParse(json['lastUpdated'] as String),
        lastFetched: json['lastFetched'] == null
            ? null
            : DateTime.tryParse(json['lastFetched'] as String),
        etag: json['etag'] as String?,
        lastModified: json['lastModified'] as String?,
        fetchError: json['fetchError'] as String?,
        articles: (json['articles'] as List<dynamic>? ?? [])
            .map((e) => RssArticle.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
