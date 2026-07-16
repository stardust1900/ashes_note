import 'dart:convert';

import 'package:ashes_note/logging.dart';
import 'package:ashes_note/models/rss/rss_models.dart';
import 'package:ashes_note/utils/const.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

/// 单次抓取结果
class RssFetchResult {
  final bool ok;
  final bool notModified; // 命中 304，内容未变
  final String? error;
  final String? title;
  final String? description;
  final String? siteUrl;
  final String? faviconUrl;
  String? etag;
  String? lastModified;
  final DateTime? lastUpdated;
  final List<RssArticle> articles;

  RssFetchResult({
    required this.ok,
    this.notModified = false,
    this.error,
    this.title,
    this.description,
    this.siteUrl,
    this.faviconUrl,
    this.etag,
    this.lastModified,
    this.lastUpdated,
    this.articles = const [],
  });
}

/// RSS/Atom 抓取与解析服务
class RssService {
  static const String _userAgent =
      'AshesNoteRssReader/1.0 (+https://gitee.com/wangyidao/ashes_note)';

  /// 抓取并解析单个订阅源。
  /// [existing] 用于携带条件请求头（ETag/Last-Modified）与保留已读/收藏状态。
  static Future<RssFetchResult> fetchFeed(
    String url, {
    RssFeed? existing,
  }) async {
    try {
      final headers = <String, String>{'User-Agent': _userAgent};
      if (existing?.etag != null) {
        headers['If-None-Match'] = existing!.etag!;
      }
      if (existing?.lastModified != null) {
        headers['If-Modified-Since'] = existing!.lastModified!;
      }

      final response = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 304) {
        return RssFetchResult(ok: true, notModified: true);
      }
      if (response.statusCode != 200) {
        return RssFetchResult(
          ok: false,
          error: 'HTTP ${response.statusCode}',
        );
      }

      final raw = _decodeBody(response);
      final parsed = _parseFeed(raw, existing?.id ?? '');
      if (!parsed.ok) return parsed;

      // 记录条件请求头，便于下次 304 命中
      parsed.etag ??= response.headers['etag'];
      parsed.lastModified ??= response.headers['last-modified'];
      return parsed;
    } catch (e) {
      return RssFetchResult(ok: false, error: e.toString());
    }
  }

  static String? _detectCharset(http.Response response) {
    final ct = response.headers['content-type'];
    if (ct == null) return null;
    final match = RegExp(
      r"""charset\s*=\s*['\"]?([^'\"\s;]+)""",
      caseSensitive: false,
    ).firstMatch(ct);
    return match?.group(1)?.trim().toLowerCase();
  }

  /// 从 XML 声明中提取 encoding 属性
  static String? _detectXmlEncoding(List<int> bytes) {
    if (bytes.isEmpty) return null;
    final head = bytes.length > 512 ? bytes.sublist(0, 512) : bytes;
    final headStr = String.fromCharCodes(head);
    final match = RegExp(
      r"""<\?xml[^>]*encoding\s*=\s*['\"]?([^'\"\s>]+)""",
      caseSensitive: false,
    ).firstMatch(headStr);
    return match?.group(1)?.trim().toLowerCase();
  }

  /// 根据 HTTP 头/XML 声明智能解码响应体
  static String _decodeBody(http.Response response) {
    final bytes = response.bodyBytes;
    if (bytes.isEmpty) return '';

    // 1. HTTP Content-Type
    var encoding = _detectCharset(response);

    // 2. XML 声明（补充或覆盖 utf-8 声明）
    if (encoding == null ||
        encoding == 'utf-8' ||
        encoding == 'utf8') {
      final xmlEncoding = _detectXmlEncoding(bytes);
      if (xmlEncoding != null &&
          xmlEncoding != 'utf-8' &&
          xmlEncoding != 'utf8') {
        encoding = xmlEncoding;
      }
    }

    final normalized = encoding?.replaceAll(RegExp(r'[-_]'), '');

    switch (normalized) {
      case 'gbk':
      case 'gb2312':
      case 'gb18030':
        try {
          return _stripBom(gbk.decode(bytes));
        } catch (_) {
          try {
            return _stripBom(GbkCodec(allowMalformed: true).decode(bytes));
          } catch (_) {
            return _stripBom(utf8.decode(bytes, allowMalformed: true));
          }
        }
      case 'latin1':
      case 'iso88591':
      case 'iso8859':
      case 'windows1252':
        // 很多中文 RSS 源被错误标记为 Latin-1/ISO-8859-1，实际内容是 UTF-8
        try {
          return _stripBom(utf8.decode(bytes, allowMalformed: false));
        } catch (_) {
          return _stripBom(String.fromCharCodes(bytes));
        }
      case 'utf8':
      case 'utf':
      case 'utf8bom':
      case null:
      default:
        return _stripBom(utf8.decode(bytes, allowMalformed: true));
    }
  }

  static String _stripBom(String text) {
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
      return text.substring(1);
    }
    return text;
  }

  /// 公开测试接口：按 Content-Type 与 XML 声明智能解码响应体
  static String decodeResponseBody(http.Response response) => _decodeBody(response);

  /// 解析订阅源字符串（公开，便于测试与复用）
  static RssFetchResult parseFeedString(String raw, String feedId) =>
      _parseFeed(raw, feedId);

  // ==================== 解析 ====================

  static RssFetchResult _parseFeed(String raw, String feedId) {
    try {
      final doc = xml.XmlDocument.parse(raw);
      final root = doc.rootElement;
      final local = root.name.local.toLowerCase();
      if (local == 'rss') {
        return _parseRss(root, feedId);
      } else if (local == 'feed') {
        return _parseAtom(root, feedId);
      } else if (local == 'rdf') {
        return _parseRdf(doc, feedId);
      }
      return RssFetchResult(ok: false, error: '无法识别的订阅源格式');
    } catch (e) {
      appLog.warning('RSS 解析失败: $e');
      return RssFetchResult(ok: false, error: '解析失败: $e');
    }
  }

  static RssFetchResult _parseRss(xml.XmlElement rss, String feedId) {
    final channel = _child(rss, 'channel');
    if (channel == null) {
      return RssFetchResult(ok: false, error: '缺少 channel');
    }
    String? siteUrl = _text(_child(channel, 'link'));
    String? favicon;
    final image = _child(channel, 'image');
    if (image != null) favicon = _text(_child(image, 'url'));

    final articles = <RssArticle>[];
    for (final item in channel.children.whereType<xml.XmlElement>()) {
      if (item.name.local.toLowerCase() != 'item') continue;
      articles.add(_rssItem(item, feedId));
    }
    return RssFetchResult(
      ok: true,
      title: _text(_child(channel, 'title')),
      description: _html(_child(channel, 'description')),
      siteUrl: siteUrl,
      faviconUrl: favicon,
      lastUpdated: _parseDate(_text(_child(channel, 'lastBuildDate'))),
      articles: articles,
    );
  }

  static RssArticle _rssItem(xml.XmlElement item, String feedId) {
    String? content = _html(_child(item, 'encoded')); // content:encoded
    content ??= _html(_child(item, 'content'));
    content ??= _html(_child(item, 'description'));
    // 部分源把正文放在 description 的 HTML 中，已在上一步覆盖
    String? summary = _html(_child(item, 'description'));
    String? author = _text(_child(item, 'author'));
    author ??= _text(_child(item, 'creator')); // dc:creator
    return RssArticle(
      feedId: feedId,
      title: _text(_child(item, 'title')) ?? '(无标题)',
      link: _text(_child(item, 'link')),
      author: author,
      published: _parseDate(_text(_child(item, 'pubDate'))),
      summary: summary,
      content: content,
      guid: _text(_child(item, 'guid')) ?? _text(_child(item, 'link')),
    );
  }

  static RssFetchResult _parseAtom(xml.XmlElement feed, String feedId) {
    String? siteUrl = _atomLinkHref(feed);
    final icon = _child(feed, 'icon') ?? _child(feed, 'logo');
    final articles = <RssArticle>[];
    for (final entry in feed.children.whereType<xml.XmlElement>()) {
      if (entry.name.local.toLowerCase() != 'entry') continue;
      articles.add(_atomEntry(entry, feedId));
    }
    return RssFetchResult(
      ok: true,
      title: _text(_child(feed, 'title')),
      description: _html(_child(feed, 'subtitle')),
      siteUrl: siteUrl,
      faviconUrl: _text(icon),
      lastUpdated: _parseDate(_text(_child(feed, 'updated'))),
      articles: articles,
    );
  }

  static RssArticle _atomEntry(xml.XmlElement entry, String feedId) {
    String? content = _html(_child(entry, 'content'));
    content ??= _html(_child(entry, 'summary'));
    String? summary = _html(_child(entry, 'summary'));
    String? author;
    final authorEl = _child(entry, 'author');
    if (authorEl != null) author = _text(_child(authorEl, 'name'));
    final id = _text(_child(entry, 'id')) ?? _atomLinkHref(entry);
    return RssArticle(
      feedId: feedId,
      title: _text(_child(entry, 'title')) ?? '(无标题)',
      link: _atomLinkHref(entry),
      author: author,
      published: _parseDate(_text(_child(entry, 'published'))) ??
          _parseDate(_text(_child(entry, 'updated'))),
      summary: summary,
      content: content,
      guid: id,
    );
  }

  static RssFetchResult _parseRdf(xml.XmlDocument doc, String feedId) {
    // RSS 1.0 (RDF)：channel 与 item 平级
    xml.XmlElement? channel;
    final items = <xml.XmlElement>[];
    for (final el in doc.rootElement.children.whereType<xml.XmlElement>()) {
      final l = el.name.local.toLowerCase();
      if (l == 'channel') channel = el;
      if (l == 'item') items.add(el);
    }
    String? siteUrl = channel == null ? null : _text(_child(channel, 'link'));
    final articles = items.map((e) => _rssItem(e, feedId)).toList();
    return RssFetchResult(
      ok: true,
      title: channel == null ? null : _text(_child(channel, 'title')),
      description:
          channel == null ? null : _html(_child(channel, 'description')),
      siteUrl: siteUrl,
      lastUpdated: null,
      articles: articles,
    );
  }

  // ==================== 刷新与合并 ====================

  /// 刷新全部订阅源，合并新旧文章并保留已读/收藏状态。
  static Future<List<RssFeed>> refreshAll(List<RssFeed> feeds) async {
    final result = <RssFeed>[];
    // 遍历副本，避免刷新过程中（如用户增删源）原列表被并发修改
    for (final feed in List<RssFeed>.from(feeds)) {
      final res = await fetchFeed(feed.url, existing: feed);
      if (res.notModified) {
        // 内容未变，仅更新抓取时间
        feed.lastFetched = DateTime.now();
        feed.fetchError = null;
        result.add(feed);
        continue;
      }
      if (!res.ok) {
        feed.fetchError = res.error;
        feed.lastFetched = DateTime.now();
        result.add(feed);
        continue;
      }
      // 合并文章：以 dedupeKey 为键保留已读/收藏
      final oldMap = <String, RssArticle>{};
      for (final a in feed.articles) {
        oldMap[a.dedupeKey] = a;
      }
      final merged = <RssArticle>[];
      for (final a in res.articles) {
        final old = oldMap[a.dedupeKey];
        if (old != null) {
          a.isRead = old.isRead;
          a.isStarred = old.isStarred;
        }
        merged.add(a);
      }
      merged.sort((x, y) {
        final xp = x.published;
        final yp = y.published;
        if (xp == null && yp == null) return 0;
        if (xp == null) return 1;
        if (yp == null) return -1;
        return yp.compareTo(xp);
      });
      if (merged.length > RssConstants.maxArticlesPerFeed) {
        merged.length = RssConstants.maxArticlesPerFeed;
      }
      feed.title = res.title ?? feed.title;
      feed.description = res.description ?? feed.description;
      feed.siteUrl = res.siteUrl ?? feed.siteUrl;
      feed.faviconUrl = res.faviconUrl ?? _deriveFavicon(feed.siteUrl);
      feed.etag = res.etag;
      feed.lastModified = res.lastModified;
      feed.lastUpdated = res.lastUpdated;
      feed.lastFetched = DateTime.now();
      feed.fetchError = null;
      feed.articles = merged;
      result.add(feed);
    }
    return result;
  }

  /// 仅刷新单个订阅源（用于手动刷新某源）
  static Future<RssFeed> refreshOne(RssFeed feed) async {
    final list = await refreshAll([feed]);
    return list.first;
  }

  // ==================== 搜索 ====================

  /// 跨所有文章标题与正文的全文搜索（不区分大小写）
  static List<RssArticle> search(List<RssFeed> feeds, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    final out = <RssArticle>[];
    for (final feed in feeds) {
      for (final a in feed.articles) {
        final hay = '${a.title} ${a.summary ?? ''} ${a.content ?? ''}'
            .toLowerCase();
        if (hay.contains(q)) out.add(a);
      }
    }
    out.sort((x, y) {
      final xp = x.published;
      final yp = y.published;
      if (xp == null && yp == null) return 0;
      if (xp == null) return 1;
      if (yp == null) return -1;
      return yp.compareTo(xp);
    });
    return out;
  }

  // ==================== XML 辅助 ====================

  static xml.XmlElement? _child(xml.XmlElement el, String localName) {
    for (final c in el.children.whereType<xml.XmlElement>()) {
      if (c.name.local.toLowerCase() == localName.toLowerCase()) return c;
    }
    return null;
  }

  static String? _text(xml.XmlElement? el) {
    if (el == null) return null;
    final t = el.innerText.trim();
    return t.isEmpty ? null : t;
  }

  /// 取元素内部 HTML（用于 description/content）
  /// - 若元素仅有文本子节点（转义的 HTML 字符串或 CDATA），用 innerText 取得未转义内容
  /// - 若含真实子元素（如 content:encoded 中的 HTML 标签），用 innerXml 保留结构
  static String? _html(xml.XmlElement? el) {
    if (el == null) return null;
    final hasChildElements =
        el.children.any((c) => c is xml.XmlElement);
    final t = (hasChildElements ? el.innerXml : el.innerText).trim();
    return t.isEmpty ? null : t;
  }

  static String? _atomLinkHref(xml.XmlElement el) {
    xml.XmlElement? alternate;
    xml.XmlElement? first;
    for (final c in el.children.whereType<xml.XmlElement>()) {
      if (c.name.local.toLowerCase() != 'link') continue;
      first ??= c;
      final rel = c.getAttribute('rel');
      if (rel == 'alternate') {
        alternate = c;
        break;
      }
    }
    final target = alternate ?? first;
    return target?.getAttribute('href');
  }

  static String? _deriveFavicon(String? siteUrl) {
    if (siteUrl == null) return null;
    try {
      final uri = Uri.parse(siteUrl);
      if (uri.host.isEmpty) return null;
      return '${uri.scheme}://${uri.host}/favicon.ico';
    } catch (_) {
      return null;
    }
  }

  // ==================== 日期解析 ====================

  static final Map<String, int> _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  static DateTime? _parseDate(String? s) {
    if (s == null) return null;
    final str = s.trim();
    // 优先尝试 ISO8601（Atom）
    final iso = DateTime.tryParse(str);
    if (iso != null) return iso;
    // 退化解析 RFC822（RSS pubDate）
    try {
      final cleaned = str.replaceFirst(RegExp(r'^[A-Za-z]{3},\s*'), '');
      final tokens = cleaned.split(RegExp(r'\s+'));
      if (tokens.length >= 4) {
        final day = int.parse(tokens[0]);
        final mon = _months[tokens[1].toLowerCase()];
        if (mon == null) return null;
        final year = int.parse(tokens[2]);
        final timeParts = tokens[3].split(':');
        final hour = int.parse(timeParts[0]);
        final minute = int.parse(timeParts[1]);
        final second = timeParts.length > 2 ? int.parse(timeParts[2]) : 0;
        var dt = DateTime.utc(year, mon, day, hour, minute, second);
        if (tokens.length >= 5) {
          dt = _applyTz(dt, tokens[4]);
        }
        return dt;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static DateTime _applyTz(DateTime utc, String tz) {
    if (tz == 'GMT' || tz == 'UTC' || tz == 'Z') return utc;
    final sign = tz.startsWith('-') ? -1 : 1;
    final digits = tz.replaceAll(RegExp(r'[+\-]'), '');
    if (digits.length == 4) {
      final oh = int.tryParse(digits.substring(0, 2)) ?? 0;
      final om = int.tryParse(digits.substring(2, 4)) ?? 0;
      final offset = sign * (oh * 60 + om);
      return utc.subtract(Duration(minutes: offset));
    }
    return utc;
  }
}
