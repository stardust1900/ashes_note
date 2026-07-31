/// 笔记索引门面：UI 层唯一依赖的入口。
///
/// 组合链接图（内存派生）与标签索引（文件持久化），
/// 以 [ChangeNotifier] 形式向各页面广播变更。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:ashes_note/logging.dart';
import 'package:ashes_note/models/notes/note_index_models.dart';
import 'package:ashes_note/services/notes/note_link_index.dart';
import 'package:ashes_note/services/notes/tag_index_service.dart';
import 'package:ashes_note/services/notes/wiki_link_parser.dart' as wiki;
import 'package:ashes_note/utils/const.dart';

class NotesIndexService extends ChangeNotifier {
  NotesIndexService._internal();
  static final NotesIndexService _instance = NotesIndexService._internal();
  factory NotesIndexService() => _instance;

  final NoteLinkIndex _links = NoteLinkIndex();
  final TagIndexService _tags = TagIndexService();

  bool _notifyScheduled = false;
  bool _ready = false;
  TagIndexSnapshot? _syncSnapshot;

  /// 索引是否已完成首次构建。
  bool get isReady => _ready;

  /// 已索引的笔记总数。
  int get noteCount => _links.noteCount;

  /// 全部已知笔记，供补全与图谱使用。
  List<NoteRef> get allNotes => _links.allNotes;

  /// 同帧内多次变更合并为一次通知，避免 UI 抖动。
  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  // ===== 构建与生命周期 =====

  /// 全量重建索引。应在 `_loadNotebookList()` 完成后调用。
  ///
  /// [notesRootPath] 为工作目录下的 notes 根路径，用于定位标签索引文件。
  Future<void> rebuild(
    List<Notebook> notebooks, {
    String? notesRootPath,
  }) async {
    try {
      _links.buildAll(notebooks);

      if (notesRootPath != null && notesRootPath.isNotEmpty) {
        final changedRoot = _tags.notesRootPath != notesRootPath;
        _tags.notesRootPath = notesRootPath;
        if (changedRoot || !_tags.isLoaded) {
          await _tags.load();
        }
      }

      // 清理指向已删除笔记的标签记录。
      if (_tags.isLoaded) {
        final existing = _links.allNotes.map((r) => r.id).toSet();
        if (existing.isNotEmpty) {
          await _tags.pruneMissing(existing);
        }
      }

      _ready = true;
    } catch (e) {
      appLog.warning('重建笔记索引失败：$e');
    }
    _scheduleNotify();
  }

  /// 笔记内容保存后增量更新。
  void onNoteSaved(Note note, {String? notebookName}) {
    _links.updateNote(note, notebookName: notebookName);
    _scheduleNotify();
  }

  /// 笔记改名或移动笔记本。
  Future<void> onNoteRenamed(
    String oldId,
    Note newNote, {
    String? notebookName,
  }) async {
    _links.renameNote(oldId, newNote, notebookName: notebookName);
    final newId = NoteRef.of(
      notebookName ?? newNote.notebookName ?? '',
      newNote.title,
    ).id;
    await _tags.onNoteRenamed(oldId, newId);
    _scheduleNotify();
  }

  /// 笔记被删除。
  Future<void> onNoteDeleted(String noteId) async {
    _links.removeNote(noteId);
    await _tags.onNoteDeleted(noteId);
    _scheduleNotify();
  }

  /// 笔记本被删除。
  Future<void> onNotebookDeleted(String notebookName) async {
    _links.removeNotebook(notebookName);
    await _tags.onNotebookDeleted(notebookName);
    _scheduleNotify();
  }

  // ===== 链接查询 =====

  /// 解析一个链接目标。
  LinkResolution resolve(String rawTarget, {String? currentNotebook}) =>
      _links.resolve(rawTarget, currentNotebook: currentNotebook);

  /// 查询指向某篇笔记的反向链接。
  List<Backlink> backlinksOf(String noteId) => _links.backlinksOf(noteId);

