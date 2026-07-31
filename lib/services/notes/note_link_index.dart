/// 内存中的笔记链接图：正向出链、反向入链、未解析链接与标题索引。
///
/// 该类不做任何 I/O，数据完全从 `Note.content` 派生，可随时重建。
library;

import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:ashes_note/models/notes/note_index_models.dart';
import 'package:ashes_note/services/notes/wiki_link_parser.dart';
import 'package:ashes_note/utils/const.dart';

/// 一条已解析的出链记录。
class OutLink {
  final WikiLinkMatch match;
  final LinkResolution resolution;

  const OutLink(this.match, this.resolution);

  /// 解析成功时的目标 id。
  String? get resolvedTargetId =>
      resolution is LinkResolved ? (resolution as LinkResolved).target.id : null;
}

class NoteLinkIndex {
  /// noteId -> 该笔记的全部出链。
  final Map<String, List<OutLink>> _forward = {};

  /// 目标 noteId -> 引用它的来源 noteId 集合。
  final Map<String, Set<String>> _backward = {};

  /// 归一化目标名 -> 引用它但未解析成功的来源 noteId 集合。
  final Map<String, Set<String>> _unresolved = {};

  /// 归一化标题 -> 同名笔记引用列表（用于解析与补全）。
  final Map<String, List<NoteRef>> _titleIndex = {};

  /// noteId -> 笔记正文，供反链摘要按需截取。
  final Map<String, String> _contents = {};

  /// noteId -> NoteRef，全部已知笔记。
  final Map<String, NoteRef> _notes = {};

  /// 当前已索引的笔记总数。
  int get noteCount => _notes.length;

  /// 全部已知笔记引用，按笔记本+标题排序，供补全使用。
  List<NoteRef> get allNotes {
    final list = _notes.values.toList();
    list.sort((a, b) {
      final c = a.notebookName.compareTo(b.notebookName);
      return c != 0 ? c : a.title.compareTo(b.title);
    });
    return list;
  }

  /// 全量重建索引。
  void buildAll(List<Notebook> notebooks) {
    _forward.clear();
    _backward.clear();
    _unresolved.clear();
    _titleIndex.clear();
    _contents.clear();
    _notes.clear();

    // 第一遍：建立标题索引，确保后续解析能看到全部笔记。
    for (final notebook in notebooks) {
      for (final note in notebook.notes) {
        final ref = NoteRef.of(notebook.name, note.title);
        _notes[ref.id] = ref;
        _contents[ref.id] = note.content;
        _titleIndex.putIfAbsent(normalizeKey(note.title), () => []).add(ref);
      }
    }

    // 第二遍：解析链接建图。
    for (final id in _notes.keys) {
      _indexOutLinks(id);
    }
  }

  /// 解析单篇笔记的出链并写入正向表与反向表。
  void _indexOutLinks(String noteId) {
    final content = _contents[noteId];
    if (content == null) return;
    final currentNotebook = _notes[noteId]?.notebookName;

    final links = parseLinks(content);
    final outLinks = <OutLink>[];

    for (final link in links) {
      final resolution = resolve(link.target, currentNotebook: currentNotebook);
      outLinks.add(OutLink(link, resolution));

      switch (resolution) {
        case LinkResolved(:final target):
          _backward.putIfAbsent(target.id, () => <String>{}).add(noteId);
        case LinkAmbiguous(:final candidates):
          // 歧义链接对所有候选都记一条反链，便于用户从任一候选发现引用。
          for (final c in candidates) {
            _backward.putIfAbsent(c.id, () => <String>{}).add(noteId);
          }
        case LinkMissing(:final rawTarget):
          _unresolved
              .putIfAbsent(normalizeKey(rawTarget), () => <String>{})
              .add(noteId);
      }
    }

    if (outLinks.isEmpty) {
      _forward.remove(noteId);
    } else {
      _forward[noteId] = outLinks;
    }
  }

