// 笔记本数据模型
import 'dart:ui' show Color;
import 'package:flutter/material.dart' show Colors;

class Notebook {
  final String name;
  final List<Note> notes;
  final Color color;

  Notebook({required this.name, required this.notes, this.color = Colors.blue});
}

// 笔记数据模型
class Note {
  String id;
  String title;
  String content;
  DateTime lastModified;

  Note({
    required this.id,
    required this.title,
    required this.content,
    required this.lastModified,
  });
}
