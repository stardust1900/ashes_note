import 'dart:typed_data';

/// 书籍解析器抽象接口
/// 用于支持多种书籍格式（EPUB、MOBI、PDF等）
abstract class BookParser {
  /// 解析书籍文件
  Future<BookData> parse(String filePath);

  /// 解析书籍字节数据
  Future<BookData> parseBytes(Uint8List bytes, {String? fileName});

  /// 检查是否支持该文件格式
  bool supportsFormat(String filePath);
}

/// 解析后的书籍数据
class BookData {
  final String title;
  final String? author;
  final String? description;
  final List<BookChapter> chapters;
  final Uint8List? coverImage;
  final Map<String, dynamic> metadata;

  BookData({
    required this.title,
    this.author,
    this.description,
    required this.chapters,
    this.coverImage,
    this.metadata = const {},
  });
}

/// 书籍章节数据
class BookChapter {
  final String title;
  final String content;
  final String? anchor;
  final List<BookChapter> subChapters;

  BookChapter({
    required this.title,
    required this.content,
    this.anchor,
    this.subChapters = const [],
  });
}
