import 'package:flutter/material.dart';

/// 书签数据类
class Bookmark {
  final int chapterIndex;
  final int pageIndex;
  final String title;
  final DateTime timestamp;
  final String? note;
  int colorIndex; // 0-4 对应5种颜色

  Bookmark({
    required this.chapterIndex,
    required this.pageIndex,
    required this.title,
    required this.timestamp,
    this.note,
    this.colorIndex = 0,
  });

  // 获取书签颜色
  Color get color =>
      BookmarkColors.colors[colorIndex % BookmarkColors.colors.length];

  Map<String, dynamic> toJson() {
    return {
      'chapterIndex': chapterIndex,
      'pageIndex': pageIndex,
      'title': title,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'note': note,
      'colorIndex': colorIndex,
    };
  }

  factory Bookmark.fromJson(Map<String, dynamic> json) {
    return Bookmark(
      chapterIndex: json['chapterIndex'] as int,
      pageIndex: json['pageIndex'] as int,
      title: json['title'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
      note: json['note'] as String?,
      colorIndex: json['colorIndex'] as int? ?? 0,
    );
  }
}

// 书签颜色配置 - 5种显眼颜色
class BookmarkColors {
  static const List<Color> colors = [
    Color(0xFFFF0000), // 红色
    Color(0xFFFFA500), // 橙色
    Color(0xFFFFFF00), // 黄色
    Color(0xFF00FF00), // 绿色
    Color(0xFF0000FF), // 蓝色
  ];
}
