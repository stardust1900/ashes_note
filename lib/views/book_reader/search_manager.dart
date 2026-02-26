import 'package:epub_plus/epub_plus.dart';
import '../../models/book_reader/highlight.dart';
import '../../models/book_reader/page_content.dart';
import '../../models/book_reader/content_item.dart' show ContentItem, TextContent;

/// 搜索管理器
class SearchManager {
  /// 执行搜索
  static List<SearchResult> performSearch(
    String searchText,
    List<EpubChapter> chapters,
    List<PageContent> pages,
  ) {
    final results = <SearchResult>[];

    // 遍历所有章节进行搜索
    for (int chapterIndex = 0; chapterIndex < chapters.length; chapterIndex++) {
      final chapter = chapters[chapterIndex];
      if (chapter.htmlContent == null) continue;

      // 获取该章节的所有页面
      final chapterPages = pages
          .where((p) => p.chapterIndex == chapterIndex)
          .toList();
      if (chapterPages.isEmpty) continue;

      // 构建章节纯文本用于显示上下文
      final chapterText = chapterPages
          .expand((page) => page.contentItems.whereType<TextContent>())
          .map((tc) => tc.text)
          .join();

      // 遍历章节的所有页面和 TextContent 进行搜索
      int cumulativeOffset = 0;

      for (final page in chapterPages) {
        int pageOffset = cumulativeOffset;

        for (final item in page.contentItems) {
          if (item is TextContent) {
            final textContent = item.text;
            if (textContent.isEmpty) continue;

            final textOffset = cumulativeOffset;

            // 在当前 TextContent 中搜索
            int index = 0;
            while (true) {
              final pos = textContent.indexOf(searchText, index);
              if (pos == -1) break;

              final absolutePos = textOffset + pos;
              final actualMatchedText = textContent.substring(
                pos.clamp(0, textContent.length),
                (pos + searchText.length).clamp(0, textContent.length),
              );

              // 获取匹配文本的上下文
              final contextStart = (absolutePos - 30).clamp(
                0,
                chapterText.length,
              );
              final contextEnd = (absolutePos + actualMatchedText.length + 30)
                  .clamp(0, chapterText.length);
              final contextText = chapterText.substring(
                contextStart,
                contextEnd,
              );

              final pageIndex = pages.indexOf(page);

              results.add(
                SearchResult(
                  chapterIndex: chapterIndex,
                  chapterTitle: chapter.title ?? '第 ${chapterIndex + 1} 章',
                  pageIndex: pageIndex,
                  positionOffset: absolutePos,
                  contextText: contextText,
                  matchedText: actualMatchedText,
                ),
              );

              index = pos + searchText.length;
            }

            cumulativeOffset += textContent.length;
          }
        }
      }
    }

    return results;
  }

  /// 合并同一页的搜索结果
  static List<SearchResult> mergeResultsByPage(List<SearchResult> searchResults) {
    final Map<String, List<SearchResult>> pageResultsMap = {};

    // 按页分组
    for (final result in searchResults) {
      final pageKey = '${result.chapterIndex}_${result.pageIndex}';
      if (!pageResultsMap.containsKey(pageKey)) {
        pageResultsMap[pageKey] = [];
      }
      pageResultsMap[pageKey]!.add(result);
    }

    // 每页只保留第一个用于显示
    final mergedResults = <SearchResult>[];
    pageResultsMap.forEach((pageKey, results) {
      if (results.isNotEmpty) {
        mergedResults.add(results.first);
      }
    });

    // 按 positionOffset 排序
    mergedResults.sort((a, b) {
      if (a.chapterIndex != b.chapterIndex) {
        return a.chapterIndex.compareTo(b.chapterIndex);
      }
      return a.positionOffset.compareTo(b.positionOffset);
    });

    return mergedResults;
  }
}
