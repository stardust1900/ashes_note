/// 笔记索引层数据模型。
///
/// 本文件刻意不依赖 Flutter UI 库（除 Color 以 int 存储外），
/// 以便被纯 Dart 单元测试直接覆盖。
library;

/// 笔记引用：定位到一篇具体笔记。
///
/// [id] 与 `Note.id` 保持一致，形如 `笔记本名/标题.md`。
class NoteRef {
  /// 所属笔记本名。
  final String notebookName;

  /// 笔记标题（含 `.md` 后缀）。
  final String title;

  /// 笔记唯一标识，等于 `notebookName/title`。
  final String id;

  /// 该笔记当前是否真实存在。
  final bool exists;

  const NoteRef({
    required this.notebookName,
    required this.title,
    required this.id,
    this.exists = true,
  });

  /// 由笔记本名与标题构造，自动拼出 [id] 并补齐 `.md` 后缀。
  factory NoteRef.of(
    String notebookName,
    String title, {
    bool exists = true,
  }) {
    final normalizedTitle = ensureMdSuffix(title);
    return NoteRef(
      notebookName: notebookName,
      title: normalizedTitle,
      id: '$notebookName/$normalizedTitle',
      exists: exists,
    );
  }

  /// 由 `笔记本名/标题.md` 形式的 id 反解。
  ///
  /// 不含斜杠时 [notebookName] 为空字符串。
  factory NoteRef.fromId(String id, {bool exists = true}) {
    final idx = id.lastIndexOf('/');
    if (idx < 0) {
      return NoteRef.of('', id, exists: exists);
    }
    return NoteRef.of(
      id.substring(0, idx),
      id.substring(idx + 1),
      exists: exists,
    );
  }

  /// 去掉 `.md` 后缀的展示用标题。
  String get displayTitle => stripMdSuffix(title);

  NoteRef copyWith({bool? exists}) => NoteRef(
    notebookName: notebookName,
    title: title,
    id: id,
    exists: exists ?? this.exists,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NoteRef && other.id == id && other.exists == exists);

  @override
  int get hashCode => Object.hash(id, exists);

  @override
  String toString() => 'NoteRef($id, exists: $exists)';
}

/// 正文中一处 `[[...]]` 链接的匹配结果。
class WikiLinkMatch {
  /// 原始文本，含双方括号，例如 `[[读书笔记/卡片法|卡片]]`。
  final String raw;

  /// 竖线前的目标部分，例如 `读书笔记/卡片法`。
  final String target;

  /// 竖线后的别名；未指定时为 null。
  final String? alias;

  /// [raw] 在原文中的起始偏移（含）。
  final int start;

  /// [raw] 在原文中的结束偏移（不含）。
  final int end;

  const WikiLinkMatch({
    required this.raw,
    required this.target,
    this.alias,
    required this.start,
    required this.end,
  });

  /// 预览中实际显示的文本：有别名用别名，否则用去掉笔记本前缀与 `.md` 的标题。
  String get displayText {
    if (alias != null && alias!.trim().isNotEmpty) return alias!.trim();
    final idx = target.lastIndexOf('/');
    final titlePart = idx < 0 ? target : target.substring(idx + 1);
    return stripMdSuffix(titlePart);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WikiLinkMatch &&
          other.raw == raw &&
          other.start == start &&
          other.end == end);

  @override
  int get hashCode => Object.hash(raw, start, end);

  @override
  String toString() => 'WikiLinkMatch($raw @$start-$end)';
}

/// 链接解析结果。
sealed class LinkResolution {
  const LinkResolution();
}

/// 唯一命中一篇已存在的笔记。
class LinkResolved extends LinkResolution {
  final NoteRef target;
  const LinkResolved(this.target);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is LinkResolved && other.target == target);

  @override
  int get hashCode => target.hashCode;

  @override
  String toString() => 'LinkResolved(${target.id})';
}

/// 命中多篇同名笔记，需由用户在 [candidates] 中选择。
class LinkAmbiguous extends LinkResolution {
  final String rawTarget;
  final List<NoteRef> candidates;
  const LinkAmbiguous(this.rawTarget, this.candidates);

  @override
  String toString() =>
      'LinkAmbiguous($rawTarget, ${candidates.length} candidates)';
}

