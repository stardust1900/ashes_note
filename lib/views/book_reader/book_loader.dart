import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:epub_plus/epub_plus.dart';
import 'package:image/image.dart' as img show encodeJpg;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;
import '../../utils/prefs_util.dart';
import '../../utils/const.dart' show BookReaderConstants, PrefKeys;
import '../../models/book_reader/page_content.dart';
import '../../models/book_reader/content_item.dart'
    show
        ContentItem,
        TextContent,
        ImageContent,
        CoverContent,
        HeaderContent,
        LinkContent;

/// 批量解析入参
class _ParseHtmlBatchTask {
  final List<_ParseHtmlTask> tasks;
  const _ParseHtmlBatchTask(this.tasks);
}

/// 批量解析（单个 Isolate 处理所有章节，避免重复启动开销）
List<_ParseHtmlResult> _parseHtmlBatchIsolate(_ParseHtmlBatchTask batch) {
  return batch.tasks.map((t) => _parseHtmlIsolate(t)).toList();
}

/// Isolate 入参：HTML 解析任务
class _ParseHtmlTask {
  final String html;
  final int chapterIndex;
  final String? htmlFileName;
  const _ParseHtmlTask(this.html, this.chapterIndex, this.htmlFileName);
}

/// Isolate 出参：解析结果
class _ParseHtmlResult {
  final List<Map<String, dynamic>> items; // ContentItem 序列化为 Map
  final String plainText;
  final List<Map<String, dynamic>> links;
  const _ParseHtmlResult(this.items, this.plainText, this.links);
}

/// 顶层函数，供 compute() 调用（不能是实例方法）
_ParseHtmlResult _parseHtmlIsolate(_ParseHtmlTask task) {
  final result = _parseHtmlStatic(
    task.html,
    task.chapterIndex,
    task.htmlFileName,
  );
  return result;
}

