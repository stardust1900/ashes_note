import 'package:flutter/material.dart';
import '../../models/book_reader/highlight.dart';

/// 高亮操作相关逻辑
class HighlightOperations {
  /// 检查选择区域是否与已有高亮/划线重叠，返回所有匹配的标记
  static List<Highlight> getHighlightsAtSelection(
    List<Highlight> highlights,
    int chapterIndex,
    int startOffset,
    int endOffset,
  ) {
    return highlights.where((h) {
      return h.chapterIndex == chapterIndex &&
          h.startOffset < endOffset &&
          h.endOffset > startOffset;
    }).toList();
  }

  /// 构建带高亮/划线的文本样式（支持叠加）
  static List<TextSpan> buildHighlightSpans(
    String text,
    int textStartOffset,
    int chapterIndex,
    List<Highlight> highlights,
    List<SearchResult>? searchResults,
    bool highlightSearchResults,
  ) {
    // 获取当前文本段的所有高亮和划线
    final textHighlights = highlights.where((h) {
      return h.chapterIndex == chapterIndex &&
          h.endOffset > textStartOffset &&
          h.startOffset < textStartOffset + text.length;
    }).toList();

    // 获取搜索结果（如果启用搜索高亮）
    final searchHighlights = highlightSearchResults && searchResults != null
        ? searchResults.where((r) {
            if (r.chapterIndex != chapterIndex) return false;
            final searchEnd = r.positionOffset + r.matchedText.length;
            return r.positionOffset < textStartOffset + text.length &&
                searchEnd > textStartOffset;
          }).toList()
        : [];

    if (textHighlights.isEmpty && searchHighlights.isEmpty) {
      return [TextSpan(text: text)];
    }

    // 分离高亮和划线
    final highls = textHighlights.where((h) => !h.isUnderline).toList();
    final underlines = textHighlights.where((h) => h.isUnderline).toList();

    // 收集所有分割点
    final Set<int> splitPoints = {0, text.length};
    for (final h in textHighlights) {
      final start = (h.startOffset - textStartOffset).clamp(0, text.length);
      final end = (h.endOffset - textStartOffset).clamp(0, text.length);
      splitPoints.add(start);
      splitPoints.add(end);
    }

    // 添加搜索结果的分割点
    for (final s in searchHighlights) {
      final relativePos = s.positionOffset - textStartOffset;
      final searchLength = s.matchedText.length;
      final searchEndOffset = s.positionOffset + searchLength;
      final relativeEnd = searchEndOffset - textStartOffset;

      final intersectionStart = relativePos.clamp(0, text.length);
      final intersectionEnd = relativeEnd.clamp(0, text.length);

      if (intersectionStart < intersectionEnd) {
        splitPoints.add(intersectionStart);
        splitPoints.add(intersectionEnd);
      }
    }

    final sortedPoints = splitPoints.toList()..sort();

    // 构建每个段的样式
    final spans = <TextSpan>[];
    for (int i = 0; i < sortedPoints.length - 1; i++) {
      final segStart = sortedPoints[i];
      final segEnd = sortedPoints[i + 1];
      if (segStart >= segEnd) continue;

      final segText = text.substring(segStart, segEnd);

      // 检查该段是否有高亮
      final hasHighlight = highls.any((h) {
        final hStart = h.startOffset - textStartOffset;
        final hEnd = h.endOffset - textStartOffset;
        return segStart < hEnd && segEnd > hStart;
      });

      // 检查该段是否有划线
      final hasUnderline = underlines.any((h) {
        final hStart = h.startOffset - textStartOffset;
        final hEnd = h.endOffset - textStartOffset;
        return segStart < hEnd && segEnd > hStart;
      });

      // 检查该段是否有搜索结果高亮
      final hasSearchHighlight = searchHighlights.any((s) {
        final relativePos = s.positionOffset - textStartOffset;
        final searchEndOffset = s.positionOffset + s.matchedText.length;
        final relativeEnd = searchEndOffset - textStartOffset;

        final intersectionStart = relativePos.clamp(0, text.length);
        final intersectionEnd = relativeEnd.clamp(0, text.length);

        return segStart < intersectionEnd && segEnd > intersectionStart;
      });

      // 获取高亮颜色（取第一个匹配的高亮）
      Color? highlightColor;
      if (hasHighlight) {
        final matchingHighlight = highls.firstWhere((h) {
          final hStart = h.startOffset - textStartOffset;
          final hEnd = h.endOffset - textStartOffset;
          return segStart < hEnd && segEnd > hStart;
        });
        highlightColor = matchingHighlight.color;
      }

      // 构建样式
      TextStyle? style;
      if (hasSearchHighlight) {
        style = TextStyle(
          backgroundColor: Colors.orange.withValues(alpha: 0.5),
          fontWeight: FontWeight.bold,
        );
        if (hasUnderline) {
          style = style!.copyWith(
            decoration: TextDecoration.underline,
            decorationColor: Colors.red,
            decorationThickness: 2.5,
          );
        }
      } else if (hasHighlight && hasUnderline) {
        style = TextStyle(
          backgroundColor: highlightColor!.withValues(alpha: 0.4),
          decoration: TextDecoration.underline,
          decorationColor: Colors.red,
          decorationThickness: 2.5,
        );
      } else if (hasHighlight) {
        style = TextStyle(
          backgroundColor: highlightColor!.withValues(alpha: 0.4),
        );
      } else if (hasUnderline) {
        style = TextStyle(
          decoration: TextDecoration.underline,
          decorationColor: Colors.black,
          decorationThickness: 2.5,
        );
      }

      spans.add(TextSpan(text: segText, style: style));
    }

    return spans;
  }

