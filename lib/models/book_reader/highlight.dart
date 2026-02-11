import 'package:flutter/material.dart';

/// 高亮笔记数据类
class Highlight {
  final String id; // 唯一标识
  final int chapterIndex; // 章节索引
  final int pageIndex; // 页面索引
  final String text; // 高亮文本内容
  final Color color; // 高亮颜色
  final int startOffset; // 在章节文本中的起始位置
  final int endOffset; // 在章节文本中的结束位置
  final DateTime createdAt; // 创建时间
  String? note; // 用户添加的笔记内容
  final bool isUnderline; // 是否为划线（false=高亮，true=划线）

  Highlight({
    String? id,
    required this.chapterIndex,
    required this.pageIndex,
    required this.text,
    required this.color,
    required this.startOffset,
    required this.endOffset,
    this.note,
    DateTime? createdAt,
    this.isUnderline = false,
  }) : id = id ?? DateTime.now().millisecondsSinceEpoch.toString(),
       createdAt = createdAt ?? DateTime.now();

  // 转换为JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'chapterIndex': chapterIndex,
      'pageIndex': pageIndex,
      'text': text,
      'color': color.toARGB32(),
      'startOffset': startOffset,
      'endOffset': endOffset,
      'note': note,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'isUnderline': isUnderline,
    };
  }

  // 从JSON创建
  factory Highlight.fromJson(Map<String, dynamic> json) {
    return Highlight(
      id: json['id'] as String,
      chapterIndex: json['chapterIndex'] as int,
      pageIndex: json['pageIndex'] as int,
      text: json['text'] as String,
      color: Color(json['color'] as int),
      startOffset: json['startOffset'] as int,
      endOffset: json['endOffset'] as int,
      note: json['note'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
      isUnderline: json['isUnderline'] as bool? ?? false,
    );
  }
}

/// 章节分组辅助类
class ChapterGroup {
  final int chapterIndex;
  final String chapterTitle;
  final List<MergedHighlight> mergedHighlights;

  ChapterGroup({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.mergedHighlights,
  });
}

/// 合并后的高亮/划线标记
/// 将重叠的高亮和划线合并成一条显示
class MergedHighlight {
  final int chapterIndex;
  final int pageIndex;
  final String text; // 合并后的文本（取最大范围）
  final int startOffset; // 合并后的起始位置（最小）
  final int endOffset; // 合并后的结束位置（最大）
  final List<Highlight> originalHighlights; // 原始高亮列表
  final List<Highlight> originalUnderlines; // 原始划线列表
  final DateTime createdAt; // 最早的创建时间
  String? note; // 合并后的笔记（优先取高亮的笔记）

  MergedHighlight({
    required this.chapterIndex,
    required this.pageIndex,
    required this.text,
    required this.startOffset,
    required this.endOffset,
    required this.originalHighlights,
    required this.originalUnderlines,
    required this.createdAt,
    this.note,
  });
}
