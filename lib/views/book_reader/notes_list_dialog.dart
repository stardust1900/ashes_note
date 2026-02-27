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
    // 按章节分组高亮
    final groupedHighlights = HighlightOperations.groupHighlightsByChapter(
      highlights,
      getChapterTitle,
      getTextForRange,
    );

    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      title: _buildTitle(context),
      content: SizedBox(
        width: double.maxFinite,
        height: 450,
        child: highlights.isEmpty
            ? _buildEmptyState()
            : _buildNotesList(groupedHighlights),
      ),
      actions: _buildActions(context),
    );
  }

  /// 构建标题栏
  Widget _buildTitle(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.note_alt,
            color: Theme.of(context).primaryColor,
            size: 22,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          '笔记',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
        ),
        const Spacer(),
        _buildStatistics(),
      ],
    );
  }

  /// 构建统计信息
  Widget _buildStatistics() {
    final underlineCount = highlights.where((h) => h.isUnderline).length;
    final highlightCount = highlights.length - underlineCount;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (highlightCount > 0) ...[
          _buildStatisticBadge(
            icon: Icons.highlight,
            color: Colors.amber[800]!,
            backgroundColor: Colors.amber.withValues(alpha: 0.15),
            count: highlightCount,
          ),
        ],
        if (underlineCount > 0) ...[
          if (highlightCount > 0) const SizedBox(width: 6),
          _buildStatisticBadge(
            icon: Icons.format_underline,
            color: Colors.grey[700]!,
            backgroundColor: Colors.grey.withValues(alpha: 0.15),
            count: underlineCount,
          ),
        ],
      ],
    );
  }

  /// 构建统计徽章
  Widget _buildStatisticBadge({
    required IconData icon,
    required Color color,
    required Color backgroundColor,
    required int count,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建空状态
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lightbulb_outline,
            size: 64,
            color: Colors.grey[300],
          ),
          const SizedBox(height: 16),
          Text(
            '暂无高亮笔记',
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '长按文本选择内容后点击高亮按钮添加',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建笔记列表
  Widget _buildNotesList(List<dynamic> groupedHighlights) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
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
    return Container(
      margin: const EdgeInsets.only(top: 16, bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bookmark_outline, size: 14, color: Colors.blue[700]),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              group.chapterTitle,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.blue[600],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${group.mergedHighlights.length}',
              style: TextStyle(
                fontSize: 11,
                color: Colors.blue[700],
                fontWeight: FontWeight.w500,
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
    final hasNote = merged.note != null && merged.note!.isNotEmpty;
    final hasHighlight = merged.hasHighlight;
    final hasUnderline = merged.hasUnderline;
    final isCombined = hasHighlight && hasUnderline;

    return Container(
      margin: const EdgeInsets.only(bottom: 10, left: 4, right: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withValues(alpha: 0.1),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
        border: Border.all(color: Colors.grey.withValues(alpha: 0.1)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      decoration: BoxDecoration(
        color: isCombined
            ? merged.highlightColor.withValues(alpha: 0.08)
            : hasUnderline
                ? Colors.grey.withValues(alpha: 0.05)
                : merged.highlightColor.withValues(alpha: 0.08),
        border: Border(
          bottom: BorderSide(
            color: isCombined
                ? merged.highlightColor.withValues(alpha: 0.15)
                : hasUnderline
                    ? Colors.grey.withValues(alpha: 0.2)
                    : merged.highlightColor.withValues(alpha: 0.15),
          ),
        ),
      ),
      child: Row(
        children: [
          _buildTypeIndicator(merged, isCombined, hasHighlight, hasUnderline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _formatDate(merged.createdAt),
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[600],
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          _buildNoteButton(context, merged, hasNote),
          const SizedBox(width: 4),
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
  ) {
    if (isCombined) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: merged.highlightColor.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: Colors.white,
                width: 1.5,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.format_underline,
            size: 14,
            color: Colors.red[700],
          ),
        ],
      );
    } else if (hasUnderline) {
      return Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.grey.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(
          Icons.format_underline,
          size: 14,
          color: Colors.grey[700],
        ),
      );
    } else {
      return Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: merged.highlightColor.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: Colors.white,
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: merged.highlightColor.withValues(alpha: 0.4),
              blurRadius: 2,
            ),
          ],
        ),
      );
    }
  }

  /// 构建笔记按钮
  Widget _buildNoteButton(BuildContext context, dynamic merged, bool hasNote) {
    return InkWell(
      onTap: () async {
        final target = merged.originalHighlights.isNotEmpty
            ? merged.originalHighlights.first
            : merged.originalUnderlines.first;
        await onShowAddNoteDialog(target);
        onRefresh();
      },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: hasNote ? Colors.blue.withValues(alpha: 0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(
          hasNote ? Icons.edit_note : Icons.note_add_outlined,
          size: 18,
          color: hasNote ? Colors.blue[700] : Colors.grey[500],
        ),
      ),
    );
  }

  /// 构建删除按钮
  Widget _buildDeleteButton(BuildContext context, dynamic merged) {
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
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.all(6),
        child: Icon(
          Icons.delete_outline,
          size: 18,
          color: Colors.red[400],
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
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTextContent(context, merged, isCombined, hasHighlight, hasUnderline),
          if (hasNote) ...[
            const SizedBox(height: 10),
            _buildNoteContent(merged.note!),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 8,
      ),
      decoration: BoxDecoration(
        color: isCombined
            ? merged.highlightColor.withValues(alpha: 0.12)
            : hasUnderline
                ? Colors.grey.withValues(alpha: 0.05)
                : merged.highlightColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isCombined
              ? merged.highlightColor.withValues(alpha: 0.25)
              : hasUnderline
                  ? Colors.grey.withValues(alpha: 0.2)
                  : merged.highlightColor.withValues(alpha: 0.25),
        ),
      ),
      child: _buildMergedHighlightTextSpans(merged),
    );
  }

  /// 构建笔记内容
  Widget _buildNoteContent(String note) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.comment_outlined,
            size: 14,
            color: Colors.grey[500],
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              note,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey[700],
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建合并高亮项的文本显示
  Widget _buildMergedHighlightTextSpans(dynamic merged) {
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
            color: Colors.grey[500],
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
        style: const TextStyle(
          fontSize: 14,
          color: Colors.black87,
          height: 1.5,
          fontWeight: FontWeight.w500,
        ),
      );
    }

    return RichText(
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(children: _buildTextSpans(merged, text, textStartOffset)),
    );
  }

  /// 构建文本片段
  List<TextSpan> _buildTextSpans(dynamic merged, String text, int textStartOffset) {
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
          : Colors.black54;

      spans.add(
        TextSpan(
          text: segText,
          style: TextStyle(
            fontSize: 14,
            color: Colors.black87,
            height: 1.5,
            fontWeight: FontWeight.w500,
            decoration: segHasUnderline ? TextDecoration.underline : null,
            decorationColor: decorationColor,
            decorationThickness: segHasUnderline ? 2 : null,
          ),
        ),
      );
    }

    return spans;
  }

  /// 构建操作按钮
  List<Widget> _buildActions(BuildContext context) {
    return [
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
              horizontal: 16,
              vertical: 12,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          icon: const Icon(Icons.download, size: 18),
          label: const Text(
            '导出',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 8),
      ],
      FilledButton(
        onPressed: () => Navigator.pop(context),
        style: FilledButton.styleFrom(
          backgroundColor: Colors.grey[100],
          foregroundColor: Colors.black87,
          padding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 12,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: const Text('关闭', style: TextStyle(fontSize: 14)),
      ),
    ];
  }

  /// 格式化日期
  String _formatDate(DateTime date) {
    return '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}