  /// 查询某篇笔记的出链。
  List<OutLink> outlinksOf(String noteId) => _links.outlinksOf(noteId);

  /// 查询某篇笔记中未解析的链接。
  List<OutLink> unresolvedOf(String noteId) => _links.unresolvedOf(noteId);

  /// 判断笔记是否已被索引。
  bool containsNote(String noteId) => _links.contains(noteId);

  /// 补全候选。
  List<NoteRef> searchTitles(
    String query, {
    String? currentNotebook,
    int limit = NoteIndexConstants.maxAutocompleteItems,
  }) => _links.searchTitles(query, currentNotebook: currentNotebook, limit: limit);

  /// 把正文重写为可点击的预览 Markdown。
  String rewriteForPreview(String content, {String? currentNotebook}) {
    return wiki.rewriteForPreview(
      content,
      (target) => _links.resolve(target, currentNotebook: currentNotebook),
    );
  }

  /// 构建关系图谱，自动带上标签着色所需信息。
  NoteGraph buildGraph({
    String? focusId,
    int depth = NoteIndexConstants.graphNeighborhoodDepth,
    bool includeIsolated = true,
  }) {
    final tagsByNote = <String, List<String>>{};
    for (final ref in _links.allNotes) {
      final tags = _tags.tagsOf(ref.id);
      if (tags.isNotEmpty) tagsByNote[ref.id] = tags;
    }
    return _links.buildGraph(
      focusId: focusId,
      depth: depth,
      includeIsolated: includeIsolated,
      tagsByNote: tagsByNote,
    );
  }

  // ===== 标签查询与写入 =====

  /// 标签索引是否可用（工作目录已设置且加载完成）。
  bool get tagsAvailable => _tags.isLoaded;

  List<String> tagsOf(String noteId) => _tags.tagsOf(noteId);

  List<TagEntry> allTagsWithCount({bool sortByName = false}) =>
      _tags.allTagsWithCount(sortByName: sortByName);

  Set<String> notesOfTags(Set<String> tags, {bool matchAll = false}) =>
      _tags.notesOfTags(tags, matchAll: matchAll);

  int? tagColorOf(String tag) => _tags.colorOf(tag);

  bool hasTag(String tag) => _tags.hasTag(tag);

  Future<void> setTags(String noteId, List<String> tags) async {
    await _tags.setTags(noteId, tags);
    _scheduleNotify();
  }

  Future<void> addTag(String noteId, String tag) async {
    await _tags.addTag(noteId, tag);
    _scheduleNotify();
  }

  Future<void> removeTag(String noteId, String tag) async {
    await _tags.removeTag(noteId, tag);
    _scheduleNotify();
  }

  Future<void> renameTag(String from, String to) async {
    await _tags.renameTag(from, to);
    _scheduleNotify();
  }

  Future<void> deleteTag(String tag) async {
    await _tags.deleteTag(tag);
    _scheduleNotify();
  }

  Future<void> setTagColor(String tag, int? color) async {
    await _tags.setTagColor(tag, color);
    _scheduleNotify();
  }

  /// 立即把标签索引写盘（应用退出、手动同步前调用）。
  Future<void> flushTags() => _tags.flush();

  // ===== Git 同步配合 =====

  /// 同步开始前：先写盘，再对内存状态拍快照。
  Future<void> beforeGitSync() async {
    await _tags.flush();
    _syncSnapshot = _tags.snapshot();
  }

  /// 同步结束后：重新读取被远端覆盖的索引文件，并把本地改动按条目合并回来。
  Future<void> afterGitSync() async {
    final snapshot = _syncSnapshot;
    _syncSnapshot = null;

    try {
      await _tags.load();
      if (snapshot != null) {
        await _tags.mergeFrom(snapshot);
      }
    } catch (e) {
      appLog.warning('同步后合并标签索引失败：$e');
    }
    _scheduleNotify();
  }

  /// 设置标签索引所在的 notes 根路径。
  set notesRootPath(String? path) => _tags.notesRootPath = path;

  String? get notesRootPath => _tags.notesRootPath;
}
