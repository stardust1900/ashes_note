import 'dart:async';
import 'dart:io';
import 'package:ashes_note/models/book_reader/book_reader_models.dart';
import 'package:ashes_note/services/book_parser/book_parsers.dart';
import 'package:ashes_note/services/book_reader/book_reader_services.dart';
import 'package:flutter/material.dart';

/// 重构后的阅读器页面 - 使用新的服务架构
/// 
/// 优化点：
/// 1. 数据模型独立到 lib/models/book_reader/
/// 2. EPUB解析独立到 lib/services/book_parser/
/// 3. 缓存和存储服务独立到 lib/services/book_reader/
/// 4. 易于扩展支持其他格式（MOBI、PDF等）
class BookReaderPageRefactored extends StatefulWidget {
  final String bookPath;

  const BookReaderPageRefactored({
    super.key,
    required this.bookPath,
  });

  @override
  State<BookReaderPageRefactored> createState() =>
      _BookReaderPageRefactoredState();
}

class _BookReaderPageRefactoredState extends State<BookReaderPageRefactored> {
  // 服务实例
  final BookCacheService _cacheService = BookCacheService();
  final BookStorageService _storageService = BookStorageService();

  // 状态变量
  BookData? _bookData;
  List<BookChapter> _chapters = [];
  List<PageContent> _pages = [];
  List<Highlight> _highlights = [];
  List<Bookmark> _bookmarks = [];

  int _currentChapterIndex = 0;
  int _currentPageIndex = 0;
  double _fontSize = 16;
  ReadingMode _readingMode = ReadingMode.page;

  bool _isLoading = true;
  bool _hasError = false;
  String _errorMessage = '';

  String? _cacheKey;
  Size? _windowSize;

  @override
  void initState() {
    super.initState();
    _loadBook();
  }

  /// 加载书籍
  Future<void> _loadBook() async {
    try {
      setState(() {
        _isLoading = true;
        _hasError = false;
      });

      // 1. 获取解析器
      final parser = BookParserFactory.getParser(widget.bookPath);
      if (parser == null) {
        throw Exception('不支持的文件格式');
      }

      // 2. 解析书籍
      _bookData = await parser.parse(widget.bookPath);
      _chapters = _bookData?.chapters ?? [];

      // 3. 加载用户设置
      await _loadUserSettings();

      // 4. 生成缓存键
      _cacheKey = await _cacheService.generateCacheKey(widget.bookPath);

      // 5. 尝试从缓存加载页面
      if (_cacheKey != null && _windowSize != null) {
        final cachedPages = await _cacheService.loadPages(
          _cacheKey!,
          _fontSize,
          _windowSize!,
        );
        if (cachedPages != null && cachedPages.isNotEmpty) {
          setState(() {
            _pages = cachedPages;
            _isLoading = false;
          });
          return;
        }
      }

      // 6. 没有缓存，需要重新分页
      await _processPages();

      // 7. 加载阅读位置
      await _loadReadingPosition();

      // 8. 加载高亮和书签
      await _loadHighlightsAndBookmarks();

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _hasError = true;
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  /// 加载用户设置
  Future<void> _loadUserSettings() async {
    final savedFontSize = await _storageService.loadFontSize();
    if (savedFontSize != null) {
      _fontSize = savedFontSize;
    }
  }

  /// 处理页面分页
  Future<void> _processPages() async {
    // TODO: 实现分页逻辑
    // 这部分逻辑可以从原文件中提取
  }

  /// 加载阅读位置
  Future<void> _loadReadingPosition() async {
    final position = await _storageService.loadReadingPosition(widget.bookPath);
    if (position != null) {
      setState(() {
        _currentChapterIndex = position.$1;
        _currentPageIndex = position.$2;
      });
    }
  }

  /// 加载高亮和书签
  Future<void> _loadHighlightsAndBookmarks() async {
    _highlights = await _storageService.loadHighlights(widget.bookPath);
    _bookmarks = await _storageService.loadBookmarks(widget.bookPath);
  }

  /// 保存阅读位置
  Future<void> _saveReadingPosition() async {
    await _storageService.saveReadingPosition(
      widget.bookPath,
      _currentChapterIndex,
      _currentPageIndex,
    );
  }

  /// 应用字体大小变更
  Future<void> _applyFontSizeChange(double newFontSize) async {
    if (newFontSize == _fontSize) return;

    setState(() {
      _fontSize = newFontSize;
    });

    // 保存字体大小设置
    await _storageService.saveFontSize(newFontSize);

    // 清除旧缓存（仅页面布局缓存，不影响高亮和笔记）
    if (_cacheKey != null) {
      await _cacheService.clearCache(_cacheKey!);
    }

    // 重新分页
    await _processPages();
  }

  @override
  Widget build(BuildContext context) {
    // TODO: 实现UI
    return Scaffold(
      appBar: AppBar(
        title: Text(_bookData?.title ?? '阅读器'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_hasError) {
      return Center(child: Text('加载失败: $_errorMessage'));
    }

    // TODO: 实现阅读器主体UI
    return const Center(child: Text('阅读器内容'));
  }
}
