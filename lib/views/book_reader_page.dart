import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:epub_plus/epub_plus.dart';
import 'package:flutter/material.dart' hide Image;
import 'package:flutter/material.dart' as material show Image;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';

/// 阅读器页面 - 支持分页阅读和图片显示
class BookReaderPage extends StatefulWidget {
  final String bookPath;

  const BookReaderPage({super.key, required this.bookPath});

  @override
  State<BookReaderPage> createState() => _BookReaderPageState();
}

class _BookReaderPageState extends State<BookReaderPage> {
  final List<EpubChapter> _chapters = [];
  int _currentChapterIndex = 0;
  int _currentPageIndex = 0;
  bool _showTableOfContents = false;
  double _fontSize = 16;
  final List<Bookmark> _bookmarks = [];
  final TextEditingController _noteController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String _bookTitle = '';
  bool _isLoading = true;
  bool _isProcessingPages = false;
  bool _isContentLoaded = false;
  bool _hasError = false;
  String _errorMessage = '';
  EpubBook? _epubBook;
  List<PageContent> _pages = [];
  int _totalPages = 0;
  Uint8List? _coverImage;
  ReadingMode _readingMode = ReadingMode.page;
  Size? _windowSize;
  final GlobalKey _contentKey = GlobalKey();

  // 窗口大小变化防抖控制
  Timer? _resizeDebounceTimer;
  static const Duration _resizeDebounceDuration = Duration(milliseconds: 300);

  // TextPainter 缓存，避免重复创建
  TextPainter? _textPainterCache;

  // 控制栏显示状态
  bool _showControls = true;

  // 阅读位置保存相关
  static const String _readingPositionPrefix = 'reading_position_';
  static const String _lastReadBookKey = 'last_read_book';
  Timer? _savePositionTimer;
  static const Duration _savePositionDebounceDuration = Duration(seconds: 2);

  // ===== 优化相关变量 =====
  // 优先加载的章节数
  static const int _priorityChapterCount = 3;
  // 后台处理状态
  bool _isBackgroundProcessing = false;
  int _processedChaptersCount = 0;
  // 缓存相关
  String? _bookCacheKey;

  // 字体大小保存相关
  static const String _fontSizeKey = 'reader_font_size';
  bool _showFontSizeSlider = false;
  double _tempFontSize = 16;

  // 书签保存相关
  static const String _bookmarksPrefix = 'bookmarks_';

  @override
  void initState() {
    super.initState();
    _loadBook();
  }

  @override
  void dispose() {
    _saveReadingPosition(); // 退出前保存阅读位置
    _resizeDebounceTimer?.cancel();
    _savePositionTimer?.cancel();
    _textPainterCache?.dispose();
    _noteController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 生成书籍的唯一标识键
  String _getBookKey() {
    // 使用书籍路径的 hashCode 作为唯一标识
    return '${_readingPositionPrefix}${widget.bookPath.hashCode}';
  }

  /// 生成书籍缓存键（基于文件内容MD5）
  Future<String> _generateBookCacheKey() async {
    try {
      final file = File(widget.bookPath);
      final bytes = await file.readAsBytes();
      final digest = md5.convert(bytes);
      return digest.toString();
    } catch (e) {
      // 如果读取失败，使用路径和修改时间
      final file = File(widget.bookPath);
      final stat = await file.stat();
      return '${widget.bookPath.hashCode}_${stat.modified.millisecondsSinceEpoch}';
    }
  }

  /// 获取缓存目录路径
  Future<String> _getCacheDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${appDir.path}/book_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir.path;
  }

  /// 获取缓存文件路径
  Future<String> _getCacheFilePath() async {
    if (_bookCacheKey == null) return '';
    final cacheDir = await _getCacheDirectory();
    return '$cacheDir/$_bookCacheKey.json';
  }

  /// 检查缓存是否存在且有效
  Future<bool> _checkCacheValid() async {
    if (_bookCacheKey == null) return false;
    final cacheFilePath = await _getCacheFilePath();
    final cacheFile = File(cacheFilePath);
    return await cacheFile.exists();
  }

  /// 保存页面数据到缓存
  Future<void> _savePagesToCache() async {
    try {
      if (_bookCacheKey == null || _pages.isEmpty) return;

      final cacheFilePath = await _getCacheFilePath();
      final cacheData = {
        'bookKey': _bookCacheKey,
        'bookPath': widget.bookPath,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'windowWidth': _windowSize?.width ?? 0,
        'windowHeight': _windowSize?.height ?? 0,
        'fontSize': _fontSize,
        'pages': _pages.map((p) => p.toJson()).toList(),
      };

      final cacheFile = File(cacheFilePath);
      await cacheFile.writeAsString(jsonEncode(cacheData));
      print('页面缓存已保存: $cacheFilePath');
    } catch (e) {
      print('保存页面缓存失败: $e');
    }
  }

  /// 从缓存加载页面数据
  Future<List<PageContent>?> _loadPagesFromCache() async {
    try {
      if (!await _checkCacheValid()) return null;

      final cacheFilePath = await _getCacheFilePath();
      final cacheFile = File(cacheFilePath);
      final jsonString = await cacheFile.readAsString();
      final cacheData = jsonDecode(jsonString) as Map<String, dynamic>;

      // 验证缓存数据完整性
      final pagesJson = cacheData['pages'] as List<dynamic>?;
      if (pagesJson == null || pagesJson.isEmpty) return null;

      // 检查窗口大小是否匹配（如果窗口大小变化太大，缓存失效）
      final cachedWidth = (cacheData['windowWidth'] as num?)?.toDouble() ?? 0;
      final cachedHeight = (cacheData['windowHeight'] as num?)?.toDouble() ?? 0;
      final cachedFontSize = (cacheData['fontSize'] as num?)?.toDouble() ?? 16;

      if (_windowSize != null) {
        final widthDiff = (_windowSize!.width - cachedWidth).abs();
        final heightDiff = (_windowSize!.height - cachedHeight).abs();
        final fontSizeDiff = (_fontSize - cachedFontSize).abs();

        // 如果窗口大小变化超过10%或字体大小变化，认为缓存失效
        if (widthDiff / _windowSize!.width > 0.1 ||
            heightDiff / _windowSize!.height > 0.1 ||
            fontSizeDiff > 0.5) {
          print('缓存窗口大小不匹配，重新生成页面');
          return null;
        }
      }

      final pages = pagesJson
          .map((json) => PageContent.fromJson(json))
          .toList();
      print('从缓存加载了 ${pages.length} 页');
      return pages;
    } catch (e) {
      print('从缓存加载页面失败: $e');
      return null;
    }
  }

