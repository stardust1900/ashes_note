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
    show
        ContentItem,
        TextContent,
        ImageContent,
        CoverContent,
        HeaderContent,
        LinkContent;

/// 图书加载器 - 负责图书的加载、处理和缓存
class BookLoader {
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

  /// 文本行数缓存（key: 文本长度+宽度, value: 估算行数）
  static final Map<String, int> _textLinesCache = {};
  static const int _maxLinesCacheSize = 500;

  /// 字符容纳数缓存
  static final Map<String, int> _fitCharsCache = {};
  static const int _maxFitCharsCacheSize = 500;

  /// 章节纯文本映射（用于从缓存恢复时提取文本）
  final Map<int, String> _chapterPlainTextMap = {};

  /// 章节文件名映射（用于跨章节链接匹配）
  final Map<String, int> _chapterFilenameToIndex = {};

  /// 全局链接收集（所有章节的所有链接，统一处理）
  /// List<{chapterIndex, pageIndexInChapter, href, targetId, fullLinkId, offset, linkText}>
  final List<Map<String, dynamic>> _globalLinks = [];

  /// 缓存相关
  String? bookCacheKey;

  /// 图书路径
  final String bookPath;

  /// 规范化的图书路径（将 \ 替换为 /）
  late final String normalizedBookPath;

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

  /// 获取所有全局链接
  List<Map<String, dynamic>> get globalLinks => _globalLinks;