  /// 移除某篇笔记的全部出链在反向表/未解析表中的痕迹。
  void _removeOutLinks(String noteId) {
    final old = _forward.remove(noteId);
    if (old == null) return;

    for (final out in old) {
      switch (out.resolution) {
        case LinkResolved(:final target):
          _detachBackward(target.id, noteId);
        case LinkAmbiguous(:final candidates):
          for (final c in candidates) {
            _detachBackward(c.id, noteId);
          }
        case LinkMissing(:final rawTarget):
          final key = normalizeKey(rawTarget);
          final set = _unresolved[key];
          if (set != null) {
            set.remove(noteId);
            if (set.isEmpty) _unresolved.remove(key);
          }
      }
    }
  }

  void _detachBackward(String targetId, String sourceId) {
    final set = _backward[targetId];
    if (set == null) return;
    set.remove(sourceId);
    if (set.isEmpty) _backward.remove(targetId);
  }

  /// 增量更新单篇笔记（内容变更或新建）。
  ///
  /// 仅重算本篇出链并差分维护反链表；不触碰其他笔记。
  void updateNote(Note note, {String? notebookName}) {
    final nb = notebookName ?? note.notebookName ?? _notebookOf(note.id);
    final ref = NoteRef.of(nb, note.title);

    final isNew = !_notes.containsKey(ref.id);
    _removeOutLinks(ref.id);

    _notes[ref.id] = ref;
    _contents[ref.id] = note.content;

    if (isNew) {
      _titleIndex.putIfAbsent(normalizeKey(note.title), () => []).add(ref);
      // 新笔记可能让此前「未解析」的链接得以解析，需重算这些来源。
      _reindexSourcesResolvingTo(note.title);
    }

    _indexOutLinks(ref.id);
  }

  /// 删除一篇笔记。
  ///
  /// 其出链从反链表摘除；指向它的入链降级为「未解析」。
  void removeNote(String noteId) {
    _removeOutLinks(noteId);

    final ref = _notes.remove(noteId);
    _contents.remove(noteId);

    if (ref != null) {
      final key = normalizeKey(ref.title);
      final list = _titleIndex[key];
      if (list != null) {
        list.removeWhere((e) => e.id == noteId);
        if (list.isEmpty) _titleIndex.remove(key);
      }
    }

    // 曾经指向它的来源需要重算（会变成 missing 或改指同名笔记）。
    final sources = _backward.remove(noteId)?.toList() ?? const <String>[];
    for (final src in sources) {
      if (_notes.containsKey(src)) {
        _removeOutLinks(src);
        _indexOutLinks(src);
      }
    }
  }

  /// 笔记改名或移动笔记本。
  void renameNote(String oldId, Note newNote, {String? notebookName}) {
    final oldRef = _notes[oldId];
    final sources = _backward[oldId]?.toList() ?? const <String>[];
    final oldTitle = oldRef?.title;

    removeNote(oldId);
    updateNote(newNote, notebookName: notebookName);

    // 原先指向旧标题的来源重算，可能变为未解析。
    for (final src in sources) {
      if (_notes.containsKey(src)) {
        _removeOutLinks(src);
        _indexOutLinks(src);
      }
    }
    // 原先未解析到新标题的来源也可能因此命中。
    _reindexSourcesResolvingTo(newNote.title);
    if (oldTitle != null) _reindexSourcesResolvingTo(oldTitle);
  }

  /// 删除整个笔记本下的所有笔记。
  void removeNotebook(String notebookName) {
    final ids = _notes.values
        .where((r) => r.notebookName == notebookName)
        .map((r) => r.id)
        .toList();
    for (final id in ids) {
      removeNote(id);
    }
  }

  /// 重算所有「未解析目标恰好等于 [title]」的来源笔记。
  void _reindexSourcesResolvingTo(String title) {
    final key = normalizeKey(title);
    final direct = _unresolved[key]?.toList() ?? const <String>[];

    // 带笔记本前缀的未解析目标（如 `读书/卡片法`）也需要检查。
    final withPrefix = <String>[];
    for (final entry in _unresolved.entries) {
      final k = entry.key;
      final idx = k.lastIndexOf('/');
      if (idx >= 0 && k.substring(idx + 1) == key) {
        withPrefix.addAll(entry.value);
      }
    }

    final sources = {...direct, ...withPrefix};
    for (final src in sources) {
      if (_notes.containsKey(src)) {
        _removeOutLinks(src);
        _indexOutLinks(src);
      }
    }
  }