/// 静态 HTML 解析（不依赖 BookLoader 实例状态，可在 Isolate 中运行）
_ParseHtmlResult _parseHtmlStatic(
  String html,
  int chapterIndex,
  String? htmlFileName,
) {
  final RegExp _spaceTabRegex = RegExp(r'[ \t]+');

  final List<Map<String, dynamic>> itemMaps = [];
  final List<Map<String, dynamic>> links = [];
  final StringBuffer plainTextBuffer = StringBuffer();

  if (html.isEmpty) return _ParseHtmlResult([], '', []);

  final cleanedHtml = html.replaceAll(_spaceTabRegex, ' ').trim();
  final document = html_parser.parse(cleanedHtml);

  String? extractImageSource(html_dom.Element element) {
    if (element.localName == 'img') return element.attributes['src'];
    if (element.localName == 'image') {
      var xlinkHref = element.attributes['xlink:href'];
      if (xlinkHref == null) {
        for (var attr in element.attributes.entries) {
          final key = attr.key.toString().toLowerCase();
          if (key.contains('xlink') && key.contains('href')) {
            xlinkHref = attr.value.toString();
            break;
          }
        }
      }
      return xlinkHref ?? element.attributes['href'];
    }
    return null;
  }

  bool isHeaderElement(html_dom.Element node) =>
      RegExp(r'^h([1-6])$').hasMatch(node.localName ?? '');

  bool isInlineElement(html_dom.Element node) {
    final name = node.localName ?? '';
    return ['span', 'i', 'b', 'strong', 'em', 'a', 'sup', 'sub'].contains(name);
  }

  bool isFootnoteLink(html_dom.Element node) {
    final href = node.attributes['href'];
    return node.localName == 'a' && href != null && href.contains('#');
  }

  void addLink(
    String href,
    String? linkId,
    String linkText,
    String? finalLinkId,
  ) {
    final hashIndex = href.indexOf('#');
    final targetId = hashIndex != -1 ? href.substring(hashIndex + 1) : '';
    final offset = plainTextBuffer.length;
    links.add({
      'chapterIndex': chapterIndex,
      'href': href,
      'targetId': targetId,
      'fullLinkId': finalLinkId ?? 'chapter$chapterIndex#link_${links.length}',
      'linkText': linkText,
      'linkId': linkId,
      'htmlFileName': htmlFileName,
      'pageIndexInChapter': null,
      'offset': offset,
      'length': linkText.length,
      'targetChapterIndex': null,
      'targetPageIndexInChapter': null,
      'targetExplanation': null,
    });
  }

  void addLinkAt(
    String href,
    String? linkId,
    String linkText,
    String? finalLinkId,
    int offset,
  ) {
    final hashIndex = href.indexOf('#');
    final targetId = hashIndex != -1 ? href.substring(hashIndex + 1) : '';
    links.add({
      'chapterIndex': chapterIndex,
      'href': href,
      'targetId': targetId,
      'fullLinkId': finalLinkId ?? 'chapter$chapterIndex#link_${links.length}',
      'linkText': linkText,
      'linkId': linkId,
      'htmlFileName': htmlFileName,
      'pageIndexInChapter': null,
      'offset': offset,
      'length': linkText.length,
      'targetChapterIndex': null,
      'targetPageIndexInChapter': null,
      'targetExplanation': null,
    });
  }

  void addText(String text, {bool isParagraph = false}) {
    if (text.isEmpty) return;
    final offset = plainTextBuffer.length;
    plainTextBuffer.write(text);
    itemMaps.add({'type': 'text', 'text': text, 'startOffset': offset});
  }

  void addImage(String source) {
    itemMaps.add({'type': 'image', 'source': source});
  }

  void addHeader(String text, int level) {
    itemMaps.add({'type': 'header', 'text': text, 'level': level});
  }

  void processNode(html_dom.Node node) {
    if (node is html_dom.Element) {
      final name = node.localName ?? '';
      if (name == 'br') {
        if (plainTextBuffer.isNotEmpty) {
          plainTextBuffer.write('\n');
          if (itemMaps.isNotEmpty && itemMaps.last['type'] == 'text') {
            itemMaps.last['text'] = '${itemMaps.last['text']}\n';
          }
        }
      } else if (name == 'img' || name == 'image') {
        final src = extractImageSource(node);
        if (src != null && src.isNotEmpty) addImage(src);
      } else if (isHeaderElement(node)) {
        final text = node.text.trim();
        if (text.isNotEmpty) {
          final level = int.parse(RegExp(r'(\d)').firstMatch(name)!.group(1)!);
          plainTextBuffer.write(text);
          addHeader(text, level);
        }
      } else if (name == 'p') {
        // paragraph
        final buf = StringBuffer();
        void collectText(html_dom.Node n) {
          if (n is html_dom.Text) {
            final t = n.text.trim();
            if (t.isNotEmpty) {
              if (buf.isNotEmpty) buf.write(' ');
              buf.write(t);
            }
          } else if (n is html_dom.Element) {
            if (n.localName == 'img' || n.localName == 'image') {
              if (buf.isNotEmpty) {
                addText(buf.toString());
                buf.clear();
              }
              final src = extractImageSource(n);
              if (src != null) addImage(src);
            } else if (isFootnoteLink(n)) {
              final href = n.attributes['href']!;
              final linkId = n.attributes['id'];
              // 链接文本可能在子元素（如 <sup>）里
              final lt = n.text.trim();
              final fid = linkId != null && linkId.isNotEmpty
                  ? 'chapter$chapterIndex#$linkId'
                  : 'chapter$chapterIndex#link_${links.length}';
              // offset = plainTextBuffer 已写入的 + buf 中待写入的 + 可能的空格
              final linkOffset =
                  plainTextBuffer.length +
                  buf.length +
                  (buf.isNotEmpty && lt.isNotEmpty ? 1 : 0);
              addLinkAt(href, linkId, lt, fid, linkOffset);
              if (lt.isNotEmpty) {
                if (buf.isNotEmpty) buf.write(' ');
                buf.write(lt);
              }
            } else {
              for (final c in n.nodes) collectText(c);
            }
          }
        }

        for (final c in node.nodes) collectText(c);
        if (buf.isNotEmpty) {
          final text = '${buf.toString()}\n\n';
          addText(text);
        }
      } else if (name == 'div') {
        for (final c in node.nodes) processNode(c);
        // div 结束后加换行，确保块级分隔
        if (plainTextBuffer.isNotEmpty &&
            !plainTextBuffer.toString().endsWith('\n')) {
          plainTextBuffer.write('\n');
          if (itemMaps.isNotEmpty && itemMaps.last['type'] == 'text') {
            itemMaps.last['text'] = '${itemMaps.last['text']}\n';
          }
        }
      } else if (name == 'li') {
        // 列表项：处理子节点后加换行
        for (final c in node.nodes) processNode(c);
        if (plainTextBuffer.isNotEmpty &&
            !plainTextBuffer.toString().endsWith('\n')) {
          plainTextBuffer.write('\n');
          if (itemMaps.isNotEmpty && itemMaps.last['type'] == 'text') {
            itemMaps.last['text'] = '${itemMaps.last['text']}\n';
          } else {
            itemMaps.add({
              'type': 'text',
              'text': '\n',
              'startOffset': plainTextBuffer.length - 1,
            });
          }
        }
      } else if (name == 'ul' || name == 'ol') {
        for (final c in node.nodes) processNode(c);
      } else if (isInlineElement(node)) {
        if (isFootnoteLink(node)) {
          final href = node.attributes['href']!;
          final linkId = node.attributes['id'];
          final lt = node.text.trim();
          final fid = linkId != null && linkId.isNotEmpty
              ? 'chapter$chapterIndex#$linkId'
              : 'chapter$chapterIndex#link_${links.length}';
          addLink(href, linkId, lt, fid);
          if (lt.isNotEmpty) addText(lt);
        } else {
          // 先检查子节点里是否有链接，有则递归处理
          final hasChildLink = node.querySelectorAll('a[href]').isNotEmpty;
          if (hasChildLink) {
            for (final c in node.nodes) processNode(c);
          } else {
            final t = node.text.trim();
            if (t.isNotEmpty) addText(t);
          }
        }
      } else {
        for (final c in node.nodes) processNode(c);
      }
    } else if (node is html_dom.Text) {
      final t = node.text.trim();
      if (t.isNotEmpty) addText(t);
    }
  }

  processNode(document.body ?? document.documentElement!);

  // 合并相邻 TextContent
  final merged = <Map<String, dynamic>>[];
  for (final item in itemMaps) {
    if (item['type'] == 'text' &&
        merged.isNotEmpty &&
        merged.last['type'] == 'text') {
      merged.last['text'] = '${merged.last['text']}${item['text']}';
    } else {
      merged.add(item);
    }
  }

  return _ParseHtmlResult(merged, plainTextBuffer.toString(), links);
}

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
              break;
            }
          }
        }

        final result = xlinkHref ?? href;
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
      return node.localName == 'a' && href != null && href.contains('#');
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
          if (child.localName == 'br') {
            // 处理换行标签 - 添加换行符到文本
            if (blockText.isNotEmpty) {
              blockText.write('\n');
            }
          } else if (child.localName == 'img' || child.localName == 'image') {
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
              // final isFootnote =
              //     hashIndex != -1 &&
              //     !(href.contains('/') || href.contains('.html'));

              // 计算链接偏移量（在决定是否添加文本之前）
              // 链接文本会被添加到 blockText 的末尾（前面可能需要空格）
              // 所以 offset = plainTextBuffer.length + blockText.length + (前面有文本?1:0)
              final linkOffset =
                  plainTextBuffer.length +
                  blockText.length +
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
            } else {
              // 普通行内元素 - 检查是否包含脚注链接
              final footnoteLinks = child.querySelectorAll('a[href*="#"]');
              bool hasFootnoteLink = false;
              for (final link in footnoteLinks) {
                final href = link.attributes['href'] ?? '';

                if (href.contains('#')) {
                  hasFootnoteLink = true;
                  break;
                }
              }
              if (hasFootnoteLink) {
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
                      final linkOffset =
                          plainTextBuffer.length +
                          blockText.length +
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
                if (grandchild.localName == 'div') {
                  // 遇到嵌套的 div，先保存当前文本
                  if (blockText.isNotEmpty) {
                    blockItems.add(
                      TextContent(
                        text: blockText.toString().trim(),
                        startOffset: plainTextBuffer.length,
                      ),
                    );
                    blockText.clear();
                  }
                  // 递归处理嵌套的 div
                  processBlockElement(grandchild);
                  // 继续添加换行符到 blockText，作为分隔
                  if (blockText.isEmpty) {
                    blockText.write('\n');
                  } else {
                    blockText.write('\n\n');
                  }
                } else if (grandchild.localName == 'br') {
                  // 处理换行标签
                  if (blockText.isNotEmpty) {
                    blockText.write('\n');
                  }
                } else if (grandchild.localName == 'img' ||
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
                    final linkOffset =
                        plainTextBuffer.length +
                        blockText.length +
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
                            final linkOffset =
                                plainTextBuffer.length +
                                blockText.length +
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
                      if (gc.localName == 'div') {
                        // 遇到嵌套的 div，先保存当前文本，然后添加换行符
                        if (blockText.isNotEmpty) {
                          blockItems.add(
                            TextContent(
                              text: blockText.toString().trim(),
                              startOffset: plainTextBuffer.length,
                            ),
                          );
                          blockText.clear();
                        }
                        // 添加换行符
                        blockText.write('\n');
                      } else if (gc.localName == 'br') {
                        // 处理换行标签
                        if (blockText.isNotEmpty) {
                          blockText.write('\n');
                        }
                      } else if (gc.localName == 'img' ||
                          gc.localName == 'image') {
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
                          final linkOffset =
                              plainTextBuffer.length +
                              blockText.length +
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
                                  final linkOffset =
                                      plainTextBuffer.length +
                                      blockText.length +
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

      // 先保存剩余文本（不 trim，保留换行符）
      if (blockText.isNotEmpty) {
        blockItems.add(
          TextContent(
            text: blockText.toString(),
            startOffset: plainTextBuffer.length,
          ),
        );
      }

      // 不再在此处合并 TextContent，而是在分页阶段只合并同一页面的 TextContent
      // 直接使用 blockItems，不进行合并
      final List<ContentItem> mergedBlockItems = blockItems;
      // for (int i = 0; i < blockItems.length && i < 5; i++) {
      //   final item = blockItems[i];
      //   if (item is TextContent) {
      //     print(
      //       '[BookLoader]   [$i] TextContent: 长度=${item.text.length}, 文本="${item.text.substring(0, item.text.length > 20 ? 20 : item.text.length)}..."',
      //     );
      //   } else {
      //     print('[BookLoader]   [$i] ${item.runtimeType}');
      //   }
      // }

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
        if (node.localName == 'br') {
          // 处理换行标签 - 添加换行符
          if (plainTextBuffer.isNotEmpty) {
            plainTextBuffer.write('\n');
            // 如果最后一个item是TextContent，将换行符添加到其中
            if (items.isNotEmpty && items.last is TextContent) {
              final lastText = items.last as TextContent;
              items.removeLast();
              items.add(
                TextContent(
                  text: '${lastText.text}\n',
                  startOffset: lastText.startOffset,
                ),
              );
            }
          }
        } else if (node.localName == 'img' || node.localName == 'image') {
          // 根级别的图片
          final src = extractImageSource(node);
          if (src != null && src.isNotEmpty) {
            items.add(ImageContent(source: src));
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
          // div 处理前添加换行
          if (plainTextBuffer.isNotEmpty &&
              !plainTextBuffer.toString().endsWith('\n')) {
            plainTextBuffer.write('\n');
            // 如果最后一个item是TextContent，将换行符添加到其中
            if (items.isNotEmpty && items.last is TextContent) {
              final lastText = items.last as TextContent;
              items.removeLast();
              items.add(
                TextContent(
                  text: '${lastText.text}\n',
                  startOffset: lastText.startOffset,
                ),
              );
            }
          }
          // div - 递归处理其子节点
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
            final linkOffset =
                plainTextBuffer.length +
                (plainTextBuffer.isNotEmpty &&
                        !plainTextBuffer.toString().endsWith('\n')
                    ? 1
                    : 0);

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
        final lastItem = mergedItems.isNotEmpty ? mergedItems.last : null;
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

    // 先按换行符分割文本，然后逐段计算行数
    final lines = text.split('\n');
    int totalLines = 0;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty) {
        // 空行也算一行
        totalLines += 1;
      } else {
        // 使用 TextPainter 计算这一行在指定宽度下占多少行
        textPainterCache!.text = TextSpan(text: line, style: style);
        textPainterCache!.layout(maxWidth: maxWidth);
        final lineMetrics = textPainterCache!.computeLineMetrics();
        totalLines += lineMetrics.length;
      }

      // if (i == lines.length - 1) {
      //   print(
      //     '[BookLoader] calculateTextLines: totalLines=$totalLines, linesCount=${lines.length}',
      //   );
      // }
    }

    return totalLines;
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

      // 对中等长度文本进行精确校正后再缓存
      textPainterCache!.text = TextSpan(
        text: text.substring(0, estimatedChars.clamp(0, text.length)),
        style: style,
      );
      textPainterCache!.layout(maxWidth: maxWidth);
      final lineMetrics = textPainterCache!.computeLineMetrics();

      if (lineMetrics.length <= maxLines) {
        final corrected = estimatedChars;
        if (_fitCharsCache.length < _maxFitCharsCacheSize) {
          _fitCharsCache[cacheKey] = corrected;
        }
        return corrected.clamp(1, text.length);
      } else {
        // 超出，需要减少
        final corrected = (estimatedChars * 0.8).floor().clamp(1, text.length);
        if (_fitCharsCache.length < _maxFitCharsCacheSize) {
          _fitCharsCache[cacheKey] = corrected;
        }
        return corrected;
      }
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

  /// 将 Map 列表还原为 ContentItem 列表
  List<ContentItem> _mapsToContentItems(List<Map<String, dynamic>> maps) {
    return maps.map((m) {
      switch (m['type'] as String) {
        case 'text':
          return TextContent(
            text: m['text'] as String,
            startOffset: m['startOffset'] as int,
          );
        case 'image':
          return ImageContent(source: m['source'] as String);
        case 'header':
          return HeaderContent(
            text: m['text'] as String,
            level: m['level'] as int,
          );
        default:
          return TextContent(text: '', startOffset: 0);
      }
    }).toList();
  }

  /// 对已解析的内容项做 TextPainter 分页（主线程）
  List<PageContent> _splitParsedChapter(
    EpubChapter chapter,
    int chapterIndex,
    List<ContentItem> contentItems,
    String chapterPlainText,
    double availableHeight,
    double availableWidth, {
    int safetyLines = BookReaderConstants.defaultPageReserveLines,
  }) {
    final pages = <PageContent>[];

    if (contentItems.isEmpty) {
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

    // 创建与渲染端一致的 TextStyle
    // 注意：这里使用默认的 body 样式，实际渲染时会从 Theme 获取
    final textStyle = TextStyle(
      fontSize: fontSize,
      height: BookReaderConstants.lineHeight,
      color: Colors.black87,
      // 明确指定 fontFamily，避免使用系统默认字体导致的差异
      fontFamily: '.SF Pro Text', // iOS/macOS 默认字体
      fontFamilyFallback: const ['Roboto', 'Noto Sans CJK SC', 'sans-serif'],
    );
    textPainterCache ??= TextPainter(textDirection: TextDirection.ltr);
    textPainterCache!.text = TextSpan(text: '中', style: textStyle);
    textPainterCache!.layout();
    final lineHeight = textPainterCache!.height;

    // 统一可用高度计算：
    // - 减去页面垂直预留（120）
    // - 减去 kToolbarHeight
    // - 减去内容区内部 padding（20）
    // - 减去安全边距（小字体时 TextPainter 计算误差 + SelectableText 内边距）
    final usableHeight =
        availableHeight -
        BookReaderConstants.pageVerticalReserve -
        kToolbarHeight -
        BookReaderConstants.contentPaddingVertical -
        BookReaderConstants.selectableTextExtraPadding;

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
        String remaining = item.text;
        int currentOffset = item.startOffset;

        while (remaining.isNotEmpty) {
          final remainingHeight = usableHeight - currentPageHeight;
          // 根据字体大小动态计算预留行数：
          // 小字体（<=16）时 TextPainter 计算误差比例更大，预留更多行
          final remainingLines =
              (remainingHeight / lineHeight).floor() - safetyLines;

          if (remainingLines <= 0) {
            flushCurrentPage();
            continue;
          }

          final actualLines = calculateTextLines(
            remaining,
            availableWidth,
            textStyle,
          );

          if (actualLines <= remainingLines) {
            if (currentPageItems.isNotEmpty &&
                currentPageItems.last is TextContent) {
              final last = currentPageItems.last as TextContent;
              currentPageItems.removeLast();
              currentPageItems.add(
                TextContent(
                  text: '${last.text}$remaining',
                  startOffset: last.startOffset,
                ),
              );
            } else {
              currentPageItems.add(
                TextContent(text: remaining, startOffset: currentOffset),
              );
            }
            currentPageHeight += actualLines * lineHeight;
            remaining = '';
          } else {
            // 使用 calculateFitChars 精确计算能容纳的字符数
            final fitChars = calculateFitChars(
              remaining,
              availableWidth,
              remainingLines,
              textStyle,
            );

            if (fitChars <= 0) {
              flushCurrentPage();
              continue;
            }

            // 在 fitChars 位置向前查找合适的截断点（避免截断在单词中间）
            int cut = fitChars;
            // 向前查找换行符或空格，最多向前查找 20 个字符
            for (int i = 0; i < 20 && cut > 0; i++) {
              final char = remaining[cut - 1];
              if (char == '\n' || char == ' ' || char == '\u3000') {
                break;
              }
              cut--;
            }
            // 如果没有找到合适的截断点，使用原始 fitChars（防止回退太多）
            if (cut < fitChars * 0.8) {
              cut = fitChars;
            }

            final part = remaining.substring(0, cut);
            if (currentPageItems.isNotEmpty &&
                currentPageItems.last is TextContent) {
              final last = currentPageItems.last as TextContent;
              currentPageItems.removeLast();
              currentPageItems.add(
                TextContent(
                  text: '${last.text}$part',
                  startOffset: last.startOffset,
                ),
              );
            } else {
              currentPageItems.add(
                TextContent(text: part, startOffset: currentOffset),
              );
            }
            // 使用 remainingLines 作为实际使用的行数，而不是重新计算
            // 因为 calculateFitChars 是根据 remainingLines 截断的
            // 重新计算可能导致高度不一致（空白或溢出）
            currentPageHeight += remainingLines * lineHeight;
            currentOffset += part.length;
            remaining = remaining.substring(cut);
            flushCurrentPage();
          }
        }
      } else if (item is ImageContent) {
        final imageHeight = usableHeight * 0.4 + 4 * lineHeight;
        if (currentPageItems.isNotEmpty &&
            currentPageHeight + imageHeight > usableHeight)
          flushCurrentPage();
        currentPageItems.add(item);
        currentPageHeight += imageHeight;
        if (imageHeight >= usableHeight) flushCurrentPage();
      } else if (item is HeaderContent) {
        // 使用与渲染一致的标题高度计算
        final headerHeight = BookReaderConstants.getHeaderHeight(
          item.level,
          fontSize,
        );
        if (currentPageItems.isNotEmpty &&
            currentPageHeight + headerHeight > usableHeight)
          flushCurrentPage();
        currentPageItems.add(item);
        currentPageHeight += headerHeight;
      } else if (item is LinkContent) {
        currentPageItems.add(item);
      } else if (item is CoverContent) {
        if (currentPageItems.isNotEmpty) flushCurrentPage();
        currentPageItems.add(item);
        currentPageHeight = usableHeight;
        flushCurrentPage();
      }
    }

    if (currentPageItems.isNotEmpty) flushCurrentPage();
    return pages;
  }

  /// 将章节分割成页面
  List<PageContent> splitChapterIntoPages(
    EpubChapter chapter,
    int chapterIndex,
    double availableHeight,
    double availableWidth, {
    int safetyLines = BookReaderConstants.defaultPageReserveLines,
  }) {
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
    // 创建与渲染端一致的 TextStyle
    // 注意：这里使用默认的 body 样式，实际渲染时会从 Theme 获取
    final textStyle = TextStyle(
      fontSize: fontSize,
      height: BookReaderConstants.lineHeight,
      color: Colors.black87,
      // 明确指定 fontFamily，避免使用系统默认字体导致的差异
      fontFamily: '.SF Pro Text', // iOS/macOS 默认字体
      fontFamilyFallback: const ['Roboto', 'Noto Sans CJK SC', 'sans-serif'],
    );

    // 计算实际行高（只计算一次）
    textPainterCache ??= TextPainter(textDirection: TextDirection.ltr);
    textPainterCache!.text = TextSpan(text: '中', style: textStyle);
    textPainterCache!.layout();
    final lineHeight = textPainterCache!.height;

    // 计算每行平均字符数（只计算一次）
    textPainterCache!.layout(maxWidth: availableWidth);
    // final charWidth = textPainterCache!.width;
    // final charsPerLine = (availableWidth / charWidth).floor();

    // 每页可用高度：
    // - 减去页面垂直预留（120）
    // - 减去 kToolbarHeight
    // - 减去内容区内部 padding（20）
    // - 减去安全边距（小字体时 TextPainter 计算误差 + SelectableText 内边距）
    final usableHeight =
        availableHeight -
        BookReaderConstants.pageVerticalReserve -
        kToolbarHeight -
        BookReaderConstants.contentPaddingVertical -
        BookReaderConstants.selectableTextExtraPadding;
    // final linesPerPage = (usableHeight / lineHeight).floor();

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
        // item.startOffset 已经是正确的章节内全局偏移量
        // 不需要再调整 leadingSpaces
        String remaining = item.text;
        int currentOffset = item.startOffset;

        while (remaining.isNotEmpty) {
          final remainingHeight = usableHeight - currentPageHeight;
          // 根据字体大小动态计算预留行数：
          // 小字体（<=16）时 TextPainter 计算误差比例更大，预留更多行
          // 大字体（>20）时误差比例较小，预留较少行
          final remainingLines =
              (remainingHeight / lineHeight).floor() - safetyLines;

          if (remainingLines <= 0) {
            flushCurrentPage();
            continue;
          }

          // 精确计算实际行数（不管估算结果如何）
          final actualLines = calculateTextLines(
            remaining,
            availableWidth,
            textStyle,
          );

          if (actualLines <= remainingLines) {
            // 确实可以放下，尝试与上一个 TextContent 合并（同一页面内）
            bool merged = false;
            if (currentPageItems.isNotEmpty &&
                currentPageItems.last is TextContent) {
              final lastText = currentPageItems.last as TextContent;
              // 直接拼接，不添加额外分隔符
              // 换行符已经在 remaining 中
              final mergedText = '${lastText.text}$remaining';
              currentPageItems.removeLast();
              currentPageItems.add(
                TextContent(
                  text: mergedText,
                  startOffset: lastText.startOffset,
                ),
              );
              merged = true;
            }

            if (!merged) {
              currentPageItems.add(
                TextContent(text: remaining, startOffset: currentOffset),
              );
            }

            currentPageHeight += actualLines * lineHeight;
            remaining = '';
          } else {
            // 实际行数超过剩余行数，使用 calculateFitChars 精确计算截断位置
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

            // 在 fitChars 位置向前查找合适的截断点（避免截断在单词中间）
            int cut = fitChars;
            // 向前查找换行符或空格，最多向前查找 20 个字符
            for (int i = 0; i < 20 && cut > 0; i++) {
              final char = remaining[cut - 1];
              if (char == '\n' || char == ' ' || char == '\u3000') {
                break;
              }
              cut--;
            }
            // 如果没有找到合适的截断点，使用原始 fitChars（防止回退太多）
            if (cut < fitChars * 0.8) {
              cut = fitChars;
            }

            // 截取当前页面的文本
            // 不使用 trimRight，保留末尾的换行符，确保连续空行能正确显示
            String part = remaining.substring(0, cut);

            // 尝试与上一个 TextContent 合并（同一页面内）
            bool merged = false;
            if (currentPageItems.isNotEmpty &&
                currentPageItems.last is TextContent) {
              final lastText = currentPageItems.last as TextContent;
              final mergedText = '${lastText.text}$part';
              currentPageItems.removeLast();
              currentPageItems.add(
                TextContent(
                  text: mergedText,
                  startOffset: lastText.startOffset,
                ),
              );
              merged = true;
            }

            if (!merged) {
              currentPageItems.add(
                TextContent(text: part, startOffset: currentOffset),
              );
            }

            // 使用 remainingLines 作为实际使用的行数，而不是重新计算
            // 因为 calculateFitChars 是根据 remainingLines 截断的
            // 重新计算可能导致高度不一致（空白或溢出）
            currentPageHeight += remainingLines * lineHeight;
            currentOffset += part.length;
            // 不使用 trimLeft，保留开头的空行
            remaining = remaining.substring(cut);

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
          }
        }
      }

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
        final baseName = chapterFilename.contains('/')
            ? chapterFilename.split('/').last
            : chapterFilename;

        // 使用预构建的文件名映射查找目标章节
        targetChapterIndex =
            _chapterFilenameToIndex[chapterFilename] ??
            _chapterFilenameToIndex[baseName];

        // 如果目标文件名就是当前章节，当作章节内链接处理
        if (targetChapterIndex == null) {
          final htmlFileName = link['htmlFileName'] as String?;
          final currentBase = htmlFileName != null && htmlFileName.contains('/')
              ? htmlFileName.split('/').last
              : htmlFileName;
          if (currentBase == baseName || htmlFileName == chapterFilename) {
            targetChapterIndex = chapterIndex;
          }
        }

        if (targetChapterIndex == null) {
          link['targetChapterIndex'] = null;
          link['targetPageIndexInChapter'] = null;
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
            } else {}
          } else {}
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
            } else {}
          } else {}
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
          for (final page in allPages) {
            for (final item in page.contentItems) {
              if (item is TextContent && item.text.contains(linkText)) {
                actualChapterIndex = page.chapterIndex;
                linkPageIndex = page.pageIndexInChapter;
                break;
              }
            }
            if (linkPageIndex != null) break;
          }
        }

        // 更新链接的实际章节索引
        if (actualChapterIndex != chapterIndex) {
          link['chapterIndex'] = actualChapterIndex;
        }

        link['pageIndexInChapter'] = linkPageIndex;
      }
    }
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
      return null;
    }

    // 如果提供了linkText，优先使用文本匹配
    if (linkText != null && linkText.isNotEmpty) {
      for (final page in pages) {
        for (final item in page.contentItems) {
          if (item is TextContent && item.text.contains(linkText)) {
            return page.pageIndexInChapter;
          }
        }
      }
    }

    // 使用offset匹配（严格匹配，不使用tolerance以避免边界问题）
    for (final page in pages) {
      // 检查页面是否包含目标偏移量
      for (final item in page.contentItems) {
        if (item is TextContent) {
          // 严格匹配：targetOffset 必须在 [item.startOffset, item.startOffset + item.text.length) 范围内
          if (targetOffset >= item.startOffset &&
              targetOffset < item.startOffset + item.text.length) {
            // print(
            //   '[BookLoader] 通过offset找到页面: targetOffset=$targetOffset, page=${page.pageIndexInChapter}, item.startOffset=${item.startOffset}, item.text.length=${item.text.length}',
            // );
            return page.pageIndexInChapter;
          }
        }
      }
    }
    // print(
    //   '[BookLoader] 未找到目标偏移量对应的页面: targetOffset=$targetOffset, 总页面数=${pages.length}',
    // );
    // 打印所有页面的offset范围以便调试
    // for (final page in pages) {
    // final textItems = page.contentItems.whereType<TextContent>().toList();
    // if (textItems.isNotEmpty) {
    // final firstOffset = textItems.first.startOffset;
    // final lastItem = textItems.last;
    // final lastOffset = lastItem.startOffset + lastItem.text.length;
    // print(
    //   '[BookLoader] 页面${page.pageIndexInChapter}: offset范围[$firstOffset, $lastOffset)',
    // );
    // }
    // }
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
    final padding = MediaQuery.of(context).padding;
    final availableHeight = size.height - padding.top - padding.bottom;
    final availableWidth = size.width - 48;

    // 读取用户配置的预留行数
    final safetyLines = SPUtil.get<int>(
      PrefKeys.pageReserveLines,
      BookReaderConstants.defaultPageReserveLines,
    );

    final pages = <PageContent>[];

    // 清空全局链接，重新收集
    _globalLinks.clear();
    _chapterFilenameToIndex.clear();

    final spineItems = epubBook.schema?.package?.spine?.items;
    final manifestItems = epubBook.schema?.package?.manifest?.items;

    // 从guide中获取封面href
    String? coverHrefFromGuide;
    final guide = epubBook.schema?.package?.guide;
    if (guide != null) {
      EpubGuideReference? coverRef;
      for (final item in guide.items) {
        if (item.type?.toLowerCase() == 'cover') {
          coverRef = item;
          break;
        }
      }
      if (coverRef?.href != null) {
        coverHrefFromGuide = coverRef!.href;
      }
    }
    // 非章节页面索引计数器，从 -1 开始递增
    int nonChapterPageCounter = -1;
    // 添加封面页
    final coverImagePath = getCoverImagePath();
    final coverFile = File(coverImagePath);
    if (await coverFile.exists()) {
      pages.add(
        PageContent(
          chapterIndex: nonChapterPageCounter--,
          pageIndexInChapter: 0,
          contentItems: [CoverContent(imagePath: coverImagePath)],
          title: '封面',
        ),
      );
    }

    if (spineItems == null || manifestItems == null) {
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

    // ── 第一步：并行解析所有章节 HTML（Isolate，不含 TextPainter）──
    // 收集所有需要处理的 spine 项
    final List<
      ({
        int spineIndex,
        EpubChapter? chapter,
        String href,
        String? htmlContent,
        int chapterIndex,
      })
    >
    spineJobs = [];

    for (int i = 0; i < spineItems.length; i++) {
      final spineItem = spineItems[i];
      final idRef = spineItem.idRef;
      if (idRef == null) continue;

      final manifestItem = manifestItems.cast<EpubManifestItem?>().firstWhere(
        (item) => item?.id == idRef,
        orElse: () => null,
      );
      if (manifestItem == null) continue;

      final href = manifestItem.href;
      if (href == null) continue;
      if (coverHrefFromGuide != null && href == coverHrefFromGuide) continue;

      final chapter = fileNameToChapterMap[href];
      if (chapter != null) {
        final baseFilename = getBaseFileName(chapter.contentFileName);
        final chapterIndex = _chapterFilenameToIndex[baseFilename];
        if (chapterIndex == null) continue;
        spineJobs.add((
          spineIndex: i,
          chapter: chapter,
          href: href,
          htmlContent: chapter.htmlContent,
          chapterIndex: chapterIndex,
        ));
      } else {
        final htmlContent = epubBook.content?.html[href]?.content;
        if (htmlContent == null || htmlContent.isEmpty) continue;
        final nonChapterIndex = nonChapterPageCounter;
        nonChapterPageCounter--;
        // 更新文件名映射
        String baseFilename = href;
        final sep = href.contains('\\') ? '\\' : '/';
        final idx = href.lastIndexOf(sep);
        if (idx != -1) baseFilename = href.substring(idx + 1);
        _chapterFilenameToIndex[baseFilename] = nonChapterIndex;
        spineJobs.add((
          spineIndex: i,
          chapter: null,
          href: href,
          htmlContent: htmlContent,
          chapterIndex: nonChapterIndex,
        ));
      }
    }

    // ── 第一步：单个 Isolate 批量解析所有章节 HTML ──
    final tasks = spineJobs
        .map(
          (job) => _ParseHtmlTask(
            job.htmlContent ?? '',
            job.chapterIndex,
            job.chapter?.contentFileName ?? job.href,
          ),
        )
        .toList();

    final parseResults = await compute(
      _parseHtmlBatchIsolate,
      _ParseHtmlBatchTask(tasks),
    );

    // ── 第二步：主线程串行做 TextPainter 分页 ──
    for (int j = 0; j < spineJobs.length; j++) {
      final job = spineJobs[j];
      final parsed = parseResults[j];

      // 将 Map 还原为 ContentItem
      final contentItems = _mapsToContentItems(parsed.items);
      // 收集链接到 _globalLinks
      _globalLinks.addAll(parsed.links);
      _chapterPlainTextMap[job.chapterIndex] = parsed.plainText;

      final chapter =
          job.chapter ??
          EpubChapter(
            title: '页面 ${job.spineIndex + 1}',
            contentFileName: job.href,
            htmlContent: job.htmlContent,
          );

      final chapterPages = _splitParsedChapter(
        chapter,
        job.chapterIndex,
        contentItems,
        parsed.plainText,
        availableHeight,
        availableWidth,
        safetyLines: safetyLines,
      );
      pages.addAll(chapterPages);

      if (j % 5 == 0) await Future.delayed(const Duration(milliseconds: 1));
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
  void onWindowResize(
    Size newSize,
    EpubBook epubBook,
    BuildContext context, {
    int currentChapterIndex = 0,
  }) {
    if (windowSize == null ||
        (newSize.width != windowSize!.width ||
            newSize.height != windowSize!.height)) {
      windowSize = newSize;
      // 防抖处理：取消之前的定时器，避免频繁重绘
      resizeDebounceTimer?.cancel();
      resizeDebounceTimer = Timer(resizeDebounceDuration, () {
        processPages(epubBook, context, currentChapterIndex);
      });
    }
  }
}
