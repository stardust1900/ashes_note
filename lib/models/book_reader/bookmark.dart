import 'package:flutter/material.dart';

/// 书签
class Bookmark {
  final int chapterIndex;
  final int pageIndex;
  final String chapterTitle;
  final DateTime createdAt;
  final Color color;
  final String? note;

  Bookmark({
    required this.chapterIndex,
    required this.pageIndex,
    required this.chapterTitle,
    DateTime? createdAt,
    this.color = Colors.blue,
    this.note,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'chapterIndex': chapterIndex,
      'pageIndex': pageIndex,
      'chapterTitle': chapterTitle,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'color': color.toARGB32(),
      'note': note,
    };
  }

  factory Bookmark.fromJson(Map<String, dynamic> json) {
    return Bookmark(
      chapterIndex: json['chapterIndex'] as int,
      pageIndex: json['pageIndex'] as int,
      chapterTitle: json['chapterTitle'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
      color: Color(json['color'] as int),
      note: json['note'] as String?,
    );
  }
}

// 书签颜色配置 - 5种显眼颜色
class BookmarkColors {
  static const List<Color> colors = [
    Colors.red,
    Colors.orange,
    Colors.yellow,
    Colors.green,
    Colors.blue,
  ];
}
