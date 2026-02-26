import 'dart:typed_data';

/// 内容项基类
abstract class ContentItem {
  Map<String, dynamic> toJson();
  static ContentItem fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'text':
        return TextContent.fromJson(json);
      case 'image':
        return ImageContent.fromJson(json);
      case 'cover':
        return CoverContent.fromJson(json);
      default:
        throw Exception('Unknown content type: $type');
    }
  }
}

/// 文本内容项
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

/// 封面内容项
class CoverContent extends ContentItem {
  final Uint8List imageData;

  CoverContent({required this.imageData});

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'cover', 'imageData': imageData};
  }

  factory CoverContent.fromJson(Map<String, dynamic> json) {
    return CoverContent(imageData: Uint8List.fromList((json['imageData'] as List<dynamic>).cast<int>()));
  }
}
