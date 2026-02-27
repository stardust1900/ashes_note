import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/book_reader/book_reader_models.dart';

/// 书籍数据存储服务
/// 管理阅读进度、书签、高亮等数据的持久化
class BookStorageService {
  static final BookStorageService _instance = BookStorageService._internal();
  factory BookStorageService() => _instance;
  BookStorageService._internal();

  static const String _readingPositionPrefix = 'reading_position_';
  static const String _lastReadBookKey = 'last_read_book';
  static const String _bookmarksPrefix = 'bookmarks_';
  static const String _highlightsPrefix = 'book_highlights_';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _preferences async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // ==================== 阅读位置 ====================

  /// 保存阅读位置
  Future<void> saveReadingPosition(
    String bookPath,
    int chapterIndex,
    int pageIndex,
  ) async {
    try {
      final prefs = await _preferences;
      final bookKey = '$_readingPositionPrefix${bookPath.hashCode}';
      final position = '$chapterIndex:$pageIndex';
      await prefs.setString(bookKey, position);
    } catch (e) {
      print('保存阅读位置失败: $e');
    }
  }

  /// 加载阅读位置
  Future<(int chapterIndex, int pageIndex)?> loadReadingPosition(
    String bookPath,
  ) async {
    try {
      final prefs = await _preferences;
      final bookKey = '$_readingPositionPrefix${bookPath.hashCode}';
      final position = prefs.getString(bookKey);
      if (position != null) {
        final parts = position.split(':');
        if (parts.length == 2) {
          return (int.parse(parts[0]), int.parse(parts[1]));
        }
      }
    } catch (e) {
      print('加载阅读位置失败: $e');
    }
    return null;
  }

  /// 保存最后阅读的书籍
  Future<void> saveLastReadBook(String bookPath) async {
    try {
      final prefs = await _preferences;
      await prefs.setString(_lastReadBookKey, bookPath);
    } catch (e) {
      print('保存最后阅读书籍失败: $e');
    }
  }

  /// 获取最后阅读的书籍路径
  Future<String?> getLastReadBook() async {
    try {
      final prefs = await _preferences;
      return prefs.getString(_lastReadBookKey);
    } catch (e) {
      return null;
    }
  }

  // ==================== 书签 ====================

  /// 保存书签列表
  Future<void> saveBookmarks(String bookPath, List<Bookmark> bookmarks) async {
    try {
      final prefs = await _preferences;
      final bookKey = '$_bookmarksPrefix${bookPath.hashCode}';
      final bookmarksJson = bookmarks.map((b) => b.toJson()).toList();
      await prefs.setString(bookKey, jsonEncode(bookmarksJson));
    } catch (e) {
      print('保存书签失败: $e');
    }
  }

  /// 加载书签列表
  Future<List<Bookmark>> loadBookmarks(String bookPath) async {
    try {
      final prefs = await _preferences;
      final bookKey = '$_bookmarksPrefix${bookPath.hashCode}';
      final bookmarksString = prefs.getString(bookKey);
      if (bookmarksString != null) {
        final bookmarksList = jsonDecode(bookmarksString) as List<dynamic>;
        return bookmarksList
            .map((json) => Bookmark.fromJson(json as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      print('加载书签失败: $e');
    }
    return [];
  }

  // ==================== 高亮 ====================

  /// 保存高亮列表
  Future<void> saveHighlights(String bookPath, List<Highlight> highlights) async {
    try {
      final prefs = await _preferences;
      final bookKey = '$_highlightsPrefix${bookPath.hashCode}';
      final highlightsJson = highlights.map((h) => h.toJson()).toList();
      await prefs.setString(bookKey, jsonEncode(highlightsJson));
    } catch (e) {
      print('保存高亮失败: $e');
    }
  }

  /// 加载高亮列表
  Future<List<Highlight>> loadHighlights(String bookPath) async {
    try {
      final prefs = await _preferences;
      final bookKey = '$_highlightsPrefix${bookPath.hashCode}';
      final highlightsString = prefs.getString(bookKey);
      if (highlightsString != null) {
        final highlightsList = jsonDecode(highlightsString) as List<dynamic>;
        return highlightsList
            .map((json) => Highlight.fromJson(json as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      print('加载高亮失败: $e');
    }
    return [];
  }

  // ==================== 字体大小 ====================

  /// 保存字体大小
  Future<void> saveFontSize(String bookPath, double fontSize) async {
    try {
      final prefs = await _preferences;
      final bookKey = 'book_font_size_${bookPath.hashCode}';
      await prefs.setDouble(bookKey, fontSize);
    } catch (e) {
      print('保存字体大小失败: $e');
    }
  }

  /// 加载字体大小
  Future<double?> loadFontSize(String bookPath) async {
    try {
      final prefs = await _preferences;
      final bookKey = 'book_font_size_${bookPath.hashCode}';
      return prefs.getDouble(bookKey);
    } catch (e) {
      return null;
    }
  }

  // ==================== 数据迁移 ====================

  /// 迁移书籍相关数据（修改书名后使用）
  Future<void> migrateBookData(
    String oldBookPath,
    String newBookPath,
  ) async {
    try {
      final prefs = await _preferences;

      // 迁移阅读位置
      final oldPositionKey = '$_readingPositionPrefix${oldBookPath.hashCode}';
      final newPositionKey = '$_readingPositionPrefix${newBookPath.hashCode}';
      final position = prefs.getString(oldPositionKey);
      if (position != null) {
        await prefs.setString(newPositionKey, position);
        await prefs.remove(oldPositionKey);
      }

      // 迁移书签
      final oldBookmarksKey = '$_bookmarksPrefix${oldBookPath.hashCode}';
      final newBookmarksKey = '$_bookmarksPrefix${newBookPath.hashCode}';
      final bookmarks = prefs.getString(oldBookmarksKey);
      if (bookmarks != null) {
        await prefs.setString(newBookmarksKey, bookmarks);
        await prefs.remove(oldBookmarksKey);
      }

      // 迁移高亮
      final oldHighlightsKey = '$_highlightsPrefix${oldBookPath.hashCode}';
      final newHighlightsKey = '$_highlightsPrefix${newBookPath.hashCode}';
      final highlights = prefs.getString(oldHighlightsKey);
      if (highlights != null) {
        await prefs.setString(newHighlightsKey, highlights);
        await prefs.remove(oldHighlightsKey);
      }

      // 迁移字体大小
      final oldFontSizeKey = 'book_font_size_${oldBookPath.hashCode}';
      final newFontSizeKey = 'book_font_size_${newBookPath.hashCode}';
      final fontSize = prefs.getDouble(oldFontSizeKey);
      if (fontSize != null) {
        await prefs.setDouble(newFontSizeKey, fontSize);
        await prefs.remove(oldFontSizeKey);
      }

      // 更新最后阅读书籍
      final lastReadBook = prefs.getString(_lastReadBookKey);
      if (lastReadBook == oldBookPath) {
        await prefs.setString(_lastReadBookKey, newBookPath);
      }
    } catch (e) {
      print('迁移书籍数据失败: $e');
    }
  }
}
