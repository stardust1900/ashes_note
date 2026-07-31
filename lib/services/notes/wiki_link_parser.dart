/// `[[...]]` 双向链接语法解析器。
///
/// 全部为纯函数，无副作用、无 I/O，便于单元测试。
library;

import 'package:ashes_note/models/notes/note_index_models.dart';
import 'package:ashes_note/utils/const.dart';

/// 文本中的一个半开区间 `[start, end)`。
class TextRange {
  final int start;
  final int end;
  const TextRange(this.start, this.end);

  bool contains(int offset) => offset >= start && offset < end;
  int get length => end - start;

  @override
  String toString() => '[$start,$end)';
}

/// `[[目标]]` / `[[目标|别名]]`。
///
/// 目标与别名内部都不允许出现 `[`、`]`、换行，避免跨行误匹配。
final RegExp _wikiLinkPattern = RegExp(r'\[\[([^\[\]\n|]+)(?:\|([^\[\]\n]*))?\]\]');

/// 围栏代码块起始行：``` 或 ~~~。
///
/// 不用单条正则匹配整块，因为「未闭合围栏应延伸到文末」这一规则
/// 用 `\z` 在 multiLine 模式下并不可靠，改为手工扫描配对。
final RegExp _fenceOpenPattern = RegExp(
  r'^[ \t]*(`{3,}|~{3,})[^\n]*$',
  multiLine: true,
);

/// 行内代码：一个或多个反引号包裹，不跨行。
final RegExp _inlineCodePattern = RegExp(r'(`+)(?:(?!\1)[\s\S])*?\1');

/// 缩进代码块（四空格或制表符起始的行）。
final RegExp _indentedCodePattern = RegExp(r'^(?: {4}|\t)[^\n]*$', multiLine: true);

/// 计算 [content] 中所有「代码区域」的偏移区间。
///
/// 依次识别围栏代码块、缩进代码块、行内代码；
/// 后两者只在围栏之外的区域内查找，避免重复与嵌套误判。
List<TextRange> findCodeRegions(String content) {
  final regions = <TextRange>[];

  // 手工配对围栏：遇到开围栏后找同类型且长度不短于它的闭围栏；
  // 找不到则一直延伸到文末。
  final fences = _fenceOpenPattern.allMatches(content).toList();
  var i = 0;
  while (i < fences.length) {
    final open = fences[i];
    final marker = open.group(1)!;
    final fenceChar = marker[0];

    var closeIdx = -1;
    for (var j = i + 1; j < fences.length; j++) {
      final candidate = fences[j].group(1)!;
      if (candidate[0] == fenceChar && candidate.length >= marker.length) {
        closeIdx = j;
        break;
      }
    }

    if (closeIdx < 0) {
      regions.add(TextRange(open.start, content.length));
      break;
    }
    regions.add(TextRange(open.start, fences[closeIdx].end));
    i = closeIdx + 1;
  }

  bool insideFence(int offset) => regions.any((r) => r.contains(offset));

  for (final m in _indentedCodePattern.allMatches(content)) {
    if (!insideFence(m.start)) regions.add(TextRange(m.start, m.end));
  }

  for (final m in _inlineCodePattern.allMatches(content)) {
    if (!insideFence(m.start)) regions.add(TextRange(m.start, m.end));
  }

  regions.sort((a, b) => a.start.compareTo(b.start));
  return regions;
}

