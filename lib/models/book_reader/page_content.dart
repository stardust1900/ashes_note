import 'content_item.dart'
    show ContentItem, TextContent, TextContentRef, LinkContent;

/// 页面内容
class PageContent {
  final int chapterIndex;
  final int pageIndexInChapter;
  final List<ContentItem> contentItems;
  final String? title;

  // 章节纯文本（用于从 TextContentRef 提取文本）
  String? chapterPlainText;

  PageContent({
    required this.chapterIndex,
    required this.pageIndexInChapter,
    required this.contentItems,
    this.title,
    this.chapterPlainText,
  });

  /// 将所有 TextContentRef 转换为 TextContent
  PageContent resolveTextRefs() {
    if (chapterPlainText == null) {
      print(
        '[PageContent] resolveTextRefs: chapterPlainText 为空，无法解析 TextContentRef, chapterIndex=$chapterIndex',
      );
      return this;
    }

    final resolvedItems = contentItems.map((item) {
      if (item is TextContentRef) {
        final textContent = item.toTextContent(chapterPlainText!);
        return textContent;
      }
      return item;
    }).toList();

    return PageContent(
      chapterIndex: chapterIndex,
      pageIndexInChapter: pageIndexInChapter,
      contentItems: resolvedItems,
      title: title,
      chapterPlainText: null, // 解析后不再需要纯文本
    );
  }

  /// 将所有 TextContent 转换为 TextContentRef（用于缓存）
  PageContent optimizeForCache() {
    final optimizedItems = contentItems.map((item) {
      if (item is TextContent) {
        return TextContentRef(
          offset: item.startOffset,
          length: item.text.length,
        );
      }
      return item;
    }).toList();

    final textContentCount = contentItems.whereType<TextContent>().length;
    final linkContentCount = contentItems.whereType<LinkContent>().length;
    final optimizedLinkCount = optimizedItems.whereType<LinkContent>().length;

    print(
      '[PageContent] optimizeForCache: chapterIndex=$chapterIndex, chapterPlainText长度=${chapterPlainText?.length ?? 0}, TextContent数量=$textContentCount, LinkContent数量=$linkContentCount, 优化后LinkContent数量=$optimizedLinkCount',
    );

    return PageContent(
      chapterIndex: chapterIndex,
      pageIndexInChapter: pageIndexInChapter,
      contentItems: optimizedItems,
      title: title,
      chapterPlainText: chapterPlainText,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'chapterIndex': chapterIndex,
      'pageIndexInChapter': pageIndexInChapter,
      'contentItems': contentItems.map((item) => item.toJson()).toList(),
      'title': title,
      // 不缓存 chapterPlainText，会在加载时重建
    };
  }

  factory PageContent.fromJson(Map<String, dynamic> json) {
    return PageContent(
      chapterIndex: json['chapterIndex'] as int,
      pageIndexInChapter: json['pageIndexInChapter'] as int,
      contentItems: (json['contentItems'] as List<dynamic>)
          .map((item) => ContentItem.fromJson(item as Map<String, dynamic>))
          .toList(),
      title: json['title'] as String?,
    );
  }
}
