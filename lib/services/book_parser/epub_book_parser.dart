import 'dart:io';
import 'dart:typed_data';
import 'package:epub_plus/epub_plus.dart';
import 'book_parser.dart';

/// EPUB 书籍解析器
class EpubBookParser implements BookParser {
  @override
  bool supportsFormat(String filePath) {
    return filePath.toLowerCase().endsWith('.epub');
  }

  @override
  Future<BookData> parse(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    return parseBytes(bytes, fileName: filePath);
  }

  @override
  Future<BookData> parseBytes(Uint8List bytes, {String? fileName}) async {
    final epub = await EpubReader.readBook(bytes);

    // 提取封面图片
    Uint8List? coverImage;
    if (epub.coverImage != null) {
      // 将 ImageData 转换为 Uint8List
      coverImage = Uint8List.fromList(epub.coverImage!.data as List<int>);
    }

    // 解析章节
    final chapters = _parseChapters(epub.chapters);

    return BookData(
      title: epub.title ?? '未知书籍',
      author: epub.author,
      description: null, // epub_plus 包可能不支持此字段
      chapters: chapters,
      coverImage: coverImage,
      metadata: {
        'fileName': fileName,
        // epub_plus 包可能不支持以下字段
        'language': null,
        'publisher': null,
        'pubDate': null,
      },
    );
  }

  List<BookChapter> _parseChapters(List<EpubChapter>? epubChapters) {
    if (epubChapters == null || epubChapters.isEmpty) {
      return [];
    }

    return epubChapters.map((chapter) {
      return BookChapter(
        title: chapter.title ?? '无标题章节',
        content: chapter.htmlContent ?? '',
        anchor: chapter.anchor,
        subChapters: _parseChapters(chapter.subChapters),
      );
    }).toList();
  }
}
