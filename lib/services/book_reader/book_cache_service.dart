import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../../models/book_reader/book_reader_models.dart';

/// 书籍缓存服务
/// 管理书籍页面布局缓存
class BookCacheService {
  static final BookCacheService _instance = BookCacheService._internal();
  factory BookCacheService() => _instance;
  BookCacheService._internal();

  String? _cacheDirPath;

  /// 获取缓存目录路径
  Future<String> _getCacheDirectory() async {
    if (_cacheDirPath != null) return _cacheDirPath!;
    final appDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${appDir.path}/book_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    _cacheDirPath = cacheDir.path;
    return _cacheDirPath!;
  }

  /// 生成书籍缓存键（基于文件路径哈希）
  Future<String?> generateCacheKey(String bookPath) async {
    try {
      final file = File(bookPath);
      if (!await file.exists()) return null;

      // 使用文件路径哈希作为缓存键
      return bookPath.hashCode.toString();
    } catch (e) {
      print('生成缓存键失败: $e');
      return null;
    }
  }

  /// 获取缓存文件路径
  Future<String> _getCacheFilePath(String cacheKey) async {
    final cacheDir = await _getCacheDirectory();
    return '$cacheDir/$cacheKey.json';
  }

  /// 检查缓存是否存在且有效
  Future<bool> isCacheValid(String cacheKey) async {
    try {
      final cacheFilePath = await _getCacheFilePath(cacheKey);
      final cacheFile = File(cacheFilePath);
      return await cacheFile.exists();
    } catch (e) {
      return false;
    }
  }

  /// 保存页面数据到缓存
  Future<void> savePages(
    String cacheKey,
    String bookPath,
    List<PageContent> pages,
    double fontSize,
    Size windowSize,
  ) async {
    try {
      if (pages.isEmpty) return;

      final cacheFilePath = await _getCacheFilePath(cacheKey);
      final cacheData = {
        'bookKey': cacheKey,
        'bookPath': bookPath,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'windowWidth': windowSize.width,
        'windowHeight': windowSize.height,
        'fontSize': fontSize,
        'pages': pages.map((p) => p.toJson()).toList(),
      };

      final cacheFile = File(cacheFilePath);
      await cacheFile.writeAsString(jsonEncode(cacheData));
    } catch (e) {
      print('保存页面缓存失败: $e');
    }
  }

  /// 从缓存加载页面数据
  Future<List<PageContent>?> loadPages(
    String cacheKey,
    double currentFontSize,
    Size currentWindowSize,
  ) async {
    try {
      if (!await isCacheValid(cacheKey)) return null;

      final cacheFilePath = await _getCacheFilePath(cacheKey);
      final cacheFile = File(cacheFilePath);
      final jsonString = await cacheFile.readAsString();
      final cacheData = jsonDecode(jsonString) as Map<String, dynamic>;

      // 验证缓存数据完整性
      final pagesJson = cacheData['pages'] as List<dynamic>?;
      if (pagesJson == null || pagesJson.isEmpty) return null;

      // 检查窗口大小和字体大小是否匹配
      final cachedWidth = (cacheData['windowWidth'] as num?)?.toDouble() ?? 0;
      final cachedHeight = (cacheData['windowHeight'] as num?)?.toDouble() ?? 0;
      final cachedFontSize = (cacheData['fontSize'] as num?)?.toDouble() ?? 16;

      final widthDiff = (currentWindowSize.width - cachedWidth).abs();
      final heightDiff = (currentWindowSize.height - cachedHeight).abs();
      final fontSizeDiff = (currentFontSize - cachedFontSize).abs();

      // 如果窗口大小变化超过10%或字体大小变化，认为缓存失效
      if (widthDiff / currentWindowSize.width > 0.1 ||
          heightDiff / currentWindowSize.height > 0.1 ||
          fontSizeDiff > 0.5) {
        print('缓存窗口大小不匹配，重新生成页面');
        return null;
      }

      return pagesJson
          .map((json) => PageContent.fromJson(json))
          .toList();
    } catch (e) {
      print('从缓存加载页面失败: $e');
      return null;
    }
  }

  /// 清除指定缓存
  Future<void> clearCache(String cacheKey) async {
    try {
      final cacheFilePath = await _getCacheFilePath(cacheKey);
      final cacheFile = File(cacheFilePath);
      if (await cacheFile.exists()) {
        await cacheFile.delete();
      }
    } catch (e) {
      print('清除缓存失败: $e');
    }
  }

  /// 清除所有缓存
  Future<void> clearAllCache() async {
    try {
      final cacheDir = Directory(await _getCacheDirectory());
      if (await cacheDir.exists()) {
        final files = await cacheDir.list().toList();
        for (final file in files) {
          if (file is File) {
            await file.delete();
          }
        }
      }
    } catch (e) {
      print('清除所有缓存失败: $e');
    }
  }
}

class Size {
  final double width;
  final double height;
  const Size(this.width, this.height);
}
