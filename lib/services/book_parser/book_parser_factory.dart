import 'book_parser.dart';
import 'epub_book_parser.dart';

/// 书籍解析器工厂
/// 用于获取支持特定格式的解析器
class BookParserFactory {
  static final List<BookParser> _parsers = [
    EpubBookParser(),
    // 未来可以添加其他格式解析器：
    // MobiBookParser(),
    // PdfBookParser(),
    // TxtBookParser(),
  ];

  /// 获取支持该文件格式的解析器
  static BookParser? getParser(String filePath) {
    for (final parser in _parsers) {
      if (parser.supportsFormat(filePath)) {
        return parser;
      }
    }
    return null;
  }

  /// 检查是否支持该文件格式
  static bool isSupported(String filePath) {
    return getParser(filePath) != null;
  }

  /// 注册新的解析器
  static void registerParser(BookParser parser) {
    _parsers.add(parser);
  }
}
