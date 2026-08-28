import 'package:ashes_note/ashes_theme.dart';
import 'package:ashes_note/models/rss/rss_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

/// 解析 HTML 属性中的尺寸（支持 "50" / "50px" / "50%" 等写法）
double? _parseDimension(String? value) {
  if (value == null || value.isEmpty) return null;
  final n = double.tryParse(value.replaceAll(RegExp(r'[^0-9.]'), ''));
  return n;
}

/// 从 style 字符串中提取 width（如 "width: 50px"）
double? _parseStyleWidth(String? style) {
  if (style == null || style.isEmpty) return null;
  final m = RegExp(r'width\s*:\s*([0-9.]+)\s*px', caseSensitive: false)
      .firstMatch(style);
  if (m != null) return double.tryParse(m.group(1)!);
  return null;
}

/// 判断图片 style/属性是否表明它是 em 级的小图（如 emoji：height:1em）
bool _isEmSizedImage(String? style) {
  if (style == null || style.isEmpty) return false;
  final m = RegExp(r'(?:width|height|max-height|max-width)\s*:\s*([0-9.]+)\s*em',
          caseSensitive: false)
      .firstMatch(style);
  if (m == null) return false;
  final n = double.tryParse(m.group(1)!);
  return n != null && n <= 3;
}

/// 判断浮动元素是否为“小图标前缀”（表情/头像/小图）：
/// 宽度很小、或图片本身为 emoji/smiley、或 em 级尺寸。
bool _isIconFloat(dom.Element el, dom.Element img) {
  final w = _parseStyleWidth(el.attributes['style']) ??
      _parseDimension(el.attributes['width']);
  if (w != null && w <= 48) return true;
  final cls = (img.attributes['class'] ?? '').toLowerCase();
  if (cls.contains('smiley') || cls.contains('emoji')) return true;
  return _isEmSizedImage(img.attributes['style']);
}

/// 从 style 中移除 float 声明。
String _stripFloat(String style) {
  return style
      .replaceAll(RegExp(r'\s*float\s*:\s*(left|right)\s*;?',
          caseSensitive: false), '')
      .trim();
}

/// 递归移除某子树 style 中的百分比 width（如 width: 88%），避免 flutter_html
/// 对百分比宽度解析异常导致文字被挤成一字一行。保留 px 宽度与图片尺寸。
void _stripPctWidthRecursive(dom.Element el) {
  final s = el.attributes['style'];
  if (s != null) {
    el.attributes['style'] = s
        .replaceAll(RegExp(r'\s*width\s*:\s*[0-9.]+\s*%\s*;?',
            caseSensitive: false), '')
        .trim();
  }
  for (final child in el.children) {
    _stripPctWidthRecursive(child);
  }
}

/// 清洗 flutter_html 不支持的 float / 百分比宽度，修复 ifanr 等源“图标独占一行、
/// 文字被挤成一字一行”的错乱；并把仅含单图的浮动前缀块提升为行内图标，使其与后续
/// 文字进入正常流式排版。解析异常时原样返回，避免正文消失。
String _sanitizeRssHtml(String rawHtml) {
  if (rawHtml.trim().isEmpty) return rawHtml;
  try {
    final doc = html_parser.parse(rawHtml);

    final floatEls = doc.querySelectorAll('*').where((el) {
      final s = el.attributes['style'] ?? '';
      return RegExp(r'float\s*:\s*(left|right)', caseSensitive: false)
          .hasMatch(s);
    }).toList();

    for (final el in floatEls) {
      // 移除 float 声明，避免 flutter_html 无法处理导致的错乱
      el.attributes['style'] = _stripFloat(el.attributes['style'] ?? '');

      // 仅含单图的浮动小图标：提升为后续文字块的行内前置，与文字同行显示
      final img = el.querySelector('img');
      final parent = el.parent;
      if (img != null && parent != null && _isIconFloat(el, img)) {
        final next = el.nextElementSibling;
        if (next != null) {
          final target = next.querySelector('p, span, a, div') ?? next;
          target.insertBefore(img, target.firstChild);
          _stripPctWidthRecursive(next);
        } else {
          parent.insertBefore(img, el);
        }
        el.remove();
      }
    }

    return doc.body?.innerHtml ?? rawHtml;
  } catch (_) {
    return rawHtml;
  }
}

