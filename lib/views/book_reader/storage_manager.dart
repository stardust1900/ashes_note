import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/book_reader/bookmark.dart';
import '../../models/book_reader/highlight.dart';

/// 存储管理器 - 处理书签、高亮、阅读位置等的持久化
class StorageManager {
  // 书签保存相关
  static const String _bookmarksPrefix = 'bookmarks_';

  // 高亮保存相关
  static const String _highlightsPrefix = 'book_highlights_';

  // 阅读位置保存相关
  static const String _readingPositionPrefix = 'reading_position_';
  static const String _lastReadBookKey = 'last_read_book';

  /// 生成书籍的唯一标识键
  static String getBookKey(String bookPath) {
    final normalizedPath = bookPath.replaceAll('\\', '/');
    return '$_readingPositionPrefix${normalizedPath.hashCode}';
  }

  /// 保存阅读位置到本地
  static Future<void> saveReadingPosition({
    required String bookPath,
    required String bookTitle,
    required int chapterIndex,
    required int pageIndex,
    required double scrollOffset,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bookKey = getBookKey(bookPath);

      final positionData = {
        'bookPath': bookPath,
        'bookTitle': bookTitle,
        'chapterIndex': chapterIndex,
        'pageIndex': pageIndex,
        'scrollOffset': scrollOffset,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      await prefs.setString(bookKey, positionData.toString());
      await prefs.setString(_lastReadBookKey, bookPath);
    } catch (e) {
      print('保存阅读位置失败: $e');
    }
  }

  /// 从本地加载阅读位置
  static Future<Map<String, dynamic>?> loadReadingPosition(
    String bookPath,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bookKey = getBookKey(bookPath);
      final positionStr = prefs.getString(bookKey);

      if (positionStr == null) return null;

      return _parsePositionData(positionStr);
    } catch (e) {
      print('加载阅读位置失败: $e');
      return null;
    }
  }

  /// 解析位置数据字符串
  static Map<String, dynamic> _parsePositionData(String data) {
    final result = <String, dynamic>{};
    final content = data.substring(1, data.length - 1);
    final pairs = content.split(', ');

    for (final pair in pairs) {
      final parts = pair.split(': ');
      if (parts.length == 2) {
        final key = parts[0].trim();
        final value = parts[1].trim();

        if (key == 'bookPath' || key == 'bookTitle') {
          result[key] = value;
        } else if (key == 'timestamp') {
          result[key] = int.tryParse(value) ?? 0;
        } else if (key == 'scrollOffset') {
          result[key] = double.tryParse(value) ?? 0.0;
        } else {
          result[key] = int.tryParse(value) ?? 0;
        }
      }
    }
    return result;
  }

  /// 生成书签存储键
  static String _getBookmarksKey(String bookPath) {
    final normalizedPath = bookPath.replaceAll('\\', '/');
    return '$_bookmarksPrefix${normalizedPath.hashCode}';
  }

  /// 保存书签到本地
  static Future<void> saveBookmarks(
    String bookPath,
    List<Bookmark> bookmarks,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getBookmarksKey(bookPath);
      final bookmarksJson = bookmarks
          .map(
            (b) => jsonEncode({
              'chapterIndex': b.chapterIndex,
              'pageIndex': b.pageIndex,
              'title': b.title,
              'timestamp': b.timestamp.millisecondsSinceEpoch,
              'note': b.note,
              'colorIndex': b.colorIndex,
            }),
          )
          .toList();
      await prefs.setStringList(key, bookmarksJson);
    } catch (e) {
      print('保存书签失败: $e');
    }
  }

  /// 从本地加载书签
  static Future<List<Bookmark>> loadBookmarks(String bookPath) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getBookmarksKey(bookPath);
      final bookmarksJson = prefs.getStringList(key);

      if (bookmarksJson != null && bookmarksJson.isNotEmpty) {
        final bookmarks = <Bookmark>[];
        for (var json in bookmarksJson) {
          try {
            final data = jsonDecode(json) as Map<String, dynamic>;
            bookmarks.add(
              Bookmark(
                chapterIndex: data['chapterIndex'] as int,
                pageIndex: data['pageIndex'] as int,
                title: data['title'] as String,
                timestamp: DateTime.fromMillisecondsSinceEpoch(
                  data['timestamp'] as int,
                ),
                note: data['note'] as String?,
                colorIndex: data['colorIndex'] as int? ?? 0,
              ),
            );
          } catch (e) {
            print('解析书签失败: $e');
          }
        }
        return bookmarks;
      }
    } catch (e) {
      print('加载书签失败: $e');
    }
    return [];
  }

  /// 保存高亮到本地存储
  static Future<void> saveHighlights(
    String bookPath,
    List<Highlight> highlights,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final normalizedPath = bookPath.replaceAll('\\', '/');
      final bookKey = '$_highlightsPrefix${normalizedPath.hashCode}';
      final highlightsJson = highlights.map((h) => h.toJson()).toList();
      await prefs.setString(bookKey, jsonEncode(highlightsJson));
    } catch (e) {
      print('保存高亮失败: $e');
    }
  }

  /// 从本地存储加载高亮
  static Future<List<Highlight>> loadHighlights(String bookPath) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final normalizedPath = bookPath.replaceAll('\\', '/');
      final bookKey = '$_highlightsPrefix${normalizedPath.hashCode}';
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

  /// 保存字体大小
  static Future<void> saveFontSize(String bookPath, double fontSize) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final normalizedPath = bookPath.replaceAll('\\', '/');
      final bookKey = 'book_font_size_${normalizedPath.hashCode}';
      await prefs.setDouble(bookKey, fontSize);
    } catch (e) {
      print('保存字体大小失败: $e');
    }
  }

  /// 加载保存的字体大小
  static Future<double?> loadFontSize(String bookPath) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final normalizedPath = bookPath.replaceAll('\\', '/');
      final bookKey = 'book_font_size_${normalizedPath.hashCode}';
      return prefs.getDouble(bookKey);
    } catch (e) {
      print('加载字体大小失败: $e');
      return null;
    }
  }

  /// 保存默认高亮颜色
  static Future<void> saveDefaultHighlightColor(Color color) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('default_highlight_color', color.toARGB32());
    } catch (e) {
      print('保存默认高亮颜色失败: $e');
    }
  }

  /// 加载默认高亮颜色
  static Future<Color?> loadDefaultHighlightColor() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final colorValue = prefs.getInt('default_highlight_color');
      if (colorValue != null) {
        return Color(colorValue);
      }
    } catch (e) {
      print('加载默认高亮颜色失败: $e');
    }
    return null;
  }

  /// 保存词典翻译目标语言
  static Future<void> saveDictionaryTargetLanguage(String language) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('dictionary_target_language', language);
    } catch (e) {
      print('保存词典翻译目标语言失败: $e');
    }
  }

  /// 加载词典翻译目标语言
  static Future<String?> loadDictionaryTargetLanguage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('dictionary_target_language');
    } catch (e) {
      print('加载词典翻译目标语言失败: $e');
      return null;
    }
  }
}
