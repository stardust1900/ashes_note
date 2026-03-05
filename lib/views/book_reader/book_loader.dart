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
  /// List<{chapterIndex, href, targetId, fullLinkId, startOffset, linkText, isCrossChapter}>
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
        'bookPath': normalizedBookPath,
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

  /// 构建章节文件名到索引的映射
  void _buildChapterFilenameMap(List<EpubChapter> chapters) {
    _chapterFilenameToIndex.clear();

    for (int i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      final contentFileName = chapter.contentFileName;
      final title = chapter.title ?? '';

      if (contentFileName == null || contentFileName.isEmpty) {
        print('[BookLoader] 警告：章节 $i $title 的 contentFileName 为空');
        continue;
      }

      // 处理文件名：提取基础文件名（去除路径前缀）
      String baseFilename = contentFileName;

      // 如果包含路径分隔符，提取最后的部分
      final pathSeparator = contentFileName.contains('\\') ? '\\' : '/';
      final lastSlashIndex = contentFileName.lastIndexOf(pathSeparator);

      if (lastSlashIndex != -1) {
        baseFilename = contentFileName.substring(lastSlashIndex + 1);
      }

      // 映射文件名到章节索引
      _chapterFilenameToIndex[baseFilename] = i;

      print('[BookLoader] 章节 $i ($title) 映射: contentFileName=$contentFileName, baseFilename=$baseFilename');
    }

    print(
      '[BookLoader] 文件名映射完成: ${_chapterFilenameToIndex.entries.map((e) => '${e.key}=${e.value}').join(", ")}',
    );
  }

  /// 解析 HTML 内容（使用 package:html，返回纯文本和带偏移量的内容项）
  ({List<ContentItem> items, String plainText}) parseHtmlContent(
    String html, [
    int chapterIndex = -1,
  ]) {
    final List<ContentItem> items = <ContentItem>[];
    final StringBuffer plainTextBuffer = StringBuffer();

    if (html.isEmpty) return (items: items, plainText: '');

    final String cleanedHtml = html.replaceAll(_spaceTabRegex, ' ').trim();
    final html_dom.Document document = html_parser.parse(cleanedHtml);

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
          name == 'a';
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
          if (child.localName == 'img') {
            // 遇到图片，先保存之前的文本
            if (blockText.isNotEmpty) {
              blockItems.add(
                TextContent(
                  text: blockText.toString().trim(),
                  startOffset: plainTextBuffer.length,
                ),
              );
              blockText.clear();
            }
            blockItems.add(ImageContent(source: child.attributes['src'] ?? ''));
          } else if (isInlineElement(child)) {
            // 检查是否为脚注链接
            if (isFootnoteLink(child) && chapterIndex >= 0) {
              final linkId = child.attributes['id'];
              final href = child.attributes['href']!;
              final linkText = child.text.trim();

              // 检查是否为跨章节链接
              final isCrossChapter =
                  href.contains('/') || href.contains('.html');
              final hashIndex = href.indexOf('#');
              if (hashIndex == -1) {
                // 没有 #，不是脚注链接，当作普通文本处理
                if (linkText.isNotEmpty) {
                  if (blockText.isNotEmpty) {
                    blockText.write(' ');
                  }
                  blockText.write(linkText);
                }
                continue;
              }

              final targetId = href.substring(hashIndex + 1);

              // 生成或使用 linkId
              String? finalLinkId;
              if (linkId != null && linkId.isNotEmpty) {
                finalLinkId = 'chapter$chapterIndex#$linkId';
              } else {
                // 生成默认 ID
                finalLinkId =
                    'chapter$chapterIndex#link_${_globalLinks.length}';
              }

              // 先保存之前的文本
              if (blockText.isNotEmpty) {
                blockItems.add(
                  TextContent(
                    text: blockText.toString().trim(),
                    startOffset: plainTextBuffer.length,
                  ),
                );
                blockText.clear();
              }

              // 记录链接在文本中的位置（此时还没写入 plainTextBuffer）
              final linkOffset = plainTextBuffer.length;

              // 将链接文本添加到 blockText（后续会统一写入 plainTextBuffer）
              if (linkText.isNotEmpty) {
                if (blockText.isNotEmpty) {
                  blockText.write(' ');
                }
                blockText.write(linkText);
              }

              // 计算链接的结束位置
              final linkEndOffset = linkOffset + linkText.length;

              // 创建 LinkContent（只记录位置，不独立渲染）
              blockItems.add(
                LinkContent(
                  id: finalLinkId,
                  text: linkText,
                  startOffset: linkOffset,
                  endOffset: linkEndOffset,
                  href: href, // 使用原始 HTML href
                ),
              );

              // 统一收集所有链接，后续统一处理
              _globalLinks.add({
                'chapterIndex': chapterIndex,
                'href': href,
                'targetId': targetId,
                'fullLinkId': finalLinkId,
                'startOffset': linkOffset,
                'linkText': linkText,
                'isCrossChapter': isCrossChapter,
              });
              print(
                '[BookLoader] 收集链接: chapter=$chapterIndex, href=$href, fullLinkId=$finalLinkId, offset=$linkOffset',
              );
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
          } else if (isHeaderElement(child)) {
            // 块级元素内的标题 - 先保存文本，再处理标题
            if (blockText.isNotEmpty) {
              blockItems.add(
                TextContent(
                  text: blockText.toString().trim(),
                  startOffset: plainTextBuffer.length,
                ),
              );
              plainTextBuffer.write(blockText.toString().trim());
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
                    blockItems.add(
                      TextContent(
                        text: blockText.toString().trim(),
                        startOffset: plainTextBuffer.length,
                      ),
                    );
                    blockText.clear();
                  }
                  blockItems.add(
                    ImageContent(source: grandchild.attributes['src'] ?? ''),
                  );
                } else if (isInlineElement(grandchild)) {
                  // 检查是否为脚注链接
                  if (isFootnoteLink(grandchild)) {
                    // 处理脚注链接
                    final linkId = grandchild.attributes['id'];
                    final href = grandchild.attributes['href']!;
                    final linkText = grandchild.text.trim();
                    final hashIndex = href.indexOf('#');
                    if (hashIndex == -1) {
                      // 没有 #，不是脚注链接，当作普通文本处理
                      if (linkText.isNotEmpty) {
                        if (blockText.isNotEmpty) {
                          blockText.write(' ');
                        }
                        blockText.write(linkText);
                      }
                      continue;
                    }

                    final targetId = href.substring(hashIndex + 1);
                    final isCrossChapter =
                        href.contains('/') || href.contains('.html');

                    // 生成或使用 linkId
                    String? finalLinkId;
                    if (linkId != null && linkId.isNotEmpty) {
                      finalLinkId = 'chapter$chapterIndex#$linkId';
                    } else {
                      // 生成默认 ID
                      finalLinkId =
                          'chapter$chapterIndex#link_${_globalLinks.length}';
                    }

                    // 先保存之前的文本
                    if (blockText.isNotEmpty) {
                      blockItems.add(
                        TextContent(
                          text: blockText.toString().trim(),
                          startOffset: plainTextBuffer.length,
                        ),
                      );
                      blockText.clear();
                    }

                    // 记录链接在文本中的位置（此时还没写入 plainTextBuffer）
                    final linkOffset = plainTextBuffer.length;

                    // 将链接文本添加到 blockText（后续会统一写入 plainTextBuffer）
                    if (linkText.isNotEmpty) {
                      if (blockText.isNotEmpty) {
                        blockText.write(' ');
                      }
                      blockText.write(linkText);
                    }

                    // 计算链接的结束位置
                    final linkEndOffset = linkOffset + linkText.length;

                    // 创建 LinkContent（只记录位置，不独立渲染）
                    blockItems.add(
                      LinkContent(
                        id: finalLinkId,
                        text: linkText,
                        startOffset: linkOffset,
                        endOffset: linkEndOffset,
                        href: href, // 使用原始 HTML href
                      ),
                    );

                    // 统一收集所有链接
                    _globalLinks.add({
                      'chapterIndex': chapterIndex,
                      'href': href,
                      'targetId': targetId,
                      'fullLinkId': finalLinkId,
                      'startOffset': linkOffset,
                      'linkText': linkText,
                      'isCrossChapter': isCrossChapter,
                    });
                    print(
                      '[BookLoader] 收集链接(块级-子节点): chapter=$chapterIndex, href=$href, fullLinkId=$finalLinkId, offset=$linkOffset',
                    );
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
                      if (gc.localName == 'img') {
                        if (blockText.isNotEmpty) {
                          blockItems.add(
                            TextContent(
                              text: blockText.toString().trim(),
                              startOffset: plainTextBuffer.length,
                            ),
                          );
                          blockText.clear();
                        }
                        blockItems.add(
                          ImageContent(source: gc.attributes['src'] ?? ''),
                        );
                      } else if (isInlineElement(gc)) {
                        // 检查是否为脚注链接
                        if (isFootnoteLink(gc) && chapterIndex >= 0) {
                          final linkId = gc.attributes['id'];
                          final href = gc.attributes['href']!;
                          final linkText = gc.text.trim();
                          final hashIndex = href.indexOf('#');
                          if (hashIndex == -1) {
                            // 没有 #，不是脚注链接，当作普通文本处理
                            if (linkText.isNotEmpty) {
                              if (blockText.isNotEmpty) {
                                blockText.write(' ');
                              }
                              blockText.write(linkText);
                            }
                            continue;
                          }

                          final targetId = href.substring(hashIndex + 1);
                          final isCrossChapter =
                              href.contains('/') || href.contains('.html');

                          // 生成或使用 linkId
                          String? finalLinkId;
                          if (linkId != null && linkId.isNotEmpty) {
                            finalLinkId = 'chapter$chapterIndex#$linkId';
                          } else {
                            // 生成默认 ID
                            finalLinkId =
                                'chapter$chapterIndex#link_${_globalLinks.length}';
                          }

                          // 先保存之前的文本
                          if (blockText.isNotEmpty) {
                            blockItems.add(
                              TextContent(
                                text: blockText.toString().trim(),
                                startOffset: plainTextBuffer.length,
                              ),
                            );
                            blockText.clear();
                          }

                          // 记录链接在文本中的位置（此时还没写入 plainTextBuffer）
                          final linkOffset = plainTextBuffer.length;

                          // 将链接文本添加到 blockText（后续会统一写入 plainTextBuffer）
                          if (linkText.isNotEmpty) {
                            if (blockText.isNotEmpty) {
                              blockText.write(' ');
                            }
                            blockText.write(linkText);
                          }

                          // 计算链接的结束位置
                          final linkEndOffset = linkOffset + linkText.length;

                          // 创建 LinkContent（只记录位置，不独立渲染）
                          blockItems.add(
                            LinkContent(
                              id: finalLinkId,
                              text: linkText,
                              startOffset: linkOffset,
                              endOffset: linkEndOffset,
                              href: href, // 使用原始 HTML href
                            ),
                          );

                          // 统一收集所有链接
                          _globalLinks.add({
                            'chapterIndex': chapterIndex,
                            'href': href,
                            'targetId': targetId,
                            'fullLinkId': finalLinkId,
                            'startOffset': linkOffset,
                            'linkText': linkText,
                            'isCrossChapter': isCrossChapter,
                          });
                          print(
                            '[BookLoader] 收集链接(块级-孙节点): chapter=$chapterIndex, href=$href, fullLinkId=$finalLinkId, offset=$linkOffset',
                          );
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
                      } else if (isHeaderElement(gc)) {
                        if (blockText.isNotEmpty) {
                          blockItems.add(
                            TextContent(
                              text: blockText.toString().trim(),
                              startOffset: plainTextBuffer.length,
                            ),
                          );
                          plainTextBuffer.write(blockText.toString().trim());
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
        blockItems.add(
          TextContent(
            text: blockText.toString().trim(),
            startOffset: plainTextBuffer.length,
          ),
        );
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
        } else if (blockItem is LinkContent) {
          // LinkContent 不添加到 items（文本已经包含在前面的 TextContent 中）
          // LinkContent 只作为标记，用于在渲染时应用样式
          // 将 LinkContent 也添加到 items，但渲染时会跳过
          items.add(blockItem);
          // 不写入 plainTextBuffer（文本已在 TextContent 中）
          // 不需要添加换行符,不更新 lastTextContent
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
            plainTextBuffer.write(headerText);
            final levelMatch = RegExp(
              r'^h([1-6])$',
            ).firstMatch(node.localName ?? '');
            final level = levelMatch != null
                ? int.parse(levelMatch.group(1)!)
                : 1;
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
          // 检查是否为脚注链接
          if (isFootnoteLink(node) && chapterIndex >= 0) {
            final linkId = node.attributes['id'];
            final href = node.attributes['href']!;
            final linkText = node.text.trim();
            final hashIndex = href.indexOf('#');
            if (hashIndex == -1) {
              // 没有 #，不是脚注链接，当作普通文本处理
              if (linkText.isNotEmpty) {
                if (plainTextBuffer.isNotEmpty &&
                    plainTextBuffer.toString().endsWith('\n') == false) {
                  plainTextBuffer.write(' ');
                }
                plainTextBuffer.write(linkText);
              }
              return;
            }

            final targetId = href.substring(hashIndex + 1);
            final isCrossChapter = href.contains('/') || href.contains('.html');

            // 生成或使用 linkId
            String? finalLinkId;
            if (linkId != null && linkId.isNotEmpty) {
              finalLinkId = 'chapter$chapterIndex#$linkId';
            } else {
              // 生成默认 ID
              finalLinkId = 'chapter$chapterIndex#link_${_globalLinks.length}';
            }

            if (plainTextBuffer.isNotEmpty &&
                plainTextBuffer.toString().endsWith('\n') == false) {
              plainTextBuffer.write(' ');
            }

            final offset = plainTextBuffer.length;

            // 根级别的链接直接写入 plainTextBuffer
            plainTextBuffer.write(linkText);

            // 计算链接的结束位置
            final linkEndOffset = offset + linkText.length;

            // 添加 LinkContent（只记录位置）
            items.add(
              LinkContent(
                id: finalLinkId,
                text: linkText,
                startOffset: offset,
                endOffset: linkEndOffset,
                href: href,
              ),
            ); // 使用原始 HTML href

            // 统一收集所有链接
            _globalLinks.add({
              'chapterIndex': chapterIndex,
              'href': href,
              'targetId': targetId,
              'fullLinkId': finalLinkId,
              'startOffset': offset,
              'linkText': linkText,
              'isCrossChapter': isCrossChapter,
            });
            print(
              '[BookLoader] 收集链接(traverseNode): chapter=$chapterIndex, href=$href, fullLinkId=$finalLinkId, offset=$offset',
            );
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

    final parsed = parseHtmlContent(htmlContent, chapterIndex);
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
        // LinkContent - 作为文本内容的一部分，单独处理
        final linkText = item.text;
        if (linkText.isNotEmpty) {
          // 估算脚注链接占用的行数（通常很短，假设占用 1 行）
          final linkHeight = lineHeight;
          if (currentPageItems.isNotEmpty &&
              currentPageHeight + linkHeight > usableHeight) {
            flushCurrentPage();
          }
          currentPageItems.add(item);
          currentPageHeight += linkHeight;
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

  /// 统一处理所有链接（包括章节内和跨章节）
  Future<void> _processGlobalLinks(
    List<EpubChapter> chapters,
    List<PageContent> allPages,
  ) async {
    // 先构建章节文件名映射
    _buildChapterFilenameMap(chapters);

    print('[BookLoader] 开始统一处理所有链接，共 ${_globalLinks.length} 个链接');

    // 构建章节到页面的映射，用于快速查找
    final Map<int, List<PageContent>> chapterToPagesMap = {};
    for (final page in allPages) {
      chapterToPagesMap.putIfAbsent(page.chapterIndex, () => []).add(page);
    }

    // 统一处理所有链接，不区分章节内和跨章节
    for (final link in _globalLinks) {
      final chapterIndex = link['chapterIndex'] as int;
      final href = link['href'] as String;
      final targetId = link['targetId'] as String;
      final fullLinkId = link['fullLinkId'] as String;
      final isCrossChapter = link['isCrossChapter'] as bool;

      // 解析 href 找到目标章节索引和页面索引
      int? targetChapterIndex;
      int? targetPageIndexInChapter;
      String? targetExplanation;

      if (isCrossChapter) {
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

        // 查找目标章节的目标元素
        final targetChapter = chapters[targetChapterIndex];
        final htmlContent = targetChapter.htmlContent ?? '';
        if (htmlContent.isNotEmpty) {
          final document = html_parser.parse(htmlContent);
          final targetElement = document.querySelector('[id="$targetId"]');
          if (targetElement != null) {
            targetExplanation = targetElement.text.trim();

            // 计算目标元素的偏移量并查找对应页面
            final targetOffset = _calculateElementOffset(
              document,
              targetElement,
              targetChapter,
            );
            if (targetOffset != null) {
              targetPageIndexInChapter = _findPageIndexByOffset(
                chapterToPagesMap[targetChapterIndex] ?? [],
                targetOffset,
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
        if (chapterIndex >= 0 && chapterIndex < chapters.length) {
          final chapter = chapters[chapterIndex];
          final htmlContent = chapter.htmlContent ?? '';
          if (htmlContent.isNotEmpty) {
            final document = html_parser.parse(htmlContent);
            final targetElement = document.querySelector('[id="$targetId"]');
            if (targetElement != null) {
              targetExplanation = targetElement.text.trim();

              // 计算目标元素的偏移量并查找对应页面
              final targetOffset = _calculateElementOffset(
                document,
                targetElement,
                chapter,
              );
              if (targetOffset != null) {
                targetPageIndexInChapter = _findPageIndexByOffset(
                  chapterToPagesMap[chapterIndex] ?? [],
                  targetOffset,
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
      }

      // 直接更新 pages 中的 LinkContent
      for (final page in allPages) {
        if (page.chapterIndex != chapterIndex) continue;

        for (int i = 0; i < page.contentItems.length; i++) {
          final item = page.contentItems[i];
          if (item is LinkContent && item.id == fullLinkId) {
            // 创建更新后的 LinkContent
            final updatedLink = LinkContent(
              id: item.id,
              text: item.text,
              startOffset: item.startOffset,
              href: item.href,
              pageIndexInChapter: page.pageIndexInChapter,
              targetChapterIndex: targetChapterIndex,
              targetPageIndexInChapter: targetPageIndexInChapter,
              targetExplanation: targetExplanation,
            );
            page.contentItems[i] = updatedLink;
            print(
              '[BookLoader] 更新链接: chapter=$chapterIndex, page=${page.pageIndexInChapter}, linkId=$fullLinkId, targetChapter=$targetChapterIndex, targetPageIndex=$targetPageIndexInChapter',
            );
            break;
          }
        }
      }
    }

    print('[BookLoader] 全局链接处理完成');
  }

  /// 计算元素在章节中的偏移量
  int? _calculateElementOffset(
    html_dom.Document document,
    html_dom.Element targetElement,
    EpubChapter chapter,
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
        if (element.localName == 'img') {
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
  int? _findPageIndexByOffset(List<PageContent> pages, int targetOffset) {
    for (final page in pages) {
      // 检查页面是否包含目标偏移量
      for (final item in page.contentItems) {
        if (item is TextContent) {
          if (targetOffset >= item.startOffset &&
              targetOffset < item.startOffset + item.text.length) {
            return page.pageIndexInChapter;
          }
        }
      }
    }
    return null;
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

    // 重新处理所有链接
    await _processGlobalLinks(chapters, pages);

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
