import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:epub_plus/epub_plus.dart';
import 'package:flutter/material.dart' hide Image;
import 'package:flutter/material.dart' as material show Image;
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../services/book_reader/youdao_dictionary_service.dart';
import '../services/book_reader/free_dictionary_service.dart';
import '../services/book_reader/hz_dictionary_service.dart';
import '../models/book_reader/page_content.dart';
import '../models/book_reader/bookmark.dart';
import '../models/book_reader/highlight.dart';
import '../models/book_reader/content_item.dart'
    show ContentItem, TextContent, ImageContent, CoverContent;
import 'book_reader/highlight_operations.dart';
import 'book_reader/search_manager.dart';
import 'book_reader/note_export.dart';
import 'book_reader/storage_manager.dart';
import 'book_reader/selectable_text_with_toolbar.dart';

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
  bool _showFontSizeSlider = false;
  double _tempFontSize = 16;

  // 词典翻译目标语言保存相关
  // 语言代码映射（有道词典 -> Free Dictionary API）
  // Free Dictionary API 使用 cmn 表示普通话（中文翻译）
  static const Map<String, String> _languageCodeMap = {
    'zh-CHS': 'cmn', // 简体中文 -> Chinese Mandarin
    'zh': 'cmn',
    'cmn': 'cmn',
    'en': 'en',
    'ja': 'ja',
    'ko': 'ko',
    'fr': 'fr',
    'de': 'de',
    'es': 'es',
  };

  /// 转换语言代码到 Free Dictionary API 格式
  String _convertToFreeDictionaryLanguageCode(String code) {
    return _languageCodeMap[code] ?? code;
  }

  // 文本选择和气泡工具栏相关
  String? _selectedText;
  bool _showTextToolbar = false;
  Offset _toolbarPosition = Offset.zero;
  OverlayEntry? _toolbarOverlay;

  // 高亮笔记相关
  final List<Highlight> _highlights = [];
  Color _defaultHighlightColor = Colors.yellow; // 默认高亮颜色

  // 默认高亮长度
  static const int _defaultHighlightLengthChinese = 5; // 中文默认高亮长度
  static const int _defaultHighlightLengthEnglish = 10; // 英文默认高亮长度

  // 当前选择的文本位置信息
  int? _selectionStartOffset;
  int? _selectionEndOffset;
  int? _selectionChapterIndex;
  int? _selectionPageIndex;

  // 当前选中的高亮/划线列表（支持叠加）
  List<Highlight> _selectedHighlights = [];

  // 字典服务
  // 有道词典服务（需要配置 App ID 和 App Key）
  late final YoudaoDictionaryService _youdaoService;
  late final FreeDictionaryService _freeDictionaryService;
  late final HzDictionaryService _hzService;

  // 搜索相关
  bool _showSearchDrawer = false;
  bool _searchDrawerOnRight = true; // 搜索抽屉在右侧显示
  List<SearchResult> _searchResults = [];
  List<SearchResult> _displaySearchResults = []; // 用于对话框显示的合并后的结果
  int _currentSearchIndex = 0;
  bool _highlightSearchResults = false; // 是否高亮搜索结果
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadBook();
    _loadDefaultHighlightColor();
    _loadDictionaryTargetLanguage();

    // 初始化有道词典服务（使用默认配置，实际使用需要替换）
    _youdaoService = YoudaoDictionaryService(
      appId: '55b585b48ea1a831', // 请替换为有道应用的 App ID
      appKey: 'xi4pR1yRyTuWamZVCJRnNXC6FR4l8seQ', // 请替换为有道应用的 App Key
    );
    // 初始化 Free Dictionary 服务
    _freeDictionaryService = FreeDictionaryService();
    // 初始化 Hz Dictionary 服务（需要在 https://www.apihz.cn 注册获取 id 和 key）
    _hzService = HzDictionaryService(
      apiId: '10011903', // 请替换为 apihz.cn 注册的 ID
      apiKey: 'd0aed98ccccd258debe5c6bc67d858fd', // 请替换为 apihz.cn 注册的 Key
    );
  }

  @override
  void dispose() {
    _saveReadingPosition(); // 退出前保存阅读位置
    _resizeDebounceTimer?.cancel();
    _savePositionTimer?.cancel();
    _textPainterCache?.dispose();
    _noteController.dispose();
    _scrollController.dispose();
    _searchController.dispose(); // 清理搜索控制器
    _hideTextToolbar(); // 清理工具栏
    super.dispose();
  }

  /// 计算页面起始偏移量
  int _calculatePageStartOffset(PageContent page) {
    int offset = 0;
    // 遍历该页之前的所有页面（全局索引）
    for (int i = 0; i < _pages.length; i++) {
      final p = _pages[i];
      if (p == page) {
        break; // 找到当前页面，停止累加
      }
      if (p.chapterIndex == page.chapterIndex) {
        // 累加同章节之前所有页面文本的长度
        for (final item in p.contentItems) {
          if (item is TextContent) {
            offset += item.text.length;
          }
        }
      }
    }
    return offset;
  }

  /// 构建带高亮/划线的文本样式（支持叠加）
  List<TextSpan> _buildHighlightSpans(
    String text,
    int textStartOffset,
    int chapterIndex,
  ) {
    return HighlightOperations.buildHighlightSpans(
      text,
      textStartOffset,
      chapterIndex,
      _highlights,
      _highlightSearchResults ? _searchResults : null,
      _highlightSearchResults,
    );
  }

  /// 显示文本选择工具栏
  void _showTextToolbarAt(
    Offset position,
    String selectedText, {
    List<Highlight>? existingHighlights,
  }) {
    _selectedText = selectedText;
    _selectedHighlights = existingHighlights ?? []; // 恢复高亮/划线信息
    _toolbarPosition = position;

    if (!_showTextToolbar) {
      // 如果工具栏未显示，创建 Overlay
      _showTextToolbar = true;
      _toolbarOverlay = OverlayEntry(
        builder: (context) => _buildTextToolbarOverlay(),
      );
      Overlay.of(context).insert(_toolbarOverlay!);
    } else {
      // 如果工具栏已显示，只更新位置并触发 Overlay 重建
      _toolbarOverlay?.markNeedsBuild();
    }

    // 打印调试信息
    // print('显示工具栏位置: $_toolbarPosition');
  }

  /// 加载默认高亮颜色
  Future<void> _loadDefaultHighlightColor() async {
    final color = await StorageManager.loadDefaultHighlightColor();
    if (color != null) {
      setState(() {
        _defaultHighlightColor = color;
      });
    }
  }

  /// 保存默认高亮颜色
  Future<void> _saveDefaultHighlightColor(Color color) async {
    await StorageManager.saveDefaultHighlightColor(color);
    setState(() {
      _defaultHighlightColor = color;
    });
  }

  /// 加载词典翻译目标语言
  Future<void> _loadDictionaryTargetLanguage() async {
    final targetLang = await StorageManager.loadDictionaryTargetLanguage();
    if (targetLang != null) {}
  }

  /// 保存词典翻译目标语言
  Future<void> _saveDictionaryTargetLanguage(String language) async {
    await StorageManager.saveDictionaryTargetLanguage(language);
  }

  /// 判断文本是否主要为英文
  bool _isEnglishText(String text) {
    if (text.isEmpty) return false;
    // 计算英文字符的比例
    int englishCount = 0;
    for (int i = 0; i < text.length; i++) {
      final codeUnit = text.codeUnitAt(i);
      // ASCII 范围（字母、数字、标点）
      if ((codeUnit >= 32 && codeUnit <= 126) || codeUnit == 8230) {
        englishCount++;
      }
    }
    return englishCount / text.length > 0.7; // 70% 以上是英文字符
  }

  /// 隐藏文本选择工具栏
  void _hideTextToolbar({bool applyDefaultHighlight = false}) {
    if (applyDefaultHighlight &&
        _selectedText != null &&
        _selectedHighlights.isEmpty) {
      final text = _selectedText!;
      final isEnglish = _isEnglishText(text);

      // 根据语言类型决定是否自动高亮
      if (isEnglish) {
        // 英文：只有选中完整单词时才自动高亮
        // 英文单词通常较长，且单个字母高亮意义不大
        if (text.length >= 10 && _containsCompleteWord(text)) {
          _onHighlightWithColor(_defaultHighlightColor);
        }
      } else {
        // 中文：长度>=5个字符才自动高亮
        if (text.length >= 5) {
          _onHighlightWithColor(_defaultHighlightColor);
        }
      }
    }

    _toolbarOverlay?.remove();
    _toolbarOverlay = null;
    _showTextToolbar = false;
    _selectedText = null;
    _selectedHighlights = [];
  }

  /// 判断文本是否包含完整单词（英文）
  bool _containsCompleteWord(String text) {
    // 简单判断：文本开始或结束是字母，且包含空格或连字符
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    // 检查是否以字母开头和结尾
    final firstChar = trimmed[0];
    final lastChar = trimmed[trimmed.length - 1];
    final isAlpha = RegExp(r'^[a-zA-Z]$').hasMatch;
    return isAlpha(firstChar) && isAlpha(lastChar);
  }

  /// 构建气泡式工具栏
  Widget _buildTextToolbarOverlay() {
    final screenSize = MediaQuery.of(context).size;

    // 打印调试信息
    // print('构建工具栏 - 原始位置: $_toolbarPosition');

    // 计算工具栏位置（始终贴在所选文字上方，除了最上面几行）
    double left = _toolbarPosition.dx - 130; // 工具栏宽度约260，居中
    double top = _toolbarPosition.dy - 50; // 贴在选中区域上方

    // print('计算后 - left: $left, top: $top');

    // 边界检查
    if (left < 10) left = 10;
    if (left > screenSize.width - 270) left = screenSize.width - 270;

    // 只有在最上面几行（top < 100）时，工具栏才显示在文字下方
    if (top < 100) {
      top = _toolbarPosition.dy + 50; // 显示在选中区域下方
      // print('空间不足，移到下方 - top: $top');
    }

    // print('最终位置 - left: $left, top: $top');

    return Stack(
      children: [
        // 透明背景，点击隐藏工具栏（如果选中文本未高亮，则使用默认颜色高亮）
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => _hideTextToolbar(applyDefaultHighlight: true),
            child: Container(color: Colors.transparent),
          ),
        ),
        // 工具栏
        Positioned(
          left: left,
          top: top,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            color: Theme.of(context).colorScheme.surface,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: _selectedHighlights.isNotEmpty
                    ? _buildExistingHighlightToolbar() // 已高亮/划线文本的工具栏
                    : _buildNewHighlightToolbar(), // 新选择的文本工具栏
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 构建新选择文本的工具栏（未高亮）
  List<Widget> _buildNewHighlightToolbar() {
    // 判断选择文本长度是否超过默认高亮长度
    List<Widget> colorButtons;
    bool showAsDelete = false; // 是否显示为删除按钮

    if (_selectedText != null) {
      final text = _selectedText!;
      final isEnglish = _isEnglishText(text);
      final defaultLength = isEnglish
          ? _defaultHighlightLengthEnglish
          : _defaultHighlightLengthChinese;
      showAsDelete = text.length >= defaultLength;
    }

    // 只有默认高亮颜色按钮显示为删除状态，其他颜色按钮正常显示
    // 使用 toARGB32() 比较颜色值，避免 MaterialColor 对象比较问题
    final defaultColorValue = _defaultHighlightColor.toARGB32();
    final yellowIsCurrent =
        showAsDelete && defaultColorValue == Colors.yellow.toARGB32();
    final greenIsCurrent =
        showAsDelete && defaultColorValue == Colors.green.toARGB32();
    final blueIsCurrent =
        showAsDelete && defaultColorValue == Colors.blue.toARGB32();

    colorButtons = [
      _buildColorHighlightButton(
        Colors.yellow,
        yellowIsCurrent ? '删除高亮' : '黄色高亮',
        isCurrentColor: yellowIsCurrent,
      ),
      _buildColorHighlightButton(
        Colors.green,
        greenIsCurrent ? '删除高亮' : '绿色高亮',
        isCurrentColor: greenIsCurrent,
      ),
      _buildColorHighlightButton(
        Colors.blue,
        blueIsCurrent ? '删除高亮' : '蓝色高亮',
        isCurrentColor: blueIsCurrent,
      ),
    ];

    return [
      ...colorButtons,
      _buildToolbarDivider(),
      _buildToolbarIconButton(
        icon: Icons.format_underline,
        tooltip: '划线',
        onTap: () {
          _onUnderlineSelected();
          _hideTextToolbar();
        },
      ),
      _buildToolbarDivider(),
      _buildToolbarIconButton(
        icon: Icons.note_add,
        tooltip: '添加笔记',
        onTap: () {
          _onAddNoteToNewHighlight();
          _hideTextToolbar();
        },
      ),
      _buildToolbarDivider(),
      _buildToolbarIconButton(
        icon: Icons.copy,
        tooltip: '复制',
        onTap: () {
          _onCopySelected();
        },
      ),
      _buildToolbarDivider(),
      _buildToolbarIconButton(
        icon: Icons.menu_book,
        tooltip: '字典',
        onTap: () {
          _onDictionarySelected();
        },
      ),
    ];
  }

  /// 构建已高亮/划线文本的工具栏（支持叠加）
  List<Widget> _buildExistingHighlightToolbar() {
    // 分离高亮和划线
    final highlights = _selectedHighlights
        .where((h) => !h.isUnderline)
        .toList();
    final underlines = _selectedHighlights.where((h) => h.isUnderline).toList();
    final hasHighlight = highlights.isNotEmpty;
    final hasUnderline = underlines.isNotEmpty;

    final List<Widget> buttons = [];

    // 如果有高亮，显示颜色按钮
    if (hasHighlight) {
      final currentColor = highlights.first.color;
      final currentColorValue = currentColor.toARGB32();
      bool isYellow = currentColorValue == Colors.yellow.toARGB32();
      bool isGreen = currentColorValue == Colors.green.toARGB32();
      bool isBlue = currentColorValue == Colors.blue.toARGB32();

      buttons.addAll([
        _buildColorHighlightButton(
          Colors.yellow,
          isYellow ? '删除高亮' : '更换为黄色',
          isCurrentColor: isYellow,
        ),
        _buildColorHighlightButton(
          Colors.green,
          isGreen ? '删除高亮' : '更换为绿色',
          isCurrentColor: isGreen,
        ),
        _buildColorHighlightButton(
          Colors.blue,
          isBlue ? '删除高亮' : '更换为蓝色',
          isCurrentColor: isBlue,
        ),
      ]);
    } else {
      // 没有高亮，显示添加高亮按钮
      buttons.addAll([
        _buildColorHighlightButton(Colors.yellow, '黄色高亮'),
        _buildColorHighlightButton(Colors.green, '绿色高亮'),
        _buildColorHighlightButton(Colors.blue, '蓝色高亮'),
      ]);
    }

    buttons.add(_buildToolbarDivider());

    // 划线按钮：如果有划线显示删除，否则显示添加
    if (hasUnderline) {
      buttons.add(
        _buildToolbarIconButton(
          icon: Icons.format_underline,
          tooltip: '删除划线',
          color: Colors.red,
          onTap: () {
            _onDeleteUnderline();
            _hideTextToolbar();
          },
        ),
      );
    } else {
      buttons.add(
        _buildToolbarIconButton(
          icon: Icons.format_underline,
          tooltip: '划线',
          onTap: () {
            _onUnderlineSelected();
            _hideTextToolbar();
          },
        ),
      );
    }

    // 获取笔记（合并高亮和划线的笔记）
    final note = _getMergedNote();

    buttons.addAll([
      _buildToolbarDivider(),
      _buildToolbarIconButton(
        icon: note != null && note.isNotEmpty
            ? Icons.edit_note
            : Icons.note_add,
        tooltip: note != null && note.isNotEmpty ? '编辑笔记' : '添加笔记',
        onTap: () {
          _onAddNoteToExistingHighlights();
          _hideTextToolbar();
        },
      ),
      _buildToolbarDivider(),
      _buildToolbarIconButton(
        icon: Icons.copy,
        tooltip: '复制',
        onTap: () {
          _onCopySelected();
        },
      ),
      _buildToolbarDivider(),
      _buildToolbarIconButton(
        icon: Icons.menu_book,
        tooltip: '字典',
        onTap: () {
          _onDictionarySelected();
        },
      ),
    ]);

    return buttons;
  }

  /// 获取合并后的笔记
  String? _getMergedNote() {
    for (final h in _selectedHighlights) {
      if (h.note != null && h.note!.isNotEmpty) {
        return h.note;
      }
    }
    return null;
  }

  /// 构建颜色高亮按钮
  /// [isCurrentColor] 如果为true，显示"×"表示点击会删除此高亮
  Widget _buildColorHighlightButton(
    Color color,
    String tooltip, {
    bool isCurrentColor = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () {
          if (isCurrentColor) {
            // 点击当前颜色按钮，删除高亮
            if (_selectedHighlights.isEmpty) {
              // 如果没有选中任何高亮，则查找并删除当前选择范围内的高亮
              _deleteHighlightsInRange();
            } else {
              _onDeleteHighlight();
            }
          } else {
            // 点击其他颜色按钮，更换颜色
            _onHighlightWithColor(color);
          }
          _hideTextToolbar();
        },
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: 28,
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(4),
            border: isCurrentColor
                ? Border.all(color: Colors.white, width: 2)
                : Border.all(color: Colors.white.withValues(alpha: 0.3)),
          ),
          child: Icon(
            isCurrentColor ? Icons.close : Icons.highlight,
            color: isCurrentColor ? Colors.red : Colors.black87,
            size: 18,
          ),
        ),
      ),
    );
  }

  /// 构建纯图标工具栏按钮
  Widget _buildToolbarIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? color,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          child: Icon(icon, color: color, size: 20),
        ),
      ),
    );
  }

  Widget _buildToolbarDivider() {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      color: Colors.white.withValues(alpha: 0.2),
    );
  }

  /// 处理带颜色的高亮（新增或更换颜色）
  void _onHighlightWithColor(Color color) async {
    // 立即保存所有选择相关的值，避免异步操作后被清空
    final selectedText = _selectedText ?? '';
    final startOffset = _selectionStartOffset;
    final endOffset = _selectionEndOffset;
    final chapterIndex = _selectionChapterIndex;
    final pageIndex = _selectionPageIndex ?? _currentPageIndex;

    if (startOffset == null ||
        endOffset == null ||
        chapterIndex == null ||
        selectedText.isEmpty)
      return;

    // 保存默认高亮颜色
    await _saveDefaultHighlightColor(color);

    // 只移除与该位置重叠的高亮（保留划线），避免同类型重复
    setState(() {
      _highlights.removeWhere((h) {
        return !h.isUnderline && // 只删除高亮
            h.chapterIndex == chapterIndex &&
            h.startOffset < endOffset &&
            h.endOffset > startOffset;
      });
    });

    final existingHighlights = _selectedHighlights
        .where((h) => !h.isUnderline)
        .toList();
    if (existingHighlights.isNotEmpty) {
      // 更换已有高亮的颜色 - 保留原有信息，只改颜色
      final oldHighlight = existingHighlights.first;
      setState(() {
        _highlights.add(
          Highlight(
            id: oldHighlight.id,
            chapterIndex: oldHighlight.chapterIndex,
            pageIndex: oldHighlight.pageIndex,
            text: oldHighlight.text,
            color: color,
            startOffset: oldHighlight.startOffset,
            endOffset: oldHighlight.endOffset,
            note: oldHighlight.note,
            createdAt: oldHighlight.createdAt,
          ),
        );
      });
    } else {
      // 创建新高亮对象
      final highlight = Highlight(
        chapterIndex: chapterIndex,
        pageIndex: pageIndex,
        text: selectedText,
        color: color,
        startOffset: startOffset,
        endOffset: endOffset,
      );

      setState(() {
        _highlights.add(highlight);
      });
    }

    // 保存到持久化存储
    await _saveHighlights();
  }

  /// 删除高亮（删除选中的高亮标记）
  void _onDeleteHighlight() async {
    final highlights = _selectedHighlights
        .where((h) => !h.isUnderline)
        .toList();
    if (highlights.isEmpty) return;

    setState(() {
      for (final h in highlights) {
        _highlights.removeWhere((item) => item.id == h.id);
      }
    });
    await _saveHighlights();
  }

  /// 删除当前选择范围内的高亮
  void _deleteHighlightsInRange() async {
    if (_selectionChapterIndex == null ||
        _selectionPageIndex == null ||
        _selectionStartOffset == null ||
        _selectionEndOffset == null) {
      return;
    }

    final chapterIndex = _selectionChapterIndex!;
    final pageIndex = _selectionPageIndex!;
    final startOffset = _selectionStartOffset!;
    final endOffset = _selectionEndOffset!;

    // 查找与当前选择范围重叠的高亮
    final highlightsToDelete = <Highlight>[];
    for (final highlight in _highlights) {
      if (!highlight.isUnderline &&
          highlight.chapterIndex == chapterIndex &&
          highlight.pageIndex == pageIndex) {
        // 检查是否与选择范围重叠
        if (highlight.startOffset < endOffset &&
            highlight.endOffset > startOffset) {
          highlightsToDelete.add(highlight);
        }
      }
    }

    if (highlightsToDelete.isEmpty) return;

    setState(() {
      for (final h in highlightsToDelete) {
        _highlights.removeWhere((item) => item.id == h.id);
      }
    });
    await _saveHighlights();
  }

  /// 删除划线（删除选中的划线标记）
  void _onDeleteUnderline() async {
    final underlines = _selectedHighlights.where((h) => h.isUnderline).toList();
    if (underlines.isEmpty) return;

    setState(() {
      for (final h in underlines) {
        _highlights.removeWhere((item) => item.id == h.id);
      }
    });
    await _saveHighlights();
  }

  /// 保存高亮到本地存储
  Future<void> _saveHighlights() async {
    await StorageManager.saveHighlights(widget.bookPath, _highlights);
  }

  /// 从本地存储加载高亮
  Future<void> _loadHighlights() async {
    final highlights = await StorageManager.loadHighlights(widget.bookPath);
    setState(() {
      _highlights.clear();
      _highlights.addAll(highlights);
    });
  }

  /// 删除高亮
  Future<void> _deleteHighlight(String id) async {
    setState(() {
      _highlights.removeWhere((h) => h.id == id);
    });
    await _saveHighlights();
  }

  /// 处理划线
  void _onUnderlineSelected() async {
    // 立即保存所有选择相关的值，避免异步操作后被清空
    final selectedText = _selectedText ?? '';
    final startOffset = _selectionStartOffset;
    final endOffset = _selectionEndOffset;
    final chapterIndex = _selectionChapterIndex;
    final pageIndex = _selectionPageIndex ?? _currentPageIndex;

    if (startOffset == null ||
        endOffset == null ||
        chapterIndex == null ||
        selectedText.isEmpty)
      return;

    // 只移除与该位置重叠的划线（保留高亮），避免同类型重复
    setState(() {
      _highlights.removeWhere((h) {
        return h.isUnderline && // 只删除划线
            h.chapterIndex == chapterIndex &&
            h.startOffset < endOffset &&
            h.endOffset > startOffset;
      });
    });

    // 创建划线对象（使用黑色作为默认划线颜色）
    final underline = Highlight(
      chapterIndex: chapterIndex,
      pageIndex: pageIndex,
      text: selectedText,
      color: Colors.black,
      startOffset: startOffset,
      endOffset: endOffset,
      isUnderline: true,
    );

    setState(() {
      _highlights.add(underline);
    });

    // 保存到持久化存储
    await _saveHighlights();
  }

  /// 为新选择的高亮添加笔记（先高亮再添加笔记）
  void _onAddNoteToNewHighlight() {
    if (_selectedText == null ||
        _selectionStartOffset == null ||
        _selectionEndOffset == null ||
        _selectionChapterIndex == null)
      return;

    // 先使用默认黄色高亮
    _onHighlightWithColor(Colors.yellow);

    // 获取刚刚创建的高亮
    final newHighlight = _highlights.lastWhere(
      (h) =>
          h.chapterIndex == _selectionChapterIndex &&
          h.startOffset == _selectionStartOffset &&
          h.endOffset == _selectionEndOffset,
      orElse: () => _highlights.last,
    );

    _selectedHighlights = [newHighlight];

    // 显示添加笔记对话框
    _showAddNoteDialog(newHighlight);
  }

  /// 为已有高亮/划线添加/编辑笔记（支持叠加）
  void _onAddNoteToExistingHighlights() {
    if (_selectedHighlights.isEmpty) return;

    // 如果有高亮，优先编辑高亮的笔记；否则编辑划线的笔记
    final targetHighlight = _selectedHighlights.firstWhere(
      (h) => !h.isUnderline,
      orElse: () => _selectedHighlights.first,
    );

    _showAddNoteDialog(targetHighlight);
  }

  /// 显示添加/编辑笔记对话框
  Future<void> _showAddNoteDialog(Highlight highlight) async {
    final noteController = TextEditingController(text: highlight.note ?? '');
    final isEditing = highlight.note != null && highlight.note!.isNotEmpty;

    // 根据高亮颜色计算对比色
    final bgColor = highlight.color.withValues(alpha: 0.15);
    final borderColor = highlight.color.withValues(alpha: 0.5);

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: highlight.color.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: highlight.color.withValues(alpha: 0.5),
                  width: 2,
                ),
              ),
              child: Icon(
                isEditing ? Icons.edit_note : Icons.note_add,
                color: Theme.of(context).colorScheme.onSurface,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              isEditing ? '编辑笔记' : '添加笔记',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 引用文本区域
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: borderColor, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: highlight.color.withValues(alpha: 0.1),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.format_quote,
                          size: 14,
                          color: Colors.grey[600],
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '引用原文',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      highlight.text,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.black87,
                        height: 1.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // 笔记输入区域
              TextField(
                controller: noteController,
                maxLines: 5,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontSize: 15, height: 1.5),
                decoration: InputDecoration(
                  hintText: '在此输入您的笔记...',
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Theme.of(context).dividerColor,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Theme.of(context).dividerColor,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: highlight.color.withValues(alpha: 0.8),
                      width: 2,
                    ),
                  ),
                  contentPadding: const EdgeInsets.all(16),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(
              foregroundColor: Colors.grey[600],
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            child: const Text('取消', style: TextStyle(fontSize: 14)),
          ),
          FilledButton(
            onPressed: () async {
              final noteText = noteController.text.trim();
              setState(() {
                highlight.note = noteText.isEmpty ? null : noteText;
              });
              await _saveHighlights();
              Navigator.pop(context);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(isEditing ? '笔记已更新' : '笔记已保存'),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: highlight.color,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Text(
              isEditing ? '更新' : '保存',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  /// 显示笔记列表对话框（AppBar按钮调用）
  void _showNotesListDialog() {
    _showHighlightListDialog();
  }

  /// 显示高亮列表对话框
  void _showHighlightListDialog() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          // 按章节分组高亮
          final groupedHighlights = _groupHighlightsByChapter(_highlights);

          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            actionsPadding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.note_alt,
                    color: Theme.of(context).primaryColor,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '笔记',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                // 统计高亮和划线数量
                Builder(
                  builder: (context) {
                    final underlineCount = _highlights
                        .where((h) => h.isUnderline)
                        .length;
                    final highlightCount = _highlights.length - underlineCount;
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (highlightCount > 0) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.amber.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.highlight,
                                  size: 12,
                                  color: Colors.amber[800],
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '$highlightCount',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.amber[800],
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (underlineCount > 0) ...[
                          if (highlightCount > 0) const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.format_underline,
                                  size: 12,
                                  color: Colors.grey[700],
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '$underlineCount',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[700],
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: 450,
              child: _highlights.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.lightbulb_outline,
                            size: 64,
                            color: Colors.grey[300],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '暂无高亮笔记',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '长按文本选择内容后点击高亮按钮添加',
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: groupedHighlights.length,
                      itemBuilder: (context, index) {
                        return _buildGroupedHighlightItem(
                          groupedHighlights[index],
                          setDialogState,
                        );
                      },
                    ),
            ),
            actions: [
              // 导出按钮
              if (_highlights.isNotEmpty)
                FilledButton.icon(
                  onPressed: () => exportNotesToMarkdown(),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text(
                    '导出',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.grey[100],
                  foregroundColor: Colors.black87,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('关闭', style: TextStyle(fontSize: 14)),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 按章节分组高亮，并合并重叠的高亮和划线
  List<ChapterGroup> _groupHighlightsByChapter(List<Highlight> highlights) {
    return HighlightOperations.groupHighlightsByChapter(
      highlights,
      _getChapterTitle,
      _getTextForRange,
    );
  }

  /// 导出笔记到 Markdown 文件
  Future<void> exportNotesToMarkdown() async {
    await NoteExport.exportNotesToMarkdown(
      _bookTitle,
      _highlights,
      _getChapterTitle,
      _getTextForRange,
      context,
    );
  }

  /// 根据章节和位置范围获取文本
  String _getTextForRange(int chapterIndex, int startOffset, int endOffset) {
    // 从所有页面中查找该范围的文本
    StringBuffer result = StringBuffer();
    int currentOffset = 0;

    for (final page in _pages) {
      if (page.chapterIndex != chapterIndex) continue;

      for (final item in page.contentItems) {
        if (item is TextContent) {
          final text = item.text;
          final textStart = currentOffset;
          final textEnd = currentOffset + text.length;

          // 检查是否有重叠
          if (textEnd > startOffset && textStart < endOffset) {
            final overlapStart = startOffset > textStart
                ? startOffset - textStart
                : 0;
            final overlapEnd = endOffset < textEnd
                ? endOffset - textStart
                : text.length;

            if (overlapStart < overlapEnd) {
              result.write(text.substring(overlapStart, overlapEnd));
            }
          }

          currentOffset += text.length;
        }
      }
    }

    return result.toString();
  }

  /// 获取章节标题
  String _getChapterTitle(int chapterIndex) {
    if (chapterIndex >= 0 && chapterIndex < _chapters.length) {
      return _chapters[chapterIndex].title ?? '第${chapterIndex + 1}章';
    }
    return '第${chapterIndex + 1}章';
  }

  /// 构建分组的高亮项
  Widget _buildGroupedHighlightItem(
    ChapterGroup group,
    StateSetter setDialogState,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 章节标题
        Container(
          margin: const EdgeInsets.only(top: 16, bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.blue.withValues(alpha: 0.15)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bookmark_outline, size: 14, color: Colors.blue[700]),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  group.chapterTitle,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.blue[600],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${group.mergedHighlights.length}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.blue[700],
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        // 该章节下的所有合并后的高亮
        ...group.mergedHighlights.map(
          (merged) => _buildMergedHighlightListItem(merged, setDialogState),
        ),
      ],
    );
  }

  /// 构建合并后的高亮列表项
  Widget _buildMergedHighlightListItem(
    MergedHighlight merged, [
    StateSetter? setDialogState,
  ]) {
    final hasNote = merged.note != null && merged.note!.isNotEmpty;
    final hasHighlight = merged.hasHighlight;
    final hasUnderline = merged.hasUnderline;
    final isCombined = hasHighlight && hasUnderline;

    return Container(
      margin: const EdgeInsets.only(bottom: 10, left: 4, right: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withValues(alpha: 0.1),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
        border: Border.all(color: Colors.grey.withValues(alpha: 0.1)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              Navigator.pop(context);
              // 跳转到第一个原始标记的位置
              final firstHighlight = merged.originalHighlights.isNotEmpty
                  ? merged.originalHighlights.first
                  : merged.originalUnderlines.first;
              _jumpToHighlight(firstHighlight);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部：类型标识 + 日期 + 操作按钮
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
                  decoration: BoxDecoration(
                    color: isCombined
                        ? merged.highlightColor.withValues(alpha: 0.08)
                        : hasUnderline
                        ? Colors.grey.withValues(alpha: 0.05)
                        : merged.highlightColor.withValues(alpha: 0.08),
                    border: Border(
                      bottom: BorderSide(
                        color: isCombined
                            ? merged.highlightColor.withValues(alpha: 0.15)
                            : hasUnderline
                            ? Colors.grey.withValues(alpha: 0.2)
                            : merged.highlightColor.withValues(alpha: 0.15),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      // 类型标识
                      isCombined
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 高亮颜色块
                                Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: merged.highlightColor.withValues(
                                      alpha: 0.8,
                                    ),
                                    borderRadius: BorderRadius.circular(3),
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                // 划线图标
                                Icon(
                                  Icons.format_underline,
                                  size: 14,
                                  color: Colors.red[700],
                                ),
                              ],
                            )
                          : hasUnderline
                          ? Container(
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                color: Colors.grey.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Icon(
                                Icons.format_underline,
                                size: 14,
                                color: Colors.grey[700],
                              ),
                            )
                          : Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: merged.highlightColor.withValues(
                                  alpha: 0.8,
                                ),
                                borderRadius: BorderRadius.circular(3),
                                border: Border.all(
                                  color: Colors.white,
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: merged.highlightColor.withValues(
                                      alpha: 0.4,
                                    ),
                                    blurRadius: 2,
                                  ),
                                ],
                              ),
                            ),
                      const SizedBox(width: 8),
                      // 日期
                      Expanded(
                        child: Text(
                          _formatDate(merged.createdAt),
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      // 笔记按钮 - 编辑第一个有高亮笔记的标记
                      InkWell(
                        onTap: () async {
                          // 优先编辑高亮的笔记
                          final target = merged.originalHighlights.isNotEmpty
                              ? merged.originalHighlights.first
                              : merged.originalUnderlines.first;
                          await _showAddNoteDialog(target);
                          setDialogState?.call(() {});
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: hasNote
                                ? Colors.blue.withValues(alpha: 0.1)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            hasNote ? Icons.edit_note : Icons.note_add_outlined,
                            size: 18,
                            color: hasNote
                                ? Colors.blue[700]
                                : Colors.grey[500],
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // 删除按钮 - 删除所有原始标记
                      InkWell(
                        onTap: () async {
                          // 删除所有原始高亮和划线
                          for (final h in merged.originalHighlights) {
                            await _deleteHighlight(h.id);
                          }
                          for (final u in merged.originalUnderlines) {
                            await _deleteHighlight(u.id);
                          }
                          if (mounted) {
                            setState(() {});
                            setDialogState?.call(() {});
                          }
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          child: Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: Colors.red[400],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 内容区域
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 合并后的文本 - 使用RichText分段显示，只对实际有划线的部分加下划线
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isCombined
                              ? merged.highlightColor.withValues(alpha: 0.12)
                              : hasUnderline
                              ? Colors.grey.withValues(alpha: 0.05)
                              : merged.highlightColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isCombined
                                ? merged.highlightColor.withValues(alpha: 0.25)
                                : hasUnderline
                                ? Colors.grey.withValues(alpha: 0.2)
                                : merged.highlightColor.withValues(alpha: 0.25),
                          ),
                        ),
                        child: _buildMergedHighlightTextSpans(merged),
                      ),
                      // 笔记内容
                      if (hasNote) ...[
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.grey[50],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey[200]!),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.comment_outlined,
                                size: 14,
                                color: Colors.grey[500],
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  merged.note!,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey[700],
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 构建合并高亮项的文本显示 - 分段渲染，只对实际有划线的部分加下划线
  Widget _buildMergedHighlightTextSpans(MergedHighlight merged) {
    final hasUnderline = merged.hasUnderline;
    String text = merged.text;
    final textStartOffset = merged.startOffset;

    // 优先使用原始高亮/划线中的文本，避免合并时丢失文本
    if (text.isEmpty) {
      for (final h in merged.originalHighlights) {
        if (h.text.isNotEmpty) {
          text = h.text;
          break;
        }
      }
      if (text.isEmpty) {
        for (final u in merged.originalUnderlines) {
          if (u.text.isNotEmpty) {
            text = u.text;
            break;
          }
        }
      }
    }

    // 如果仍然没有文本，显示提示文字
    if (text.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(10),
        child: Text(
          '（文本内容丢失）',
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey[500],
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    // 如果没有划线，直接显示普通文本
    if (!hasUnderline) {
      return Text(
        text,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 14,
          color: Colors.black87,
          height: 1.5,
          fontWeight: FontWeight.w500,
        ),
      );
    }

    // 收集所有分割点（划线的起始/结束位置，相对于合并文本的起始位置）
    final Set<int> splitPoints = {0, text.length};
    for (final u in merged.originalUnderlines) {
      final start = (u.startOffset - textStartOffset).clamp(0, text.length);
      final end = (u.endOffset - textStartOffset).clamp(0, text.length);
      if (start < end) {
        splitPoints.add(start);
        splitPoints.add(end);
      }
    }

    // 如果有高亮，也加入分割点（用于区分叠加区域）
    for (final h in merged.originalHighlights) {
      final start = (h.startOffset - textStartOffset).clamp(0, text.length);
      final end = (h.endOffset - textStartOffset).clamp(0, text.length);
      if (start < end) {
        splitPoints.add(start);
        splitPoints.add(end);
      }
    }

    final sortedPoints = splitPoints.toList()..sort();

    // 构建每个段的样式
    final spans = <TextSpan>[];
    for (int i = 0; i < sortedPoints.length - 1; i++) {
      final segStart = sortedPoints[i];
      final segEnd = sortedPoints[i + 1];
      if (segStart >= segEnd) continue;

      final segText = text.substring(segStart, segEnd);

      // 检查该段是否有划线
      final segHasUnderline = merged.originalUnderlines.any((u) {
        final uStart = u.startOffset - textStartOffset;
        final uEnd = u.endOffset - textStartOffset;
        return segStart < uEnd && segEnd > uStart;
      });

      // 检查该段是否有高亮（用于确定划线颜色）
      final segHasHighlight = merged.originalHighlights.any((h) {
        final hStart = h.startOffset - textStartOffset;
        final hEnd = h.endOffset - textStartOffset;
        return segStart < hEnd && segEnd > hStart;
      });

      // 确定划线颜色：叠加时红色，仅划线时黑色
      final decorationColor = segHasUnderline && segHasHighlight
          ? Colors.red
          : Colors.black54;

      spans.add(
        TextSpan(
          text: segText,
          style: TextStyle(
            fontSize: 14,
            color: Colors.black87,
            height: 1.5,
            fontWeight: FontWeight.w500,
            decoration: segHasUnderline ? TextDecoration.underline : null,
            decorationColor: decorationColor,
            decorationThickness: segHasUnderline ? 2 : null,
          ),
        ),
      );
    }

    return RichText(
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(children: spans),
    );
  }

  /// 格式化日期
  String _formatDate(DateTime date) {
    return '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  /// 跳转到高亮位置
  void _jumpToHighlight(Highlight highlight) {
    // 查找包含该高亮的页面
    for (int i = 0; i < _pages.length; i++) {
      final page = _pages[i];
      if (page.chapterIndex == highlight.chapterIndex) {
        // 计算该页面的文本范围
        int pageStartOffset = _calculatePageStartOffset(page);
        int pageEndOffset = pageStartOffset;
        for (final item in page.contentItems) {
          if (item is TextContent) {
            pageEndOffset += item.text.length;
          }
        }

        // 检查高亮是否在该页面范围内
        if (highlight.startOffset < pageEndOffset &&
            highlight.endOffset > pageStartOffset) {
          setState(() {
            _currentPageIndex = i;
            _currentChapterIndex = page.chapterIndex;
          });
          _saveReadingPosition();
          break;
        }
      }
    }
  }

  /// 执行搜索
  void _performSearch(String searchText) {
    // 先清空之前的搜索结果
    setState(() {
      _searchResults.clear();
      _displaySearchResults.clear();
      _currentSearchIndex = 0;
    });

    // 执行搜索
    final results = SearchManager.performSearch(searchText, _chapters, _pages);

    if (results.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('未找到匹配的内容')));
    } else {
      // 合并同一页的搜索结果
      final mergedResults = SearchManager.mergeResultsByPage(results);

      setState(() {
        _searchResults = results;
        _displaySearchResults = mergedResults;
        _showSearchDrawer = true;
        _highlightSearchResults = true;
        _currentSearchIndex = 0;
      });
    }
  }

  /// 显示搜索对话框
  /// 构建搜索抽屉
  Widget _buildSearchDrawer() {
    final theme = Theme.of(context);
    return Positioned(
      left: _searchDrawerOnRight ? null : 0,
      right: _searchDrawerOnRight ? 0 : null,
      top: 0,
      bottom: 0,
      child: Container(
        width: 320,
        decoration: BoxDecoration(
          color: theme.cardColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 8,
              offset: Offset(_searchDrawerOnRight ? -2 : 2, 0),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.dividerColor,
                border: Border(bottom: BorderSide(color: theme.dividerColor)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '搜索',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Row(
                    children: [
                      // 左右切换按钮
                      IconButton(
                        icon: Icon(
                          _searchDrawerOnRight
                              ? Icons.arrow_back
                              : Icons.arrow_forward,
                        ),
                        color: theme.iconTheme.color,
                        onPressed: () {
                          setState(() {
                            _searchDrawerOnRight = !_searchDrawerOnRight;
                          });
                        },
                        tooltip: '切换位置',
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        color: Colors.grey[600],
                        onPressed: () {
                          setState(() {
                            _showSearchDrawer = false;
                            _highlightSearchResults = false; // 关闭时取消高亮
                          });
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      autofocus: false,
                      style: Theme.of(context).textTheme.bodyMedium,
                      decoration: InputDecoration(
                        hintText: '输入搜索词',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      onSubmitted: (value) {
                        final searchText = value.trim();
                        if (searchText.isNotEmpty) {
                          _performSearch(searchText);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      final searchText = _searchController.text.trim();
                      if (searchText.isNotEmpty) {
                        _performSearch(searchText);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                    ),
                    child: const Text('搜索'),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      setState(() {
                        _searchController.clear();
                        _searchResults.clear();
                        _displaySearchResults.clear();
                        _currentSearchIndex = 0;
                        _highlightSearchResults = false;
                      });
                    },
                    tooltip: '清除',
                  ),
                ],
              ),
            ),
            // 搜索结果数量
            if (_searchResults.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  '共 ${_displaySearchResults.length} 页 (${_searchResults.length} 条)',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontSize: 12),
                ),
              ),
            Expanded(
              child: _displaySearchResults.isEmpty
                  ? Center(
                      child: Text(
                        _searchResults.isEmpty ? '输入搜索词进行搜索' : '未找到匹配的内容',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _displaySearchResults.length,
                      itemBuilder: (context, index) {
                        final result = _displaySearchResults[index];
                        final matchCount = _searchResults
                            .where(
                              (r) =>
                                  r.chapterIndex == result.chapterIndex &&
                                  r.pageIndex == result.pageIndex,
                            )
                            .length;

                        final tappedIndex = index;

                        return Column(
                          children: [
                            InkWell(
                              onTap: () {
                                Future.microtask(() {
                                  _goToSearchResult(
                                    tappedIndex,
                                    showDialog: false,
                                  );
                                });
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 14,
                                      backgroundColor:
                                          tappedIndex == _currentSearchIndex
                                          ? Theme.of(context).primaryColor
                                          : Theme.of(context).primaryColor
                                                .withValues(alpha: 0.2),
                                      child: Text(
                                        '${tappedIndex + 1}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color:
                                              tappedIndex == _currentSearchIndex
                                              ? Colors.white
                                              : null,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            result.chapterTitle,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w500,
                                                  fontSize: 13,
                                                  color:
                                                      tappedIndex ==
                                                          _currentSearchIndex
                                                      ? Theme.of(
                                                          context,
                                                        ).primaryColor
                                                      : null,
                                                ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          if (matchCount > 1)
                                            Text(
                                              '该页 $matchCount 处匹配',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(fontSize: 10),
                                            ),
                                          Text(
                                            result.contextText,
                                            maxLines: matchCount > 1 ? 1 : 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(fontSize: 12),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (index < _displaySearchResults.length - 1)
                              Divider(
                                height: 1,
                                color: Theme.of(context).dividerColor,
                              ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// 跳转到指定的搜索结果
  void _goToSearchResult(int index, {bool showDialog = true}) {
    if (index < 0 || index >= _displaySearchResults.length) return;

    final result = _displaySearchResults[index];
    setState(() {
      _currentChapterIndex = result.chapterIndex;
      _currentPageIndex = result.pageIndex;
      _currentSearchIndex = index;
      _highlightSearchResults = true; // 启用搜索结果高亮
    });

    if (showDialog) {
      Navigator.pop(context);
    }
    _saveReadingPosition();

    // 延迟一段时间后滚动到搜索位置
    Future.delayed(const Duration(milliseconds: 300), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          result.positionOffset.toDouble(),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  /// 复制选中文本
  void _onCopySelected() async {
    if (_selectedText == null || _selectedText!.isEmpty) return;

    // 保存文本长度，因为 _hideTextToolbar 会清空 _selectedText
    final textLength = _selectedText!.length;

    await Clipboard.setData(ClipboardData(text: _selectedText!));
    _hideTextToolbar();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已复制: $textLength 个字符'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  /// 处理字典查询
  void _onDictionarySelected() async {
    if (_selectedText == null || _selectedText!.trim().isEmpty) return;

    final selectedWord = _selectedText!.trim();
    print('词典查询: $selectedWord'); // 调试信息

    if (!mounted) return;
    // 本地没有，调用词典 API
    _showLoadingDialog();

    // 检测文字类型，选择默认词典源
    final isEnglish = RegExp(r'^[a-zA-Z\s\-]+$').hasMatch(selectedWord);
    dynamic result;
    String dataSource = isEnglish ? 'free' : 'hz'; // 默认值
    String from = isEnglish ? 'en' : 'zh-CHS';
    String to = isEnglish ? 'zh-CHS' : 'zh-CHS';

    try {
      if (isEnglish) {
        // 英文默认使用 Free Dictionary
        dataSource = 'free';
        final freeFrom = _convertToFreeDictionaryLanguageCode(from);
        final freeTo = _convertToFreeDictionaryLanguageCode(to);
        result = await _freeDictionaryService.lookup(
          selectedWord,
          from: freeFrom,
          to: freeTo,
        );
      } else {
        // 中文默认使用 Hz Dictionary
        dataSource = 'hz';
        result = await _hzService.lookup(selectedWord);
        print('Hz 词典结果: $result'); // 调试信息
      }

      _hideLoadingDialog();

      if (!mounted) return;

      _hideTextToolbar();

      // 无论 result 是否为 null，都显示词典结果对话框
      // 如果为 null，对话框会显示"没有查到"信息
      _showDictionaryResultDialog(
        selectedWord,
        result,
        from: from,
        to: to,
        dataSource: dataSource,
      );
    } catch (e) {
      print('词典查询异常: $e'); // 调试信息
      _hideLoadingDialog();
      if (mounted) {
        _hideTextToolbar();
        _showDictionaryResultDialog(
          selectedWord,
          null,
          from: from,
          to: to,
          dataSource: dataSource,
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('网络请求失败')));
      }
    }
  }

  /// 显示加载对话框
  void _showLoadingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('正在查询词典...'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 隐藏加载对话框
  void _hideLoadingDialog() {
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  /// 解析简单的 Markdown 格式文本为 Widget 列表
  List<Widget> _parseMarkdown(String markdown) {
    final widgets = <Widget>[];
    final lines = markdown.split('\n');
    final buffer = StringBuffer();
    bool isBold = false;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      if (line.isEmpty) {
        // 空行，如果 buffer 有内容则添加
        if (buffer.isNotEmpty) {
          widgets.add(
            SelectableText(
              buffer.toString().trim(),
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color:
                    Theme.of(context).textTheme.bodyMedium?.color ??
                    Colors.white,
                fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          );
          widgets.add(SizedBox(height: 8));
          buffer.clear();
          isBold = false;
        } else {
          // 连续的空行
          widgets.add(SizedBox(height: 8));
        }
        continue;
      }

      // 检查是否是粗体标记 **文本**
      if (line.startsWith('**') && line.endsWith('**')) {
        // 处理单行粗体
        if (buffer.isNotEmpty) {
          widgets.add(
            SelectableText(
              buffer.toString().trim(),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontSize: 14, height: 1.6),
            ),
          );
          buffer.clear();
        }
        final boldText = line.substring(2, line.length - 2);
        widgets.add(
          SelectableText(
            boldText,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: 14,
              height: 1.6,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).primaryColor,
            ),
          ),
        );
        widgets.add(SizedBox(height: 4));
        continue;
      }

      // 检查是否是粗体开始标记 **
      if (line.startsWith('**')) {
        if (buffer.isNotEmpty) {
          widgets.add(
            SelectableText(
              buffer.toString().trim(),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontSize: 14, height: 1.6),
            ),
          );
          buffer.clear();
        }
        final boldPart = line.substring(2);
        buffer.writeln(boldPart);
        isBold = true;
        continue;
      }

      // 检查是否是粗体结束标记 **
      if (line.endsWith('**')) {
        final boldPart = line.substring(0, line.length - 2);
        buffer.writeln(boldPart);
        isBold = false;
        widgets.add(
          SelectableText(
            buffer.toString().trim(),
            style: TextStyle(
              fontSize: 14,
              height: 1.6,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).primaryColor,
            ),
          ),
        );
        widgets.add(SizedBox(height: 8));
        buffer.clear();
        continue;
      }

      // 普通文本行
      buffer.writeln(line);
    }

    // 处理剩余的 buffer
    if (buffer.isNotEmpty) {
      widgets.add(
        SelectableText(
          buffer.toString().trim(),
          style: TextStyle(
            fontSize: 14,
            height: 1.6,
            color:
                Theme.of(context).textTheme.bodyMedium?.color ?? Colors.white,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      );
    }

    return widgets;
  }

  /// 显示词典结果对话框
  void _showDictionaryResultDialog(
    String word,
    dynamic result, {
    String from = 'en',
    String to = 'zh-CHS',
    String dataSource = 'hz',
  }) {
    // 检测所选文字是否为中文
    final isSourceChinese = word.contains(RegExp(r'[\u4e00-\u9fa5]'));
    final sourceLanguageText = isSourceChinese ? '中文' : '英文';

    // Free Dictionary 只支持英文
    final canUseFreeDictionary = !isSourceChinese;

    StateSetter? setState;
    String currentWord = word;
    dynamic currentResult = result;
    bool isLoading = false;
    String currentFrom = from;
    String currentTo = to;
    String currentDataSource = dataSource;

    void fetchDictionary(
      String dataSource,
      String newFrom,
      String newTo,
    ) async {
      if (!mounted) return;
      setState?.call(() {
        isLoading = true;
      });

      dynamic newResult;
      if (dataSource == 'hz') {
        // Hz Dictionary API
        newResult = await _hzService.lookup(currentWord);
      } else if (dataSource == 'free') {
        // Free Dictionary API 需要转换语言代码
        final freeFrom = _convertToFreeDictionaryLanguageCode(newFrom);
        final freeTo = _convertToFreeDictionaryLanguageCode(newTo);
        newResult = await _freeDictionaryService.lookup(
          currentWord,
          from: freeFrom,
          to: freeTo,
        );
      } else {
        newResult = await _youdaoService.lookup(
          currentWord,
          from: newFrom,
          to: newTo,
        );
      }

      if (!mounted) return;
      setState?.call(() {
        currentResult = newResult;
        currentDataSource = dataSource;
        currentFrom = newFrom;
        currentTo = newTo;
        isLoading = false;
      });
    }

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setStateBuilder) {
          setState = setStateBuilder;

          // 根据结果类型解析数据
          String? phoneticOrPinyin;
          String? phoneticDisplay;
          List<String>? explains;
          List<dynamic>? webTranslations;
          String? translation;
          String? formInfo; // 变形信息
          String? hzDefinition; // Hz 词典的完整解释
          String? hzImageUrl; // Hz 词典的图片 URL

          if (currentDataSource == 'hz') {
            // Hz Dictionary 结果
            hzDefinition = currentResult?.definition;
            hzImageUrl = currentResult?.imageUrl;
          } else if (currentDataSource == 'free') {
            // Free Dictionary 结果
            phoneticOrPinyin = currentResult.phonetic ?? '';
            explains = currentResult.explains;
            webTranslations = currentResult.web?.cast<dynamic>();
            translation = currentResult.translation;
            formInfo = currentResult.formInfo;
            phoneticDisplay = phoneticOrPinyin?.isNotEmpty == true
                ? '[$phoneticOrPinyin]'
                : '';
          } else if (currentResult is YoudaoDictionaryResult) {
            // 有道词典结果
            final basic = currentResult.basic;
            phoneticOrPinyin = currentFrom == 'en'
                ? (basic?.phonetic ?? '')
                : (currentResult.basic?.phonetic ?? '');
            phoneticDisplay =
                currentFrom == 'en' && (phoneticOrPinyin?.isNotEmpty ?? false)
                ? '[$phoneticOrPinyin]'
                : (phoneticOrPinyin ?? '');
            explains = basic?.explains?.map((e) => '$e').toList();
            webTranslations = currentResult.web?.cast<dynamic>();
            translation = currentResult.translation ?? '';
          }

          final explainsText = explains?.join('; ') ?? '';
          final webTranslationsText =
              webTranslations
                  ?.map((w) => '${w.key}: ${(w.value as List).join('; ')}')
                  .join('\n') ??
              '';

          return AlertDialog(
            title: Row(
              children: [
                Icon(Icons.menu_book, size: 28),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        currentWord,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        sourceLanguageText,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (phoneticDisplay?.isNotEmpty == true)
                  Text(
                    phoneticDisplay!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(fontSize: 14),
                  ),
              ],
            ),
            content: isLoading
                ? Center(child: CircularProgressIndicator())
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 词典源选择下拉框（不在滚动区域内）
                      DropdownButtonFormField<String>(
                        value: currentDataSource,
                        decoration: InputDecoration(
                          labelText: '词典源',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        items: [
                          DropdownMenuItem(value: 'hz', child: Text('Hz 词典')),
                          DropdownMenuItem(
                            value: 'youdao',
                            child: Text('有道词典'),
                          ),
                          if (canUseFreeDictionary)
                            DropdownMenuItem(
                              value: 'free',
                              child: Text('Free Dictionary'),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null && value != currentDataSource) {
                            fetchDictionary(value, currentFrom, currentTo);
                          }
                        },
                      ),
                      SizedBox(height: 12),
                      // 内容区域（可滚动）
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 检查是否有结果
                              if ((currentDataSource == 'hz' &&
                                      hzDefinition == null) ||
                                  (currentDataSource != 'hz' &&
                                      explainsText.isEmpty &&
                                      translation?.isEmpty != false)) ...[
                                // 没有查到结果
                                Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Column(
                                      children: [
                                        Icon(
                                          Icons.search_off,
                                          size: 48,
                                          color: Theme.of(
                                            context,
                                          ).iconTheme.color,
                                        ),
                                        SizedBox(height: 16),
                                        Text(
                                          '没有查到结果',
                                          style: TextStyle(
                                            fontSize: 16,
                                            color: Theme.of(
                                              context,
                                            ).textTheme.bodySmall?.color,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ] else ...[
                                // Hz 词典显示完整解释（使用 Markdown 渲染）
                                if (currentDataSource == 'hz' &&
                                    hzDefinition != null &&
                                    hzDefinition.isNotEmpty) ...[
                                  // 显示汉字图片
                                  if (hzImageUrl != null &&
                                      hzImageUrl.isNotEmpty) ...[
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: material.Image.network(
                                        hzImageUrl,
                                        width: 120,
                                        height: 120,
                                        fit: BoxFit.contain,
                                        errorBuilder:
                                            (context, error, stackTrace) {
                                              return Container(
                                                width: 120,
                                                height: 120,
                                                decoration: BoxDecoration(
                                                  color: Theme.of(
                                                    context,
                                                  ).dividerColor,
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                ),
                                                child: Icon(
                                                  Icons.image_not_supported,
                                                  size: 40,
                                                  color: Theme.of(
                                                    context,
                                                  ).iconTheme.color,
                                                ),
                                              );
                                            },
                                        loadingBuilder:
                                            (context, child, loadingProgress) {
                                              if (loadingProgress == null) {
                                                return child;
                                              }
                                              return Container(
                                                width: 120,
                                                height: 120,
                                                decoration: BoxDecoration(
                                                  color: Theme.of(
                                                    context,
                                                  ).colorScheme.surface,
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                ),
                                                child: Center(
                                                  child:
                                                      CircularProgressIndicator(),
                                                ),
                                              );
                                            },
                                      ),
                                    ),
                                    SizedBox(height: 12),
                                  ],
                                  // 显示详细解释
                                  Container(
                                    padding: EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: _parseMarkdown(hzDefinition),
                                    ),
                                  ),
                                ] else ...[
                                  // 翻译方向切换按钮
                                  if (currentDataSource == 'youdao') ...[
                                    // 有道词典支持中文
                                    Wrap(
                                      spacing: 8,
                                      children: [
                                        if (isSourceChinese) ...[
                                          ChoiceChip(
                                            label: Text('中→英'),
                                            selected: currentTo == 'en',
                                            onSelected: (selected) {
                                              if (selected) {
                                                fetchDictionary(
                                                  'youdao',
                                                  'zh-CHS',
                                                  'en',
                                                );
                                              }
                                            },
                                          ),
                                          ChoiceChip(
                                            label: Text('中→中'),
                                            selected: currentTo == 'zh-CHS',
                                            onSelected: (selected) {
                                              if (selected) {
                                                fetchDictionary(
                                                  'youdao',
                                                  'zh-CHS',
                                                  'zh-CHS',
                                                );
                                              }
                                            },
                                          ),
                                        ] else ...[
                                          ChoiceChip(
                                            label: Text('英→中'),
                                            selected: currentTo == 'zh-CHS',
                                            onSelected: (selected) {
                                              if (selected) {
                                                _saveDictionaryTargetLanguage(
                                                  'zh-CHS',
                                                );
                                                fetchDictionary(
                                                  'youdao',
                                                  'en',
                                                  'zh-CHS',
                                                );
                                              }
                                            },
                                          ),
                                          ChoiceChip(
                                            label: Text('英→英'),
                                            selected: currentTo == 'en',
                                            onSelected: (selected) {
                                              if (selected) {
                                                _saveDictionaryTargetLanguage(
                                                  'en',
                                                );
                                                fetchDictionary(
                                                  'youdao',
                                                  'en',
                                                  'en',
                                                );
                                              }
                                            },
                                          ),
                                        ],
                                      ],
                                    ),
                                    SizedBox(height: 12),
                                  ] else if (currentDataSource == 'free') ...[
                                    // Free Dictionary 支持英文翻译方向
                                    Wrap(
                                      spacing: 8,
                                      children: [
                                        ChoiceChip(
                                          label: Text('英→中'),
                                          selected: currentTo == 'zh-CHS',
                                          onSelected: (selected) {
                                            if (selected) {
                                              _saveDictionaryTargetLanguage(
                                                'zh-CHS',
                                              );
                                              fetchDictionary(
                                                'free',
                                                'en',
                                                'zh-CHS',
                                              );
                                            }
                                          },
                                        ),
                                        ChoiceChip(
                                          label: Text('英→英'),
                                          selected: currentTo == 'en',
                                          onSelected: (selected) {
                                            if (selected) {
                                              _saveDictionaryTargetLanguage(
                                                'en',
                                              );
                                              fetchDictionary(
                                                'free',
                                                'en',
                                                'en',
                                              );
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: 12),
                                  ],
                                  if (formInfo?.isNotEmpty == true) ...[
                                    Text(
                                      formInfo!,
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.orange[700],
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                    SizedBox(height: 16),
                                  ],
                                  if (translation?.isNotEmpty == true) ...[
                                    Text(
                                      '翻译',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      translation!,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(fontSize: 12),
                                    ),
                                    SizedBox(height: 16),
                                  ],
                                  if (explainsText.isNotEmpty) ...[
                                    Text(
                                      '基本释义',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      explainsText,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(fontSize: 12),
                                    ),
                                    SizedBox(height: 16),
                                  ],
                                  if (webTranslationsText.isNotEmpty) ...[
                                    Text(
                                      '网络释义',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      webTranslationsText,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(fontSize: 12),
                                    ),
                                    SizedBox(height: 16),
                                  ],
                                ],
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
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

    await StorageManager.saveReadingPosition(
      bookPath: widget.bookPath,
      bookTitle: _bookTitle,
      chapterIndex: _currentChapterIndex,
      pageIndex: _currentPageIndex,
      scrollOffset: _scrollController.hasClients
          ? _scrollController.offset
          : 0.0,
    );
    print('阅读位置已保存: 第 $_currentPageIndex 页, 章节 $_currentChapterIndex');
  }

  /// 从本地加载阅读位置
  Future<Map<String, dynamic>?> _loadReadingPosition() async {
    return await StorageManager.loadReadingPosition(widget.bookPath);
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
    final savedFontSize = await StorageManager.loadFontSize();
    if (savedFontSize != null && savedFontSize >= 12 && savedFontSize <= 32) {
      setState(() {
        _fontSize = savedFontSize;
      });
      print('加载字体大小: $_fontSize');
    }
  }

  /// 保存字体大小
  Future<void> _saveFontSize() async {
    await StorageManager.saveFontSize(_fontSize);
    print('保存字体大小: $_fontSize');
  }

  /// 保存书签到本地
  Future<void> _saveBookmarks() async {
    await StorageManager.saveBookmarks(widget.bookPath, _bookmarks);
  }

  /// 从本地加载书签
  Future<void> _loadBookmarks() async {
    _bookmarks.clear();
    _bookmarks.addAll(await StorageManager.loadBookmarks(widget.bookPath));
  }

  /// 恢复阅读位置
  void _restoreReadingPosition(Map<String, dynamic> position) {
    final savedPageIndex = (position['pageIndex'] as int?) ?? 0;
    final savedChapterIndex = (position['chapterIndex'] as int?) ?? 0;

    print('恢复阅读位置: 第 $savedPageIndex 页, 章节 $savedChapterIndex');

    // 延迟恢复位置，确保页面已渲染
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      // 跳转到保存的页码
      if (savedPageIndex >= 0 && savedPageIndex < _pages.length) {
        _goToPage(savedPageIndex);
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

      // 加载高亮笔记
      await _loadHighlights();

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
    // 计算该页之前所有文本的累积偏移量
    int cumulativeOffset = _calculatePageStartOffset(page);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: page.contentItems.map((item) {
            if (item is TextContent) {
              final textStartOffset = cumulativeOffset;
              cumulativeOffset += item.text.length;

              // 构建带高亮的文本
              final highlightedSpans = _buildHighlightSpans(
                item.text,
                textStartOffset,
                page.chapterIndex,
              );

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SelectableTextWithToolbar(
                  text: item.text,
                  style: TextStyle(
                    fontSize: _fontSize,
                    height: 1.5,
                    color:
                        Theme.of(context).textTheme.bodyMedium?.color ??
                        Colors.black87,
                  ),
                  textStartOffset: textStartOffset,
                  chapterIndex: page.chapterIndex,
                  pageIndex: _currentPageIndex,
                  spans: highlightedSpans,
                  onTextSelected:
                      (selectedText, position, startOffset, endOffset) {
                        _selectionStartOffset = startOffset;
                        _selectionEndOffset = endOffset;
                        _selectionChapterIndex = page.chapterIndex;
                        _selectionPageIndex = _currentPageIndex;

                        // 检查是否选中了已有高亮/划线
                        var existingHighlights =
                            HighlightOperations.getHighlightsAtSelection(
                              _highlights,
                              page.chapterIndex,
                              startOffset,
                              endOffset,
                            );

                        _showTextToolbarAt(
                          position,
                          selectedText,
                          existingHighlights: existingHighlights,
                        );
                      },
                  onSelectionCleared: () {
                    if (_showTextToolbar) {
                      _hideTextToolbar();
                    }
                  },
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
                              style: Theme.of(context).textTheme.bodySmall,
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
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
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
              // 内容层（不包含手势检测）
              Container(
                key: _contentKey,
                width: double.infinity,
                height: double.infinity,
                color: Theme.of(context).colorScheme.surface,
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
                    // 底部占位区域（控制栏会覆盖在这里）
                    const SizedBox(height: 50),
                  ],
                ),
              ),
              // 翻页手势层（放在内容层之上，但控制栏之下）
              GestureDetector(
                behavior: HitTestBehavior.translucent,
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
              ),
              // 底部控制栏（放在最上层，可以响应点击事件）
              if (_showControls)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: AnimatedOpacity(
                    opacity: _showControls ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 24,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  // 书签列表
                                  if (_bookmarks.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 12),
                                      child: Row(
                                        children: _bookmarks.map((bookmark) {
                                          return Padding(
                                            padding: const EdgeInsets.only(
                                              right: 4,
                                            ),
                                            child: InkWell(
                                              onTap: () =>
                                                  _onBookmarkTap(bookmark),
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                              child: Padding(
                                                padding: const EdgeInsets.all(
                                                  8,
                                                ),
                                                child: Icon(
                                                  Icons.bookmark,
                                                  color: bookmark.color,
                                                  size: 20,
                                                ),
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
                            ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书签已移除'), duration: Duration(seconds: 2)),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书签已添加'), duration: Duration(seconds: 2)),
      );
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
    final theme = Theme.of(context);
    return Positioned(
      top: 80,
      right: 16,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        color: theme.cardColor,
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
                  color: theme.primaryColor,
                ),
              ),
              const SizedBox(height: 8),
              // A+ 图标（点击增加字体）
              InkWell(
                onTap: () {
                  setState(() {
                    _tempFontSize = (_tempFontSize + 1).clamp(12.0, 32.0);
                  });
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.text_increase,
                    size: 18,
                    color: _tempFontSize < 32
                        ? theme.primaryColor
                        : Colors.grey[400],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // 垂直滑动条
              Expanded(
                child: RotatedBox(
                  quarterTurns: 3, // 旋转为垂直方向
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: theme.primaryColor,
                      inactiveTrackColor: theme.primaryColor.withValues(
                        alpha: 0.5,
                      ),
                      thumbColor: theme.primaryColor,
                      overlayColor: theme.primaryColor.withValues(alpha: 0.2),
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
              // A- 图标（点击减小字体）
              InkWell(
                onTap: () {
                  setState(() {
                    _tempFontSize = (_tempFontSize - 1).clamp(12.0, 32.0);
                  });
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.text_decrease,
                    size: 18,
                    color: _tempFontSize > 12
                        ? theme.primaryColor
                        : Colors.grey[400],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // 确认按钮
              InkWell(
                onTap: _applyFontSizeChange,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    // 与当前字体一致时主题色，不一致时灰色
                    color: _tempFontSize == _fontSize
                        ? Theme.of(context).primaryColor
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
        // 通过 pageIndex 查找 _bookmarks 列表中的实际对象并修改
        final actualBookmark = _bookmarks.firstWhere(
          (b) => b.pageIndex == bookmark.pageIndex,
          orElse: () => bookmark,
        );
        actualBookmark.colorIndex =
            (actualBookmark.colorIndex + 1) % BookmarkColors.colors.length;
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
                    _isBookmarked() ? Icons.bookmark : Icons.bookmark_border,
                    color: _isBookmarked()
                        ? Theme.of(context).primaryColor
                        : null,
                  ),
                  onPressed: _addBookmark,
                  tooltip: '书签',
                ),
                IconButton(
                  icon: Icon(
                    _showFontSizeSlider
                        ? Icons.format_size
                        : Icons.format_size_outlined,
                    color: _showFontSizeSlider
                        ? Theme.of(context).primaryColor
                        : null,
                  ),
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
                    color: _showTableOfContents
                        ? Theme.of(context).primaryColor
                        : null,
                  ),
                  onPressed: () {
                    setState(() {
                      _showTableOfContents = !_showTableOfContents;
                    });
                  },
                  tooltip: '目录',
                ),
                IconButton(
                  icon: const Icon(Icons.note_alt),
                  onPressed: _showNotesListDialog,
                  tooltip: '笔记',
                ),
                IconButton(
                  icon: Icon(
                    Icons.search,
                    color: _showSearchDrawer
                        ? Theme.of(context).primaryColor
                        : null,
                  ),
                  onPressed: () {
                    setState(() {
                      if (_showSearchDrawer) {
                        // 关闭抽屉时取消高亮
                        _highlightSearchResults = false;
                      }
                      _showSearchDrawer = !_showSearchDrawer;
                    });
                  },
                  tooltip: '搜索',
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
                  Icon(
                    Icons.error,
                    size: 64,
                    color: Theme.of(context).colorScheme.error,
                  ),
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
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(fontSize: 12),
                      ),
                    ),
                ],
              ),
            );
          }

          if (!_isContentLoaded || _pages.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.menu_book,
                    size: 64,
                    color: Theme.of(context).primaryColor,
                  ),
                  SizedBox(height: 16),
                  Text('暂无内容', style: Theme.of(context).textTheme.bodyLarge),
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
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: _buildPageMode(),
                ),
              ),
              if (_showTableOfContents) _buildTableOfContents(),
              if (_showSearchDrawer) _buildSearchDrawer(),
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
    final theme = Theme.of(context);
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: Container(
        width: 280,
        decoration: BoxDecoration(
          color: theme.cardColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
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
                color: theme.canvasColor,
                border: Border(bottom: BorderSide(color: theme.dividerColor)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '目录',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    color: theme.iconTheme.color,
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
                          ? Theme.of(context).primaryColor
                          : Theme.of(context).colorScheme.surface,
                      child: isBookmarked
                          ? Icon(
                              Icons.bookmark,
                              size: 14,
                              color: Theme.of(context).colorScheme.onSurface,
                            )
                          : Text(
                              '${index + 1}',
                              style: TextStyle(
                                color: isCurrentChapter
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.onSurface,
                                fontSize: 12,
                              ),
                            ),
                    ),
                    title: Text(
                      chapter.title ?? '第 ${index + 1} 章',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: isCurrentChapter
                            ? Theme.of(context).primaryColor
                            : null,
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