/// 文章阅读页：用 flutter_html 渲染正文，支持标记已读/收藏、外链打开。
/// 可内嵌于主从布局右侧（提供 [onBack]/[onPrev]/[onNext]），也可作为独立路由使用。
class ArticleViewPage extends StatefulWidget {
  final RssArticle article;
  final String? feedTitle;
  final VoidCallback onUpdated;
  final VoidCallback? onBack; // 返回列表（内嵌模式提供）
  final VoidCallback? onPrev; // 上一篇
  final VoidCallback? onNext; // 下一篇
  final bool hasPrev;
  final bool hasNext;

  const ArticleViewPage({
    super.key,
    required this.article,
    this.feedTitle,
    required this.onUpdated,
    this.onBack,
    this.onPrev,
    this.onNext,
    this.hasPrev = false,
    this.hasNext = false,
  });

  @override
  State<ArticleViewPage> createState() => _ArticleViewPageState();
}

class _ArticleViewPageState extends State<ArticleViewPage> {
  late bool _isRead;
  late bool _isStarred;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  bool _ready = false; // 首帧布局完成前不响应滚动，避免一次性跳到底部

  @override
  void initState() {
    super.initState();
    _isRead = widget.article.isRead;
    _isStarred = widget.article.isStarred;
    // 首帧布局完成后才允许滚动，并把位置重置到顶部
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ready = true;
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    });
    // 打开即标记已读：延迟到首帧之后，避免在父级 build 期间触发 setState
    if (!widget.article.isRead) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.article.isRead = true;
        _isRead = true;
        setState(() {});
        widget.onUpdated();
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 向下/向上滚动一屏（Space 向下，Shift+Space 向上）
  void _scrollByPage(bool down) {
    if (!_scrollController.hasClients) return;
    void doScroll() {
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      // 布局尚未完成（viewport/content 尺寸未知）时不滚动，避免一次性跳到底部
      if (!pos.hasViewportDimension || !pos.hasContentDimensions) return;
      final delta = pos.viewportDimension * 0.9 * (down ? 1 : -1);
      final target = (pos.pixels + delta)
          .clamp(pos.minScrollExtent, pos.maxScrollExtent);
      // 已到边界则不再滚动，避免无效动画
      if ((target - pos.pixels).abs() < 1.0) return;
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }

    if (_ready) {
      doScroll();
    } else {
      // 首帧布局尚未完成：强制等待一帧再滚动，确保尺寸已就绪
      WidgetsBinding.instance.addPostFrameCallback((_) => doScroll());
    }
  }

  /// 键盘快捷键处理
  void _handleKey(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;
    final key = event.logicalKey;
    // 上一篇 / 下一篇
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageUp) {
      if (widget.hasPrev) widget.onPrev?.call();
      return;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.pageDown) {
      if (widget.hasNext) widget.onNext?.call();
      return;
    }
    // 滚动：仅用 Space / Shift+Space。
    // 注意：不使用 ↑/↓ 方向键滚动——文章正文被 SelectionArea 包裹，
    // 方向键会被 SelectionArea 的文本导航消费，与我们这里的处理叠加，
    // 导致首次按 ↓ 直接跳到底部。Space 不受影响，故保留。
    if (key == LogicalKeyboardKey.space) {
      _scrollByPage(!event.isShiftPressed);
      return;
    }
  }

  void _toggleRead() {
    setState(() {
      _isRead = !_isRead;
      widget.article.isRead = _isRead;
    });
    widget.onUpdated();
  }

  void _toggleStar() {
    setState(() {
      _isStarred = !_isStarred;
      widget.article.isStarred = _isStarred;
    });
    widget.onUpdated();
  }

  Future<void> _openLink() async {
    final link = widget.article.link;
    if (link == null) return;
    final uri = Uri.tryParse(link);
    if (uri == null) return;
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开链接'), duration: Duration(seconds: 1)),
        );
      }
    }
  }

  /// 将图片相对地址解析为绝对地址（基于文章链接）
  String _resolveUrl(String src) {
    if (src.startsWith('http://') || src.startsWith('https://')) return src;
    if (src.startsWith('//')) return 'https:$src';
    final base = widget.article.link;
    if (base != null && base.isNotEmpty) {
      try {
        return Uri.parse(base).resolve(src).toString();
      } catch (_) {}
    }
    return src;
  }

  /// 点击图片：全屏可缩放查看
  void _openImageViewer(String url) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Dialog(
        insetPadding: EdgeInsets.zero,
        backgroundColor: Colors.transparent,
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 5,
              child: Center(
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (context, _, _) => const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white54,
                    size: 64,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 40,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 自定义 a 标签渲染：flutter_html 在该版本下链接虽可点击，但 hover 时不会
  /// 自动变为手形光标。这里用 MouseRegion 包裹，使鼠标悬停时显示手形，并保留
  /// 内部富文本与点击打开外链的行为。
  Widget _buildLink(ExtensionContext ec) {
    final url = ec.attributes['href'];
    final spans = ec.inlineSpanChildren ?? const <InlineSpan>[];
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () async {
          if (url == null) return;
          final uri = Uri.tryParse(url);
          if (uri != null && await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
        child: RichText(
          text: TextSpan(children: spans),
          // 继承 flutter_html 的默认文本排版
          textAlign: TextAlign.start,
          softWrap: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeManager.getCurrentTheme();
    // 墨水屏虽被 isDarkMode 归为“深色”，但其背景为白色，文字应为黑色；
    // 仅真正的暗黑模式才使用浅色文字。
    final isInk = ThemeManager.isInkMode();
    final isDark = ThemeManager.isDarkMode() && !isInk;
    final textColor = isDark ? Colors.white70 : Colors.black87;
    final subColor = isDark ? Colors.white54 : Colors.black54;
    final linkColor = theme.mainTheme.colorScheme.primary;

    final published = widget.article.published;
    final dateStr = published == null
        ? ''
        : DateFormat.yMMMd().add_Hm().format(published);

    final html = widget.article.content ??
        widget.article.summary ??
        '<p style="color:grey">（该文章没有可显示的正文内容）</p>';

    return RawKeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKey: _handleKey,
      child: Scaffold(
      appBar: AppBar(
        leading: widget.onBack == null
            ? null
            : IconButton(
                tooltip: '返回列表',
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
              ),
        title: Text(widget.feedTitle ?? '阅读'),
        actions: [
          // 上一篇 / 下一篇
          IconButton(
            tooltip: '上一篇',
            icon: const Icon(Icons.chevron_left),
            onPressed: widget.hasPrev ? widget.onPrev : null,
          ),
          IconButton(
            tooltip: '下一篇',
            icon: const Icon(Icons.chevron_right),
            onPressed: widget.hasNext ? widget.onNext : null,
          ),
          IconButton(
            tooltip: _isRead ? '标记为未读' : '标记为已读',
            icon: Icon(_isRead ? Icons.mark_email_read : Icons.mark_as_unread),
            onPressed: _toggleRead,
          ),
          IconButton(
            tooltip: _isStarred ? '取消收藏' : '收藏',
            icon: Icon(
              _isStarred ? Icons.star : Icons.star_border,
              color: _isStarred ? Colors.amber : null,
            ),
            onPressed: _toggleStar,
          ),
          IconButton(
            tooltip: '在浏览器打开',
            icon: const Icon(Icons.open_in_browser),
            onPressed: _openLink,
          ),
        ],
      ),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 880),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: ListView(
            controller: _scrollController,
            children: [
              Text(
                widget.article.title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (widget.article.author != null)
                    Expanded(
                      child: Text(
                        widget.article.author!,
                        style: TextStyle(fontSize: 13, color: subColor),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (dateStr.isNotEmpty)
                    Text(dateStr, style: TextStyle(fontSize: 13, color: subColor)),
                ],
              ),
              const Divider(height: 24),
              SelectionArea(
                child: Html(
                  data: _sanitizeRssHtml(html),
                  style: {
                    'body': Style(
                      color: textColor,
                      fontSize: FontSize(15),
                      lineHeight: LineHeight(1.6),
                    ),
                    'a': Style(color: linkColor),
                    'h1': Style(
                        color: textColor,
                        fontSize: FontSize(22),
                        fontWeight: FontWeight.w700),
                    'h2': Style(
                        color: textColor,
                        fontSize: FontSize(19),
                        fontWeight: FontWeight.w700),
                    'h3': Style(
                        color: textColor,
                        fontSize: FontSize(17),
                        fontWeight: FontWeight.w600),
                    'pre': Style(
                      backgroundColor: isDark
                          ? const Color(0xFF2A2A2A)
                          : const Color(0xFFF2F2F2),
                      padding: HtmlPaddings.all(12),
                    ),
                    'code': Style(
                      backgroundColor: isDark
                          ? const Color(0xFF2A2A2A)
                          : const Color(0xFFF2F2F2),
                      fontFamily: 'monospace',
                    ),
                    'blockquote': Style(
                      border: Border(
                        left: BorderSide(color: linkColor, width: 3),
                      ),
                      padding: HtmlPaddings.only(left: 12),
                      color: subColor,
                    ),
                  },
                  extensions: [
                    // 自定义链接渲染：悬停显示手形光标，点击打开外链
                    TagExtension(
                      tagsToExtend: {'a'},
                      builder: (ec) => _buildLink(ec),
                    ),
                    // 自定义图片渲染：撑满正文宽度、保持比例，点击查看大图
                    TagExtension(
                      tagsToExtend: {'img'},
                      builder: (ec) {
                        final src = ec.attributes['src'];
                        if (src == null || src.trim().isEmpty) {
                          return const SizedBox.shrink();
                        }
                        final url = _resolveUrl(src.trim());

                        final cls = (ec.attributes['class'] ?? '').toLowerCase();
                        final alt = (ec.attributes['alt'] ?? '').toLowerCase();
                        final style = ec.attributes['style'];
                        final isAvatar = cls.contains('avatar') ||
                            cls.contains('author') ||
                            cls.contains('profile') ||
                            cls.contains('head') ||
                            alt.contains('头像') ||
                            alt.contains('作者');
                        // emoji / 表情小图：wp-smiley、emoji 类，或 em 级尺寸
                        final isEmoji = cls.contains('smiley') ||
                            cls.contains('emoji') ||
                            _isEmSizedImage(style);
                        final declaredW = _parseDimension(ec.attributes['width']) ??
                            _parseStyleWidth(style);
                        final isSmall = declaredW != null && declaredW <= 120;

                        if (isEmoji) {
                          // 表情/emoji：随文字大小的小图，与正文行内对齐
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 1),
                            child: Image.network(
                              url,
                              width: 18,
                              height: 18,
                              fit: BoxFit.contain,
                              errorBuilder: (context, _, _) =>
                                  const SizedBox(width: 18, height: 18),
                            ),
                          );
                        }

                        if (isAvatar) {
                          // 头像：固定小尺寸、圆形、左对齐，避免被拉伸成巨图
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isDark
                                      ? Colors.white24
                                      : Colors.black12,
                                  width: 1,
                                ),
                              ),
                              child: ClipOval(
                                child: Image.network(
                                  url,
                                  width: 44,
                                  height: 44,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, _, _) => const Icon(
                                    Icons.person,
                                    size: 28,
                                    color: Colors.grey,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }

                        if (isSmall) {
                          // 其它小图（图标/表情等）：保持原尺寸，不撑满宽度
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Image.network(
                              url,
                              fit: BoxFit.scaleDown,
                              errorBuilder: (context, _, _) => const Icon(
                                Icons.broken_image_outlined,
                                color: Colors.grey,
                              ),
                            ),
                          );
                        }

                        // 普通大图：撑满正文宽度，点击查看大图
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: GestureDetector(
                            onTap: () => _openImageViewer(url),
                            child: Image.network(
                              url,
                              width: double.infinity,
                              fit: BoxFit.fitWidth,
                              loadingBuilder: (context, child, progress) {
                                if (progress == null) return child;
                                return const SizedBox(
                                  height: 160,
                                  child: Center(
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                );
                              },
                              errorBuilder: (context, _, _) => const SizedBox(
                                height: 80,
                                child: Center(
                                  child: Icon(Icons.broken_image_outlined,
                                      color: Colors.grey),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
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
}
