import 'dart:convert';
import 'dart:typed_data';

/// 内容项抽象类
abstract class ContentItem {
  Map<String, dynamic> toJson();

  static ContentItem fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
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

/// 文本内容
class TextContent extends ContentItem {
  final String text;

  TextContent({required this.text});

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'text', 'text': text};
  }

  factory TextContent.fromJson(Map<String, dynamic> json) {
    return TextContent(text: json['text'] as String);
  }
}

/// 图片内容
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

/// 封面内容
class CoverContent extends ContentItem {
  final Uint8List imageData;

  CoverContent({required this.imageData});

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'cover', 'imageData': base64Encode(imageData)};
  }

  factory CoverContent.fromJson(Map<String, dynamic> json) {
    return CoverContent(
      imageData: base64Decode(json['imageData'] as String),
    );
  }
}