  String _notebookOf(String id) {
    final idx = id.lastIndexOf('/');
    return idx < 0 ? '' : id.substring(0, idx);
  }

  /// 解析一个链接目标。
  ///
  /// 优先级：带笔记本前缀精确匹配 → 当前笔记本内同名 → 全局唯一同名 →
  /// 多篇同名则 ambiguous → 无匹配则 missing。
  LinkResolution resolve(String rawTarget, {String? currentNotebook}) {
    final trimmed = rawTarget.trim();
    if (trimmed.isEmpty) {
      return LinkMissing(rawTarget, currentNotebook);
    }

    final parts = splitTarget(trimmed);

    // 情况一：显式写了 `笔记本/标题`。
    if (parts.notebook != null && parts.notebook!.isNotEmpty) {
      final exactId = '${parts.notebook}/${ensureMdSuffix(parts.title)}';
      final direct = _notes[exactId];
      if (direct != null) return LinkResolved(direct);

      // 大小写不敏感回退。
      final nbKey = parts.notebook!.toLowerCase();
      final titleKey = normalizeKey(parts.title);
      for (final ref in _notes.values) {
        if (ref.notebookName.toLowerCase() == nbKey &&
            normalizeKey(ref.title) == titleKey) {
          return LinkResolved(ref);
        }
      }
      return LinkMissing(trimmed, parts.notebook);
    }

    // 情况二：只写了标题。
    final candidates = _titleIndex[normalizeKey(parts.title)];
    if (candidates == null || candidates.isEmpty) {
      return LinkMissing(trimmed, currentNotebook);
    }
    if (candidates.length == 1) {
      return LinkResolved(candidates.first);
    }

    // 多篇同名：当前笔记本优先。
    if (currentNotebook != null) {
      for (final c in candidates) {
        if (c.notebookName == currentNotebook) return LinkResolved(c);
      }
    }
    return LinkAmbiguous(trimmed, List.unmodifiable(candidates));
  }

  /// 查询指向 [noteId] 的全部反向链接（含上下文摘要）。
  List<Backlink> backlinksOf(String noteId) {
    final sources = _backward[noteId];
    if (sources == null || sources.isEmpty) return const [];

    final result = <Backlink>[];
    for (final sourceId in sources) {
      final sourceRef = _notes[sourceId];
      final content = _contents[sourceId];
      if (sourceRef == null || content == null) continue;

      final outs = _forward[sourceId] ?? const <OutLink>[];
      final hits = outs.where((o) {
        switch (o.resolution) {
          case LinkResolved(:final target):
            return target.id == noteId;
          case LinkAmbiguous(:final candidates):
            return candidates.any((c) => c.id == noteId);
          case LinkMissing():
            return false;
        }
      }).toList();
      if (hits.isEmpty) continue;

      final snippet = buildSnippet(content, hits.first.match);
      result.add(
        Backlink(
          sourceRef: sourceRef,
          snippet: snippet.snippet,
          highlightStart: snippet.highlightStart,
          highlightLength: snippet.highlightLength,
          matchCount: hits.length,
        ),
      );
    }

    result.sort((a, b) => a.sourceRef.id.compareTo(b.sourceRef.id));
    return result;
  }

  /// 查询 [noteId] 的全部出链。
  List<OutLink> outlinksOf(String noteId) =>
      List.unmodifiable(_forward[noteId] ?? const <OutLink>[]);

  /// 查询 [noteId] 中未能解析的链接。
  List<OutLink> unresolvedOf(String noteId) => List.unmodifiable(
    (_forward[noteId] ?? const <OutLink>[])
        .where((o) => o.resolution is LinkMissing)
        .toList(),
  );

  /// 判断某篇笔记是否已被索引。
  bool contains(String noteId) => _notes.containsKey(noteId);

