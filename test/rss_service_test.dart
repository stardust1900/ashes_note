import 'dart:convert';

import 'package:ashes_note/models/rss/rss_models.dart';
import 'package:ashes_note/services/rss/opml_service.dart';
import 'package:ashes_note/services/rss/rss_service.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;


const _rssXml = '''
<?xml version="1.0"?>
<rss version="2.0">
  <channel>
    <title>Test Feed</title>
    <link>https://example.com</link>
    <description>RSS description</description>
    <lastBuildDate>Wed, 02 Oct 2002 13:00:00 GMT</lastBuildDate>
    <item>
      <title>Item 1</title>
      <link>https://example.com/1</link>
      <description>&lt;p&gt;Hello&lt;/p&gt;</description>
      <author>john@example.com</author>
      <pubDate>Tue, 15 Nov 2022 12:00:00 +0000</pubDate>
      <guid>guid-1</guid>
    </item>
    <item>
      <title>Item 2</title>
      <link>https://example.com/2</link>
      <description>Second</description>
    </item>
  </channel>
</rss>
''';

const _atomXml = '''
<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom Feed</title>
  <link rel="alternate" href="https://atom.example.com"/>
  <updated>2022-11-15T12:00:00Z</updated>
  <entry>
    <id>atom-1</id>
    <title>Atom Item</title>
    <link rel="alternate" href="https://atom.example.com/1"/>
    <author><name>Jane</name></author>
    <published>2022-11-15T10:00:00Z</published>
    <content>&lt;p&gt;Atom content&lt;/p&gt;</content>
  </entry>
</feed>
''';

const _opmlXml = '''
<?xml version="1.0"?>
<opml version="2.0">
  <body>
    <outline text="Group A" title="Group A">
      <outline text="Feed1" title="Feed1" xmlUrl="https://a.com/feed"/>
    </outline>
    <outline text="Feed2" title="Feed2" xmlUrl="https://b.com/feed"/>
  </body>
</opml>
''';

void main() {
  group('RssService 解析', () {
    test('解析 RSS 2.0', () {
      final res = RssService.parseFeedString(_rssXml, 'feed-1');
      expect(res.ok, isTrue);
      expect(res.title, 'Test Feed');
      expect(res.articles.length, 2);
      final a = res.articles.first;
      expect(a.title, 'Item 1');
      expect(a.link, 'https://example.com/1');
      expect(a.author, 'john@example.com');
      expect(a.content, '<p>Hello</p>');
      expect(a.published, isNotNull);
      expect(a.guid, 'guid-1');
    });

    test('解析 Atom', () {
      final res = RssService.parseFeedString(_atomXml, 'feed-2');
      expect(res.ok, isTrue);
      expect(res.title, 'Atom Feed');
      expect(res.articles.length, 1);
      final a = res.articles.first;
      expect(a.title, 'Atom Item');
      expect(a.link, 'https://atom.example.com/1');
      expect(a.author, 'Jane');
      expect(a.content, '<p>Atom content</p>');
    });

    test('无法识别的格式返回错误', () {
      final res = RssService.parseFeedString('<html></html>', 'x');
      expect(res.ok, isFalse);
    });
  });

  group('OpmlService', () {
    test('解析 OPML', () {
      final feeds = OpmlService.parse(_opmlXml);
      expect(feeds.length, 2);
      expect(feeds[0].title, 'Feed1');
      expect(feeds[0].url, 'https://a.com/feed');
      expect(feeds[0].category, 'Group A');
      expect(feeds[1].category, isNull);
    });

    test('导出再解析往返一致', () {
      final src = [
        RssFeed(title: 'F1', url: 'https://a.com/f', category: 'G1'),
        RssFeed(title: 'F2', url: 'https://b.com/f'),
      ];
      final xml = OpmlService.build(src);
      final parsed = OpmlService.parse(xml);
      expect(parsed.length, 2);
      expect(parsed.map((e) => e.url).toSet(),
          containsAll(['https://a.com/f', 'https://b.com/f']));
    });
  });

  group('RssFeed 模型', () {
    test('JSON 往返', () {
      final feed = RssFeed(
        title: 'T',
        url: 'https://x.com/f',
        category: 'C',
        articles: [
          RssArticle(feedId: 'fid', title: 'A1', isStarred: true),
          RssArticle(feedId: 'fid', title: 'A2', isRead: true),
        ],
      );
      final json = feed.toJson();
      final back = RssFeed.fromJson(json);
      expect(back.title, feed.title);
      expect(back.category, 'C');
      expect(back.articles.length, 2);
      expect(back.unreadCount, 1);
      expect(back.starredCount, 1);
    });
  });

  group('RssService 编码解码', () {
    test('GBK 源按 charset=gb2312 正确解码', () {
      final xml =
          '<?xml version="1.0" encoding="gb2312"?><rss><channel><title>中文标题</title></channel></rss>';
      final bytes = gbk.encode(xml);
      final response = http.Response.bytes(
        bytes,
        200,
        headers: {'content-type': 'text/xml; charset=gb2312'},
      );
      final decoded = RssService.decodeResponseBody(response);
      expect(decoded, contains('<title>中文标题</title>'));
    });

    test('XML 声明含 GBK 时正确解码', () {
      final xml =
          '<?xml version="1.0" encoding="gbk"?><rss><channel><title>中文标题</title></channel></rss>';
      final bytes = gbk.encode(xml);
      final response = http.Response.bytes(
        bytes,
        200,
        headers: {'content-type': 'text/xml'},
      );
      final decoded = RssService.decodeResponseBody(response);
      expect(decoded, contains('<title>中文标题</title>'));
    });

    test('Latin-1 误标但实际为 UTF-8 仍正确解码', () {
      final xml =
          '<?xml version="1.0"?><rss><channel><title>中文标题</title></channel></rss>';
      final bytes = utf8.encode(xml);
      final response = http.Response.bytes(
        bytes,
        200,
        headers: {'content-type': 'text/xml; charset=iso-8859-1'},
      );
      final decoded = RssService.decodeResponseBody(response);
      expect(decoded, contains('<title>中文标题</title>'));
    });

    test('UTF-8 源正常解码', () {
      final xml =
          '<?xml version="1.0"?><rss><channel><title>中文标题</title></channel></rss>';
      final bytes = utf8.encode(xml);
      final response = http.Response.bytes(
        bytes,
        200,
        headers: {'content-type': 'text/xml; charset=utf-8'},
      );
      final decoded = RssService.decodeResponseBody(response);
      expect(decoded, contains('<title>中文标题</title>'));
    });
  });
}
