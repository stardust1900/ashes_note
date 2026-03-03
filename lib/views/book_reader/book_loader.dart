import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:epub_plus/epub_plus.dart';
import 'package:image/image.dart' as img show encodeJpg;
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;
import '../../utils/prefs_util.dart';
import '../../models/book_reader/page_content.dart';
import '../../models/book_reader/content_item.dart'
    show ContentItem, TextContent, ImageContent, CoverContent, HeaderContent;

/// 图书加载器 - 负责图书的加载、处理和缓存
class BookLoader {
  /// 优先加载的章节数
  static const int priorityChapterCount = 3;

  /// 窗口大小变化防抖控制
  Timer? resizeDebounceTimer;
  static const Duration resizeDebounceDuration = Duration(milliseconds: 300);

  /// TextPainter 缓存，避免重复创建
  TextPainter? textPainterCache;

  /// HTML 标签移除的正则表达式缓存（用于特殊标签处理）
  static final RegExp _spaceTabRegex = RegExp(r'[ \t]+');

  /// 窗口大小
  Size? windowSize;

  /// 字体大小
  double fontSize = 16;

  /// 后台处理状态
  bool isBackgroundProcessing = false;
  int processedChaptersCount = 0;

  /// 文本行数缓存（key: 文本长度+宽度, value: 估算行数）
  static final Map<String, int> _textLinesCache = {};
  static const int _maxLinesCacheSize = 500;

  /// 字符容纳数缓存
  static final Map<String, int> _fitCharsCache = {};
  static const int _maxFitCharsCacheSize = 500;

  /// 章节纯文本映射（用于从缓存恢复时提取文本）
  final Map<int, String> _chapterPlainTextMap = {};

  /// 缓存相关
  String? bookCacheKey;

  /// 图书路径
  final String bookPath;

  /// 加载回调函数
  final Function(bool isLoading, bool isContentLoaded, String? errorMessage)?
  onLoadingStateChanged;

  /// 页面更新回调函数
  final Function(
    List<PageContent> pages,
    int totalPages,
    int currentPageIndex,
    int currentChapterIndex,
  )?
  onPagesUpdated;

  /// 章节更新回调函数
  final Function(List<EpubChapter> chapters)? onChaptersUpdated;

  BookLoader({
    required this.bookPath,
    this.onLoadingStateChanged,
    this.onPagesUpdated,
    this.onChaptersUpdated,
  });

  /// 释放资源
  void dispose() {
    resizeDebounceTimer?.cancel();
    textPainterCache?.dispose();
  }

  /// 生成书籍缓存键（基于文件内容MD5）
  Future<String> generateBookCacheKey() async {
    try {
      final file = File(bookPath);
      final bytes = await file.readAsBytes();
      final digest = md5.convert(bytes);
      return digest.toString();
    } catch (e) {
      // 如果读取失败，使用路径和修改时间
      try {
        final file = File(bookPath);
        final stat = await file.stat();
        return '${bookPath.hashCode}_${stat.modified.millisecondsSinceEpoch}';
      } catch (statError) {
        // 如果获取文件状态也失败，使用路径哈希
        print('获取文件状态失败，使用路径哈希: $statError');
        return bookPath.hashCode.toString();
      }
    }
  }