  BookLoader({
    required this.bookPath,
    this.onLoadingStateChanged,
    this.onPagesUpdated,
    this.onChaptersUpdated,
  }) {
    normalizedBookPath = bookPath.replaceAll('\\', '/');
  }

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
        return '${normalizedBookPath.hashCode}_${stat.modified.millisecondsSinceEpoch}';
      } catch (statError) {
        // 如果获取文件状态也失败，使用路径哈希
        print('获取文件状态失败，使用路径哈希: $statError');
        return normalizedBookPath.hashCode.toString();
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
    return '$cacheDir/cover_${normalizedBookPath.hashCode}.jpg';
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

  /// 保存页面数据到缓存（优化版：链接单独存储，文本仅记录位置）
  Future<void> savePagesToCache(List<PageContent> pages) async {
    try {
      if (bookCacheKey == null || pages.isEmpty) return;

      final cacheFilePath = await getCacheFilePath();

      // 优化：将 TextContent 转换为 TextContentRef，只存储偏移量
      final optimizedPages = pages.map((p) => p.optimizeForCache()).toList();

      // 收集所有章节的纯文本（转换为 String 键以支持 JSON 序列化）
      // 每个章节只保存一次纯文本，避免重复
      final chapterTexts = <String, String>{};
      for (final page in pages) {
        final chapterIndexStr = page.chapterIndex.toString();
        // 只保存每个章节的第一个页面的纯文本
        if (page.chapterPlainText != null &&
            !chapterTexts.containsKey(chapterIndexStr)) {
          chapterTexts[chapterIndexStr] = page.chapterPlainText!;
        }
      }

      // 收集所有链接并记录所在章节和页面
      // 链接的offset保持为章节内的全局偏移量（与TextContent.startOffset一致）
      final links = <Map<String, dynamic>>[];
      for (final link in _globalLinks) {
        final linkOffset = link['offset'] as int?;

        // 截断 targetExplanation，超过200字符仅保留前200字符
        String? targetExplanation = link['targetExplanation'] as String?;
        if (targetExplanation != null && targetExplanation.length > 200) {
          targetExplanation = targetExplanation.substring(0, 200);
        }
        links.add({
          'id': link['fullLinkId'] as String,
          'text': link['linkText'] as String,
          'targetChapterIndex': link['targetChapterIndex'] as int?,
          'targetPageIndexInChapter': link['targetPageIndexInChapter'] as int?,
          'targetExplanation': targetExplanation,
          'chapterIndex': link['chapterIndex'] as int,
          'pageIndexInChapter': link['pageIndexInChapter'] as int?,
          'offset': linkOffset, // 保持原始的章节内全局偏移量
          'length': link['length'] as int?,
        });
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
        'bookPath': normalizedBookPath,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'windowWidth': windowSize?.width ?? 0,
        'windowHeight': windowSize?.height ?? 0,
        'fontSize': fontSize,
        'chapterTexts': chapterTexts, // 存储章节纯文本
        'links': links, // 单独存储所有链接，记录所在章节和页面
        'pages': optimizedPages.map((p) => p.toJson()).toList(), // 文本仅记录位置
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
      print('📊 缓存统计: 页面数=${pages.length}, 链接数=${links.length}');
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
          print(
            '  当前: ${windowSize!.width}x${windowSize!.height}, 字体: $fontSize',
          );
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
      print('[BookLoader] 加载缓存: 章节文本数量=${chapterTexts.length}');

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
        } else {
          print('[BookLoader] 警告: 章节 $page.chapterIndex 没有纯文本数据');
        }
        return page;
      }).toList();

      // 解析所有 TextContentRef 为 TextContent
      final resolvedPages = pages.map((p) => p.resolveTextRefs()).toList();

      // 从缓存的 links 中重建 _globalLinks
      _globalLinks.clear();
      final linksData = cacheData['links'] as List<dynamic>?;
      if (linksData != null) {
        for (final linkData in linksData) {
          final linkMap = linkData as Map<String, dynamic>;

          // 直接使用缓存中的offset，它已经是章节内的全局偏移量
          _globalLinks.add({
            'chapterIndex': linkMap['chapterIndex'] as int,
            'fullLinkId': linkMap['id'] as String,
            'linkText': linkMap['text'] as String,
            'pageIndexInChapter': linkMap['pageIndexInChapter'] as int?,
            'offset': linkMap['offset'] as int?, // 章节内的全局偏移量
            'length': linkMap['length'] as int?,
            'targetChapterIndex': linkMap['targetChapterIndex'] as int?,
            'targetPageIndexInChapter':
                linkMap['targetPageIndexInChapter'] as int?,
            'targetExplanation': linkMap['targetExplanation'] as String?,
          });
        }
      }
      print('[BookLoader] 从缓存重建 _globalLinks: 数量=${_globalLinks.length}');

      // 调试：统计每个章节每个页面的链接数量
      final linkStats = <String, int>{};
      for (final link in _globalLinks) {
        final chapter = link['chapterIndex'] as int?;
        final page = link['pageIndexInChapter'] as int?;
        final key = 'chapter$chapter-page$page';
        linkStats[key] = (linkStats[key] ?? 0) + 1;
      }
      print('[BookLoader] 链接分布统计（前10个）:');
      int count = 0;
      for (final entry in linkStats.entries) {
        if (count++ >= 10) break;
        print('  ${entry.key}: ${entry.value}个链接');
      }

      print('从缓存加载了 ${resolvedPages.length} 页（链接单独存储版本）');
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
  ({List<ContentItem> items, String plainText}) parseHtmlContent(
    String html, [
    int chapterIndex = -1,
    String? htmlFileName,
  ]) {
    final List<ContentItem> items = <ContentItem>[];
    final StringBuffer plainTextBuffer = StringBuffer();

    if (html.isEmpty) return (items: items, plainText: '');

    final String cleanedHtml = html.replaceAll(_spaceTabRegex, ' ').trim();
    final html_dom.Document document = html_parser.parse(cleanedHtml);

    // 辅助函数：从元素中提取图片源
    String? extractImageSource(html_dom.Element element) {
      if (element.localName == 'img') {
        return element.attributes['src'];
      } else if (element.localName == 'image') {
        // SVG 中的 image 元素，使用 xlink:href 或 href 属性
        // 尝试多种可能的属性名称（包括命名空间变体）
        var xlinkHref = element.attributes['xlink:href'];
        var href = element.attributes['href'];

        // 如果属性名为空，尝试通过 attributes 属性直接访问
        if (xlinkHref == null) {
          // 遍历所有属性，找到匹配的
          for (var attr in element.attributes.entries) {
            final key = attr.key.toString().toLowerCase();
            if (key.contains('xlink') && key.contains('href')) {
              xlinkHref = attr.value.toString();
              print('[BookLoader] 通过属性遍历找到 xlink:href: $xlinkHref');
              break;
            }
          }
        }

        final result = xlinkHref ?? href;
        print(
          '[BookLoader] extractImageSource 结果: $result (xlinkHref=$xlinkHref, href=$href)',
        );
        return result;
      }
      return null;
    }

    // 判断是否为块级元素
    // bool isBlockElement(html_dom.Element node) {
    //   final name = node.localName ?? '';
    //   return name == 'p' || name == 'div' || name == 'br';
    // }

    // 判断是否为标题元素
    bool isHeaderElement(html_dom.Element node) {
      final name = node.localName ?? '';
      return RegExp(r'^h([1-6])$').hasMatch(name);
    }

    // 判断是否为行内元素
    bool isInlineElement(html_dom.Element node) {
      final name = node.localName ?? '';
      return name == 'span' ||
          name == 'i' ||
          name == 'b' ||
          name == 'strong' ||
          name == 'em' ||
          name == 'a' ||
          name == 'sup' ||
          name == 'sub';
    }

    // 判断是否为脚注链接（有 id 和 href）
    bool isFootnoteLink(html_dom.Element node) {
      final href = node.attributes['href'];
      final result =
          node.localName == 'a' && href != null && href.contains('#');
      if (node.localName == 'a') {
        print('[BookLoader] 检查 a 标签: href=$href, isFootnoteLink=$result');
      }
      return result;
    }

    // 处理块级元素内的内容
    void processBlockElement(
      html_dom.Element node, {
      bool isParagraph = false,
    }) {
      final List<ContentItem> blockItems = [];
      StringBuffer blockText = StringBuffer();

      // 遍历子节点
      for (final child in node.nodes) {
        if (child is html_dom.Element) {
          if (htmlFileName!.contains('part0004_split_002')) {
            print(
              '$htmlFileName child $child node.localName:${child.localName}',
            );
          }
          if (child.localName == 'img' || child.localName == 'image') {
            // 遇到图片，先保存之前的文本
            final imageSource = extractImageSource(child);
            if (imageSource != null && imageSource.isNotEmpty) {
              if (blockText.isNotEmpty) {
                blockItems.add(
                  TextContent(
                    text: blockText.toString().trim(),
                    startOffset: plainTextBuffer.length,
                  ),
                );
                blockText.clear();
              }
              blockItems.add(ImageContent(source: imageSource));
            }
          } else if (isInlineElement(child)) {
            // 检查是否为脚注链接
            if (isFootnoteLink(child)) {
              final linkId = child.attributes['id'];
              final href = child.attributes['href']!;
              final linkText = child.text.trim();
              final hashIndex = href.indexOf('#');

              // 生成或使用 linkId
              String? finalLinkId;
              if (linkId != null && linkId.isNotEmpty) {
                finalLinkId = 'chapter$chapterIndex#$linkId';
              } else {
                // 生成默认 ID
                finalLinkId =
                    'chapter$chapterIndex#link_${_globalLinks.length}';
              }

              // 提取 targetId
              final targetId = hashIndex != -1
                  ? href.substring(hashIndex + 1)
                  : '';

              // 章节内脚注链接（有 # 且无跨章节标识）不记录文本到 blockText
              final isFootnote =
                  hashIndex != -1 &&
                  !(href.contains('/') || href.contains('.html'));

              // 计算链接偏移量（在决定是否添加文本之前）
              // 链接文本会被添加到 blockText 的末尾（前面可能需要空格）
              // 所以 offset = plainTextBuffer.length + blockText.length + (前面有文本?1:0)
              final linkOffset = plainTextBuffer.length + blockText.length +
                  (blockText.isNotEmpty ? 1 : 0);

              // 所有链接都添加到 _globalLinks
              _globalLinks.add({
                'chapterIndex': chapterIndex,
                'href': href,
                'targetId': targetId,
                'fullLinkId': finalLinkId,
                'linkText': linkText,
                'linkId': linkId,
                'htmlFileName': htmlFileName, // 记录HTML文件名
                'pageIndexInChapter': null,
                'offset': linkOffset,
                'length': linkText.length,
                'targetChapterIndex': null,
                'targetPageIndexInChapter': null,
                'targetExplanation': null,
              });

              // 所有链接都记录文本（包括脚注链接）
              if (linkText.isNotEmpty) {
                if (blockText.isNotEmpty) {
                  blockText.write(' ');
                }
                blockText.write(linkText);
              }

              print(
                '[BookLoader] 收集链接: chapter=$chapterIndex, href=$href, linkText="$linkText", fullLinkId=$finalLinkId, isFootnote=$isFootnote',
              );
            } else {
              // 普通行内元素 - 检查是否包含脚注链接
              print(
                '[BookLoader] 检查行内元素: ${child.localName}, chapterIndex=$chapterIndex',
              );
              final footnoteLinks = child.querySelectorAll('a[href*="#"]');
              print(
                '[BookLoader] 找到 ${footnoteLinks.length} 个链接在 ${child.localName} 中',
              );
              bool hasFootnoteLink = false;
              for (final link in footnoteLinks) {
                final href = link.attributes['href'] ?? '';

                print('[BookLoader] 检查链接: href=$href');
                if (href.contains('#')) {
                  hasFootnoteLink = true;
                  break;
                }
              }
              if (hasFootnoteLink) {
                print('[BookLoader] ${child.localName} 包含脚注链接，递归处理');
                // 如果包含脚注链接，递归处理子元素中的链接
                for (final grandchild in child.nodes) {
                  if (grandchild is html_dom.Element) {
                    if (isFootnoteLink(grandchild)) {
                      // 处理脚注链接
                      final linkId = grandchild.attributes['id'];
                      final href = grandchild.attributes['href']!;
                      final linkText = grandchild.text.trim();
                      final hashIndex = href.indexOf('#');

                      // 生成或使用 linkId
                      String? finalLinkId;
                      if (linkId != null && linkId.isNotEmpty) {
                        finalLinkId = 'chapter$chapterIndex#$linkId';
                      } else {
                        finalLinkId =
                            'chapter$chapterIndex#link_${_globalLinks.length}';
                      }

                      // 提取 targetId
                      final targetId = hashIndex != -1
                          ? href.substring(hashIndex + 1)
                          : '';

                      // 添加到 _globalLinks
                      // offset 需要考虑 blockText 的长度和可能的空格
                      final linkOffset = plainTextBuffer.length + blockText.length +
                          (blockText.isNotEmpty ? 1 : 0);
                      _globalLinks.add({
                        'chapterIndex': chapterIndex,
                        'href': href,
                        'targetId': targetId,
                        'fullLinkId': finalLinkId,
                        'linkText': linkText,
                        'linkId': linkId,
                        'htmlFileName': htmlFileName, // 记录HTML文件名
                        'pageIndexInChapter': null,
                        'offset': linkOffset,
                        'length': linkText.length,
                        'targetChapterIndex': null,
                        'targetPageIndexInChapter': null,
                        'targetExplanation': null,
                      });
                      print(
                        '[BookLoader] 收集链接(行内元素-子元素): chapter=$chapterIndex, href=$href, linkText="$linkText", fullLinkId=$finalLinkId',
                      );
                    }
                  }
                }
                // 记录文本
                if (blockText.isNotEmpty) {
                  blockText.write(' ');
                }
                blockText.write(child.text.trim());
              } else {
                // 普通行内元素 - 提取文本
                final text = child.text.trim();
                if (text.isNotEmpty) {
                  if (blockText.isNotEmpty) {
                    blockText.write(' ');
                  }
                  blockText.write(text);
                }
              }
            }
          } else if (isHeaderElement(child)) {
            // 块级元素内的标题 - 先保存文本，再处理标题
            if (blockText.isNotEmpty) {
              blockItems.add(
                TextContent(
                  text: blockText.toString().trim(),
                  startOffset: plainTextBuffer.length,
                ),
              );
              // 注意：不在这里写入 plainTextBuffer，而是在遍历 blockItems 时统一写入
              blockText.clear();
            }
            final headerText = child.text.trim();
            if (headerText.isNotEmpty) {
              final levelMatch = RegExp(
                r'^h([1-6])$',
              ).firstMatch(child.localName ?? '');
              final level = levelMatch != null
                  ? int.parse(levelMatch.group(1)!)
                  : 1;
              // Header 文本也添加到 plainText
              plainTextBuffer.write(headerText);
              // plainTextBuffer.write('\n');
              blockItems.add(HeaderContent(text: headerText, level: level));
            }
          }
          // 其他块级元素 - 递归处理，处理其子节点
          else {
            for (final grandchild in child.nodes) {
              if (grandchild is html_dom.Element) {
                if (grandchild.localName == 'img' ||
                    grandchild.localName == 'image') {
                  // 遇到图片，先保存之前的文本
                  final imageSource = extractImageSource(grandchild);
                  if (imageSource != null && imageSource.isNotEmpty) {
                    if (blockText.isNotEmpty) {
                      blockItems.add(
                        TextContent(
                          text: blockText.toString().trim(),
                          startOffset: plainTextBuffer.length,
                        ),
                      );
                      blockText.clear();
                    }
                    blockItems.add(ImageContent(source: imageSource));
                  }
                } else if (isInlineElement(grandchild)) {
                  // 检查是否为脚注链接
                  if (isFootnoteLink(grandchild)) {
                    // 处理脚注链接
                    final linkId = grandchild.attributes['id'];
                    final href = grandchild.attributes['href']!;
                    final linkText = grandchild.text.trim();
                    final hashIndex = href.indexOf('#');

                    // 生成或使用 linkId
                    String? finalLinkId;
                    if (linkId != null && linkId.isNotEmpty) {
                      finalLinkId = 'chapter$chapterIndex#$linkId';
                    } else {
                      // 生成默认 ID
                      finalLinkId =
                          'chapter$chapterIndex#link_${_globalLinks.length}';
                    }

                    // 提取 targetId
                    final targetId = hashIndex != -1
                        ? href.substring(hashIndex + 1)
                        : '';

                    // 所有链接都添加到 _globalLinks
                    // offset 需要考虑 blockText 的长度和可能的空格
                    final linkOffset = plainTextBuffer.length + blockText.length +
                        (blockText.isNotEmpty ? 1 : 0);
                    _globalLinks.add({
                      'chapterIndex': chapterIndex,
                      'href': href,
                      'targetId': targetId,
                      'fullLinkId': finalLinkId,
                      'linkText': linkText,
                      'linkId': linkId,
                      'htmlFileName': htmlFileName, // 记录HTML文件名
                      'pageIndexInChapter': null,
                      'offset': linkOffset,
                      'length': linkText.length,
                      'targetChapterIndex': null,
                      'targetPageIndexInChapter': null,
                      'targetExplanation': null,
                    });

                    // 章节内脚注链接（有 # 且无跨章节标识）不记录文本到 blockText
                    final isFootnote =
                        hashIndex != -1 &&
                        !(href.contains('/') || href.contains('.html'));

                    // 所有链接都记录文本（包括脚注链接）
                    if (linkText.isNotEmpty) {
                      if (blockText.isNotEmpty) {
                        blockText.write(' ');
                      }
                      blockText.write(linkText);
                    }
                    print(
                      '[BookLoader] 收集链接(块级-子节点): chapter=$chapterIndex, href=$href, fullLinkId=$finalLinkId',
                    );
                  } else {
                    // 普通行内元素 - 检查是否包含脚注链接
                    final footnoteLinks = grandchild.querySelectorAll(
                      'a[href*="#"]',
                    );
                    bool hasFootnoteLink = false;
                    for (final link in footnoteLinks) {
                      final href = link.attributes['href'] ?? '';
                      if (href.contains('#') &&
                          !(href.contains('/') || href.contains('.html'))) {
                        hasFootnoteLink = true;
                        break;
                      }
                    }
                    if (hasFootnoteLink) {
                      // 如果包含脚注链接，递归处理子元素中的链接
                      for (final gg in grandchild.nodes) {
                        if (gg is html_dom.Element) {
                          if (isFootnoteLink(gg)) {
                            // 处理脚注链接
                            final linkId = gg.attributes['id'];
                            final href = gg.attributes['href']!;
                            final linkText = gg.text.trim();
                            final hashIndex = href.indexOf('#');

                            // 生成或使用 linkId
                            String? finalLinkId;
                            if (linkId != null && linkId.isNotEmpty) {
                              finalLinkId = 'chapter$chapterIndex#$linkId';
                            } else {
                              finalLinkId =
                                  'chapter$chapterIndex#link_${_globalLinks.length}';
                            }

                            // 提取 targetId
                            final targetId = hashIndex != -1
                                ? href.substring(hashIndex + 1)
                                : '';

                            // 添加到 _globalLinks
                            // offset 需要考虑 blockText 的长度和可能的空格
                            final linkOffset = plainTextBuffer.length + blockText.length +
                                (blockText.isNotEmpty ? 1 : 0);
                            _globalLinks.add({
                              'chapterIndex': chapterIndex,
                              'href': href,
                              'targetId': targetId,
                              'fullLinkId': finalLinkId,
                              'linkText': linkText,
                              'linkId': linkId,
                              'htmlFileName': htmlFileName, // 记录HTML文件名
                              'pageIndexInChapter': null,
                              'offset': linkOffset,
                              'length': linkText.length,
                              'targetChapterIndex': null,
                              'targetPageIndexInChapter': null,
                              'targetExplanation': null,
                            });
                            print(
                              '[BookLoader] 收集链接(块级-子元素-孙元素): chapter=$chapterIndex, href=$href, fullLinkId=$finalLinkId',
                            );
                          }
                        }
                      }
                    } else {
                      // 普通行内元素 - 提取文本
                      final text = grandchild.text.trim();
                      if (text.isNotEmpty) {
                        if (blockText.isNotEmpty) {
                          blockText.write(' ');
                        }
                        blockText.write(text);
                      }
                    }
                  }
                } else if (isHeaderElement(grandchild)) {
                  // 块级元素内的标题 - 先保存文本，再处理标题
                  if (blockText.isNotEmpty) {
                    blockItems.add(
                      TextContent(
                        text: blockText.toString().trim(),
                        startOffset: plainTextBuffer.length,
                      ),
                    );
                    blockText.clear();
                  }
                  final headerText = grandchild.text.trim();
                  if (headerText.isNotEmpty) {
                    final levelMatch = RegExp(
                      r'^h([1-6])$',
                    ).firstMatch(grandchild.localName ?? '');
                    final level = levelMatch != null
                        ? int.parse(levelMatch.group(1)!)
                        : 1;
                    // Header 文本将在遍历 blockItems 时写入 plainTextBuffer
                    // 这里先写入一次确保 offset 正确,稍后在遍历时会再次写入
                    plainTextBuffer.write(headerText);
                    plainTextBuffer.write('\n');
                    blockItems.add(
                      HeaderContent(text: headerText, level: level),
                    );
                  }
                }
                // 继续递归处理更深的嵌套
                else {
                  for (final gc in grandchild.nodes) {
                    if (gc is html_dom.Element) {
                      if (gc.localName == 'img' || gc.localName == 'image') {
                        final imageSource = extractImageSource(gc);
                        if (imageSource != null && imageSource.isNotEmpty) {
                          if (blockText.isNotEmpty) {
                            blockItems.add(
                              TextContent(
                                text: blockText.toString().trim(),
                                startOffset: plainTextBuffer.length,
                              ),
                            );
                            blockText.clear();
                          }
                          blockItems.add(ImageContent(source: imageSource));
                        }
                      } else if (isInlineElement(gc)) {
                        // 检查是否为脚注链接
                        if (isFootnoteLink(gc)) {
                          final linkId = gc.attributes['id'];
                          final href = gc.attributes['href']!;
                          final linkText = gc.text.trim();
                          final hashIndex = href.indexOf('#');

                          // 生成或使用 linkId
                          String? finalLinkId;
                          if (linkId != null && linkId.isNotEmpty) {
                            finalLinkId = 'chapter$chapterIndex#$linkId';
                          } else {
                            // 生成默认 ID
                            finalLinkId =
                                'chapter$chapterIndex#link_${_globalLinks.length}';
                          }

                          // 提取 targetId
                          final targetId = hashIndex != -1
                              ? href.substring(hashIndex + 1)
                              : '';

                          // 所有链接都添加到 _globalLinks
                          // offset 需要考虑 blockText 的长度和可能的空格
                          final linkOffset = plainTextBuffer.length + blockText.length +
                              (blockText.isNotEmpty ? 1 : 0);
                          _globalLinks.add({
                            'chapterIndex': chapterIndex,
                            'href': href,
                            'targetId': targetId,
                            'fullLinkId': finalLinkId,
                            'linkText': linkText,
                            'linkId': linkId,
                            'htmlFileName': htmlFileName, // 记录HTML文件名
                            'pageIndexInChapter': null,
                            'offset': linkOffset,
                            'length': linkText.length,
                            'targetChapterIndex': null,
                            'targetPageIndexInChapter': null,
                            'targetExplanation': null,
                          });

                          // 章节内脚注链接（有 # 且无跨章节标识）不记录文本到 blockText
                          final isFootnote =
                              hashIndex != -1 &&
                              !(href.contains('/') || href.contains('.html'));

                          // 所有链接都记录文本（包括脚注链接）
                          if (linkText.isNotEmpty) {
                            if (blockText.isNotEmpty) {
                              blockText.write(' ');
                            }
                            blockText.write(linkText);
                          }
                          print(
                            '[BookLoader] 收集链接(块级-孙节点): chapter=$chapterIndex, href=$href, fullLinkId=$finalLinkId',
                          );
                        } else {
                          // 普通行内元素 - 检查是否包含脚注链接
                          final footnoteLinks = gc.querySelectorAll(
                            'a[href*="#"]',
                          );
                          bool hasFootnoteLink = false;
                          for (final link in footnoteLinks) {
                            final href = link.attributes['href'] ?? '';
                            if (href.contains('#') &&
                                !(href.contains('/') ||
                                    href.contains('.html'))) {
                              hasFootnoteLink = true;
                              break;
                            }
                          }
                          if (hasFootnoteLink) {
                            // 如果包含脚注链接，递归处理子元素中的链接
                            for (final ggc in gc.nodes) {
                              if (ggc is html_dom.Element) {
                                if (isFootnoteLink(ggc)) {
                                  // 处理脚注链接
                                  final linkId = ggc.attributes['id'];
                                  final href = ggc.attributes['href']!;
                                  final linkText = ggc.text.trim();
                                  final hashIndex = href.indexOf('#');

                                  // 生成或使用 linkId
                                  String? finalLinkId;
                                  if (linkId != null && linkId.isNotEmpty) {
                                    finalLinkId =
                                        'chapter$chapterIndex#$linkId';
                                  } else {
                                    finalLinkId =
                                        'chapter$chapterIndex#link_${_globalLinks.length}';
                                  }

                                  // 提取 targetId
                                  final targetId = hashIndex != -1
                                      ? href.substring(hashIndex + 1)
                                      : '';

                                  // 添加到 _globalLinks
                                  // offset 需要考虑 blockText 的长度和可能的空格
                                  final linkOffset = plainTextBuffer.length + blockText.length +
                                      (blockText.isNotEmpty ? 1 : 0);
                                  _globalLinks.add({
                                    'chapterIndex': chapterIndex,
                                    'href': href,
                                    'targetId': targetId,
                                    'fullLinkId': finalLinkId,
                                    'linkText': linkText,
                                    'linkId': linkId,
                                    'htmlFileName': htmlFileName, // 记录HTML文件名
                                    'pageIndexInChapter': null,
                                    'offset': linkOffset,
                                    'length': linkText.length,
                                    'targetChapterIndex': null,
                                    'targetPageIndexInChapter': null,
                                    'targetExplanation': null,
                                  });
                                  print(
                                    '[BookLoader] 收集链接(块级-子元素-孙元素-曾孙元素): chapter=$chapterIndex, href=$href, fullLinkId=$finalLinkId',
                                  );
                                }
                              }
                            }
                          } else {
                            // 普通行内元素 - 提取文本
                            final text = gc.text.trim();
                            if (text.isNotEmpty) {
                              if (blockText.isNotEmpty) {
                                blockText.write(' ');
                              }
                              blockText.write(text);
                            }
                          }
                        }
                      } else if (isHeaderElement(gc)) {
                        if (blockText.isNotEmpty) {
                          blockItems.add(
                            TextContent(
                              text: blockText.toString().trim(),
                              startOffset: plainTextBuffer.length,
                            ),
                          );
                          // 注意：不在这里写入 plainTextBuffer，而是在遍历 blockItems 时统一写入
                          blockText.clear();
                        }
                        final headerText = gc.text.trim();
                        if (headerText.isNotEmpty) {
                          final levelMatch = RegExp(
                            r'^h([1-6])$',
                          ).firstMatch(gc.localName ?? '');
                          final level = levelMatch != null
                              ? int.parse(levelMatch.group(1)!)
                              : 1;
                          plainTextBuffer.write(headerText);
                          plainTextBuffer.write('\n');
                          blockItems.add(
                            HeaderContent(text: headerText, level: level),
                          );
                        }
                      }
                    } else if (gc is html_dom.Element &&
                        gc.localName == 'svg') {
                      // SVG 元素 - 递归处理查找其中的 image
                      // print('[BookLoader] 遇到 SVG 元素（递归）');
                      void processSvgChildren(html_dom.Node svgNode) {
                        if (svgNode is html_dom.Element) {
                          if (svgNode.localName == 'image') {
                            final imageSource = extractImageSource(svgNode);
                            if (imageSource != null && imageSource.isNotEmpty) {
                              if (blockText.isNotEmpty) {
                                blockItems.add(
                                  TextContent(
                                    text: blockText.toString().trim(),
                                    startOffset: plainTextBuffer.length,
                                  ),
                                );
                                blockText.clear();
                              }
                              blockItems.add(ImageContent(source: imageSource));
                              // print('[BookLoader] 从 SVG 中提取到图片: $imageSource');
                            }
                          } else {
                            for (final child in svgNode.nodes) {
                              processSvgChildren(child);
                            }
                          }
                        }
                      }

                      for (final child in gc.nodes) {
                        processSvgChildren(child);
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
                // 检查 grandchild 是否包含脚注链接
                bool hasFootnoteLinkInGrandchild = false;
                if (grandchild is html_dom.Element) {
                  final footnoteLinks = grandchild.querySelectorAll(
                    'a[href*="#"]',
                  );
                  for (final link in footnoteLinks) {
                    final href = link.attributes['href'] ?? '';
                    if (href.contains('#') &&
                        !(href.contains('/') || href.contains('.html'))) {
                      hasFootnoteLinkInGrandchild = true;
                      break;
                    }
                  }
                }
                if (!hasFootnoteLinkInGrandchild) {
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

      // 先保存剩余文本
      if (blockText.isNotEmpty) {
        blockItems.add(
          TextContent(
            text: blockText.toString().trim(),
            startOffset: plainTextBuffer.length,
          ),
        );
      }

      // 合并连续的 TextContent 以减少碎片化
      final List<ContentItem> mergedBlockItems = [];
      for (final blockItem in blockItems) {
        if (blockItem is TextContent) {
          final lastItem = mergedBlockItems.isNotEmpty
              ? mergedBlockItems.last
              : null;
          if (lastItem is TextContent) {
            // 合并到上一个 TextContent
            final mergedText = '${lastItem.text}${blockItem.text}';
            mergedBlockItems.removeLast();
            mergedBlockItems.add(
              TextContent(text: mergedText, startOffset: lastItem.startOffset),
            );
          } else {
            mergedBlockItems.add(blockItem);
          }
        } else {
          mergedBlockItems.add(blockItem);
        }
      }

      // 将块级元素的所有内容添加到主列表
      bool hasTextContent = false;
      TextContent? lastTextContent;
      for (final blockItem in mergedBlockItems) {
        if (blockItem is TextContent) {
          // 更新 startOffset 为当前的 plainTextBuffer.length
          final updatedTextContent = TextContent(
            text: blockItem.text,
            startOffset: plainTextBuffer.length,
          );
          plainTextBuffer.write(blockItem.text);
          items.add(updatedTextContent);
          hasTextContent = true;
          lastTextContent = updatedTextContent;
        } else if (blockItem is LinkContent) {
          // LinkContent：写入链接文本到 plainTextBuffer，并添加到 items
          // 注意：链接文本应该写入 plainTextBuffer，以保持 offset 的连续性
          // plainTextBuffer.write(blockItem.text);
          print(
            '[BookLoader] LinkContent: offset=${blockItem.offset}, length=${blockItem.length}, text="${blockItem.text}"',
          );
          items.add(blockItem);
        } else if (blockItem is ImageContent || blockItem is HeaderContent) {
          items.add(blockItem);
        }
      }

      // 块级元素处理完后添加换行（如果有内容）
      if (hasTextContent && plainTextBuffer.isNotEmpty) {
        // 段落（<p>）添加两个换行符，其他块级元素添加一个换行符
        // 注意：不检查是否已经以 \n 结尾，因为每个块级元素都需要自己的换行符
        final newlines = isParagraph ? '\n\n' : '\n';
        plainTextBuffer.write(newlines);

        // 将换行符也添加到最后一个 TextContent 中，这样缓存恢复时换行符不会丢失
        if (lastTextContent != null) {
          // 移除最后一个 TextContent 并重新创建，包含换行符
          items.removeLast();
          final textWithNewlines = '${lastTextContent.text}$newlines';
          items.add(
            TextContent(
              text: textWithNewlines,
              startOffset: lastTextContent.startOffset,
            ),
          );
        }
      }
    }

    // 递归遍历 DOM 树
    void traverseNode(html_dom.Node node) {
      if (node is html_dom.Element) {
        if (node.localName == 'img' || node.localName == 'image') {
          // 根级别的图片
          final src = extractImageSource(node);
          if (src != null && src.isNotEmpty) {
            items.add(ImageContent(source: src));
            print('[BookLoader] 提取到图片(traverseNode): src=$src');
          }
        } else if (node.localName == 'svg') {
          // SVG 元素 - 递归处理其子节点，查找其中的 image 元素
          for (final child in node.nodes) {
            if (child is html_dom.Element) {
              if (child.localName == 'image') {}
            }
            traverseNode(child);
          }
        } else if (isHeaderElement(node)) {
          // 标题节点 - 单独处理
          final headerText = node.text.trim();
          if (headerText.isNotEmpty) {
            // 检查是否需要添加换行符
            String headerTextWithNewline = headerText;
            if (plainTextBuffer.isNotEmpty &&
                plainTextBuffer.toString().endsWith('\n') == false) {
              plainTextBuffer.write('\n');
              headerTextWithNewline = '\n$headerText';
            }
            plainTextBuffer.write(headerText);
            final levelMatch = RegExp(
              r'^h([1-6])$',
            ).firstMatch(node.localName ?? '');
            final level = levelMatch != null
                ? int.parse(levelMatch.group(1)!)
                : 1;
            items.add(HeaderContent(text: headerTextWithNewline, level: level));
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
          // 检查是否为脚注链接
          if (isFootnoteLink(node)) {
            final linkId = node.attributes['id'];
            final href = node.attributes['href']!;
            final linkText = node.text.trim();
            final hashIndex = href.indexOf('#');

            // 生成或使用 linkId
            String? finalLinkId;
            if (linkId != null && linkId.isNotEmpty) {
              finalLinkId = 'chapter$chapterIndex#$linkId';
            } else {
              // 生成默认 ID
              finalLinkId = 'chapter$chapterIndex#link_${_globalLinks.length}';
            }

            // 提取 targetId
            final targetId = hashIndex != -1
                ? href.substring(hashIndex + 1)
                : '';

            // 计算链接偏移量
            // 如果 plainTextBuffer 不为空且不以换行符结尾，会先添加一个空格
            final linkOffset = plainTextBuffer.length +
                (plainTextBuffer.isNotEmpty && !plainTextBuffer.toString().endsWith('\n') ? 1 : 0);

            // 所有链接都添加到 _globalLinks
            _globalLinks.add({
              'chapterIndex': chapterIndex,
              'href': href,
              'targetId': targetId,
              'fullLinkId': finalLinkId,
              'linkText': linkText,
              'linkId': linkId,
              'htmlFileName': htmlFileName, // 记录HTML文件名
              'pageIndexInChapter': null,
              'offset': linkOffset,
              'length': linkText.length,
              'targetChapterIndex': null,
              'targetPageIndexInChapter': null,
              'targetExplanation': null,
            });

            // 章节内脚注链接（有 # 且无跨章节标识）
            final isFootnote =
                hashIndex != -1 &&
                !(href.contains('/') || href.contains('.html'));

            // 所有链接都记录文本（包括脚注链接）
            if (linkText.isNotEmpty) {
              if (plainTextBuffer.isNotEmpty &&
                  plainTextBuffer.toString().endsWith('\n') == false) {
                plainTextBuffer.write(' ');
              }
              plainTextBuffer.write(linkText);
              items.add(
                TextContent(
                  text: linkText,
                  startOffset: plainTextBuffer.length - linkText.length,
                ),
              );
            }
          } else {
            // 普通行内元素 - 提取文本内容
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
    // 只压缩连续的 3 个或更多换行符为 2 个（保留段落间的换行）
    finalText = finalText.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    // 去除多余的空格
    finalText = finalText.replaceAll(RegExp(r' {2,}'), ' ');
    // 去除行首行尾的空格
    finalText = finalText.replaceAll(RegExp(r' ?\n ?'), '\n');
    finalText = finalText.trim();

    // 合并所有连续的 TextContent 以减少碎片化
    final List<ContentItem> mergedItems = [];
    for (final item in items) {
      if (item is TextContent) {
        final lastItem = mergedItems.isNotEmpty
            ? mergedItems.last
            : null;
        if (lastItem is TextContent) {
          // 合并到上一个 TextContent
          final mergedText = '${lastItem.text}${item.text}';
          mergedItems.removeLast();
          mergedItems.add(
            TextContent(text: mergedText, startOffset: lastItem.startOffset),
          );
        } else {
          mergedItems.add(item);
        }
      } else {
        mergedItems.add(item);
      }
    }

    return (items: mergedItems, plainText: finalText);
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

    print(
      '[BookLoader] splitChapterIntoPages: chapterIndex=$chapterIndex, chapter.title=${chapter.title}, contentFileName=${chapter.contentFileName}',
    );

    final parsed = parseHtmlContent(
      htmlContent,
      chapterIndex,
      chapter.contentFileName, // 传递HTML文件名
    );
    final contentItems = parsed.items;
    final chapterPlainText = parsed.plainText;

    print(
      '[BookLoader] 章节 $chapterIndex (${chapter.title}): HTML名称=${chapter.contentFileName}, contentItems数量=${contentItems.length}, plainText长度=${chapterPlainText.length}',
    );

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
        print(
          '[BookLoader] 创建页面: chapterIndex=$chapterIndex, pageIndexInChapter=$chapterLocalPageIndex, chapter.title=${chapter.title}',
        );
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
        // item.startOffset 已经是正确的章节内全局偏移量
        // 不需要再调整 leadingSpaces
        String remaining = item.text;
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
            currentPageItems.add(
              TextContent(text: remaining, startOffset: currentOffset),
            );

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

            currentPageItems.add(
              TextContent(text: part, startOffset: currentOffset),
            );

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
      } else if (item is LinkContent) {
        // LinkContent - 只作为标记，不独立占用页面空间
        // 文本已经包含在 TextContent 中，这里只添加标记
        currentPageItems.add(item);
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

  /// 统一处理所有链接（包括章节内和跨章节）
  Future<void> _processGlobalLinks(
    EpubBook epubBook,
    List<PageContent> allPages,
  ) async {
    print('[BookLoader] 开始统一处理所有链接，共 ${_globalLinks.length} 个链接');

    // 构建章节到页面的映射，用于快速查找
    final Map<int, List<PageContent>> chapterToPagesMap = {};
    for (final page in allPages) {
      chapterToPagesMap.putIfAbsent(page.chapterIndex, () => []).add(page);
    }
    final manifestItems = epubBook.schema?.package?.manifest?.items;
    // 统一处理所有链接，不区分章节内和跨章节
    for (final link in _globalLinks) {
      int chapterIndex = link['chapterIndex'] as int;
      final href = link['href'] as String?;
      final targetId = link['targetId'] as String?;
      final fullLinkId = link['fullLinkId'] as String;
      final linkText = link['linkText'] as String?;
      final htmlFileName = link['htmlFileName'] as String?;

      // 使用htmlFileName查找正确的chapterIndex
      if (htmlFileName != null &&
          _chapterFilenameToIndex.containsKey(htmlFileName)) {
        final correctChapterIndex = _chapterFilenameToIndex[htmlFileName];
        if (correctChapterIndex != null &&
            correctChapterIndex != chapterIndex) {
          print(
            '[BookLoader] 修正链接章节索引: fullLinkId=$fullLinkId, htmlFileName=$htmlFileName, 原chapterIndex=$chapterIndex -> 正确chapterIndex=$correctChapterIndex',
          );
          chapterIndex = correctChapterIndex;
          link['chapterIndex'] = correctChapterIndex;

          // 同时更新fullLinkId中的章节索引
          final oldLinkId = fullLinkId;
          final newLinkId = fullLinkId.replaceFirst(
            RegExp(r'chapter\d+'),
            'chapter$correctChapterIndex',
          );
          if (newLinkId != oldLinkId) {
            link['fullLinkId'] = newLinkId;
            print('[BookLoader] 更新链接ID: $oldLinkId -> $newLinkId');
          }
        }
      }

      print(
        '[BookLoader] 处理链接: fullLinkId=${link['fullLinkId']}, chapterIndex=$chapterIndex, linkText="$linkText", htmlFileName=$htmlFileName',
      );

      // 解析 href 找到目标章节索引和页面索引
      int? targetChapterIndex;
      int? targetPageIndexInChapter;
      String? targetExplanation;

      // 如果 href 为 null，跳过处理（从缓存恢复的链接已有完整信息）
      if (href == null) {
        continue;
      }

      // 判断是否跨章节（检查 href 是否包含文件名）
      final isCrossChapterLink = href.contains('/') || href.contains('.html');

      if (isCrossChapterLink) {
        // 跨章节链接：解析 href 格式: part0004_split_004.html#note1n
        final hashIndex = href.indexOf('#');
        if (hashIndex == -1) continue;

        final chapterFilename = href.substring(0, hashIndex);

        print(
          '[BookLoader] 处理跨章节链接: chapter=$chapterIndex, href=$href, chapterFilename=$chapterFilename',
        );

        // 使用预构建的文件名映射查找目标章节
        targetChapterIndex = _chapterFilenameToIndex[chapterFilename];

        if (targetChapterIndex == null) {
          print('[BookLoader] 警告：找不到章节文件 $chapterFilename 对应的索引，href=$href');
          print(
            '[BookLoader] 已映射的文件名: ${_chapterFilenameToIndex.keys.join(", ")}',
          );
          continue;
        }

        // 查找对应的manifest item
        final manifestItem = manifestItems!
            .cast<EpubManifestItem?>()
            .firstWhere((item) {
              final itemHref = item?.href;
              return itemHref != null && itemHref.contains(chapterFilename);
            }, orElse: () => null);

        // 获取HTML内容
        final htmlContent = manifestItem?.href != null
            ? epubBook.content?.html[manifestItem!.href]?.content
            : null;
        if (htmlContent != null && htmlContent.isNotEmpty) {
          final document = html_parser.parse(htmlContent);
          final targetElement = document.querySelector('[id="$targetId"]');
          if (targetElement != null) {
            targetExplanation = targetElement.text.trim();

            // 计算目标元素的偏移量并查找对应页面
            final targetOffset = _calculateElementOffset(
              document,
              targetElement,
            );
            if (targetOffset != null) {
              targetPageIndexInChapter = _findPageIndexByOffset(
                chapterToPagesMap[targetChapterIndex] ?? [],
                targetOffset,
                linkText: targetExplanation,
              );
              print(
                '[BookLoader] 跨章节链接找到目标: chapter=$chapterIndex -> $targetChapterIndex, targetId=$targetId, targetOffset=$targetOffset, targetPageIndex=$targetPageIndexInChapter',
              );
            } else {
              print(
                '[BookLoader] 跨章节链接无法计算目标偏移: chapter=$chapterIndex -> $targetChapterIndex, targetId=$targetId',
              );
            }
          } else {
            print(
              '[BookLoader] 跨章节链接未找到目标: chapter=$chapterIndex -> $targetChapterIndex, targetId=$targetId, htmlContent长度=${htmlContent.length}',
            );
          }
        }
      } else {
        // 章节内链接
        targetChapterIndex = chapterIndex;

        // 查找对应的manifest item
        final manifestItem = htmlFileName != null
            ? manifestItems!.cast<EpubManifestItem?>().firstWhere((item) {
                final itemHref = item?.href;
                return itemHref != null && itemHref.contains(htmlFileName);
              }, orElse: () => null)
            : null;

        // 获取HTML内容
        final htmlContent = manifestItem?.href != null
            ? epubBook.content?.html[manifestItem!.href]?.content
            : null;

        if (htmlContent != null && htmlContent.isNotEmpty) {
          final document = html_parser.parse(htmlContent);
          final targetElement = document.querySelector('[id="$targetId"]');
          if (targetElement != null) {
            targetExplanation = targetElement.text.trim();

            // 计算目标元素的偏移量并查找对应页面
            final targetOffset = _calculateElementOffset(
              document,
              targetElement,
            );
            if (targetOffset != null) {
              targetPageIndexInChapter = _findPageIndexByOffset(
                chapterToPagesMap[chapterIndex] ?? [],
                targetOffset,
                linkText: targetExplanation,
              );
              print(
                '[BookLoader] 章节内链接找到目标: chapter=$chapterIndex, targetId=$targetId, targetOffset=$targetOffset, targetPageIndex=$targetPageIndexInChapter',
              );
            } else {
              print(
                '[BookLoader] 章节内链接无法计算目标偏移: chapter=$chapterIndex, targetId=$targetId',
              );
            }
          } else {
            print(
              '[BookLoader] 章节内链接未找到目标: chapter=$chapterIndex, targetId=$targetId, htmlContent长度=${htmlContent.length}',
            );
          }
        }
      }

      // 更新 _globalLinks 中的链接信息
      link['targetChapterIndex'] = targetChapterIndex;
      link['targetPageIndexInChapter'] = targetPageIndexInChapter;
      link['targetExplanation'] = targetExplanation;

      // 计算链接所在页面的索引（使用链接文本进行匹配）
      // 首先在原chapterIndex的页面中查找
      final linkOffset = link['offset'] as int?;
      int? actualChapterIndex = chapterIndex;
      int? linkPageIndex;

      if (linkOffset != null && linkText != null) {
        // 先在原chapterIndex的页面中查找
        linkPageIndex = _findPageIndexByOffset(
          chapterToPagesMap[chapterIndex] ?? [],
          linkOffset,
          linkText: linkText,
        );

        // 如果在原章节中找不到，说明链接可能属于其他章节
        // 在所有页面中搜索包含此链接文本的页面
        if (linkPageIndex == null) {
          print('[BookLoader] 在章节$chapterIndex中找不到链接"$linkText"，在所有页面中搜索...');

          for (final page in allPages) {
            for (final item in page.contentItems) {
              if (item is TextContent && item.text.contains(linkText)) {
                actualChapterIndex = page.chapterIndex;
                linkPageIndex = page.pageIndexInChapter;
                print(
                  '[BookLoader] 找到链接"$linkText"在章节$actualChapterIndex第${linkPageIndex}页',
                );
                break;
              }
            }
            if (linkPageIndex != null) break;
          }
        }

        // 更新链接的实际章节索引
        if (actualChapterIndex != chapterIndex) {
          print(
            '[BookLoader] 修正链接章节: fullLinkId=$fullLinkId, 原chapterIndex=$chapterIndex -> 实际chapterIndex=$actualChapterIndex',
          );
          link['chapterIndex'] = actualChapterIndex;
        }

        link['pageIndexInChapter'] = linkPageIndex;

        // 调试：打印链接的页面索引计算结果
        if (actualChapterIndex == 1 && linkPageIndex != null) {
          print(
            '[BookLoader] 第1章链接页面索引: fullLinkId=$fullLinkId, linkText="$linkText", linkOffset=$linkOffset, pageIndex=$linkPageIndex',
          );
        }
      }

      if (targetExplanation != null) {
        print(
          '[BookLoader] 更新链接信息: fullLinkId=$fullLinkId, pageIndexInChapter=${link['pageIndexInChapter']}, targetChapter=$targetChapterIndex, targetPageIndex=$targetPageIndexInChapter, targetExplanation=${targetExplanation.length > 20 ? targetExplanation.substring(0, 20) : targetExplanation}...',
        );
      } else {
        print(
          '[BookLoader] 更新链接信息: fullLinkId=$fullLinkId, pageIndexInChapter=${link['pageIndexInChapter']}, targetChapter=$targetChapterIndex, targetPageIndex=$targetPageIndexInChapter, targetExplanation=null',
        );
      }
    }

    print('[BookLoader] 全局链接处理完成');
  }

  /// 计算元素在章节中的偏移量
  int? _calculateElementOffset(
    html_dom.Document document,
    html_dom.Element targetElement,
  ) {
    // 遍历文档，计算目标元素之前的文本长度
    int offset = 0;
    bool foundTarget = false;

    void traverse(html_dom.Node node) {
      if (foundTarget) return;

      if (node == targetElement) {
        foundTarget = true;
        return;
      }

      if (node.nodeType == html_dom.Node.TEXT_NODE) {
        final text = node.text?.trim();
        if (text != null && text.isNotEmpty) {
          offset += text.length;
          // 节点之间的空格
          offset += 1;
        }
      } else if (node.nodeType == html_dom.Node.ELEMENT_NODE) {
        final element = node as html_dom.Element;
        // 跳过某些元素（如图片）
        if (element.localName == 'img' || element.localName == 'image') {
          return;
        }
        // 遍历子节点
        for (final child in element.nodes) {
          traverse(child);
        }
      }
    }

    if (document.documentElement != null) {
      traverse(document.documentElement!);
    }
    return foundTarget ? offset : null;
  }

  /// 根据偏移量查找页面索引
  int? _findPageIndexByOffset(
    List<PageContent> pages,
    int targetOffset, {
    String? linkText,
  }) {
    if (pages.isEmpty) {
      print('[BookLoader] _findPageIndexByOffset: 页面列表为空');
      return null;
    }

    // 如果提供了linkText，优先使用文本匹配
    if (linkText != null && linkText.isNotEmpty) {
      for (final page in pages) {
        for (final item in page.contentItems) {
          if (item is TextContent && item.text.contains(linkText)) {
            print(
              '[BookLoader] 通过文本找到页面: linkText="$linkText", page=${page.pageIndexInChapter}',
            );
            return page.pageIndexInChapter;
          }
        }
      }
      // print('[BookLoader] 未通过文本找到页面: linkText="$linkText"，尝试使用offset');
    }

    // 使用offset匹配（允许±2个字符的偏差，因为换行符可能导致轻微差异）
    for (final page in pages) {
      // 检查页面是否包含目标偏移量
      for (final item in page.contentItems) {
        if (item is TextContent) {
          final tolerance = 2; // 允许2个字符的偏差
          if (targetOffset >= item.startOffset - tolerance &&
              targetOffset < item.startOffset + item.text.length + tolerance) {
            print(
              '[BookLoader] 通过offset找到页面: targetOffset=$targetOffset, page=${page.pageIndexInChapter}, item.startOffset=${item.startOffset}, item.text.length=${item.text.length}',
            );
            return page.pageIndexInChapter;
          }
        }
      }
    }
    print(
      '[BookLoader] 未找到目标偏移量对应的页面: targetOffset=$targetOffset, 总页面数=${pages.length}',
    );
    // 打印所有页面的offset范围以便调试
    for (final page in pages) {
      final textItems = page.contentItems.whereType<TextContent>().toList();
      if (textItems.isNotEmpty) {
        final firstOffset = textItems.first.startOffset;
        final lastItem = textItems.last;
        final lastOffset = lastItem.startOffset + lastItem.text.length;
        print(
          '[BookLoader] 页面${page.pageIndexInChapter}: offset范围[$firstOffset, $lastOffset)',
        );
      }
    }
    // 如果没有找到，返回第一页作为默认值
    return pages.first.pageIndexInChapter;
  }

  String? getBaseFileName(String? contentFileName) {
    // 处理文件名：提取基础文件名（去除路径前缀）
    String? baseFilename = contentFileName;

    // 如果包含路径分隔符，提取最后的部分
    final pathSeparator = contentFileName!.contains('\\') ? '\\' : '/';
    final lastSlashIndex = contentFileName.lastIndexOf(pathSeparator);

    if (lastSlashIndex != -1) {
      baseFilename = contentFileName.substring(lastSlashIndex + 1);
    }
    return baseFilename;
  }

  /// 重新处理所有页面（用于窗口大小变化等情况）
  Future<void> processPages(
    EpubBook epubBook,
    BuildContext context,
    int currentPageIndex,
  ) async {
    final size = MediaQuery.of(context).size;
    windowSize = size;

    final availableHeight = size.height - 20;
    final availableWidth = size.width - 48;

    final pages = <PageContent>[];

    // 清空全局链接，重新收集
    _globalLinks.clear();
    _chapterFilenameToIndex.clear();

    final spineItems = epubBook.schema?.package?.spine?.items;
    final manifestItems = epubBook.schema?.package?.manifest?.items;

    // 添加封面页
    // final coverImagePath = getCoverImagePath();
    // final coverFile = File(coverImagePath);
    // if (await coverFile.exists()) {
    //   pages.add(
    //     PageContent(
    //       chapterIndex: -1,
    //       pageIndexInChapter: 0,
    //       contentItems: [CoverContent(imagePath: coverImagePath)],
    //       title: '封面',
    //     ),
    //   );
    // }

    if (spineItems == null || manifestItems == null) {
      print('[BookLoader] spine 或 manifest 为空，无法处理页面');
      return;
    }

    // 构建 contentFileName 到 chapter 的映射
    final Map<String, EpubChapter> fileNameToChapterMap = {};
    final List<EpubChapter> chapters = flattenChapters(epubBook.chapters);

    for (int i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      final contentFileName = chapter.contentFileName;
      if (contentFileName != null && contentFileName.isNotEmpty) {
        fileNameToChapterMap[contentFileName] = chapter;
      }
      // 处理文件名：提取基础文件名（去除路径前缀）
      String? baseFilename = getBaseFileName(contentFileName);
      // 映射文件名到章节索引
      _chapterFilenameToIndex[baseFilename!] = i;
    }

    // print('[BookLoader] 章节文件映射: ${fileNameToChapterMap.keys.join(", ")}');

    // 非章节页面索引计数器，从 -1 开始递增
    int nonChapterPageCounter = -1;

    // 遍历 spine 处理所有页面
    for (int i = 0; i < spineItems.length; i++) {
      final spineItem = spineItems[i];
      final idRef = spineItem.idRef;

      if (idRef == null) {
        print('[BookLoader] spine item $i 缺少 idRef，跳过');
        continue;
      }

      // 在 manifest 中查找对应的 item
      final manifestItem = manifestItems.cast<EpubManifestItem?>().firstWhere(
        (item) => item?.id == idRef,
        orElse: () => null,
      );

      if (manifestItem == null) {
        print('[BookLoader] 在 manifest 中找不到 idRef=$idRef 的项，跳过');
        continue;
      }

      final href = manifestItem.href;
      if (href == null) {
        print('[BookLoader] manifest item id=$idRef 缺少 href，跳过');
        continue;
      }
      // 检查该文件是否有对应的 chapter
      final chapter = fileNameToChapterMap[href];

      if (chapter != null) {
        // 有对应的 chapter，按原方式处理
        String? baseFilename = getBaseFileName(chapter.contentFileName);
        final chapterIndex = _chapterFilenameToIndex[baseFilename];

        print(
          '[BookLoader] 处理章节: spine=$i, href=$href, chapter.title=${chapter.title}, chapterIndex=$chapterIndex',
        );
        final chapterPages = splitChapterIntoPages(
          chapter,
          chapterIndex!,
          availableHeight,
          availableWidth,
        );
        pages.addAll(chapterPages);
        print(
          '[BookLoader] 处理章节完成: spine=$i, href=$href, chapterIndex=$chapterIndex, 生成页面数=${chapterPages.length}',
        );
      } else {
        // 没有对应的 chapter，从 epubBook.content.html 获取内容
        final htmlContent = epubBook.content?.html[href]?.content;
        if (htmlContent != null && htmlContent.isNotEmpty) {
          // 创建临时 chapter 用于处理
          final tempChapter = EpubChapter(
            title: manifestItem.id ?? '页面 ${i + 1}',
            contentFileName: href,
            htmlContent: htmlContent,
          );

          // 非章节页面使用负数索引，避免与章节索引冲突
          // 使用单独计数器，使非章节页面索引连续递增：-1, -2, -3...
          final nonChapterIndex = nonChapterPageCounter;

          final chapterPages = splitChapterIntoPages(
            tempChapter,
            nonChapterIndex,
            availableHeight,
            availableWidth,
          );
          pages.addAll(chapterPages);
          print(
            '[BookLoader] 处理非章节页面: spine=$i, href=$href, chapterIndex=$nonChapterIndex, htmlContent长度=${htmlContent.length}',
          );
          // 处理文件名：提取基础文件名（去除路径前缀）
          String? baseFilename = href;

          // 如果包含路径分隔符，提取最后的部分
          final pathSeparator = href.contains('\\') ? '\\' : '/';
          final lastSlashIndex = href.lastIndexOf(pathSeparator);

          if (lastSlashIndex != -1) {
            baseFilename = href.substring(lastSlashIndex + 1);
          }

          _chapterFilenameToIndex[baseFilename] = nonChapterIndex;

          // 递增非章节页面计数器
          nonChapterPageCounter--;
        } else {
          print('[BookLoader] 警告：找不到 HTML 内容，href=$href');
        }
      }

      // 每处理几个页面让出时间片
      if (i % 5 == 0) {
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }

    // 重新处理所有链接（在 onPagesUpdated 之前）
    await _processGlobalLinks(epubBook, pages);

    // 通知UI更新（此时链接已经处理完成）
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
  void onWindowResize(Size newSize, EpubBook epubBook, BuildContext context) {
    if (windowSize == null ||
        (newSize.width != windowSize!.width ||
            newSize.height != windowSize!.height)) {
      windowSize = newSize;
      // 防抖处理：取消之前的定时器，避免频繁重绘
      resizeDebounceTimer?.cancel();
      resizeDebounceTimer = Timer(resizeDebounceDuration, () {
        processPages(epubBook, context, 0);
      });
    }
  }
}
