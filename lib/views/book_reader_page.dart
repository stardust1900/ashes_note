import 'dart:io';
import 'dart:typed_data';
import 'package:epub_plus/epub_plus.dart';
import 'package:flutter/material.dart' hide Image;
import 'package:flutter/material.dart' as material show Image;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

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

  @override
  void initState() {
    super.initState();
    _loadBook();
  }

  @override
  void dispose() {
    _noteController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onWindowResize() {
    final newSize = MediaQuery.of(context).size;
    if (_windowSize == null ||
        (newSize.width != _windowSize!.width ||
            newSize.height != _windowSize!.height)) {
      _windowSize = newSize;
      if (_epubBook != null && _chapters.isNotEmpty) {
        _processPages();
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

      final file = File(widget.bookPath);
      final bytes = await file.readAsBytes();
      final epub = await EpubReader.readBook(bytes);

      setState(() {
        _bookTitle = epub.title ?? '未知书籍';
        _epubBook = epub;
        _chapters.addAll(_flattenChapters(epub.chapters));
        _isLoading = false;
      });

      await _loadCoverImage(epub);

      // 使用微任务队列确保UI更新后再处理页面
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _processPagesAsync();
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
    });

    try {
      // 分步骤处理，避免阻塞UI
      await Future.delayed(const Duration(milliseconds: 100));

      // 实际的页面处理逻辑
      await _processPages();

      if (mounted) {
        setState(() {
          _isContentLoaded = true;
          _isProcessingPages = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessingPages = false;
          _hasError = true;
          _errorMessage = e.toString();
          _isContentLoaded = true;
        });

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('页面处理失败: $e')));
      }
    }
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

  Future<void> _processPages() async {
    final BuildContext? contentContext = _contentKey.currentContext;
    // 如果当前模式没有渲染带 key 的容器（例如默认为滚动模式），
    // 回退使用 State 的 context 来获取窗口尺寸，避免提前返回导致不生成页面。
    final BuildContext useContext = contentContext ?? this.context;
    final size = MediaQuery.of(useContext).size;
    _windowSize = size;

    final availableHeight = size.height - 120;
    final availableWidth = size.width - 48; // 页面左右 padding

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

    for (
      int chapterIndex = 0;
      chapterIndex < _chapters.length;
      chapterIndex++
    ) {
      final chapter = _chapters[chapterIndex];
      final chapterPages = _splitChapterIntoPages(
        chapter,
        chapterIndex,
        availableHeight,
        availableWidth,
      );
      pages.addAll(chapterPages);
    }

    setState(() {
      _pages = pages;
      _totalPages = pages.length;
      if (_totalPages > 0) {
        _currentPageIndex = 0;
        _currentChapterIndex = pages[0].chapterIndex;
      }
    });
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

    final lineHeight = _fontSize * 1.6;
    final linesPerPage = (availableHeight - 40) ~/ lineHeight;
    final charsPerLine = (availableWidth / (_fontSize * 0.6)).floor().clamp(
      20,
      1000,
    );

    List<ContentItem> currentPageItems = [];
    int currentPageLines = 0;
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
        currentPageLines = 0;
      }
    }

    for (final item in contentItems) {
      if (item is TextContent) {
        String remaining = item.text.trim();
        while (remaining.isNotEmpty) {
          final remainingLines = linesPerPage - currentPageLines;
          if (remainingLines <= 0) {
            flushCurrentPage();
            continue;
          }

          final fitChars = remainingLines * charsPerLine;
          if (fitChars >= remaining.length) {
            // fits in current page
            currentPageItems.add(TextContent(text: remaining));
            currentPageLines += (remaining.length / charsPerLine).ceil();
            remaining = '';
          } else {
            // try to cut at last space to avoid breaking a word
            int cut = fitChars;
            final sub = remaining.substring(0, fitChars);
            final lastSpace = sub.lastIndexOf(' ');
            if (lastSpace > (fitChars * 0.6).floor()) {
              cut = lastSpace;
            }

            String part = remaining.substring(0, cut).trimRight();
            if (part.isEmpty) {
              part = remaining.substring(0, fitChars);
              cut = fitChars;
            }

            currentPageItems.add(TextContent(text: part));
            currentPageLines += (part.length / charsPerLine).ceil();
            remaining = remaining.substring(cut).trimLeft();

            // current page is full now
            flushCurrentPage();
          }
        }
      } else if (item is ImageContent) {
        final itemLines = (linesPerPage * 0.4).ceil();
        if (currentPageItems.isNotEmpty &&
            currentPageLines + itemLines > linesPerPage) {
          flushCurrentPage();
        }
        currentPageItems.add(item);
        currentPageLines += itemLines;

        // If image itself larger than one page, place it on its own page
        if (itemLines >= linesPerPage) {
          flushCurrentPage();
        }
      } else if (item is CoverContent) {
        // cover always occupies a full page
        if (currentPageItems.isNotEmpty) {
          flushCurrentPage();
        }
        currentPageItems.add(item);
        currentPageLines += linesPerPage;
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
        .replaceAll(RegExp('<h[1-6][^>]*>.*?</h[1-6]>', caseSensitive: false, multiLine: true, dotAll: true), '\n')
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
    return SingleChildScrollView(
      // 添加滚动支持
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...page.contentItems.map((item) {
              if (item is TextContent) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
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
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
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
                                  (MediaQuery.of(context).size.width * 0.7)
                                      .clamp(200.0, 500.0);
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
            }),
          ],
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
        return SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.all(24.0),
          child: _buildScrollContent(),
        );
      },
    );
  }

  Widget _buildPageMode() {
    return LayoutBuilder(
      builder: (context, constraints) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _onWindowResize();
        });

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
                  final tapX = details.globalPosition.dx;

                  if (tapX < screenWidth * 0.2) {
                    _previousPage();
                  } else if (tapX > screenWidth * 0.8) {
                    _nextPage();
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
                      Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 24,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '第 ${_currentPageIndex + 1} 页 / 共 $_totalPages 页',
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 14,
                                  ),
                                ),
                                if (_pages.isNotEmpty &&
                                    _pages[_currentPageIndex].title != null &&
                                    _pages[_currentPageIndex].chapterIndex >= 0)
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
      _bookmarks.removeWhere((b) => b.pageIndex == _currentPageIndex);
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

  void _toggleFontSize(bool increase) {
    setState(() {
      _fontSize = (increase ? _fontSize + 1 : _fontSize - 1).clamp(12, 32);
    });
  }

  bool _isBookmarked() {
    return _bookmarks.any((b) => b.pageIndex == _currentPageIndex);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
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
            tooltip: _readingMode == ReadingMode.scroll ? '切换到分页模式' : '切换到滚动模式',
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
            icon: const Icon(Icons.text_decrease),
            onPressed: () => _toggleFontSize(false),
            tooltip: '减小字体',
          ),
          IconButton(
            icon: const Icon(Icons.text_increase),
            onPressed: () => _toggleFontSize(true),
            tooltip: '增大字体',
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
                    TextButton(onPressed: _saveNote, child: const Text('保存')),
                  ],
                ),
              );
            },
            tooltip: '添加笔记',
          ),
        ],
      ),
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

          if (_isProcessingPages) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在处理页面内容...'),
                  Text('这可能需要几秒钟时间'),
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
              Container(
                width: double.infinity,
                height: double.infinity,
                color: Colors.white,
                child: _readingMode == ReadingMode.scroll
                    ? _buildScrollMode()
                    : _buildPageMode(),
              ),
              if (_showTableOfContents && _readingMode == ReadingMode.page)
                _buildTableOfContents(),
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
                  const Text(
                    '目录',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
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

abstract class ContentItem {}

class TextContent extends ContentItem {
  final String text;

  TextContent({required this.text});
}

class ImageContent extends ContentItem {
  final String source;

  ImageContent({required this.source});
}

class CoverContent extends ContentItem {
  final Uint8List imageData;

  CoverContent({required this.imageData});
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
}

enum ReadingMode { scroll, page }

class Bookmark {
  final int chapterIndex;
  final int pageIndex;
  final String title;
  final DateTime timestamp;
  final String? note;

  Bookmark({
    required this.chapterIndex,
    required this.pageIndex,
    required this.title,
    required this.timestamp,
    this.note,
  });
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