  /// 保存阅读位置到本地
  Future<void> _saveReadingPosition() async {
    if (_epubBook == null) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final bookKey = _getBookKey();

      // 保存阅读位置信息
      final positionData = {
        'bookPath': widget.bookPath,
        'bookTitle': _bookTitle,
        'chapterIndex': _currentChapterIndex,
        'pageIndex': _currentPageIndex,
        'scrollOffset': _scrollController.hasClients
            ? _scrollController.offset
            : 0.0,
        'readingMode': _readingMode.index,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      await prefs.setString(bookKey, positionData.toString());
      await prefs.setString(_lastReadBookKey, widget.bookPath);

      print('阅读位置已保存: 第 $_currentPageIndex 页, 章节 $_currentChapterIndex');
    } catch (e) {
      print('保存阅读位置失败: $e');
    }
  }

  /// 从本地加载阅读位置
  Future<Map<String, dynamic>?> _loadReadingPosition() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bookKey = _getBookKey();
      final positionStr = prefs.getString(bookKey);

      if (positionStr == null) return null;

      // 解析保存的位置数据
      final positionData = _parsePositionData(positionStr);
      return positionData;
    } catch (e) {
      print('加载阅读位置失败: $e');
      return null;
    }
  }

  /// 解析位置数据字符串
  Map<String, dynamic> _parsePositionData(String data) {
    final result = <String, dynamic>{};
    // 移除大括号并按逗号分割
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

  /// 延迟保存阅读位置（防抖）
  void _debounceSaveReadingPosition() {
    _savePositionTimer?.cancel();
    _savePositionTimer = Timer(_savePositionDebounceDuration, () {
      _saveReadingPosition();
    });
  }

  /// 加载保存的字体大小
  Future<void> _loadFontSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedFontSize = prefs.getDouble(_fontSizeKey);
      if (savedFontSize != null && savedFontSize >= 12 && savedFontSize <= 32) {
        setState(() {
          _fontSize = savedFontSize;
        });
        print('加载字体大小: $_fontSize');
      }
    } catch (e) {
      print('加载字体大小失败: $e');
    }
  }

  /// 保存字体大小
  Future<void> _saveFontSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_fontSizeKey, _fontSize);
      print('保存字体大小: $_fontSize');
    } catch (e) {
      print('保存字体大小失败: $e');
    }
  }

  /// 生成书签存储键
  String _getBookmarksKey() {
    return '$_bookmarksPrefix${widget.bookPath.hashCode}';
  }

  /// 保存书签到本地
  Future<void> _saveBookmarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getBookmarksKey();
      final bookmarksJson = _bookmarks.map((b) => jsonEncode({
        'chapterIndex': b.chapterIndex,
        'pageIndex': b.pageIndex,
        'title': b.title,
        'timestamp': b.timestamp.millisecondsSinceEpoch,
        'note': b.note,
        'colorIndex': b.colorIndex,
      })).toList();
      await prefs.setStringList(key, bookmarksJson);
      print('保存了 ${_bookmarks.length} 个书签');
    } catch (e) {
      print('保存书签失败: $e');
    }
  }

  /// 从本地加载书签
  Future<void> _loadBookmarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getBookmarksKey();
      final bookmarksJson = prefs.getStringList(key);
      if (bookmarksJson != null && bookmarksJson.isNotEmpty) {
        _bookmarks.clear();
        for (var json in bookmarksJson) {
          try {
            final data = jsonDecode(json) as Map<String, dynamic>;
            _bookmarks.add(Bookmark(
              chapterIndex: data['chapterIndex'] as int,
              pageIndex: data['pageIndex'] as int,
              title: data['title'] as String,
              timestamp: DateTime.fromMillisecondsSinceEpoch(data['timestamp'] as int),
              note: data['note'] as String?,
              colorIndex: data['colorIndex'] as int? ?? 0,
            ));
          } catch (e) {
            print('解析书签失败: $e');
          }
        }
        print('加载了 ${_bookmarks.length} 个书签');
      }
    } catch (e) {
      print('加载书签失败: $e');
    }
  }

  /// 恢复阅读位置
  void _restoreReadingPosition(Map<String, dynamic> position) {
    final savedPageIndex = (position['pageIndex'] as int?) ?? 0;
    final savedChapterIndex = (position['chapterIndex'] as int?) ?? 0;
    final savedScrollOffset = (position['scrollOffset'] as double?) ?? 0.0;
    final savedReadingMode =
        ReadingMode.values[(position['readingMode'] as int?) ?? 0];

    print('恢复阅读位置: 第 $savedPageIndex 页, 章节 $savedChapterIndex');

    // 恢复阅读模式
    if (_readingMode != savedReadingMode) {
      setState(() {
        _readingMode = savedReadingMode;
      });
    }

    // 延迟恢复位置，确保页面已渲染
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      if (_readingMode == ReadingMode.page) {
        // 分页模式：跳转到保存的页码
        if (savedPageIndex >= 0 && savedPageIndex < _pages.length) {
          _goToPage(savedPageIndex);
        }
      } else {
        // 滚动模式：恢复滚动位置
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(
            savedScrollOffset.clamp(
              0.0,
              _scrollController.position.maxScrollExtent,
            ),
          );
        }
      }

      // 显示恢复提示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已恢复到上次阅读位置'), duration: Duration(seconds: 2)),
      );
    });
  }

  void _onWindowResize() {
    final newSize = MediaQuery.of(context).size;
    if (_windowSize == null ||
        (newSize.width != _windowSize!.width ||
            newSize.height != _windowSize!.height)) {
      _windowSize = newSize;
      if (_epubBook != null && _chapters.isNotEmpty) {
        // 防抖处理：取消之前的定时器，避免频繁重绘
        _resizeDebounceTimer?.cancel();
        _resizeDebounceTimer = Timer(_resizeDebounceDuration, () {
          if (mounted) {
            _processPages();
          }
        });
      }
    }
  }

  Future<void> _loadBook() async {
    try {
      setState(() {
        _isLoading = true;
        _isContentLoaded = false;
        _hasError = false;
        _errorMessage = '';
      });

      // 加载保存的字体大小
      await _loadFontSize();

      // 生成缓存键
      _bookCacheKey = await _generateBookCacheKey();

      final file = File(widget.bookPath);
      final bytes = await file.readAsBytes();
      final epub = await EpubReader.readBook(bytes);

      setState(() {
        _bookTitle = epub.title ?? '未知书籍';
        _epubBook = epub;
        _chapters.addAll(_flattenChapters(epub.chapters));
      });

      await _loadCoverImage(epub);

      // 加载上次阅读位置
      final savedPosition = await _loadReadingPosition();

      // 加载书签
      await _loadBookmarks();

      // 获取窗口大小用于检查缓存有效性
      if (mounted) {
        _windowSize = MediaQuery.of(context).size;
      }

      // 尝试从缓存加载
      final cachedPages = await _loadPagesFromCache();

      if (cachedPages != null && cachedPages.isNotEmpty) {
        // 从缓存加载成功
        setState(() {
          _pages = cachedPages;
          _totalPages = cachedPages.length;
          _isLoading = false;
          _isContentLoaded = true;
          if (_totalPages > 0) {
            _currentPageIndex = 0;
            _currentChapterIndex = cachedPages[0].chapterIndex;
          }
        });

        // 恢复阅读位置
        if (savedPosition != null && mounted) {
          _restoreReadingPosition(savedPosition);
        }

        print('从缓存加载完成，共 $_totalPages 页');
        return;
      }

      // 没有缓存，需要处理页面
      setState(() {
        _isLoading = false;
      });

      // 使用微任务队列确保UI更新后再处理页面
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _processPagesAsync();

        // 页面处理完成后恢复阅读位置
        if (savedPosition != null && mounted) {
          _restoreReadingPosition(savedPosition);
        }
      });
    } catch (e) {
      setState(() {
        _bookTitle = '加载失败';
        _isLoading = false;
        _isContentLoaded = false;
        _hasError = true;
        _errorMessage = e.toString();
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载书籍失败: $e')));
      }
    }
  }

  Future<void> _processPagesAsync() async {
    if (_isProcessingPages || !mounted) return;

    setState(() {
      _isProcessingPages = true;
      _isContentLoaded = false;
      _processedChaptersCount = 0;
    });

    try {
      // 分步骤处理，避免阻塞UI
      await Future.delayed(const Duration(milliseconds: 50));

      // 获取窗口大小
      final BuildContext? contentContext = _contentKey.currentContext;
      final BuildContext useContext = contentContext ?? this.context;
      final size = MediaQuery.of(useContext).size;
      _windowSize = size;

      final availableHeight = size.height - 20;
      final availableWidth = size.width - 48;

      final pages = <PageContent>[];

      // 添加封面页
      if (_coverImage != null) {
        pages.add(
          PageContent(
            chapterIndex: -1,
            pageIndexInChapter: 0,
            contentItems: [CoverContent(imageData: _coverImage!)],
            title: '封面',
          ),
        );
      }

      // ===== 第一步：优先处理前几个章节，让用户可以立即开始阅读 =====
      final priorityCount = _chapters.length < _priorityChapterCount
          ? _chapters.length
          : _priorityChapterCount;

      print('开始优先处理前 $priorityCount 个章节...');

      for (int i = 0; i < priorityCount; i++) {
        final chapter = _chapters[i];
        final chapterPages = _splitChapterIntoPages(
          chapter,
          i,
          availableHeight,
          availableWidth,
        );
        pages.addAll(chapterPages);
        _processedChaptersCount++;

        // 每处理完一个章节，让出时间片给UI
        if (i < priorityCount - 1) {
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }

      // 优先章节处理完成，立即显示内容
      if (mounted) {
        setState(() {
          _pages = List.from(pages);
          _totalPages = pages.length;
          _isContentLoaded = true;
          _isProcessingPages = false;
          if (_totalPages > 0) {
            _currentPageIndex = 0;
            _currentChapterIndex = pages[0].chapterIndex;
          }
        });
        print('优先章节处理完成，已加载 $_totalPages 页，用户可以开始阅读');
      }

      // ===== 第二步：后台处理剩余章节 =====
      if (_chapters.length > priorityCount) {
        _isBackgroundProcessing = true;
        _processRemainingChaptersInBackground(
          pages,
          priorityCount,
          availableHeight,
          availableWidth,
        );
      } else {
        // 所有章节处理完成，保存缓存
        await _savePagesToCache();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessingPages = false;
          _hasError = true;
          _errorMessage = e.toString();
          _isContentLoaded = _pages.isNotEmpty;
        });

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('页面处理失败: $e')));
      }
    }
  }

  /// 后台处理剩余章节
  Future<void> _processRemainingChaptersInBackground(
    List<PageContent> existingPages,
    int startIndex,
    double availableHeight,
    double availableWidth,
  ) async {
    print('开始后台处理剩余 ${_chapters.length - startIndex} 个章节...');

    try {
      final pages = List<PageContent>.from(existingPages);
      final totalChapters = _chapters.length;

      for (int i = startIndex; i < totalChapters; i++) {
        if (!mounted) break;

        final chapter = _chapters[i];

        // 使用 Isolate 在后台处理单个章节
        final chapterPages = await _processChapterInIsolate(
          chapter,
          i,
          availableHeight,
          availableWidth,
        );

        pages.addAll(chapterPages);
        _processedChaptersCount++;

        // 每处理完几个章节，更新UI并保存进度
        if (i % 3 == 0 || i == totalChapters - 1) {
          if (mounted) {
            setState(() {
              _pages = List.from(pages);
              _totalPages = pages.length;
            });
          }
          print('后台处理进度: $_processedChaptersCount/$totalChapters 章节');
        }

        // 让出时间片，避免阻塞UI
        await Future.delayed(const Duration(milliseconds: 5));
      }

      // 所有章节处理完成
      _isBackgroundProcessing = false;

      if (mounted) {
        setState(() {
          _pages = pages;
          _totalPages = pages.length;
        });
        print('所有章节处理完成，共 $_totalPages 页');

        // 显示完成提示
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('书籍加载完成，共 $_totalPages 页'),
            duration: Duration(seconds: 2),
          ),
        );
      }

      // 保存到缓存
      await _savePagesToCache();
    } catch (e) {
      print('后台处理章节失败: $e');
      _isBackgroundProcessing = false;
    }
  }

  /// 在 Isolate 中处理单个章节
  Future<List<PageContent>> _processChapterInIsolate(
    EpubChapter chapter,
    int chapterIndex,
    double availableHeight,
    double availableWidth,
  ) async {
    // 由于 TextPainter 依赖于 Flutter 的渲染层，不能在 Isolate 中使用
    // 这里使用微任务来模拟后台处理
    return await Future.microtask(() {
      return _splitChapterIntoPages(
        chapter,
        chapterIndex,
        availableHeight,
        availableWidth,
      );
    });
  }

  Future<void> _loadCoverImage(EpubBook epub) async {
    try {
      if (epub.coverImage != null) {
        final bytes = Uint8List.fromList(img.encodePng(epub.coverImage!));
        setState(() {
          _coverImage = bytes;
        });
      }
    } catch (e) {
      print('加载封面图片失败: $e');
    }
  }

  /// 重新处理所有页面（用于窗口大小变化等情况）
  Future<void> _processPages() async {
    final BuildContext? contentContext = _contentKey.currentContext;
    final BuildContext useContext = contentContext ?? this.context;
    final size = MediaQuery.of(useContext).size;
    _windowSize = size;

    final availableHeight = size.height - 20;
    final availableWidth = size.width - 48;

    final pages = <PageContent>[];

    if (_coverImage != null) {
      pages.add(
        PageContent(
          chapterIndex: -1,
          pageIndexInChapter: 0,
          contentItems: [CoverContent(imageData: _coverImage!)],
          title: '封面',
        ),
      );
    }

    // 重新处理所有章节
    for (int i = 0; i < _chapters.length; i++) {
      final chapter = _chapters[i];
      final chapterPages = _splitChapterIntoPages(
        chapter,
        i,
        availableHeight,
        availableWidth,
      );
      pages.addAll(chapterPages);

      // 每处理几个章节让出时间片
      if (i % 5 == 0) {
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }

    setState(() {
      _pages = pages;
      _totalPages = pages.length;
      if (_totalPages > 0) {
        _currentPageIndex = _currentPageIndex.clamp(0, _totalPages - 1);
        _currentChapterIndex = _pages[_currentPageIndex].chapterIndex;
      }
    });

    // 窗口大小变化后，清除旧缓存，保存新布局
    await _savePagesToCache();
  }

  /// 使用 TextPainter 计算文本在指定宽度下的实际行数
  int _calculateTextLines(String text, double maxWidth, TextStyle style) {
    _textPainterCache ??= TextPainter(textDirection: TextDirection.ltr);

    _textPainterCache!.text = TextSpan(text: text, style: style);
    _textPainterCache!.layout(maxWidth: maxWidth);

    final lineMetrics = _textPainterCache!.computeLineMetrics();
    return lineMetrics.length;
  }

  /// 使用 TextPainter 计算文本在指定宽度下能容纳的最大字符数
  int _calculateFitChars(
    String text,
    double maxWidth,
    int maxLines,
    TextStyle style,
  ) {
    if (text.isEmpty) return 0;

    _textPainterCache ??= TextPainter(textDirection: TextDirection.ltr);

    // 二分查找找到最合适的字符数
    int left = 0;
    int right = text.length;
    int bestFit = 0;

    while (left <= right) {
      final mid = (left + right) ~/ 2;
      final substring = text.substring(0, mid);

      _textPainterCache!.text = TextSpan(text: substring, style: style);
      _textPainterCache!.layout(maxWidth: maxWidth);

      final lineMetrics = _textPainterCache!.computeLineMetrics();

      if (lineMetrics.length <= maxLines) {
        bestFit = mid;
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }

    return bestFit;
  }

  List<PageContent> _splitChapterIntoPages(
    EpubChapter chapter,
    int chapterIndex,
    double availableHeight,
    double availableWidth,
  ) {
    final pages = <PageContent>[];
    final htmlContent = chapter.htmlContent ?? '';

    final contentItems = _parseHtmlContent(htmlContent);

    if (contentItems.isEmpty) {
      return pages;
    }

    // 使用 TextPainter 精确计算行高
    final textStyle = TextStyle(
      fontSize: _fontSize,
      height: 1.5,
      color: Colors.black87,
    );

    // 计算实际行高
    _textPainterCache ??= TextPainter(textDirection: TextDirection.ltr);
    _textPainterCache!.text = TextSpan(text: '中', style: textStyle);
    _textPainterCache!.layout();
    final lineHeight = _textPainterCache!.height;

    // 每页可用高度（减去 padding）
    final usableHeight = availableHeight - 96;

    List<ContentItem> currentPageItems = [];
    double currentPageHeight = 0;
    int chapterLocalPageIndex = 0;

    void flushCurrentPage() {
      if (currentPageItems.isNotEmpty) {
        pages.add(
          PageContent(
            chapterIndex: chapterIndex,
            pageIndexInChapter: chapterLocalPageIndex,
            contentItems: List.from(currentPageItems),
            title: chapter.title,
          ),
        );
        chapterLocalPageIndex++;
        currentPageItems = [];
        currentPageHeight = 0;
      }
    }

    for (final item in contentItems) {
      if (item is TextContent) {
        String remaining = item.text.trim();
        while (remaining.isNotEmpty) {
          final remainingHeight = usableHeight - currentPageHeight;
          final remainingLines = (remainingHeight / lineHeight).floor();

          if (remainingLines <= 0) {
            flushCurrentPage();
            continue;
          }

          // 使用 TextPainter 精确计算能容纳的字符数
          final fitChars = _calculateFitChars(
            remaining,
            availableWidth,
            remainingLines,
            textStyle,
          );

          if (fitChars >= remaining.length) {
            // 剩余内容可以全部放入当前页
            currentPageItems.add(TextContent(text: remaining));
            final actualLines = _calculateTextLines(
              remaining,
              availableWidth,
              textStyle,
            );
            currentPageHeight += actualLines * lineHeight;
            remaining = '';
          } else {
            // 需要分割文本
            // 尝试在单词边界处截断
            int cut = fitChars;
            if (cut > 0) {
              final sub = remaining.substring(0, cut);
              final lastSpace = sub.lastIndexOf(' ');
              if (lastSpace > (cut * 0.6).floor()) {
                cut = lastSpace;
              }
            }

            // 确保至少截取一个字符
            cut = cut.clamp(1, remaining.length);

            String part = remaining.substring(0, cut).trimRight();
            if (part.isEmpty) {
              part = remaining.substring(0, cut);
            }

            currentPageItems.add(TextContent(text: part));
            final partLines = _calculateTextLines(
              part,
              availableWidth,
              textStyle,
            );
            currentPageHeight += partLines * lineHeight;
            remaining = remaining.substring(cut).trimLeft();

            // current page is full now
            flushCurrentPage();
          }
        }
      } else if (item is ImageContent) {
        // 图片高度估算（基于可用高度的 40%），额外增加 4 行空间作为边距
        final extraLines = 4;
        final extraHeight = extraLines * lineHeight;
        final imageHeight = usableHeight * 0.4 + extraHeight;
        if (currentPageItems.isNotEmpty &&
            currentPageHeight + imageHeight > usableHeight) {
          flushCurrentPage();
        }
        currentPageItems.add(item);
        currentPageHeight += imageHeight;

        // If image itself larger than one page, place it on its own page
        if (imageHeight >= usableHeight) {
          flushCurrentPage();
        }
      } else if (item is CoverContent) {
        // cover always occupies a full page
        if (currentPageItems.isNotEmpty) {
          flushCurrentPage();
        }
        currentPageItems.add(item);
        currentPageHeight = usableHeight;
        flushCurrentPage();
      }
    }

    if (currentPageItems.isNotEmpty) {
      flushCurrentPage();
    }

    return pages;
  }

  List<ContentItem> _parseHtmlContent(String html) {
    final List<ContentItem> items = <ContentItem>[];

    String cleanedHtml = html.replaceAll(RegExp(r'\s+'), ' ').trim();

    const String imgTag = '<img';
    const String srcAttr = 'src=';

    int currentIndex = 0;
    while (currentIndex < cleanedHtml.length) {
      int imgStart = cleanedHtml.indexOf(imgTag, currentIndex);
      if (imgStart == -1) {
        String remainingText = cleanedHtml.substring(currentIndex);
        String cleanText = _stripHtmlTags(remainingText);
        if (cleanText.trim().isNotEmpty) {
          items.add(TextContent(text: cleanText));
        }
        break;
      }

      if (imgStart > currentIndex) {
        String textBeforeImg = cleanedHtml.substring(currentIndex, imgStart);
        String cleanText = _stripHtmlTags(textBeforeImg);
        if (cleanText.trim().isNotEmpty) {
          items.add(TextContent(text: cleanText));
        }
      }

      int srcStart = cleanedHtml.indexOf(srcAttr, imgStart);
      if (srcStart != -1) {
        int srcValueStart = srcStart + srcAttr.length;
        while (srcValueStart < cleanedHtml.length &&
            (cleanedHtml[srcValueStart] == ' ' ||
                cleanedHtml[srcValueStart] == '=')) {
          srcValueStart++;
        }

        String quote = '';
        if (srcValueStart < cleanedHtml.length) {
          if (cleanedHtml[srcValueStart] == '"' ||
              cleanedHtml[srcValueStart] == "'") {
            quote = cleanedHtml[srcValueStart];
            srcValueStart++;
          }
        }

        int srcValueEnd = srcValueStart;
        while (srcValueEnd < cleanedHtml.length) {
          if (quote.isNotEmpty) {
            if (cleanedHtml[srcValueEnd] == quote) {
              break;
            }
          } else {
            if (cleanedHtml[srcValueEnd] == ' ' ||
                cleanedHtml[srcValueEnd] == '>' ||
                cleanedHtml[srcValueEnd] == '/') {
              break;
            }
          }
          srcValueEnd++;
        }

        if (srcValueEnd > srcValueStart) {
          String srcValue = cleanedHtml.substring(srcValueStart, srcValueEnd);
          if (srcValue.isNotEmpty) {
            items.add(ImageContent(source: srcValue));
          }
        }

        int imgEnd = cleanedHtml.indexOf('>', imgStart);
        currentIndex = imgEnd != -1 ? imgEnd + 1 : imgStart + 1;
      } else {
        int imgEnd = cleanedHtml.indexOf('>', imgStart);
        currentIndex = imgEnd != -1 ? imgEnd + 1 : imgStart + 1;
      }
    }

    return items;
  }

  List<EpubChapter> _flattenChapters(List<EpubChapter> chapters) {
    final result = <EpubChapter>[];
    for (var chapter in chapters) {
      if (chapter.htmlContent != null && chapter.htmlContent!.isNotEmpty) {
        result.add(chapter);
      }
      if (chapter.subChapters.isNotEmpty) {
        result.addAll(_flattenChapters(chapter.subChapters));
      }
    }
    return result;
  }

  String _stripHtmlTags(String html) {
    String result = html
        .replaceAll(RegExp('<br\\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp('<p[^>]*>', caseSensitive: false), '\n')
        .replaceAll(RegExp('</p>', caseSensitive: false), '\n')
        .replaceAll(RegExp('<div[^>]*>', caseSensitive: false), '\n')
        .replaceAll(RegExp('</div>', caseSensitive: false), '\n')
        .replaceAll(
          RegExp(
            '<h[1-6][^>]*>.*?</h[1-6]>',
            caseSensitive: false,
            multiLine: true,
            dotAll: true,
          ),
          '\n',
        )
        .replaceAll(RegExp('<[^>]*>', multiLine: true, dotAll: true), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp('[ \\t]+'), ' ')
        .trim();

    result = result.replaceAll(RegExp('\n+'), '\n');
    return result.trim();
  }

  Future<Uint8List?> _getImageData(String imagePath) async {
    try {
      if (_epubBook == null) {
        print('EPUB书籍未加载');
        return null;
      }

      String normalizedPath = imagePath;
      if (normalizedPath.startsWith('./')) {
        normalizedPath = normalizedPath.substring(2);
      }
      if (normalizedPath.startsWith('../')) {
        normalizedPath = normalizedPath.substring(3);
      }

      if (_epubBook!.content != null && _epubBook!.content!.images.isNotEmpty) {
        if (_epubBook!.content!.images.containsKey(normalizedPath)) {
          final imageFile = _epubBook!.content!.images[normalizedPath];
          if (imageFile != null && imageFile.content != null) {
            return Uint8List.fromList(imageFile.content!);
          }
        }

        for (var entry in _epubBook!.content!.images.entries) {
          final key = entry.key;
          if (key == imagePath ||
              key.endsWith(imagePath) ||
              imagePath.endsWith(key) ||
              key.endsWith(normalizedPath)) {
            final imageFile = entry.value;
            if (imageFile.content != null) {
              return Uint8List.fromList(imageFile.content!);
            }
          }
        }
      }

      print('未找到图片: $imagePath');
      return null;
    } catch (e) {
      print('加载图片失败 ($imagePath): $e');
      return null;
    }
  }

  Widget _buildPageContent(PageContent page, double availableHeight) {
    // availableHeight 已剔除顶部/底部控制区的高度，确保页面内容不超高
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: page.contentItems.map((item) {
            if (item is TextContent) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  item.text,
                  style: TextStyle(
                    fontSize: _fontSize,
                    height: 1.5,
                    color: Colors.black87,
                  ),
                ),
              );
            } else if (item is ImageContent) {
              return FutureBuilder<Uint8List?>(
                future: _getImageData(item.source),
                builder: (context, snapshot) {
                  final maxHeight = availableHeight * 0.5;

                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return Container(
                      height: maxHeight,
                      alignment: Alignment.center,
                      child: const CircularProgressIndicator(),
                    );
                  }

                  if (snapshot.hasData && snapshot.data != null) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: constraints.maxWidth,
                              maxHeight: maxHeight,
                            ),
                            child: material.Image.memory(
                              snapshot.data!,
                              fit: BoxFit.contain,
                              width: double.infinity,
                              errorBuilder: (context, error, stackTrace) {
                                return Container(
                                  height: maxHeight,
                                  color: Colors.grey[200],
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.broken_image,
                                        size: 48,
                                        color: Colors.grey[400],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        '图片加载失败',
                                        style: TextStyle(
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
                    );
                  } else {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        height: maxHeight,
                        color: Colors.grey[200],
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.image_not_supported,
                              size: 48,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '图片: ${item.source}',
                              style: TextStyle(color: Colors.grey[600]),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                },
              );
            } else if (item is CoverContent) {
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _bookTitle,
                      style: TextStyle(
                        fontSize: _fontSize * 2,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: (MediaQuery.of(context).size.width * 0.7)
                              .clamp(200.0, 500.0),
                          maxHeight: (availableHeight * 0.7).clamp(
                            300.0,
                            700.0,
                          ),
                        ),
                        child: material.Image.memory(
                          item.imageData,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) {
                            final coverWidth =
                                (MediaQuery.of(context).size.width * 0.7).clamp(
                                  200.0,
                                  500.0,
                                );
                            final coverHeight = (availableHeight * 0.7).clamp(
                              300.0,
                              700.0,
                            );
                            return Container(
                              width: coverWidth,
                              height: coverHeight,
                              color: Colors.grey[200],
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.broken_image,
                                    size: 48,
                                    color: Colors.grey[400],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '封面加载失败',
                                    style: TextStyle(color: Colors.grey[600]),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }
            return const SizedBox.shrink();
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildScrollContent() {
    return SingleChildScrollView(
      // 添加滚动支持
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _pages.map((page) {
          final contentWidgets = page.contentItems.map((item) {
            if (item is TextContent) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  item.text,
                  style: TextStyle(
                    fontSize: _fontSize,
                    height: 1.6,
                    color: Colors.black87,
                  ),
                ),
              );
            } else if (item is ImageContent) {
              return FutureBuilder<Uint8List?>(
                future: _getImageData(item.source),
                builder: (context, snapshot) {
                  final screenSize = MediaQuery.of(context).size;
                  final maxHeight = screenSize.height * 0.5;

                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return Container(
                      height: maxHeight,
                      alignment: Alignment.center,
                      child: const CircularProgressIndicator(),
                    );
                  }

                  if (snapshot.hasData && snapshot.data != null) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: constraints.maxWidth,
                              maxHeight: maxHeight,
                            ),
                            child: material.Image.memory(
                              snapshot.data!,
                              fit: BoxFit.contain,
                              width: double.infinity,
                              errorBuilder: (context, error, stackTrace) {
                                return Container(
                                  height: maxHeight,
                                  color: Colors.grey[200],
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.broken_image,
                                        size: 48,
                                        color: Colors.grey[400],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        '图片加载失败',
                                        style: TextStyle(
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
                    );
                  } else {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Container(
                        height: maxHeight,
                        color: Colors.grey[200],
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.image_not_supported,
                              size: 48,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '图片: ${item.source}',
                              style: TextStyle(color: Colors.grey[600]),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                },
              );
            } else if (item is CoverContent) {
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    Text(
                      _bookTitle,
                      style: TextStyle(
                        fontSize: _fontSize * 2,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final screenSize = MediaQuery.of(context).size;
                        final availableHeight = screenSize.height - 200;
                        final coverWidth = (screenSize.width * 0.7).clamp(
                          200.0,
                          500.0,
                        );
                        final coverHeight = (availableHeight * 0.7).clamp(
                          300.0,
                          700.0,
                        );

                        return ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: coverWidth,
                              maxHeight: coverHeight,
                            ),
                            child: material.Image.memory(
                              item.imageData,
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) {
                                return Container(
                                  width: coverWidth,
                                  height: coverHeight,
                                  color: Colors.grey[200],
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.broken_image,
                                        size: 48,
                                        color: Colors.grey[400],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        '封面加载失败',
                                        style: TextStyle(
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              );
            }
            return const SizedBox.shrink();
          }).toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [...contentWidgets],
          );
        }).toList(),
      ),
    );
  }

  void _toggleReadingMode() {
    setState(() {
      _readingMode = _readingMode == ReadingMode.scroll
          ? ReadingMode.page
          : ReadingMode.scroll;
    });
  }

  Widget _buildScrollMode() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onTapUp: (details) {
            final screenHeight = MediaQuery.of(context).size.height;
            final tapY = details.globalPosition.dy;
            // 点击中间区域切换控制栏显示
            if (tapY > screenHeight * 0.2 && tapY < screenHeight * 0.8) {
              setState(() {
                _showControls = !_showControls;
              });
            }
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              // 滚动结束时保存阅读位置
              if (notification is ScrollEndNotification) {
                _debounceSaveReadingPosition();
              }
              return false;
            },
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.all(24.0),
              child: _buildScrollContent(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPageMode() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 检测窗口大小变化并触发重计算
        final newSize = Size(constraints.maxWidth, constraints.maxHeight);
        if (_windowSize == null ||
            (_windowSize!.width != newSize.width ||
                _windowSize!.height != newSize.height)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _onWindowResize();
          });
        }

        return Focus(
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                  event.logicalKey == LogicalKeyboardKey.pageUp) {
                _previousPage();
                return KeyEventResult.handled;
              } else if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
                  event.logicalKey == LogicalKeyboardKey.pageDown) {
                _nextPage();
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
          },
          child: Stack(
            children: [
              GestureDetector(
                onTapUp: (details) {
                  final screenWidth = MediaQuery.of(context).size.width;
                  final screenHeight = MediaQuery.of(context).size.height;
                  final tapX = details.globalPosition.dx;
                  final tapY = details.globalPosition.dy;

                  // 点击左右区域翻页
                  if (tapX < screenWidth * 0.2) {
                    _previousPage();
                  } else if (tapX > screenWidth * 0.8) {
                    _nextPage();
                  } else if (tapY > screenHeight * 0.2 &&
                      tapY < screenHeight * 0.8) {
                    // 点击中间区域切换控制栏显示
                    setState(() {
                      _showControls = !_showControls;
                    });
                  }
                },
                child: Container(
                  key: _contentKey,
                  width: double.infinity,
                  height: double.infinity,
                  color: Colors.white,
                  child: Column(
                    children: [
                      Expanded(
                        child: _pages.isNotEmpty
                            ? _buildPageContent(
                                _pages[_currentPageIndex],
                                // 预留顶部/底部工具栏高度，保证分页计算一致
                                constraints.maxHeight - 120,
                              )
                            : const Center(child: Text('暂无内容')),
                      ),
                      AnimatedOpacity(
                        opacity: _showControls ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 6,
                            horizontal: 24,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  // 书签列表
                                  if (_bookmarks.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 12),
                                      child: Row(
                                        children: _bookmarks.map((bookmark) {
                                          return Padding(
                                            padding: const EdgeInsets.only(right: 4),
                                            child: InkWell(
                                              onTap: () => _onBookmarkTap(bookmark),
                                              child: Icon(
                                                Icons.bookmark,
                                                color: bookmark.color,
                                                size: 20,
                                              ),
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                    ),
                                  Text(
                                    '第 ${_currentPageIndex + 1} 页 / 共 $_totalPages 页',
                                    style: TextStyle(
                                      color: Colors.grey[600],
                                      fontSize: 14,
                                    ),
                                  ),
                                  if (_isBackgroundProcessing)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 8),
                                      child: SizedBox(
                                        width: 12,
                                        height: 12,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                Colors.blue,
                                              ),
                                        ),
                                      ),
                                    ),
                                  if (_pages.isNotEmpty &&
                                      _pages[_currentPageIndex].title != null &&
                                      _pages[_currentPageIndex].chapterIndex >=
                                          0)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 16),
                                      child: Text(
                                        _pages[_currentPageIndex].title!,
                                        style: TextStyle(
                                          color: Colors.grey[600],
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              Text(
                                '${((_currentPageIndex + 1) / _totalPages * 100).toStringAsFixed(1)}%',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_showTableOfContents) _buildTableOfContents(),
            ],
          ),
        );
      },
    );
  }

  void _goToPage(int pageIndex) {
    if (pageIndex >= 0 && pageIndex < _pages.length) {
      setState(() {
        _currentPageIndex = pageIndex;
        _currentChapterIndex = _pages[pageIndex].chapterIndex;
        _showTableOfContents = false;
      });

      // 保存阅读位置
      _debounceSaveReadingPosition();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        // 仅当 ScrollController 已附着到 ScrollView 时才调用 jumpTo，
        // 避免在分页模式下（未使用滚动视图）抛出异常。
        if (_scrollController.hasClients) {
          try {
            _scrollController.jumpTo(0);
          } catch (_) {
            // 忽略可能的异常，防止影响阅读器主流程
          }
        }
      });
    }
  }

  void _goToChapter(int chapterIndex) {
    for (int i = 0; i < _pages.length; i++) {
      if (_pages[i].chapterIndex == chapterIndex) {
        _goToPage(i);
        break;
      }
    }
  }

  void _previousPage() {
    if (_currentPageIndex > 0) {
      _goToPage(_currentPageIndex - 1);
    }
  }

  void _nextPage() {
    if (_currentPageIndex < _pages.length - 1) {
      _goToPage(_currentPageIndex + 1);
    }
  }

  void _addBookmark() {
    final exists = _bookmarks.any((b) => b.pageIndex == _currentPageIndex);
    if (exists) {
      setState(() {
        _bookmarks.removeWhere((b) => b.pageIndex == _currentPageIndex);
      });
      _saveBookmarks();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('书签已移除')));
    } else {
      final currentPage = _pages.isNotEmpty ? _pages[_currentPageIndex] : null;
      setState(() {
        _bookmarks.add(
          Bookmark(
            chapterIndex: _currentChapterIndex,
            pageIndex: _currentPageIndex,
            title: currentPage?.title ?? '第 ${_currentPageIndex + 1} 页',
            timestamp: DateTime.now(),
          ),
        );
      });
      _saveBookmarks();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('书签已添加')));
    }
  }

  void _saveNote() {
    if (_noteController.text.trim().isNotEmpty) {
      final currentPage = _pages.isNotEmpty ? _pages[_currentPageIndex] : null;
      setState(() {
        _bookmarks.add(
          Bookmark(
            chapterIndex: _currentChapterIndex,
            pageIndex: _currentPageIndex,
            title: currentPage?.title ?? '第 ${_currentPageIndex + 1} 页',
            timestamp: DateTime.now(),
            note: _noteController.text.trim(),
          ),
        );
      });
      _noteController.clear();
      Navigator.pop(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('笔记已保存')));
    }
  }

  /// 清除当前书籍的缓存
  Future<void> _clearBookCache() async {
    try {
      if (_bookCacheKey == null) return;
      final cacheFilePath = await _getCacheFilePath();
      final cacheFile = File(cacheFilePath);
      if (await cacheFile.exists()) {
        await cacheFile.delete();
        print('字体变化，已清除旧缓存');
      }
    } catch (e) {
      print('清除缓存失败: $e');
    }
  }

  /// 重新分页后恢复阅读位置
  void _restorePositionAfterReflow(
    int previousPageIndex,
    int previousChapterIndex,
  ) {
    // 首先尝试找到相同章节的页面
    int targetPageIndex = -1;

    for (int i = 0; i < _pages.length; i++) {
      if (_pages[i].chapterIndex == previousChapterIndex) {
        targetPageIndex = i;
        break;
      }
    }

    // 如果找不到相同章节，尝试按百分比定位
    if (targetPageIndex == -1 && _totalPages > 0) {
      final progress = previousPageIndex / (_totalPages > 0 ? _totalPages : 1);
      targetPageIndex = (progress * _pages.length).round().clamp(
        0,
        _pages.length - 1,
      );
    }

    if (targetPageIndex >= 0 && targetPageIndex < _pages.length) {
      setState(() {
        _currentPageIndex = targetPageIndex;
        _currentChapterIndex = _pages[targetPageIndex].chapterIndex;
      });

      // 滚动到顶部
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
    }
  }

  /// 应用字体大小变更
  void _applyFontSizeChange() async {
    if (_tempFontSize == _fontSize) {
      setState(() {
        _showFontSizeSlider = false;
      });
      return;
    }

    // 立即关闭滑动条并显示处理中提示
    setState(() {
      _showFontSizeSlider = false;
      _fontSize = _tempFontSize;
      _isProcessingPages = true;
    });

    // 保存当前位置用于重新分页后恢复
    final previousPageIndex = _currentPageIndex;
    final previousChapterIndex = _currentChapterIndex;

    // 保存字体大小设置
    await _saveFontSize();

    // 清除旧缓存
    await _clearBookCache();

    // 重新计算分页
    if (_chapters.isNotEmpty) {
      await _processPages();

      // 恢复阅读位置
      if (mounted) {
        _restorePositionAfterReflow(previousPageIndex, previousChapterIndex);
      }
    }

    if (mounted) {
      setState(() {
        _isProcessingPages = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('字体大小: ${_fontSize.toInt()}'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  /// 构建字体大小滑动条
  Widget _buildFontSizeSlider() {
    return Positioned(
      top: 80,
      right: 16,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        color: Colors.white,
        child: Container(
          width: 60,
          height: 280,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Column(
            children: [
              // 字体大小显示
              Text(
                _tempFontSize.toInt().toString(),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue,
                ),
              ),
              const SizedBox(height: 8),
              // A+ 图标
              Icon(Icons.text_increase, size: 16, color: Colors.grey[600]),
              const SizedBox(height: 8),
              // 垂直滑动条
              Expanded(
                child: RotatedBox(
                  quarterTurns: 3, // 旋转为垂直方向
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: Colors.blue,
                      inactiveTrackColor: Colors.grey[300],
                      thumbColor: Colors.blue,
                      overlayColor: Colors.blue.withValues(alpha: 0.2),
                      trackHeight: 4,
                      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 8),
                      overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
                    ),
                    child: Slider(
                      value: _tempFontSize,
                      min: 12,
                      max: 32,
                      divisions: 20, // 每1一个刻度
                      onChanged: (value) {
                        setState(() {
                          _tempFontSize = value;
                        });
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // A- 图标
              Icon(Icons.text_decrease, size: 16, color: Colors.grey[600]),
              const SizedBox(height: 8),
              // 确认按钮
              InkWell(
                onTap: _applyFontSizeChange,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    // 与当前字体一致时蓝色，不一致时灰色
                    color: _tempFontSize == _fontSize
                        ? Colors.blue
                        : Colors.grey[400],
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.check, color: Colors.white, size: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isBookmarked() {
    return _bookmarks.any((b) => b.pageIndex == _currentPageIndex);
  }

  /// 处理书签点击
  void _onBookmarkTap(Bookmark bookmark) {
    // 如果当前已经在该书签位置，切换颜色
    if (_currentPageIndex == bookmark.pageIndex) {
      setState(() {
        bookmark.colorIndex = (bookmark.colorIndex + 1) % BookmarkColors.colors.length;
      });
      _saveBookmarks(); // 保存颜色更改
    } else {
      // 跳转到书签位置
      _goToPage(bookmark.pageIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _showControls
          ? AppBar(
              title: Text(_bookTitle.isEmpty ? '阅读' : _bookTitle),
              actions: [
                IconButton(
                  icon: Icon(
                    _readingMode == ReadingMode.scroll
                        ? Icons.view_stream
                        : Icons.view_carousel,
                    color: Colors.blue,
                  ),
                  onPressed: _toggleReadingMode,
                  tooltip: _readingMode == ReadingMode.scroll
                      ? '切换到分页模式'
                      : '切换到滚动模式',
                ),
                IconButton(
                  icon: Icon(
                    _isBookmarked() ? Icons.bookmark : Icons.bookmark_border,
                    color: _isBookmarked() ? Colors.blue : null,
                  ),
                  onPressed: _addBookmark,
                  tooltip: '书签',
                ),
                IconButton(
                  icon: const Icon(Icons.format_size),
                  onPressed: () {
                    setState(() {
                      _showFontSizeSlider = !_showFontSizeSlider;
                      _tempFontSize = _fontSize;
                    });
                  },
                  tooltip: '字体大小',
                ),
                IconButton(
                  icon: Icon(
                    Icons.list,
                    color: _showTableOfContents ? Colors.blue : null,
                  ),
                  onPressed: () {
                    setState(() {
                      _showTableOfContents = !_showTableOfContents;
                    });
                  },
                  tooltip: '目录',
                ),
                IconButton(
                  icon: const Icon(Icons.edit_note),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text('添加笔记 - 第 ${_currentPageIndex + 1} 页'),
                        content: TextField(
                          controller: _noteController,
                          maxLines: 5,
                          decoration: const InputDecoration(
                            hintText: '输入笔记内容...',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: _saveNote,
                            child: const Text('保存'),
                          ),
                        ],
                      ),
                    );
                  },
                  tooltip: '添加笔记',
                ),
              ],
            )
          : null,
      body: Builder(
        builder: (context) {
          if (_isLoading) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在加载书籍...'),
                ],
              ),
            );
          }

          if (_hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error, size: 64, color: Colors.red),
                  SizedBox(height: 16),
                  Text('加载失败: $_errorMessage'),
                  SizedBox(height: 16),
                  ElevatedButton(onPressed: _loadBook, child: Text('重新加载')),
                ],
              ),
            );
          }

          if (_isProcessingPages && !_isContentLoaded) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在处理页面内容...'),
                  Text('优先加载前 $_priorityChapterCount 个章节，请稍候'),
                  if (_chapters.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '共 ${_chapters.length} 个章节',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ),
                ],
              ),
            );
          }

          if (!_isContentLoaded || _pages.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.menu_book, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('暂无内容'),
                ],
              ),
            );
          }

          // 内容已准备就绪
          return Stack(
            children: [
              GestureDetector(
                onTap: () {
                  if (_showFontSizeSlider) {
                    _applyFontSizeChange();
                  }
                },
                child: Container(
                  width: double.infinity,
                  height: double.infinity,
                  color: Colors.white,
                  child: _readingMode == ReadingMode.scroll
                      ? _buildScrollMode()
                      : _buildPageMode(),
                ),
              ),
              if (_showTableOfContents && _readingMode == ReadingMode.page)
                _buildTableOfContents(),
              if (_showFontSizeSlider) _buildFontSizeSlider(),
              // 处理中提示（字体变化时显示在页面底部）
              if (_isProcessingPages && _isContentLoaded)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 60,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '处理中...',
                            style: TextStyle(color: Colors.white, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTableOfContents() {
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: Container(
        width: 280,
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 8,
              offset: const Offset(2, 0),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                border: Border(bottom: BorderSide(color: Colors.grey[300]!)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '目录',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    color: Colors.grey[600],
                    onPressed: () {
                      setState(() {
                        _showTableOfContents = false;
                      });
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _chapters.length,
                itemBuilder: (context, index) {
                  final chapter = _chapters[index];
                  final isCurrentChapter = index == _currentChapterIndex;
                  final isBookmarked = _bookmarks.any(
                    (b) => b.chapterIndex == index,
                  );

                  return ListTile(
                    leading: CircleAvatar(
                      radius: 14,
                      backgroundColor: isCurrentChapter
                          ? Colors.blue
                          : Colors.grey[300],
                      child: isBookmarked
                          ? const Icon(
                              Icons.bookmark,
                              size: 14,
                              color: Colors.white,
                            )
                          : Text(
                              '${index + 1}',
                              style: TextStyle(
                                color: isCurrentChapter
                                    ? Colors.white
                                    : Colors.grey[700],
                                fontSize: 12,
                              ),
                            ),
                    ),
                    title: Text(
                      chapter.title ?? '第 ${index + 1} 章',
                      style: TextStyle(
                        color: isCurrentChapter ? Colors.blue : Colors.black87,
                        fontWeight: isCurrentChapter
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      _goToChapter(index);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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

class CoverContent extends ContentItem {
  final Uint8List imageData;

  CoverContent({required this.imageData});

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'cover', 'imageData': base64Encode(imageData)};
  }

  factory CoverContent.fromJson(Map<String, dynamic> json) {
    return CoverContent(imageData: base64Decode(json['imageData'] as String));
  }
}

class PageContent {
  final int chapterIndex;
  final int pageIndexInChapter;
  final List<ContentItem> contentItems;
  final String? title;

  PageContent({
    required this.chapterIndex,
    required this.pageIndexInChapter,
    required this.contentItems,
    this.title,
  });

  Map<String, dynamic> toJson() {
    return {
      'chapterIndex': chapterIndex,
      'pageIndexInChapter': pageIndexInChapter,
      'contentItems': contentItems.map((item) => item.toJson()).toList(),
      'title': title,
    };
  }

  factory PageContent.fromJson(Map<String, dynamic> json) {
    return PageContent(
      chapterIndex: json['chapterIndex'] as int,
      pageIndexInChapter: json['pageIndexInChapter'] as int,
      contentItems: (json['contentItems'] as List<dynamic>)
          .map((item) => ContentItem.fromJson(item as Map<String, dynamic>))
          .toList(),
      title: json['title'] as String?,
    );
  }
}

enum ReadingMode { scroll, page }

class Bookmark {
  final int chapterIndex;
  final int pageIndex;
  final String title;
  final DateTime timestamp;
  final String? note;
  int colorIndex; // 0-4 对应5种颜色

  Bookmark({
    required this.chapterIndex,
    required this.pageIndex,
    required this.title,
    required this.timestamp,
    this.note,
    this.colorIndex = 0,
  });

  // 获取书签颜色
  Color get color => BookmarkColors.colors[colorIndex % BookmarkColors.colors.length];
}

// 书签颜色配置 - 5种显眼颜色
class BookmarkColors {
  static const List<Color> colors = [
    Color(0xFFFF0000), // 红色
    Color(0xFFFFA500), // 橙色
    Color(0xFFFFFF00), // 黄色
    Color(0xFF00FF00), // 绿色
    Color(0xFF0000FF), // 蓝色
  ];
}

class Highlight {
  final int chapterIndex;
  final int pageIndex;
  final String text;
  final Color color;

  Highlight({
    required this.chapterIndex,
    required this.pageIndex,
    required this.text,
    required this.color,
  });
}