  /// 获取缓存目录路径
  Future<String> getCacheDirectory() async {
    final workingDir = SPUtil.get<String>('workingDirectory', '');
    final cacheDir = Directory('$workingDir/books/.cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir.path;
  }

  /// 获取封面图片文件路径
  String getCoverImagePath() {
    final workingDir = SPUtil.get<String>('workingDirectory', '');
    if (workingDir.isEmpty) {
      print('警告: 工作目录未设置，封面图片路径无效');
    }
    final cacheDir = '$workingDir/books/.cache';
    return '$cacheDir/cover_${bookPath.hashCode}.jpg';
  }

  /// 获取缓存文件路径
  Future<String> getCacheFilePath() async {
    if (bookCacheKey == null) return '';
    final cacheDir = await getCacheDirectory();
    return '$cacheDir/$bookCacheKey.json';
  }

  /// 检查缓存是否存在且有效
  Future<bool> checkCacheValid() async {
    if (bookCacheKey == null) return false;
    final cacheFilePath = await getCacheFilePath();
    final cacheFile = File(cacheFilePath);
    return await cacheFile.exists();
  }

  /// 清除缓存文件
  Future<void> clearCache() async {
    try {
      if (bookCacheKey == null) return;
      final cacheFilePath = await getCacheFilePath();
      final cacheFile = File(cacheFilePath);
      if (await cacheFile.exists()) {
        await cacheFile.delete();
        print('缓存文件已删除: $cacheFilePath');
      }
    } catch (e) {
      print('删除缓存文件失败: $e');
    }
  }

  /// 保存页面数据到缓存（优化版：不存储完整文本，但保留章节纯文本）
  Future<void> savePagesToCache(List<PageContent> pages) async {
    try {
      if (bookCacheKey == null || pages.isEmpty) return;

      final cacheFilePath = await getCacheFilePath();

      // 优化：将 TextContent 转换为 TextContentRef，只存储偏移量
      final optimizedPages = pages.map((p) => p.optimizeForCache()).toList();

      // 收集所有章节的纯文本（转换为 String 键以支持 JSON 序列化）
      final chapterTexts = <String, String>{};
      for (final page in pages) {
        if (page.chapterPlainText != null) {
          chapterTexts[page.chapterIndex.toString()] = page.chapterPlainText!;
        }
      }

      // 验证所有页面项都可以正确序列化
      for (int i = 0; i < optimizedPages.length; i++) {
        final page = optimizedPages[i];
        try {
          jsonEncode(page.toJson());
        } catch (e) {
          print('⚠️ 页面 $i 序列化失败: $e');
          print('  页面标题: ${page.title}');
          print('  内容项数量: ${page.contentItems.length}');
          for (int j = 0; j < page.contentItems.length; j++) {
            final item = page.contentItems[j];
            print('  项 $j 类型: ${item.runtimeType}');
            try {
              jsonEncode(item.toJson());
            } catch (itemError) {
              print('  项 $j 序列化失败: $itemError');
            }
          }
        }
      }

      final cacheData = {
        'bookKey': bookCacheKey,
        'bookPath': bookPath,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'windowWidth': windowSize?.width ?? 0,
        'windowHeight': windowSize?.height ?? 0,
        'fontSize': fontSize,
        'chapterTexts': chapterTexts, // 存储章节纯文本
        'pages': optimizedPages.map((p) => p.toJson()).toList(),
      };

      final jsonString = jsonEncode(cacheData);

      // 统计原始大小和优化后大小
      final originalData = {'pages': pages.map((p) => p.toJson()).toList()};
      final originalSize = jsonEncode(originalData).length;
      final compressedSize = jsonString.length;
      final ratio = ((1 - compressedSize / originalSize) * 100).toStringAsFixed(
        1,
      );

      final cacheFile = File(cacheFilePath);
      await cacheFile.writeAsString(jsonString);

      print('页面缓存已保存: $cacheFilePath');
      print(
        '📊 缓存优化: 原始 $originalSize 字节 → 优化后 $compressedSize 字节 (减少 ${ratio}%)',
      );
    } catch (e) {
      print('保存页面缓存失败: $e');
      print('错误堆栈: ${StackTrace.current}');
    }
  }

  /// 从缓存加载页面数据
  Future<List<PageContent>?> loadPagesFromCache() async {
    try {
      if (!await checkCacheValid()) return null;

      final cacheFilePath = await getCacheFilePath();
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

      // 如果缓存的窗口大小为0，认为缓存无效
      if (cachedWidth <= 0 || cachedHeight <= 0) {
        print('缓存的窗口大小无效 ($cachedWidth x $cachedHeight)，重新生成页面');
        await clearCache();
        return null;
      }

      if (windowSize != null &&
          windowSize!.width > 0 &&
          windowSize!.height > 0) {
        final widthDiff = (windowSize!.width - cachedWidth).abs();
        final heightDiff = (windowSize!.height - cachedHeight).abs();
        final fontSizeDiff = (fontSize - cachedFontSize).abs();

        // 如果窗口大小变化超过5%或字体大小变化超过0.1，认为缓存失效
        // 降低容差以确保分页准确性
        if (widthDiff / windowSize!.width > 0.05 ||
            heightDiff / windowSize!.height > 0.05 ||
            fontSizeDiff > 0.1) {
          print('缓存窗口大小不匹配，重新生成页面');
          print('  当前: ${windowSize!.width}x${windowSize!.height}, 字体: $fontSize');
          print('  缓存: $cachedWidth x $cachedHeight, 字体: $cachedFontSize');
          // 删除无效的缓存文件
          await clearCache();
          return null;
        }
      }

      // 从缓存加载章节纯文本
      final chapterTextsData =
          cacheData['chapterTexts'] as Map<String, dynamic>?;
      final Map<int, String> chapterTexts = {};
      if (chapterTextsData != null) {
        chapterTextsData.forEach((key, value) {
          chapterTexts[int.parse(key)] = value as String;
        });
      }

      // 从缓存加载页面（包含 TextContentRef）
      final pages = pagesJson.map((json) {
        final page = PageContent.fromJson(json);
        // 恢复章节纯文本
        if (chapterTexts.containsKey(page.chapterIndex)) {
          return PageContent(
            chapterIndex: page.chapterIndex,
            pageIndexInChapter: page.pageIndexInChapter,
            contentItems: page.contentItems,
            title: page.title,
            chapterPlainText: chapterTexts[page.chapterIndex],
          );
        }
        return page;
      }).toList();

      // 解析所有 TextContentRef 为 TextContent
      final resolvedPages = pages.map((p) => p.resolveTextRefs()).toList();

      print('从缓存加载了 ${resolvedPages.length} 页（优化版本）');
      return resolvedPages;
    } catch (e) {
      print('从缓存加载页面失败: $e');
      return null;
    }
  }

  /// 加载封面图片
  Future<void> loadCoverImage(EpubBook epub) async {
    try {
      final coverImagePath = getCoverImagePath();
      final coverFile = File(coverImagePath);

      // 检查封面图片文件是否已存在
      if (await coverFile.exists()) {
        // 文件存在，直接使用路径
        print('封面图片已存在: $coverImagePath');
        return;
      }

      // 文件不存在，从 epub 中提取并保存
      if (epub.coverImage != null) {
        final bytes = Uint8List.fromList(img.encodeJpg(epub.coverImage!));

        // 确保缓存目录存在
        await coverFile.parent.create(recursive: true);

        // 保存图片文件
        await coverFile.writeAsBytes(bytes);
        print('封面图片已保存: $coverImagePath');
      }
    } catch (e) {
      print('加载封面图片失败: $e');
    }
  }

  /// 扁平化章节列表
  List<EpubChapter> flattenChapters(List<EpubChapter> chapters) {
    final result = <EpubChapter>[];
    for (var chapter in chapters) {
      // 添加所有章节，即使没有 htmlContent
      // 这样可以保留章节结构，特别是只有标题的章节
      result.add(chapter);

      if (chapter.subChapters.isNotEmpty) {
        result.addAll(flattenChapters(chapter.subChapters));
      }
    }
    return result;
  }

  /// 解析 HTML 内容（使用 package:html，返回纯文本和带偏移量的内容项）
  ({List<ContentItem> items, String plainText}) parseHtmlContent(String html) {
    final List<ContentItem> items = <ContentItem>[];
    final StringBuffer plainTextBuffer = StringBuffer();

    if (html.isEmpty) return (items: items, plainText: '');

    final String cleanedHtml = html.replaceAll(_spaceTabRegex, ' ').trim();
    final html_dom.Document document = html_parser.parse(cleanedHtml);

    // 判断是否为块级元素
    bool isBlockElement(html_dom.Element node) {
      final name = node.localName ?? '';
      return name == 'p' || name == 'div' || name == 'br';
    }

    // 判断是否为标题元素
    bool isHeaderElement(html_dom.Element node) {
      final name = node.localName ?? '';
      return RegExp(r'^h([1-6])$').hasMatch(name);
    }

    // 判断是否为行内元素
    bool isInlineElement(html_dom.Element node) {
      final name = node.localName ?? '';
      return name == 'span' || name == 'i' || name == 'b' ||
             name == 'strong' || name == 'em' || name == 'a';
    }

    // 处理块级元素内的内容
    void processBlockElement(html_dom.Element node, {bool isParagraph = false}) {
      final List<ContentItem> blockItems = [];
      StringBuffer blockText = StringBuffer();
      final blockStartOffset = plainTextBuffer.length;

      print('[BookLoader] processBlockElement: isParagraph=$isParagraph, nodeName=${node.localName}');

      // 遍历子节点
      for (final child in node.nodes) {
        if (child is html_dom.Element) {
          if (child.localName == 'img') {
            // 遇到图片，先保存之前的文本
            if (blockText.isNotEmpty) {
              blockItems.add(TextContent(
                text: blockText.toString().trim(),
                startOffset: plainTextBuffer.length,
              ));
              blockText.clear();
            }
            blockItems.add(ImageContent(source: child.attributes['src'] ?? ''));
          } else if (isInlineElement(child)) {
            // 行内元素 - 提取文本
            final text = child.text.trim();
            if (text.isNotEmpty) {
              if (blockText.isNotEmpty) {
                blockText.write(' ');
              }
              blockText.write(text);
            }
          } else if (isHeaderElement(child)) {
            // 块级元素内的标题 - 先保存文本，再处理标题
            if (blockText.isNotEmpty) {
              blockItems.add(TextContent(
                text: blockText.toString().trim(),
                startOffset: plainTextBuffer.length,
              ));
              plainTextBuffer.write(blockText.toString().trim());
              blockText.clear();
            }
            final headerText = child.text.trim();
            if (headerText.isNotEmpty) {
              final levelMatch = RegExp(r'^h([1-6])$').firstMatch(child.localName ?? '');
              final level = levelMatch != null ? int.parse(levelMatch.group(1)!) : 1;
              // Header 文本也添加到 plainText
              plainTextBuffer.write(headerText);
              plainTextBuffer.write('\n');
              blockItems.add(HeaderContent(text: headerText, level: level));
            }
          }
          // 其他块级元素 - 递归处理，处理其子节点
          else {
            for (final grandchild in child.nodes) {
              if (grandchild is html_dom.Element) {
                if (grandchild.localName == 'img') {
                  // 遇到图片，先保存之前的文本
                  if (blockText.isNotEmpty) {
                    blockItems.add(TextContent(
                      text: blockText.toString().trim(),
                      startOffset: plainTextBuffer.length,
                    ));
                    blockText.clear();
                  }
                  blockItems.add(ImageContent(source: grandchild.attributes['src'] ?? ''));
                } else if (isInlineElement(grandchild)) {
                  // 行内元素 - 提取文本
                  final text = grandchild.text.trim();
                  if (text.isNotEmpty) {
                    if (blockText.isNotEmpty) {
                      blockText.write(' ');
                    }
                    blockText.write(text);
                  }
                } else if (isHeaderElement(grandchild)) {
                  // 块级元素内的标题 - 先保存文本，再处理标题
                  if (blockText.isNotEmpty) {
                    blockItems.add(TextContent(
                      text: blockText.toString().trim(),
                      startOffset: plainTextBuffer.length,
                    ));
                    plainTextBuffer.write(blockText.toString().trim());
                    blockText.clear();
                  }
                  final headerText = grandchild.text.trim();
                  if (headerText.isNotEmpty) {
                    final levelMatch = RegExp(r'^h([1-6])$').firstMatch(grandchild.localName ?? '');
                    final level = levelMatch != null ? int.parse(levelMatch.group(1)!) : 1;
                    plainTextBuffer.write(headerText);
                    plainTextBuffer.write('\n');
                    blockItems.add(HeaderContent(text: headerText, level: level));
                  }
                }
                // 继续递归处理更深的嵌套
                else {
                  for (final gc in grandchild.nodes) {
                    if (gc is html_dom.Element) {
                      if (gc.localName == 'img') {
                        if (blockText.isNotEmpty) {
                          blockItems.add(TextContent(
                            text: blockText.toString().trim(),
                            startOffset: plainTextBuffer.length,
                          ));
                          blockText.clear();
                        }
                        blockItems.add(ImageContent(source: gc.attributes['src'] ?? ''));
                      } else if (isInlineElement(gc)) {
                        final text = gc.text.trim();
                        if (text.isNotEmpty) {
                          if (blockText.isNotEmpty) {
                            blockText.write(' ');
                          }
                          blockText.write(text);
                        }
                      } else if (isHeaderElement(gc)) {
                        if (blockText.isNotEmpty) {
                          blockItems.add(TextContent(
                            text: blockText.toString().trim(),
                            startOffset: plainTextBuffer.length,
                          ));
                          plainTextBuffer.write(blockText.toString().trim());
                          blockText.clear();
                        }
                        final headerText = gc.text.trim();
                        if (headerText.isNotEmpty) {
                          final levelMatch = RegExp(r'^h([1-6])$').firstMatch(gc.localName ?? '');
                          final level = levelMatch != null ? int.parse(levelMatch.group(1)!) : 1;
                          plainTextBuffer.write(headerText);
                          plainTextBuffer.write('\n');
                          blockItems.add(HeaderContent(text: headerText, level: level));
                        }
                      }
                    } else if (gc is html_dom.Text) {
                      final text = gc.text.trim();
                      if (text.isNotEmpty) {
                        if (blockText.isNotEmpty) {
                          blockText.write(' ');
                        }
                        blockText.write(text);
                      }
                    }
                  }
                }
              } else if (grandchild is html_dom.Text) {
                final text = grandchild.text.trim();
                if (text.isNotEmpty) {
                  if (blockText.isNotEmpty) {
                    blockText.write(' ');
                  }
                  blockText.write(text);
                }
              }
            }
          }
        } else if (child is html_dom.Text) {
          final text = child.text.trim();
          if (text.isNotEmpty) {
            if (blockText.isNotEmpty) {
              blockText.write(' ');
            }
            blockText.write(text);
          }
        }
      }

      // 保存剩余文本
      if (blockText.isNotEmpty) {
        blockItems.add(TextContent(
          text: blockText.toString().trim(),
          startOffset: plainTextBuffer.length,
        ));
      }

      // 将块级元素的所有内容添加到主列表
      bool hasTextContent = false;
      TextContent? lastTextContent;
      for (final blockItem in blockItems) {
        if (blockItem is TextContent) {
          plainTextBuffer.write(blockItem.text);
          items.add(blockItem);
          hasTextContent = true;
          lastTextContent = blockItem;
        } else if (blockItem is ImageContent || blockItem is HeaderContent) {
          items.add(blockItem);
        }
      }

      // 块级元素处理完后添加换行（如果有内容）
      if (hasTextContent && plainTextBuffer.isNotEmpty) {
        // 段落（<p>）添加两个换行符，其他块级元素添加一个换行符
        // 注意：不检查是否已经以 \n 结尾，因为每个块级元素都需要自己的换行符
        final newlines = isParagraph ? '\n\n' : '\n';
        print('[BookLoader] Adding newlines: $newlines (isParagraph=$isParagraph)');
        plainTextBuffer.write(newlines);

        // 将换行符也添加到最后一个 TextContent 中，这样缓存恢复时换行符不会丢失
        if (lastTextContent != null) {
          // 移除最后一个 TextContent 并重新创建，包含换行符
          items.removeLast();
          final textWithNewlines = '${lastTextContent!.text}$newlines';
          items.add(TextContent(
            text: textWithNewlines,
            startOffset: lastTextContent!.startOffset,
          ));
          print('[BookLoader] Updated last TextContent with newlines: "${textWithNewlines.substring(0, textWithNewlines.length > 30 ? 30 : textWithNewlines.length)}..."');
        }
      }
    }

    // 递归遍历 DOM 树
    void traverseNode(html_dom.Node node) {
      if (node is html_dom.Element) {
        if (node.localName == 'img') {
          // 根级别的图片
          final src = node.attributes['src'];
          if (src != null && src.isNotEmpty) {
            items.add(ImageContent(source: src));
          }
        } else if (isHeaderElement(node)) {
          // 标题节点 - 单独处理
          final headerText = node.text.trim();
          if (headerText.isNotEmpty) {
            if (plainTextBuffer.isNotEmpty &&
                plainTextBuffer.toString().endsWith('\n') == false) {
              plainTextBuffer.write('\n');
            }
            final offset = plainTextBuffer.length;
            plainTextBuffer.write(headerText);
            final levelMatch = RegExp(r'^h([1-6])$').firstMatch(node.localName ?? '');
            final level = levelMatch != null ? int.parse(levelMatch.group(1)!) : 1;
            items.add(HeaderContent(text: headerText, level: level));
          }
        } else if (node.localName == 'p') {
          // 段落 - 直接处理
          processBlockElement(node, isParagraph: true);
        } else if (node.localName == 'div') {
          // div - 只递归处理其子节点，不作为块级元素处理
          for (final child in node.nodes) {
            traverseNode(child);
          }
        } else if (isInlineElement(node)) {
          // 行内元素 - 提取文本内容
          final text = node.text.trim();
          if (text.isNotEmpty) {
            if (plainTextBuffer.isNotEmpty &&
                plainTextBuffer.toString().endsWith('\n') == false) {
              plainTextBuffer.write(' ');
            }
            final offset = plainTextBuffer.length;
            plainTextBuffer.write(text);
            items.add(TextContent(text: text, startOffset: offset));
          }
        } else {
          // 其他元素（如嵌套的其他标签），递归处理
          for (final child in node.nodes) {
            traverseNode(child);
          }
        }
      } else if (node is html_dom.Text) {
        // 根级别的文本节点
        final text = node.text.trim();
        if (text.isNotEmpty) {
          if (plainTextBuffer.isNotEmpty &&
              plainTextBuffer.toString().endsWith('\n') == false) {
            plainTextBuffer.write(' ');
          }
          final offset = plainTextBuffer.length;
          plainTextBuffer.write(text);
          items.add(TextContent(text: text, startOffset: offset));
        }
      }
    }

    // 解析所有节点
    traverseNode(document.body ?? document.documentElement!);

    // 压缩多余换行和空格
    String finalText = plainTextBuffer.toString().trim();
    print('[BookLoader] Before regex: ${finalText.substring(0, finalText.length > 100 ? 100 : finalText.length)}');
    // 只压缩连续的 3 个或更多换行符为 2 个（保留段落间的换行）
    finalText = finalText.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    // 去除多余的空格
    finalText = finalText.replaceAll(RegExp(r' {2,}'), ' ');
    // 去除行首行尾的空格
    finalText = finalText.replaceAll(RegExp(r' ?\n ?'), '\n');
    finalText = finalText.trim();
    print('[BookLoader] After regex: ${finalText.substring(0, finalText.length > 100 ? 100 : finalText.length)}');

    return (items: items, plainText: finalText);
  }

  /// 使用 TextPainter 计算文本在指定宽度下的实际行数（带缓存）
  int calculateTextLines(String text, double maxWidth, TextStyle style) {
    if (text.isEmpty) return 0;

    textPainterCache ??= TextPainter(textDirection: TextDirection.ltr);

    // 获取字符平均宽度
    textPainterCache!.text = TextSpan(text: '中', style: style);
    textPainterCache!.layout();
    final charWidth = textPainterCache!.width;

    // 估算行数
    final estimatedCharsPerLine = (maxWidth / charWidth).floor();
    if (estimatedCharsPerLine <= 0) return text.length;

    // 对长文本使用缓存（基于文本长度和宽度的近似值）
    if (text.length >= 500) {
      final cacheKey = '${text.length}_${estimatedCharsPerLine}';
      if (_textLinesCache.containsKey(cacheKey)) {
        return _textLinesCache[cacheKey]!;
      }

      final estimatedLines = (text.length / estimatedCharsPerLine).ceil();

      // 缓存结果（控制缓存大小）
      if (_textLinesCache.length < _maxLinesCacheSize) {
        _textLinesCache[cacheKey] = estimatedLines;
      }

      return estimatedLines;
    }

    // 短文本进行精确计算
    textPainterCache!.text = TextSpan(text: text, style: style);
    textPainterCache!.layout(maxWidth: maxWidth);
    return textPainterCache!.computeLineMetrics().length;
  }

  /// 使用 TextPainter 计算文本在指定宽度下能容纳的最大字符数（带缓存）
  int calculateFitChars(
    String text,
    double maxWidth,
    int maxLines,
    TextStyle style,
  ) {
    if (maxLines <= 0 || text.isEmpty) return 0;

    textPainterCache ??= TextPainter(textDirection: TextDirection.ltr);

    // 获取字符平均宽度
    textPainterCache!.text = TextSpan(text: '中', style: style);
    textPainterCache!.layout();
    final charWidth = textPainterCache!.width;

    // 估算每行字符数
    final estimatedCharsPerLine = (maxWidth / charWidth).floor();
    if (estimatedCharsPerLine <= 0) return 0;

    // 估算总字符数
    final estimatedChars = estimatedCharsPerLine * maxLines;

    // 如果估算值超过文本长度，直接返回
    if (estimatedChars >= text.length) {
      return text.length;
    }

    // 检查缓存（对中等长度文本有效）
    if (text.length >= 1000 && text.length < 5000) {
      final cacheKey = '${text.length}_$estimatedCharsPerLine$maxLines';
      if (_fitCharsCache.containsKey(cacheKey)) {
        return _fitCharsCache[cacheKey]!.clamp(1, text.length);
      }

      // 对长文本直接返回估算值并缓存
      if (_fitCharsCache.length < _maxFitCharsCacheSize) {
        _fitCharsCache[cacheKey] = estimatedChars;
      }

      return estimatedChars.clamp(1, text.length);
    }

    // 对短文本进行精确校正（< 1000 字符）
    if (text.length < 1000) {
      textPainterCache!.text = TextSpan(
        text: text.substring(0, estimatedChars.clamp(0, text.length)),
        style: style,
      );
      textPainterCache!.layout(maxWidth: maxWidth);
      final lineMetrics = textPainterCache!.computeLineMetrics();

      if (lineMetrics.length <= maxLines) {
        // 还有空间，尝试增加 10%
        final increased = (estimatedChars * 1.1).floor().clamp(0, text.length);
        if (increased > estimatedChars) {
          textPainterCache!.text = TextSpan(
            text: text.substring(0, increased),
            style: style,
          );
          textPainterCache!.layout(maxWidth: maxWidth);
          final increasedMetrics = textPainterCache!.computeLineMetrics();

          if (increasedMetrics.length <= maxLines) {
            return increased;
          }
        }
        return estimatedChars;
      } else if (lineMetrics.length > maxLines) {
        // 超出，尝试减少
        final decreased = (estimatedChars * 0.9).floor().clamp(1, text.length);
        textPainterCache!.text = TextSpan(
          text: text.substring(0, decreased),
          style: style,
        );
        textPainterCache!.layout(maxWidth: maxWidth);
        final decreasedMetrics = textPainterCache!.computeLineMetrics();

        if (decreasedMetrics.length <= maxLines) {
          return decreased;
        }
        // 保守估计
        return (estimatedChars * 0.8).floor().clamp(1, text.length);
      }
    }

    // 非常长的文本，直接返回估算值
    return estimatedChars.clamp(1, text.length);
  }

  /// 将章节分割成页面
  List<PageContent> splitChapterIntoPages(
    EpubChapter chapter,
    int chapterIndex,
    double availableHeight,
    double availableWidth,
  ) {
    final pages = <PageContent>[];
    final htmlContent = chapter.htmlContent ?? '';

    final parsed = parseHtmlContent(htmlContent);
    final contentItems = parsed.items;
    final chapterPlainText = parsed.plainText;

    // 保存章节纯文本到映射中，用于缓存恢复
    _chapterPlainTextMap[chapterIndex] = chapterPlainText;

    // 即使没有内容项，也创建一个空页面以保留章节
    if (contentItems.isEmpty) {
      print('[BookLoader] 章节 ${chapter.title} (${chapterIndex}) 没有内容项，创建空页面');
      pages.add(
        PageContent(
          chapterIndex: chapterIndex,
          pageIndexInChapter: 0,
          contentItems: [],
          title: chapter.title,
          chapterPlainText: chapterPlainText,
        ),
      );
      return pages;
    }

    // 使用 TextPainter 精确计算行高
    final textStyle = TextStyle(
      fontSize: fontSize,
      height: 1.5,
      color: Colors.black87,
    );

    // 计算实际行高（只计算一次）
    textPainterCache ??= TextPainter(textDirection: TextDirection.ltr);
    textPainterCache!.text = TextSpan(text: '中', style: textStyle);
    textPainterCache!.layout();
    final lineHeight = textPainterCache!.height;

    // 计算每行平均字符数（只计算一次）
    textPainterCache!.layout(maxWidth: availableWidth);
    final charWidth = textPainterCache!.width;
    final charsPerLine = (availableWidth / charWidth).floor();

    // 每页可用高度（减去 padding）
    final usableHeight = availableHeight - 140 - kToolbarHeight;

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
            chapterPlainText: chapterPlainText,
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
        // 计算当前文本在章节中的起始偏移量
        int currentOffset = item.startOffset;

        while (remaining.isNotEmpty) {
          final remainingHeight = usableHeight - currentPageHeight;
          final remainingLines = (remainingHeight / lineHeight).floor();

          if (remainingLines <= 0) {
            flushCurrentPage();
            continue;
          }

          // 使用估算快速判断，减少精确计算次数
          final estimatedFit = remainingLines * charsPerLine;

          if (estimatedFit >= remaining.length) {
            // 估算可以放下，直接添加
            currentPageItems.add(TextContent(text: remaining, startOffset: currentOffset));

            // 只对短文本进行精确行数计算
            final actualLines = remaining.length < 1000
                ? calculateTextLines(remaining, availableWidth, textStyle)
                : (remaining.length / charsPerLine).ceil();

            currentPageHeight += actualLines * lineHeight;
            remaining = '';
          } else {
            // 需要分割文本，使用优化的计算方法
            final fitChars = calculateFitChars(
              remaining,
              availableWidth,
              remainingLines,
              textStyle,
            );

            if (fitChars <= 0) {
              // 无法分割，强制换页
              flushCurrentPage();
              continue;
            }

            // 尝试在单词边界处截断
            int cut = fitChars;
            if (cut > 0 && cut < remaining.length) {
              final sub = remaining.substring(0, cut);
              final lastSpace = sub.lastIndexOf(' ');
              if (lastSpace > (cut * 0.6).floor()) {
                cut = lastSpace;
              }
            }

            cut = cut.clamp(1, remaining.length);
            String part = remaining.substring(0, cut).trimRight();
            if (part.isEmpty) {
              part = remaining.substring(0, 1);
              cut = 1;
            }

            currentPageItems.add(TextContent(text: part, startOffset: currentOffset));

            // 使用估算计算行数
            final partLines = part.length < 1000
                ? calculateTextLines(part, availableWidth, textStyle)
                : (part.length / charsPerLine).ceil();

            currentPageHeight += partLines * lineHeight;
            currentOffset += part.length;
            remaining = remaining.substring(cut).trimLeft();

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
      } else if (item is HeaderContent) {
        // HeaderContent - 独占一行，根据级别设置不同的行数
        final headerLines = 3; // header 占 3 行
        final headerHeight = headerLines * lineHeight;
        if (currentPageItems.isNotEmpty &&
            currentPageHeight + headerHeight > usableHeight) {
          flushCurrentPage();
        }
        currentPageItems.add(item);
        currentPageHeight += headerHeight;
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

  /// 异步处理页面
  Future<void> processPagesAsync(
    List<EpubChapter> chapters,
    BuildContext context,
  ) async {
    isBackgroundProcessing = false;
    processedChaptersCount = 0;

    final stopwatch = Stopwatch()..start();

    try {
      // 分步骤处理，避免阻塞UI
      await Future.delayed(const Duration(milliseconds: 50));

      final size = MediaQuery.of(context).size;
      windowSize = size;

      final availableHeight = size.height - 20;
      final availableWidth = size.width - 48;

      final pages = <PageContent>[];

      // 添加封面页
      final coverImagePath = getCoverImagePath();
      final coverFile = File(coverImagePath);
      if (await coverFile.exists()) {
        pages.add(
          PageContent(
            chapterIndex: -1,
            pageIndexInChapter: 0,
            contentItems: [CoverContent(imagePath: coverImagePath)],
            title: '封面',
          ),
        );
      }

      // ===== 第一步：优先处理前几个章节，让用户可以立即开始阅读 =====
      final priorityCount = chapters.length < priorityChapterCount
          ? chapters.length
          : priorityChapterCount;

      print('📖 开始处理书籍，共 ${chapters.length} 个章节');
      print('⚡ 开始优先处理前 $priorityCount 个章节...');

      final priorityStopwatch = Stopwatch()..start();

      for (int i = 0; i < priorityCount; i++) {
        final chapter = chapters[i];
        final chapterPages = splitChapterIntoPages(
          chapter,
          i,
          availableHeight,
          availableWidth,
        );
        pages.addAll(chapterPages);
        processedChaptersCount++;

        // 每处理完一个章节，让出时间片给UI
        if (i < priorityCount - 1) {
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }

      // 优先章节处理完成，立即显示内容
      priorityStopwatch.stop();
      print('✅ 优先章节处理完成，耗时 ${priorityStopwatch.elapsedMilliseconds}ms');
      print('📄 已加载 ${pages.length} 页，用户可以开始阅读');

      onLoadingStateChanged?.call(false, true, null);
      onPagesUpdated?.call(
        pages,
        pages.length,
        0,
        pages.isNotEmpty ? pages[0].chapterIndex : 0,
      );

      // ===== 第二步：后台处理剩余章节 =====
      if (chapters.length > priorityCount) {
        isBackgroundProcessing = true;
        final backgroundStopwatch = Stopwatch()..start();
        await processRemainingChaptersInBackground(
          pages,
          chapters,
          priorityCount,
          availableHeight,
          availableWidth,
        );
        backgroundStopwatch.stop();
        print('🎉 后台处理完成，总耗时 ${stopwatch.elapsedMilliseconds}ms');
      } else {
        // 所有章节处理完成，保存缓存
        await savePagesToCache(pages);
        stopwatch.stop();
        print('🎉 所有章节处理完成，总耗时 ${stopwatch.elapsedMilliseconds}ms');
      }
    } catch (e) {
      onLoadingStateChanged?.call(false, false, e.toString());
    }
  }

  /// 后台处理剩余章节
  Future<void> processRemainingChaptersInBackground(
    List<PageContent> existingPages,
    List<EpubChapter> chapters,
    int startIndex,
    double availableHeight,
    double availableWidth,
  ) async {
    print('开始后台处理剩余 ${chapters.length - startIndex} 个章节...');

    try {
      final pages = List<PageContent>.from(existingPages);
      final totalChapters = chapters.length;

      for (int i = startIndex; i < totalChapters; i++) {
        final chapter = chapters[i];

        // 使用微任务来模拟后台处理
        final chapterPages = await Future.microtask(() {
          return splitChapterIntoPages(
            chapter,
            i,
            availableHeight,
            availableWidth,
          );
        });

        pages.addAll(chapterPages);
        processedChaptersCount++;

        // 每处理完几个章节，更新UI并保存进度
        if (i % 3 == 0 || i == totalChapters - 1) {
          onPagesUpdated?.call(
            pages,
            pages.length,
            0,
            pages.isNotEmpty ? pages[0].chapterIndex : 0,
          );
          print('后台处理进度: $processedChaptersCount/$totalChapters 章节');
        }

        // 让出时间片，避免阻塞UI
        await Future.delayed(const Duration(milliseconds: 5));
      }

      // 所有章节处理完成
      isBackgroundProcessing = false;

      onPagesUpdated?.call(
        pages,
        pages.length,
        0,
        pages.isNotEmpty ? pages[0].chapterIndex : 0,
      );
      print('所有章节处理完成，共 ${pages.length} 页');

      // 保存到缓存
      await savePagesToCache(pages);
    } catch (e) {
      print('后台处理章节失败: $e');
      isBackgroundProcessing = false;
    }
  }

  /// 重新处理所有页面（用于窗口大小变化等情况）
  Future<void> processPages(
    List<EpubChapter> chapters,
    BuildContext context,
    int currentPageIndex,
  ) async {
    final size = MediaQuery.of(context).size;
    windowSize = size;

    final availableHeight = size.height - 20;
    final availableWidth = size.width - 48;

    final pages = <PageContent>[];

    // 添加封面页
    final coverImagePath = getCoverImagePath();
    final coverFile = File(coverImagePath);
    if (await coverFile.exists()) {
      pages.add(
        PageContent(
          chapterIndex: -1,
          pageIndexInChapter: 0,
          contentItems: [CoverContent(imagePath: coverImagePath)],
          title: '封面',
        ),
      );
    }

    // 重新处理所有章节
    for (int i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      final chapterPages = splitChapterIntoPages(
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

    onPagesUpdated?.call(
      pages,
      pages.length,
      currentPageIndex.clamp(0, pages.length - 1),
      pages.isNotEmpty ? pages[0].chapterIndex : 0,
    );

    // 窗口大小变化后，清除旧缓存，保存新布局
    await savePagesToCache(pages);
  }

  /// 处理窗口大小变化
  void onWindowResize(
    Size newSize,
    List<EpubChapter> chapters,
    BuildContext context,
  ) {
    if (windowSize == null ||
        (newSize.width != windowSize!.width ||
            newSize.height != windowSize!.height)) {
      windowSize = newSize;
      if (chapters.isNotEmpty) {
        // 防抖处理：取消之前的定时器，避免频繁重绘
        resizeDebounceTimer?.cancel();
        resizeDebounceTimer = Timer(resizeDebounceDuration, () {
          processPages(chapters, context, 0);
        });
      }
    }
  }
}