/// 判断偏移 [offset] 是否落在任一代码区域内。
bool _inAnyRegion(List<TextRange> regions, int offset) {
  // 区间已按 start 升序排列，做二分查找。
  int lo = 0, hi = regions.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final r = regions[mid];
    if (offset < r.start) {
      hi = mid - 1;
    } else if (offset >= r.end) {
      lo = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

/// 解析 [content] 中所有有效的 `[[...]]` 链接，跳过代码区域。
///
/// 返回结果按出现顺序排列，目标与别名均已 trim。
List<WikiLinkMatch> parseLinks(String content) {
  if (content.isEmpty || !content.contains('[[')) return const [];

  final codeRegions = findCodeRegions(content);
  final result = <WikiLinkMatch>[];

  for (final m in _wikiLinkPattern.allMatches(content)) {
    if (_inAnyRegion(codeRegions, m.start)) continue;

    final target = (m.group(1) ?? '').trim();
    if (target.isEmpty) continue;

    final rawAlias = m.group(2);
    final alias = (rawAlias == null || rawAlias.trim().isEmpty)
        ? null
        : rawAlias.trim();

    result.add(
      WikiLinkMatch(
        raw: m.group(0)!,
        target: target,
        alias: alias,
        start: m.start,
        end: m.end,
      ),
    );
  }

  return result;
}

/// 把 [target] 拆成「笔记本名（可空）」与「标题」。
({String? notebook, String title}) splitTarget(String target) {
  final idx = target.lastIndexOf('/');
  if (idx <= 0 || idx == target.length - 1) {
    return (notebook: null, title: target.trim());
  }
  return (
    notebook: target.substring(0, idx).trim(),
    title: target.substring(idx + 1).trim(),
  );
}

/// 构造预览用的自定义 scheme URI。
///
/// 形如 `ashesnote://open?nb=读书笔记&t=卡片法.md&exists=1&raw=...`。
String buildOpenUri({
  required String rawTarget,
  String? notebookName,
  String? title,
  required bool exists,
  bool ambiguous = false,
}) {
  final params = <String, String>{
    'raw': rawTarget,
    'exists': exists ? '1' : '0',
    if (ambiguous) 'amb': '1',
    if (notebookName != null && notebookName.isNotEmpty) 'nb': notebookName,
    if (title != null && title.isNotEmpty) 't': title,
  };
  final query = params.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return '${NoteIndexConstants.linkScheme}://open?$query';
}

/// 从预览链接 URI 反解出跳转意图。
///
/// 非本应用 scheme 时返回 null。
OpenNoteIntent? parseOpenUri(String uriString) {
  final Uri uri;
  try {
    uri = Uri.parse(uriString);
  } catch (_) {
    return null;
  }
  if (uri.scheme != NoteIndexConstants.linkScheme) return null;

  final params = uri.queryParameters;
  final rawTarget = params['raw'] ?? '';
  if (rawTarget.isEmpty) return null;

  return OpenNoteIntent(
    rawTarget: rawTarget,
    notebookName: params['nb'],
    title: params['t'],
    exists: params['exists'] == '1',
    ambiguous: params['amb'] == '1',
  );
}

/// 预览中点击链接后的跳转意图。
class OpenNoteIntent {
  final String rawTarget;
  final String? notebookName;
  final String? title;
  final bool exists;
  final bool ambiguous;

  const OpenNoteIntent({
    required this.rawTarget,
    this.notebookName,
    this.title,
    required this.exists,
    this.ambiguous = false,
  });

  /// 已解析且存在时，可直接得到目标笔记 id。
  String? get noteId {
    if (!exists || notebookName == null || title == null) return null;
    return '$notebookName/$title';
  }

  @override
  String toString() => 'OpenNoteIntent($rawTarget, exists: $exists)';
}

/// 把正文中的 `[[...]]` 重写为标准 Markdown 链接，供 `flutter_markdown_plus` 渲染。
///
/// [resolver] 负责把原始目标解析为具体笔记；代码区域内的链接保持原样。
/// 替换从后往前进行，避免偏移错位。
String rewriteForPreview(
  String content,
  LinkResolution Function(String rawTarget) resolver,
) {
  final links = parseLinks(content);
  if (links.isEmpty) return content;

  final buffer = StringBuffer();
  int cursor = 0;

  for (final link in links) {
    buffer.write(content.substring(cursor, link.start));

    final resolution = resolver(link.target);
    final String uri;
    switch (resolution) {
      case LinkResolved(:final target):
        uri = buildOpenUri(
          rawTarget: link.target,
          notebookName: target.notebookName,
          title: target.title,
          exists: true,
        );
      case LinkAmbiguous():
        uri = buildOpenUri(
          rawTarget: link.target,
          exists: true,
          ambiguous: true,
        );
      case LinkMissing():
        uri = buildOpenUri(rawTarget: link.target, exists: false);
    }

    // 转义显示文本中会破坏 Markdown 链接语法的字符。
    final label = _escapeLinkLabel(link.displayText);
    buffer.write('[$label]($uri)');
    cursor = link.end;
  }

  buffer.write(content.substring(cursor));
  return buffer.toString();
}

String _escapeLinkLabel(String text) {
  return text
      .replaceAll(r'\', r'\\')
      .replaceAll('[', r'\[')
      .replaceAll(']', r'\]');
}

/// 生成自动补全的插入文本，例如 `[[读书笔记/卡片法]]`。
String buildInsertion(NoteRef ref, {String? alias}) {
  final target = ref.notebookName.isEmpty
      ? stripMdSuffix(ref.title)
      : '${ref.notebookName}/${stripMdSuffix(ref.title)}';
  if (alias != null && alias.trim().isNotEmpty) {
    return '[[$target|${alias.trim()}]]';
  }
  return '[[$target]]';
}

/// 光标处的补全上下文。
class AutocompleteContext {
  /// `[[` 之后已输入的前缀。
  final String prefix;

  /// `[[` 中第一个 `[` 的偏移。
  final int triggerStart;

  /// 光标偏移。
  final int caret;

  /// 光标右侧是否已经存在 `]]`，决定插入时是否补右括号。
  final bool hasClosing;

  const AutocompleteContext({
    required this.prefix,
    required this.triggerStart,
    required this.caret,
    required this.hasClosing,
  });
}

/// 判断光标 [caret] 是否处于一个未闭合的 `[[` 之后，并抽取已输入前缀。
///
/// 返回 null 表示当前不应触发补全。
AutocompleteContext? detectAutocomplete(String text, int caret) {
  if (caret < 2 || caret > text.length) return null;

  // 从光标向前找最近的 `[[`，遇到 `]]` 或换行则中止。
  int i = caret - 1;
  int triggerStart = -1;
  while (i >= 1) {
    final ch = text[i];
    if (ch == '\n') return null;
    if (ch == ']' && i > 0 && text[i - 1] == ']') return null;
    if (ch == '[' && text[i - 1] == '[') {
      triggerStart = i - 1;
      break;
    }
    i--;
  }
  if (triggerStart < 0) return null;

  final prefix = text.substring(triggerStart + 2, caret);
  // 前缀内不允许出现括号或换行。
  if (prefix.contains('[') || prefix.contains(']') || prefix.contains('\n')) {
    return null;
  }
  // 前缀过长时视为普通文本，停止补全。
  if (prefix.length > 60) return null;

  // 代码区域内不触发补全。
  if (_inAnyRegion(findCodeRegions(text), triggerStart)) return null;

  final hasClosing = text.startsWith(']]', caret);

  return AutocompleteContext(
    prefix: prefix,
    triggerStart: triggerStart,
    caret: caret,
    hasClosing: hasClosing,
  );
}

/// 应用补全后的文本与新光标位置。
class AutocompleteResult {
  final String newText;
  final int newCaret;
  const AutocompleteResult(this.newText, this.newCaret);
}

/// 在 [context] 处用 [ref] 替换掉已输入的 `[[前缀`，生成完整链接。
AutocompleteResult applyAutocomplete(
  String text,
  AutocompleteContext context,
  NoteRef ref,
) {
  final insertion = buildInsertion(ref);
  final tailStart = context.hasClosing ? context.caret + 2 : context.caret;
  final newText =
      text.substring(0, context.triggerStart) + insertion + text.substring(tailStart);
  return AutocompleteResult(
    newText,
    context.triggerStart + insertion.length,
  );
}

/// 搜索语句解析结果：标签条件 + 剩余关键字。
class ParsedSearchQuery {
  /// `tag:xxx` 抽取出的标签集合。
  final Set<String> tags;

  /// 去掉标签条件后剩下的关键字。
  final String keyword;

  const ParsedSearchQuery(this.tags, this.keyword);

  bool get hasTagFilter => tags.isNotEmpty;
}

/// 匹配 `tag:标签名`，标签名可用引号包裹以包含空格。
final RegExp _tagQueryPattern = RegExp(
  r'''tag:(?:"([^"]+)"|'([^']+)'|(\S+))''',
  caseSensitive: false,
);

/// 解析搜索框输入，支持 `tag:读书 关键字` 这样的组合语法。
ParsedSearchQuery parseSearchQuery(String query) {
  if (!query.toLowerCase().contains('tag:')) {
    return ParsedSearchQuery(const {}, query.trim());
  }

  final tags = <String>{};
  final rest = query.replaceAllMapped(_tagQueryPattern, (m) {
    final value = (m.group(1) ?? m.group(2) ?? m.group(3) ?? '').trim();
    if (value.isNotEmpty) tags.add(value);
    return ' ';
  });

  return ParsedSearchQuery(
    tags,
    rest.replaceAll(RegExp(r'\s+'), ' ').trim(),
  );
}

/// 从来源正文中截取链接命中处的上下文摘要。
///
/// 返回摘要文本与高亮区间（相对摘要的偏移）。
({String snippet, int highlightStart, int highlightLength}) buildSnippet(
  String content,
  WikiLinkMatch link, {
  int radius = NoteIndexConstants.snippetRadius,
}) {
  final displayText = link.displayText;

  var from = link.start - radius;
  var to = link.end + radius;
  final prefixEllipsis = from > 0;
  final suffixEllipsis = to < content.length;
  if (from < 0) from = 0;
  if (to > content.length) to = content.length;

  final before = _collapseWhitespace(content.substring(from, link.start));
  final after = _collapseWhitespace(content.substring(link.end, to));

  final head = prefixEllipsis ? '…$before' : before;
  final tail = suffixEllipsis ? '$after…' : after;

  return (
    snippet: '$head$displayText$tail',
    highlightStart: head.length,
    highlightLength: displayText.length,
  );
}

String _collapseWhitespace(String s) =>
    s.replaceAll(RegExp(r'\s+'), ' ');
