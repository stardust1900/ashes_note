import 'content_item.dart';

/// 页面内容
class PageContent {
  final int chapterIndex;
  final int pageIndexInChapter;
  final List<ContentItem> contentItems;
  final bool isChapterStart;
  final String chapterTitle;

  PageContent({
    required this.chapterIndex,
    required this.pageIndexInChapter,
    required this.contentItems,
    this.isChapterStart = false,
    this.chapterTitle = '',
  });

  Map<String, dynamic> toJson() {
    return {
      'chapterIndex': chapterIndex,
      'pageIndexInChapter': pageIndexInChapter,
      'contentItems': contentItems.map((item) => item.toJson()).toList(),
      'isChapterStart': isChapterStart,
      'chapterTitle': chapterTitle,
    };
  }

  factory PageContent.fromJson(Map<String, dynamic> json) {
    return PageContent(
      chapterIndex: json['chapterIndex'] as int,
      pageIndexInChapter: json['pageIndexInChapter'] as int,
      contentItems: (json['contentItems'] as List<dynamic>)
          .map((item) => ContentItem.fromJson(item as Map<String, dynamic>))
          .toList(),
      isChapterStart: json['isChapterStart'] as bool? ?? false,
      chapterTitle: json['chapterTitle'] as String? ?? '',
    );
  }
}
