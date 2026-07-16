import 'package:ashes_note/models/rss/rss_models.dart';
import 'package:xml/xml.dart' as xml;

/// OPML 导入/导出服务（批量迁移订阅源）
class OpmlService {
  /// 解析 OPML 字符串，返回订阅源（title/url/category）
  static List<OpmlFeed> parse(String raw) {
    final feeds = <OpmlFeed>[];
    try {
      final doc = xml.XmlDocument.parse(raw);
      final body = _child(doc.rootElement, 'body');
      if (body == null) return feeds;
      _walk(body, null, feeds);
    } catch (_) {
      // 解析失败返回已收集的部分
    }
    return feeds;
  }

  static void _walk(
    xml.XmlElement el,
    String? parentCategory,
    List<OpmlFeed> out,
  ) {
      for (final c in el.children.whereType<xml.XmlElement>()) {
        if (c.name.local.toLowerCase() != 'outline') continue;
        final xmlUrl = c.getAttribute('xmlUrl');
        if (xmlUrl?.isNotEmpty == true) {
        final title = c.getAttribute('title') ??
            c.getAttribute('text') ??
            '未命名订阅源';
        out.add(OpmlFeed(
          title: title,
          url: xmlUrl!,
          category: parentCategory,
        ));
      } else {
        // 分组节点
        final groupName =
            c.getAttribute('title') ?? c.getAttribute('text');
        _walk(c, groupName ?? parentCategory, out);
      }
    }
  }

  /// 生成 OPML 字符串
  static String build(List<RssFeed> feeds) {
    final grouped = <String?, List<RssFeed>>{};
    for (final f in feeds) {
      grouped.putIfAbsent(f.category, () => []).add(f);
    }
    final builder = xml.XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element('opml', attributes: {'version': '2.0'}, nest: () {
      builder.element('head', nest: () {
        builder.element('title', nest: 'AshesNote RSS Subscriptions');
      });
      builder.element('body', nest: () {
        // 无分组订阅源放顶层
        for (final f in grouped[null] ?? []) {
          _outline(builder, f);
        }
        // 按分组嵌套
        for (final entry in grouped.entries) {
          if (entry.key == null) continue;
          builder.element('outline',
              attributes: {'text': entry.key!, 'title': entry.key!},
              nest: () {
            for (final f in entry.value) {
              _outline(builder, f);
            }
          });
        }
      });
    });
    return builder.buildDocument().toXmlString(pretty: true);
  }

  static void _outline(xml.XmlBuilder builder, RssFeed feed) {
    builder.element('outline', attributes: {
      'text': feed.title,
      'title': feed.title,
      'type': 'rss',
      'xmlUrl': feed.url,
      if (feed.siteUrl != null) 'htmlUrl': feed.siteUrl!,
      if (feed.description != null) 'description': feed.description!,
    });
  }

  static xml.XmlElement? _child(xml.XmlElement el, String localName) {
    for (final c in el.children.whereType<xml.XmlElement>()) {
      if (c.name.local.toLowerCase() == localName.toLowerCase()) return c;
    }
    return null;
  }
}

/// OPML 中的单个订阅源
class OpmlFeed {
  final String title;
  final String url;
  final String? category;
  OpmlFeed({required this.title, required this.url, this.category});
}
