import 'package:flutter/material.dart';
import '../../models/book_reader/highlight.dart';
import 'highlight_operations.dart';
import 'note_export.dart';

/// 笔记列表对话框
/// 显示所有高亮、划线和笔记，按章节分组
class NotesListDialog extends StatelessWidget {
  final List<Highlight> highlights;
  final List<dynamic> pages;
  final List<dynamic> chapters;
  final String bookTitle;
  final Future<void> Function(String) onDeleteHighlight;
  final Future<void> Function(Highlight) onShowAddNoteDialog;
  final void Function(Highlight) onJumpToHighlight;
  final String Function(int) getChapterTitle;
  final String Function(int, int, int) getTextForRange;
  final void Function() onRefresh;

  const NotesListDialog({
    super.key,
    required this.highlights,
    required this.pages,
    required this.chapters,
    required this.bookTitle,
    required this.onDeleteHighlight,
    required this.onShowAddNoteDialog,
    required this.onJumpToHighlight,
    required this.getChapterTitle,
    required this.getTextForRange,
    required this.onRefresh,
  });

  /// 显示笔记列表对话框
  static Future<void> show({
    required BuildContext context,
    required List<Highlight> highlights,
    required List<dynamic> pages,
    required List<dynamic> chapters,
    required String bookTitle,
    required Future<void> Function(String) onDeleteHighlight,
    required Future<void> Function(Highlight) onShowAddNoteDialog,
    required void Function(Highlight) onJumpToHighlight,
    required String Function(int) getChapterTitle,
    required String Function(int, int, int) getTextForRange,
    required void Function() onRefresh,
  }) {
    return showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return NotesListDialog(
            highlights: highlights,
            pages: pages,
            chapters: chapters,
            bookTitle: bookTitle,
            onDeleteHighlight: onDeleteHighlight,
            onShowAddNoteDialog: onShowAddNoteDialog,
            onJumpToHighlight: onJumpToHighlight,
            getChapterTitle: getChapterTitle,
            getTextForRange: getTextForRange,
            onRefresh: () {
              onRefresh();
              setDialogState(() {});
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    // 按章节分组高亮
    final groupedHighlights = HighlightOperations.groupHighlightsByChapter(
      highlights,
      getChapterTitle,
      getTextForRange,
    );

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      elevation: 8,
      child: Container(
        width: double.maxFinite,
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.1),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildTitle(context),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: isDark 
                    ? theme.colorScheme.surface.withValues(alpha: 0.3)
                    : Colors.grey[50],
                ),
                child: highlights.isEmpty
                    ? _buildEmptyState(context)
                    : _buildNotesList(groupedHighlights, context),
              ),
            ),
            _buildActions(context),
          ],
        ),
      ),
    );
  }

  /// 构建标题栏
  Widget _buildTitle(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border(
          bottom: BorderSide(
            color: isDark 
              ? theme.dividerColor.withValues(alpha: 0.3)
              : Colors.grey.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  theme.primaryColor.withValues(alpha: 0.15),
                  theme.primaryColor.withValues(alpha: 0.08),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.note_alt,
              color: theme.primaryColor,
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              '笔记',
              style: theme.textTheme.titleLarge?.copyWith(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
            ),
          ),
          _buildStatistics(context),
        ],
      ),
    );
  }

  /// 构建统计信息
  Widget _buildStatistics(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    final underlineCount = highlights.where((h) => h.isUnderline).length;
    final highlightCount = highlights.length - underlineCount;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (highlightCount > 0) ...[
          _buildStatisticBadge(
            context,
            icon: Icons.highlight,
            color: Colors.amber[600]!,
            backgroundColor: Colors.amber.withValues(alpha: isDark ? 0.25 : 0.12),
            count: highlightCount,
          ),
        ],
        if (underlineCount > 0) ...[
          if (highlightCount > 0) const SizedBox(width: 6),
          _buildStatisticBadge(
            context,
            icon: Icons.format_underline,
            color: isDark ? Colors.grey[400]! : Colors.grey[700]!,
            backgroundColor: isDark 
              ? Colors.grey.withValues(alpha: 0.2)
              : Colors.grey.withValues(alpha: 0.12),
            count: underlineCount,
          ),
        ],
      ],
    );
  }

  /// 构建统计徽章
  Widget _buildStatisticBadge(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required Color backgroundColor,
    required int count,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withValues(alpha: isDark ? 0.3 : 0.2),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 5),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 13,
              color: color,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建空状态
  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  theme.primaryColor.withValues(alpha: 0.08),
                  theme.primaryColor.withValues(alpha: 0.02),
                ],
              ),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.lightbulb_outline,
              size: 56,
              color: isDark ? Colors.grey[500] : Colors.grey[400],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '暂无高亮笔记',
            style: TextStyle(
              color: isDark ? Colors.grey[300] : Colors.grey[600],
              fontSize: 17,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '长按文本选择内容后点击高亮按钮添加',
            style: TextStyle(
              color: isDark ? Colors.grey[500] : Colors.grey[450],
              fontSize: 13,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// 构建笔记列表
  Widget _buildNotesList(List<dynamic> groupedHighlights, BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      itemCount: groupedHighlights.length,
      itemBuilder: (context, index) {
        return _buildGroupedHighlightItem(
          context,
          groupedHighlights[index],
        );
      },
    );
  }

  /// 构建分组的高亮项
  Widget _buildGroupedHighlightItem(
    BuildContext context,
    dynamic group,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildChapterHeader(context, group),
        ...group.mergedHighlights.map(
          (merged) => _buildMergedHighlightListItem(
            context,
            merged,
          ),
        ),
      ],
    );
  }

  /// 构建章节标题
  Widget _buildChapterHeader(BuildContext context, dynamic group) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return Container(
      margin: const EdgeInsets.only(top: 12, bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.primaryColor.withValues(alpha: isDark ? 0.2 : 0.12),
            theme.primaryColor.withValues(alpha: isDark ? 0.1 : 0.06),
          ],
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.primaryColor.withValues(alpha: isDark ? 0.3 : 0.2),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.bookmark_outline, 
            size: 15, 
            color: theme.primaryColor,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              group.chapterTitle,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: theme.primaryColor,
                letterSpacing: 0.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: theme.primaryColor.withValues(alpha: isDark ? 0.25 : 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${group.mergedHighlights.length}',
              style: TextStyle(
                fontSize: 12,
                color: theme.primaryColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建合并后的高亮列表项
  Widget _buildMergedHighlightListItem(
    BuildContext context,
    dynamic merged,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasNote = merged.note != null && merged.note!.isNotEmpty;
    final hasHighlight = merged.hasHighlight;
    final hasUnderline = merged.hasUnderline;
    final isCombined = hasHighlight && hasUnderline;

    return Container(
      margin: const EdgeInsets.only(bottom: 12, left: 2, right: 2),
      decoration: BoxDecoration(
        color: isDark ? theme.cardColor : Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(
          color: isDark 
            ? theme.dividerColor.withValues(alpha: 0.3)
            : Colors.grey.withValues(alpha: 0.15),
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              Navigator.pop(context);
              final firstHighlight = merged.originalHighlights.isNotEmpty
                  ? merged.originalHighlights.first
                  : merged.originalUnderlines.first;
              onJumpToHighlight(firstHighlight);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildItemHeader(context, merged, isCombined, hasHighlight, hasUnderline, hasNote),
                _buildItemContent(context, merged, isCombined, hasHighlight, hasUnderline, hasNote),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 构建列表项头部
  Widget _buildItemHeader(
    BuildContext context,
    dynamic merged,
    bool isCombined,
    bool hasHighlight,
    bool hasUnderline,
    bool hasNote,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 6),
      decoration: BoxDecoration(
        color: isCombined
            ? merged.highlightColor.withValues(alpha: isDark ? 0.15 : 0.1)
            : hasUnderline
                ? (isDark ? Colors.grey.withValues(alpha: 0.08) : Colors.grey.withValues(alpha: 0.05))
                : merged.highlightColor.withValues(alpha: isDark ? 0.15 : 0.1),
        border: Border(
          bottom: BorderSide(
            color: isCombined
                ? merged.highlightColor.withValues(alpha: isDark ? 0.25 : 0.2)
                : hasUnderline
                    ? (isDark ? Colors.grey.withValues(alpha: 0.15) : Colors.grey.withValues(alpha: 0.2))
                    : merged.highlightColor.withValues(alpha: isDark ? 0.25 : 0.2),
          ),
        ),
      ),
      child: Row(
        children: [
          _buildTypeIndicator(merged, isCombined, hasHighlight, hasUnderline, context),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _formatDate(merged.createdAt),
              style: TextStyle(
                fontSize: 10,
                color: isDark ? Colors.grey[500] : Colors.grey[500],
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
            ),
          ),
          _buildNoteButton(context, merged, hasNote),
          const SizedBox(width: 2),
          _buildDeleteButton(context, merged),
        ],
      ),
    );
  }

  /// 构建类型标识
  Widget _buildTypeIndicator(
    dynamic merged,
    bool isCombined,
    bool hasHighlight,
    bool hasUnderline,
    BuildContext context,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    if (isCombined) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              color: merged.highlightColor.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: isDark ? Colors.white.withValues(alpha: 0.3) : Colors.white,
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: merged.highlightColor.withValues(alpha: 0.4),
                  blurRadius: 3,
                ),
              ],
            ),
          ),
          const SizedBox(width: 3),
          Icon(
            Icons.format_underline,
            size: 13,
            color: Colors.red[600],
          ),
        ],
      );
    } else if (hasUnderline) {
      return Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: isDark 
            ? Colors.grey.withValues(alpha: 0.15)
            : Colors.grey.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isDark 
              ? Colors.grey.withValues(alpha: 0.2)
              : Colors.grey.withValues(alpha: 0.3),
          ),
        ),
        child: Icon(
          Icons.format_underline,
          size: 13,
          color: isDark ? Colors.grey[400] : Colors.grey[700],
        ),
      );
    } else {
      return Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: merged.highlightColor.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: isDark ? Colors.white.withValues(alpha: 0.3) : Colors.white,
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: merged.highlightColor.withValues(alpha: 0.5),
              blurRadius: 4,
            ),
          ],
        ),
      );
    }
  }

  /// 构建笔记按钮
  Widget _buildNoteButton(BuildContext context, dynamic merged, bool hasNote) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return InkWell(
      onTap: () async {
        final target = merged.originalHighlights.isNotEmpty
            ? merged.originalHighlights.first
            : merged.originalUnderlines.first;
        await onShowAddNoteDialog(target);
        onRefresh();
      },
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: hasNote 
            ? theme.primaryColor.withValues(alpha: isDark ? 0.25 : 0.15)
            : (isDark ? Colors.transparent : Colors.transparent),
          borderRadius: BorderRadius.circular(7),
          border: hasNote ? Border.all(
            color: theme.primaryColor.withValues(alpha: isDark ? 0.5 : 0.4),
            width: 1.2,
          ) : null,
        ),
        child: Icon(
          hasNote ? Icons.edit_note : Icons.note_add_outlined,
          size: 17,
          color: hasNote ? theme.primaryColor : (isDark ? Colors.grey[500] : Colors.grey[500]),
        ),
      ),
    );
  }

  /// 构建删除按钮
  Widget _buildDeleteButton(BuildContext context, dynamic merged) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return InkWell(
      onTap: () async {
        for (final h in merged.originalHighlights) {
          await onDeleteHighlight(h.id);
        }
        for (final u in merged.originalUnderlines) {
          await onDeleteHighlight(u.id);
        }
        onRefresh();
      },
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: isDark ? 0.2 : 0.12),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: Colors.red.withValues(alpha: isDark ? 0.4 : 0.3),
            width: 1.2,
          ),
        ),
        child: Icon(
          Icons.delete_outline,
          size: 17,
          color: Colors.red[600],
        ),
      ),
    );
  }

  /// 构建列表项内容
  Widget _buildItemContent(
    BuildContext context,
    dynamic merged,
    bool isCombined,
    bool hasHighlight,
    bool hasUnderline,
    bool hasNote,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTextContent(context, merged, isCombined, hasHighlight, hasUnderline),
          if (hasNote) ...[
            const SizedBox(height: 12),
            _buildNoteContent(merged.note!, context),
          ],
        ],
      ),
    );
  }

  /// 构建文本内容
  Widget _buildTextContent(
    BuildContext context,
    dynamic merged,
    bool isCombined,
    bool hasHighlight,
    bool hasUnderline,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: isCombined
            ? merged.highlightColor.withValues(alpha: isDark ? 0.18 : 0.15)
            : hasUnderline
                ? (isDark ? Colors.grey.withValues(alpha: 0.08) : Colors.grey.withValues(alpha: 0.05))
                : merged.highlightColor.withValues(alpha: isDark ? 0.18 : 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isCombined
              ? merged.highlightColor.withValues(alpha: isDark ? 0.35 : 0.3)
              : hasUnderline
                  ? (isDark ? Colors.grey.withValues(alpha: 0.2) : Colors.grey.withValues(alpha: 0.25))
                  : merged.highlightColor.withValues(alpha: isDark ? 0.35 : 0.3),
          width: 1.2,
        ),
      ),
      child: _buildMergedHighlightTextSpans(merged, context),
    );
  }

  /// 构建笔记内容
  Widget _buildNoteContent(String note, BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            isDark
              ? theme.colorScheme.surface.withValues(alpha: 0.5)
              : Colors.grey[50]!,
            isDark
              ? theme.colorScheme.surface.withValues(alpha: 0.3)
              : Colors.grey[100]!,
          ],
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark
            ? theme.dividerColor.withValues(alpha: 0.3)
            : Colors.grey[200]!,
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.comment_outlined,
            size: 15,
            color: isDark ? Colors.grey[400] : Colors.grey[500],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              note,
              // 不限制行数，显示完整内容
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.grey[200] : Colors.grey[700],
                height: 1.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建合并高亮项的文本显示
  Widget _buildMergedHighlightTextSpans(dynamic merged, BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasUnderline = merged.hasUnderline;
    String text = merged.text;
    final textStartOffset = merged.startOffset;

    // 优先使用原始高亮/划线中的文本
    if (text.isEmpty) {
      for (final h in merged.originalHighlights) {
        if (h.text.isNotEmpty) {
          text = h.text;
          break;
        }
      }
      if (text.isEmpty) {
        for (final u in merged.originalUnderlines) {
          if (u.text.isNotEmpty) {
            text = u.text;
            break;
          }
        }
      }
    }

    if (text.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(10),
        child: Text(
          '（文本内容丢失）',
          style: TextStyle(
            fontSize: 13,
            color: isDark ? Colors.grey[500] : Colors.grey[500],
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    if (!hasUnderline) {
      return Text(
        text,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          color: isDark ? Colors.grey[100] : Colors.black87,
          height: 1.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      );
    }

    return RichText(
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(children: _buildTextSpans(merged, text, textStartOffset, context)),
    );
  }

  /// 构建文本片段
  List<TextSpan> _buildTextSpans(dynamic merged, String text, int textStartOffset, BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    final Set<int> splitPoints = {0, text.length};

    for (final u in merged.originalUnderlines) {
      final start = (u.startOffset - textStartOffset).clamp(0, text.length);
      final end = (u.endOffset - textStartOffset).clamp(0, text.length);
      if (start < end) {
        splitPoints.add(start);
        splitPoints.add(end);
      }
    }

    for (final h in merged.originalHighlights) {
      final start = (h.startOffset - textStartOffset).clamp(0, text.length);
      final end = (h.endOffset - textStartOffset).clamp(0, text.length);
      if (start < end) {
        splitPoints.add(start);
        splitPoints.add(end);
      }
    }

    final sortedPoints = splitPoints.toList()..sort();

    final spans = <TextSpan>[];
    for (int i = 0; i < sortedPoints.length - 1; i++) {
      final segStart = sortedPoints[i];
      final segEnd = sortedPoints[i + 1];
      if (segStart >= segEnd) continue;

      final segText = text.substring(segStart, segEnd);

      final segHasUnderline = merged.originalUnderlines.any((u) {
        final uStart = u.startOffset - textStartOffset;
        final uEnd = u.endOffset - textStartOffset;
        return segStart < uEnd && segEnd > uStart;
      });

      final segHasHighlight = merged.originalHighlights.any((h) {
        final hStart = h.startOffset - textStartOffset;
        final hEnd = h.endOffset - textStartOffset;
        return segStart < hEnd && segEnd > hStart;
      });

      final decorationColor = segHasUnderline && segHasHighlight
          ? Colors.red
          : (isDark ? Colors.grey[300] : Colors.black54);

      spans.add(
        TextSpan(
          text: segText,
          style: TextStyle(
            fontSize: 14,
            color: isDark ? Colors.grey[100] : Colors.black87,
            height: 1.5,
            fontWeight: FontWeight.w600,
            decoration: segHasUnderline ? TextDecoration.underline : null,
            decorationColor: decorationColor,
            decorationThickness: segHasUnderline ? 2.2 : null,
          ),
        ),
      );
    }

    return spans;
  }

  /// 构建操作按钮
  Widget _buildActions(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border(
          top: BorderSide(
            color: isDark 
              ? theme.dividerColor.withValues(alpha: 0.3)
              : Colors.grey.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (highlights.isNotEmpty) ...[
            FilledButton.icon(
              onPressed: () => NoteExport.exportNotesToMarkdown(
                bookTitle,
                highlights,
                getChapterTitle,
                getTextForRange,
                context,
              ),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 13,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 2,
              ),
              icon: const Icon(Icons.download, size: 19),
              label: const Text(
                '导出',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0.3),
              ),
            ),
            const SizedBox(width: 10),
          ],
          FilledButton(
            onPressed: () => Navigator.pop(context),
            style: FilledButton.styleFrom(
              backgroundColor: isDark ? Colors.grey.withValues(alpha: 0.15) : Colors.grey[100],
              foregroundColor: isDark ? Colors.grey[100] : Colors.black87,
              padding: const EdgeInsets.symmetric(
                horizontal: 28,
                vertical: 13,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: isDark 
                    ? theme.dividerColor.withValues(alpha: 0.3)
                    : Colors.grey.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
            ),
            child: Text('关闭', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  /// 格式化日期
  String _formatDate(DateTime date) {
    return '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}