/// 未命中任何笔记。[preferredNotebook] 用作「一键创建」时的默认笔记本。
class LinkMissing extends LinkResolution {
  final String rawTarget;
  final String? preferredNotebook;
  const LinkMissing(this.rawTarget, this.preferredNotebook);

  /// 一键创建时应当使用的标题（去掉笔记本前缀）。
  String get suggestedTitle {
    final idx = rawTarget.lastIndexOf('/');
    return idx < 0 ? rawTarget : rawTarget.substring(idx + 1);
  }

  /// 一键创建时应当使用的笔记本：链接里写了就用链接里的。
  String? get suggestedNotebook {
    final idx = rawTarget.lastIndexOf('/');
    if (idx <= 0) return preferredNotebook;
    return rawTarget.substring(0, idx);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LinkMissing &&
          other.rawTarget == rawTarget &&
          other.preferredNotebook == preferredNotebook);

  @override
  int get hashCode => Object.hash(rawTarget, preferredNotebook);

  @override
  String toString() => 'LinkMissing($rawTarget)';
}

/// 一条反向链接记录：谁引用了我，以及引用处的上下文。
class Backlink {
  /// 引用来源笔记。
  final NoteRef sourceRef;

  /// 命中处的上下文摘要（已做换行折叠）。
  final String snippet;

  /// 摘要中链接文本的起始偏移，供 UI 高亮。
  final int highlightStart;

  /// 摘要中链接文本的长度。
  final int highlightLength;

  /// 该来源笔记引用本篇的总次数。
  final int matchCount;

  const Backlink({
    required this.sourceRef,
    required this.snippet,
    required this.highlightStart,
    required this.highlightLength,
    this.matchCount = 1,
  });

  @override
  String toString() => 'Backlink(from ${sourceRef.id}, x$matchCount)';
}

/// 标签及其统计信息。
class TagEntry {
  final String name;

  /// 颜色的 ARGB 整数值；未设置时为 null，由 UI 按名称哈希取默认色。
  final int? color;

  /// 打了该标签的笔记数量。
  final int count;

  const TagEntry({required this.name, this.color, required this.count});

  @override
  String toString() => 'TagEntry($name x$count)';
}

/// 图谱节点。
class GraphNode {
  final String id;

  /// 展示文本（去后缀标题）。
  final String label;
  final String notebookName;

  /// 入链数量，决定节点半径。
  final int inDegree;

  /// 出链数量。
  final int outDegree;

  final List<String> tags;

  const GraphNode({
    required this.id,
    required this.label,
    required this.notebookName,
    this.inDegree = 0,
    this.outDegree = 0,
    this.tags = const [],
  });

  int get degree => inDegree + outDegree;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is GraphNode && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'GraphNode($id)';
}

/// 图谱有向边。
class GraphEdge {
  final String from;
  final String to;

  const GraphEdge(this.from, this.to);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GraphEdge && other.from == from && other.to == to);

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'GraphEdge($from -> $to)';
}

/// 图谱数据集合。
class NoteGraph {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;

  const NoteGraph({required this.nodes, required this.edges});

  static const NoteGraph empty = NoteGraph(nodes: [], edges: []);

  bool get isEmpty => nodes.isEmpty;
}

// ===== 公共工具函数 =====

/// 为标题补齐 `.md` 后缀（已有则原样返回）。
String ensureMdSuffix(String title) {
  final t = title.trim();
  if (t.toLowerCase().endsWith('.md')) return t;
  return '$t.md';
}

/// 去掉标题末尾的 `.md` 后缀。
String stripMdSuffix(String title) {
  if (title.toLowerCase().endsWith('.md')) {
    return title.substring(0, title.length - 3);
  }
  return title;
}

/// 归一化用于匹配的键：去首尾空白、折叠内部空白、去 `.md`、转小写。
///
/// 链接解析与标题索引都必须使用同一套归一化规则。
String normalizeKey(String raw) {
  return stripMdSuffix(raw.trim())
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();
}

/// 归一化标签名：去首尾空白、折叠内部空白。保留原始大小写用于展示。
String normalizeTagName(String raw) {
  return raw.trim().replaceAll(RegExp(r'\s+'), ' ');
}