  /// 按关键字过滤笔记标题，供自动补全使用。
  ///
  /// [currentNotebook] 内的笔记优先排列；[limit] 限制返回条数。
  List<NoteRef> searchTitles(
    String query, {
    String? currentNotebook,
    int limit = NoteIndexConstants.maxAutocompleteItems,
  }) {
    final q = normalizeKey(query);
    final matched = <NoteRef>[];

    for (final ref in _notes.values) {
      if (q.isEmpty) {
        matched.add(ref);
        continue;
      }
      final titleKey = normalizeKey(ref.title);
      final fullKey = normalizeKey('${ref.notebookName}/${ref.title}');
      if (titleKey.contains(q) || fullKey.contains(q)) {
        matched.add(ref);
      }
    }

    matched.sort((a, b) {
      // 当前笔记本优先。
      if (currentNotebook != null) {
        final aIn = a.notebookName == currentNotebook ? 0 : 1;
        final bIn = b.notebookName == currentNotebook ? 0 : 1;
        if (aIn != bIn) return aIn - bIn;
      }
      if (q.isNotEmpty) {
        // 前缀匹配优先于子串匹配。
        final aPrefix = normalizeKey(a.title).startsWith(q) ? 0 : 1;
        final bPrefix = normalizeKey(b.title).startsWith(q) ? 0 : 1;
        if (aPrefix != bPrefix) return aPrefix - bPrefix;
      }
      final c = a.notebookName.compareTo(b.notebookName);
      return c != 0 ? c : a.title.compareTo(b.title);
    });

    return matched.length > limit ? matched.sublist(0, limit) : matched;
  }

  /// 构建关系图谱。
  ///
  /// [focusId] 非空时只取其 [depth] 度邻域；[includeIsolated] 控制是否保留孤立节点。
  NoteGraph buildGraph({
    String? focusId,
    int depth = NoteIndexConstants.graphNeighborhoodDepth,
    bool includeIsolated = true,
    Map<String, List<String>> tagsByNote = const {},
  }) {
    // 先算出全量边（只保留解析成功且两端都存在的边）。
    final allEdges = <GraphEdge>{};
    for (final entry in _forward.entries) {
      final from = entry.key;
      for (final out in entry.value) {
        final toId = out.resolvedTargetId;
        if (toId == null || toId == from) continue;
        if (!_notes.containsKey(toId)) continue;
        allEdges.add(GraphEdge(from, toId));
      }
    }

    // 确定纳入的节点集合。
    Set<String> nodeIds;
    if (focusId != null && _notes.containsKey(focusId)) {
      final adjacency = <String, Set<String>>{};
      for (final e in allEdges) {
        adjacency.putIfAbsent(e.from, () => {}).add(e.to);
        adjacency.putIfAbsent(e.to, () => {}).add(e.from);
      }
      nodeIds = {focusId};
      var frontier = {focusId};
      for (var d = 0; d < depth; d++) {
        final next = <String>{};
        for (final id in frontier) {
          next.addAll(adjacency[id] ?? const <String>{});
        }
        next.removeAll(nodeIds);
        if (next.isEmpty) break;
        nodeIds.addAll(next);
        frontier = next;
      }
    } else {
      nodeIds = _notes.keys.toSet();
    }

    final edges = allEdges
        .where((e) => nodeIds.contains(e.from) && nodeIds.contains(e.to))
        .toList();

    final inDegree = <String, int>{};
    final outDegree = <String, int>{};
    for (final e in edges) {
      outDegree[e.from] = (outDegree[e.from] ?? 0) + 1;
      inDegree[e.to] = (inDegree[e.to] ?? 0) + 1;
    }

    final nodes = <GraphNode>[];
    for (final id in nodeIds) {
      final ref = _notes[id];
      if (ref == null) continue;
      final din = inDegree[id] ?? 0;
      final dout = outDegree[id] ?? 0;
      if (!includeIsolated && din == 0 && dout == 0 && id != focusId) continue;
      nodes.add(
        GraphNode(
          id: id,
          label: ref.displayTitle,
          notebookName: ref.notebookName,
          inDegree: din,
          outDegree: dout,
          tags: tagsByNote[id] ?? const [],
        ),
      );
    }

    nodes.sort((a, b) => a.id.compareTo(b.id));
    edges.sort((a, b) {
      final c = a.from.compareTo(b.from);
      return c != 0 ? c : a.to.compareTo(b.to);
    });

    return NoteGraph(nodes: nodes, edges: edges);
  }
}
