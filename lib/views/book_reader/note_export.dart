import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../utils/prefs_util.dart';
import '../../models/book_reader/highlight.dart';
import 'highlight_operations.dart';

/// 笔记导出功能
class NoteExport {
  /// 导出笔记为 Markdown 格式
  static Future<void> exportNotesToMarkdown(
    String bookTitle,
    List<Highlight> highlights,
    String Function(int chapterIndex) getChapterTitle,
    String Function(int chapterIndex, int startOffset, int endOffset)
    getTextForRange,
    BuildContext context,
  ) async {
    // 获取默认文件名
    final defaultFileName = '$bookTitle读书笔记';

    // 弹出文件名编辑对话框
    final fileName = await _showExportFileNameDialog(defaultFileName, context);
    if (fileName == null || fileName.isEmpty) return;

    try {
      // 生成 Markdown 内容
      final markdownContent = _generateNotesMarkdown(
        bookTitle,
        highlights,
        getChapterTitle,
        getTextForRange,
      );

      // 获取读书笔记目录路径
      final workingDirectory = SPUtil.get<String>('workingDirectory', '');
      if (workingDirectory.isEmpty) {
        throw Exception('未设置工作目录，请先在设置中配置工作目录');
      }
      final notesDir = Directory('$workingDirectory/notes/读书笔记');

      // 创建目录（如果不存在）
      if (!await notesDir.exists()) {
        await notesDir.create(recursive: true);
      }

      // 保存文件
      final filePath = '${notesDir.path}${Platform.pathSeparator}$fileName';
      final file = File(filePath);
      await file.writeAsString(markdownContent, encoding: utf8);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('笔记已导出到: $filePath'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// 显示导出文件名编辑对话框
  static Future<String?> _showExportFileNameDialog(
    String defaultName,
    BuildContext context,
  ) async {
    final controller = TextEditingController(text: defaultName);

    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.download, color: Colors.green),
            SizedBox(width: 12),
            Text('导出笔记', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '请输入导出文件名：',
              style: TextStyle(fontSize: 14, color: Colors.black87),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '文件名',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                suffixText: '.md',
              ),
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 8),
            const Text(
              '将保存到笔记目录下',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              String fileName = controller.text.trim();
              if (!fileName.toLowerCase().endsWith('.md')) {
                fileName = '$fileName.md';
              }
              Navigator.pop(context, fileName);
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('导出'),
          ),
        ],
      ),
    );
  }

  /// 生成笔记的 Markdown 内容
  static String _generateNotesMarkdown(
    String bookTitle,
    List<Highlight> highlights,
    String Function(int chapterIndex) getChapterTitle,
    String Function(int chapterIndex, int startOffset, int endOffset)
    getTextForRange,
  ) {
    final buffer = StringBuffer();

    buffer.writeln('# ${bookTitle.isEmpty ? '读书笔记' : bookTitle}');
    buffer.writeln();
    buffer.writeln('---');
    buffer.writeln();

    final groupedHighlights = HighlightOperations.groupHighlightsByChapter(
      highlights,
      getChapterTitle,
      getTextForRange,
    );

    if (groupedHighlights.isEmpty) {
      buffer.writeln('暂无笔记和高亮');
      buffer.writeln();
      return buffer.toString();
    }

    for (final group in groupedHighlights) {
      buffer.writeln('## ${group.chapterTitle}');
      buffer.writeln();

      for (final merged in group.mergedHighlights) {
        final quotedText = _formatQuotedText(merged);
        final lines = quotedText.split('\n');
        for (final line in lines) {
          buffer.writeln('> $line');
        }
        buffer.writeln();

        if (merged.note != null && merged.note!.isNotEmpty) {
          buffer.writeln(merged.note);
          buffer.writeln();
        }

        // buffer.writeln('---');
        buffer.writeln();
      }
    }

    return buffer.toString();
  }

  /// 格式化引用文本
  static String _formatQuotedText(MergedHighlight merged) {
    final text = merged.text;
    final hasHighlight = merged.hasHighlight;
    final hasUnderline = merged.hasUnderline;

    if (!hasHighlight || !hasUnderline) {
      return text;
    }

    final textStartOffset = merged.startOffset;
    final highlights = merged.originalHighlights;
    final underlines = merged.originalUnderlines;

    final Set<int> splitPoints = {0, text.length};
    for (final h in highlights) {
      final start = (h.startOffset - textStartOffset).clamp(0, text.length);
      final end = (h.endOffset - textStartOffset).clamp(0, text.length);
      if (start < end) {
        splitPoints.add(start);
        splitPoints.add(end);
      }
    }
    for (final u in underlines) {
      final start = (u.startOffset - textStartOffset).clamp(0, text.length);
      final end = (u.endOffset - textStartOffset).clamp(0, text.length);
      if (start < end) {
        splitPoints.add(start);
        splitPoints.add(end);
      }
    }

    final sortedPoints = splitPoints.toList()..sort();

    final segments = <String>[];
    for (int i = 0; i < sortedPoints.length - 1; i++) {
      final segStart = sortedPoints[i];
      final segEnd = sortedPoints[i + 1];
      if (segStart >= segEnd) continue;

      final segText = text.substring(segStart, segEnd);

      final segHasHighlight = highlights.any((h) {
        final hStart = h.startOffset - textStartOffset;
        final hEnd = h.endOffset - textStartOffset;
        return segStart < hEnd && segEnd > hStart;
      });

      final segHasUnderline = underlines.any((u) {
        final uStart = u.startOffset - textStartOffset;
        final uEnd = u.endOffset - textStartOffset;
        return segStart < uEnd && segEnd > uStart;
      });

      if (segHasHighlight && segHasUnderline) {
        segments.add('**$segText**');
      } else {
        segments.add(segText);
      }
    }

    return segments.join();
  }
}