  /// 合并重叠的高亮和划线
  static List<MergedHighlight> mergeOverlappingHighlights(
    List<Highlight> highlights,
    String Function(int chapterIndex, int startOffset, int endOffset) getTextForRange,
  ) {
    if (highlights.isEmpty) return [];

    // 按起始位置排序
    final sorted = List<Highlight>.from(highlights)
      ..sort((a, b) => a.startOffset.compareTo(b.startOffset));

    final merged = <MergedHighlight>[];

    for (final h in sorted) {
      // 查找是否有重叠的已合并标记
      MergedHighlight? overlapping;
      for (final m in merged) {
        if (h.startOffset < m.endOffset && h.endOffset > m.startOffset) {
          overlapping = m;
          break;
        }
      }

      if (overlapping != null) {
        // 合并到已有标记中，扩展范围
        final newStart = overlapping.startOffset < h.startOffset
            ? overlapping.startOffset
            : h.startOffset;
        final newEnd = overlapping.endOffset > h.endOffset
            ? overlapping.endOffset
            : h.endOffset;

        // 合并文本
        String newText = getTextForRange(h.chapterIndex, newStart, newEnd);

        if (newText.isEmpty) {
          final allWithText = [
            ...overlapping.originalHighlights,
            ...overlapping.originalUnderlines,
          ];
          allWithText.add(h);

          final sortedByText =
              allWithText.where((hl) => hl.text.isNotEmpty).toList()
                ..sort((a, b) => a.startOffset.compareTo(b.startOffset));

          newText = sortedByText.map((hl) => hl.text).join('');
        }

        final newHighlights = List<Highlight>.from(
          overlapping.originalHighlights,
        );
        final newUnderlines = List<Highlight>.from(
          overlapping.originalUnderlines,
        );

        if (h.isUnderline) {
          if (!newUnderlines.any((u) => u.id == h.id)) {
            newUnderlines.add(h);
          }
        } else {
          if (!newHighlights.any((hl) => hl.id == h.id)) {
            newHighlights.add(h);
          }
        }

        final newNote = newHighlights
            .firstWhere(
              (hl) => hl.note != null && hl.note!.isNotEmpty,
              orElse: () => newUnderlines.firstWhere(
                (u) => u.note != null && u.note!.isNotEmpty,
                orElse: () => newHighlights.isNotEmpty
                    ? newHighlights.first
                    : newUnderlines.first,
              ),
            )
            .note;

        merged.remove(overlapping);
        merged.add(
          MergedHighlight(
            chapterIndex: h.chapterIndex,
            pageIndex: h.pageIndex,
            text: newText,
            startOffset: newStart,
            endOffset: newEnd,
            originalHighlights: newHighlights,
            originalUnderlines: newUnderlines,
            createdAt: overlapping.createdAt.isBefore(h.createdAt)
                ? overlapping.createdAt
                : h.createdAt,
            note: newNote,
          ),
        );
      } else {
        // 创建新的合并标记
        final highs = h.isUnderline ? <Highlight>[] : [h];
        final underlines = h.isUnderline ? [h] : <Highlight>[];

        merged.add(
          MergedHighlight(
            chapterIndex: h.chapterIndex,
            pageIndex: h.pageIndex,
            text: h.text,
            startOffset: h.startOffset,
            endOffset: h.endOffset,
            originalHighlights: highs,
            originalUnderlines: underlines,
            createdAt: h.createdAt,
            note: h.note,
          ),
        );
      }
    }

    return merged;
  }

  /// 按章节分组高亮，并合并重叠的高亮和划线
  static List<ChapterGroup> groupHighlightsByChapter(
    List<Highlight> highlights,
    String Function(int chapterIndex) getChapterTitle,
    String Function(int chapterIndex, int startOffset, int endOffset) getTextForRange,
  ) {
    // 先按章节索引排序
    final sorted = List<Highlight>.from(highlights)
      ..sort((a, b) {
        if (a.chapterIndex != b.chapterIndex) {
          return a.chapterIndex.compareTo(b.chapterIndex);
        }
        return a.startOffset.compareTo(b.startOffset);
      });

    final groups = <ChapterGroup>[];

    // 按章节分组
    final chapterMap = <int, List<Highlight>>{};
    for (final h in sorted) {
      chapterMap.putIfAbsent(h.chapterIndex, () => []).add(h);
    }

    // 对每个章节内的标记进行合并
    for (final entry in chapterMap.entries) {
      final chapterHighlights = entry.value;
      final mergedList = mergeOverlappingHighlights(
        chapterHighlights,
        getTextForRange,
      );

      groups.add(
        ChapterGroup(
          chapterIndex: entry.key,
          chapterTitle: getChapterTitle(entry.key),
          mergedHighlights: mergedList,
        ),
      );
    }

    // 按章节索引排序
    groups.sort((a, b) => a.chapterIndex.compareTo(b.chapterIndex));
    return groups;
  }
}
