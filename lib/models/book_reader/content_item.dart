/// 内容项基类
abstract class ContentItem {
  Map<String, dynamic> toJson();
  static ContentItem fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'text':
        return TextContent.fromJson(json);
      case 'text_ref':
        return TextContentRef.fromJson(json);
      case 'header':
        return HeaderContent.fromJson(json);
      case 'image':
        return ImageContent.fromJson(json);
      case 'cover':
        return CoverContent.fromJson(json);
      default:
        throw Exception('Unknown content type: $type');
    }
  }
}

/// 文本内容项（完整文本，用于内存和渲染）
class TextContent extends ContentItem {
  final String text;
  final int startOffset; // 文本在章节中的起始偏移量

  TextContent({required this.text, this.startOffset = 0});

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'text', 'text': text, 'startOffset': startOffset};
  }

  factory TextContent.fromJson(Map<String, dynamic> json) {
    return TextContent(
      text: json['text'] as String,
      startOffset: json['startOffset'] as int? ?? 0,
    );
  }
}

/// 文本引用内容项（只存储偏移量，用于缓存）
class TextContentRef extends ContentItem {
  final int offset; // 文本在章节中的起始偏移量
  final int length; // 文本长度

  TextContentRef({required this.offset, required this.length});

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'text_ref', 'offset': offset, 'length': length};
  }

  factory TextContentRef.fromJson(Map<String, dynamic> json) {
    return TextContentRef(
      offset: json['offset'] as int,
      length: json['length'] as int,
    );
  }

  /// 从章节纯文本中提取完整文本
  TextContent toTextContent(String chapterPlainText) {
    final endOffset = offset + length;
    final text = offset < chapterPlainText.length
        ? chapterPlainText.substring(
            offset,
            endOffset.clamp(0, chapterPlainText.length),
          )
        : '';
    return TextContent(text: text, startOffset: offset);
  }
}

/// 图片内容项
class ImageContent extends ContentItem {
  final String source;

  ImageContent({required this.source});

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'image', 'source': source};
  }

  factory ImageContent.fromJson(Map<String, dynamic> json) {
    return ImageContent(source: json['source'] as String);
  }
}

/// 标题内容项
class HeaderContent extends ContentItem {
  final String text;
  final int level; // 标题级别：1-6

  HeaderContent({required this.text, required this.level});

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'header', 'text': text, 'level': level};
  }

  factory HeaderContent.fromJson(Map<String, dynamic> json) {
    return HeaderContent(
      text: json['text'] as String,
      level: json['level'] as int,
    );
  }
}

/// 封面内容项
class CoverContent extends ContentItem {
  final String? imagePath; // 封面图片文件路径

  CoverContent({this.imagePath});

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'cover', 'imagePath': imagePath};
  }

  factory CoverContent.fromJson(Map<String, dynamic> json) {
    return CoverContent(imagePath: json['imagePath'] as String?);
  }
}
