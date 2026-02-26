import 'content_item.dart';

/// 页面内容
class PageContent {
  final int chapterIndex;
  final int pageIndexInChapter;
  final List<ContentItem> contentItems;
  final String? title;

  PageContent({
    required this.chapterIndex,
    required this.pageIndexInChapter,
    required this.contentItems,
    this.title,
  });

  Map<String, dynamic> toJson() {
    return {
      'chapterIndex': chapterIndex,
      'pageIndexInChapter': pageIndexInChapter,
      'contentItems': contentItems.map((item) => item.toJson()).toList(),
      'title': title,
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
