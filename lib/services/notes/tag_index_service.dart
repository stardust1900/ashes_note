/// 标签索引：把「笔记 -> 标签」关系持久化到独立索引文件。
///
/// 刻意不写入 `.md` 原文，保证笔记在其他 Markdown 工具中打开时内容不变。
/// 索引文件位于 `<工作目录>/notes/.ashes/tags.json`。
library;

import 'dart:async';
import 'dart:convert';

import 'package:ashes_note/logging.dart';
import 'package:ashes_note/models/notes/note_index_models.dart';
import 'package:ashes_note/utils/const.dart';
import 'package:ashes_note/utils/file_util.dart';

/// 单篇笔记的标签记录。
class NoteTagRecord {
  List<String> tags;
  DateTime updatedAt;

  NoteTagRecord(this.tags, this.updatedAt);

  Map<String, dynamic> toJson() => {
    'tags': tags,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  static NoteTagRecord? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final tagsRaw = raw['tags'];
    if (tagsRaw is! List) return null;
    final tags = tagsRaw
        .whereType<String>()
        .map(normalizeTagName)
        .where((t) => t.isNotEmpty)
        .toList();
    final updatedAt =
        DateTime.tryParse(raw['updatedAt']?.toString() ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return NoteTagRecord(_dedupe(tags), updatedAt);
  }
}

/// 标签的元信息（颜色等）。
class TagMeta {
  int? color;
  DateTime createdAt;

  TagMeta(this.color, this.createdAt);

  Map<String, dynamic> toJson() => {
    if (color != null) 'color': _toHex(color!),
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  static TagMeta fromJson(dynamic raw) {
    if (raw is! Map) {
      return TagMeta(null, DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    }
    return TagMeta(
      _parseHex(raw['color']?.toString()),
      DateTime.tryParse(raw['createdAt']?.toString() ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

String _toHex(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

int? _parseHex(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  var h = hex.startsWith('#') ? hex.substring(1) : hex;
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return null;
  return int.tryParse(h, radix: 16);
}

List<String> _dedupe(List<String> tags) {
  final seen = <String>{};
  final result = <String>[];
  for (final t in tags) {
    final key = t.toLowerCase();
    if (seen.add(key)) result.add(t);
  }
  return result;
}

/// 标签索引的可序列化快照，用于 Git 同步前后的合并。
class TagIndexSnapshot {
  final Map<String, NoteTagRecord> notes;
  final Map<String, TagMeta> tagMeta;

  TagIndexSnapshot(this.notes, this.tagMeta);
}

class TagIndexService {
  TagIndexService._internal();
  static final TagIndexService _instance = TagIndexService._internal();
  factory TagIndexService() => _instance;

  /// noteId -> 标签记录。
  final Map<String, NoteTagRecord> _notes = {};

  /// 归一化标签名(小写) -> 元信息。
  final Map<String, TagMeta> _tagMeta = {};

  /// 归一化标签名(小写) -> 展示用原始名。
  final Map<String, String> _displayNames = {};

  /// 归一化标签名(小写) -> 笔记 id 集合（倒排索引）。
  final Map<String, Set<String>> _inverted = {};

  String? _notesRootPath;
  Timer? _saveDebounce;
  String? _lastWrittenJson;
  bool _loaded = false;

  /// 索引是否已成功加载。
  bool get isLoaded => _loaded;

  /// 当前工作目录下的 notes 根路径。
  set notesRootPath(String? path) {
    if (_notesRootPath != path) {
      _notesRootPath = path;
      _loaded = false;
    }
  }

  String? get notesRootPath => _notesRootPath;

  // ===== 读取 =====

  /// 从索引文件加载。文件不存在或损坏时以空索引启动，绝不抛出。
  Future<void> load() async {
    final root = _notesRootPath;
    if (root == null || root.isEmpty) {
      _loaded = false;
      return;
    }

    String? raw;
    try {
      raw = await FileUtil().readFile(
        root,
        NoteIndexConstants.indexDir,
        NoteIndexConstants.tagsFile,
      );
    } catch (_) {
      // 文件不存在属于正常情况（首次使用）。
      _clearAll();
      _loaded = true;
      _lastWrittenJson = null;
      return;
    }

    if (raw.trim().isEmpty) {
      _clearAll();
      _loaded = true;
      return;
    }

    try {
      _applyJson(raw);
      _loaded = true;
      _lastWrittenJson = raw;
    } catch (e) {
      appLog.warning('标签索引解析失败，已降级为空索引：$e');
      await _backupCorruptedFile(raw);
      _clearAll();
      _loaded = true;
      _lastWrittenJson = null;
    }
  }

  void _applyJson(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('根节点不是对象');

    final version = decoded['version'];
    if (version is int && version > NoteIndexConstants.schemaVersion) {
      appLog.warning('标签索引版本 $version 高于当前支持版本，可能存在未知字段');
    }

    _clearAll();

    final notesRaw = decoded['notes'];
    if (notesRaw is Map) {
      for (final entry in notesRaw.entries) {
        final record = NoteTagRecord.fromJson(entry.value);
        if (record == null || record.tags.isEmpty) continue;
        _notes[entry.key.toString()] = record;
      }
    }

    final metaRaw = decoded['tagMeta'];
    if (metaRaw is Map) {
      for (final entry in metaRaw.entries) {
        final name = normalizeTagName(entry.key.toString());
        if (name.isEmpty) continue;
        _tagMeta[name.toLowerCase()] = TagMeta.fromJson(entry.value);
        _displayNames[name.toLowerCase()] = name;
      }
    }

    _rebuildInverted();
  }

  Future<void> _backupCorruptedFile(String raw) async {
    final root = _notesRootPath;
    if (root == null) return;
    try {
      await FileUtil().saveFile(
        root,
        NoteIndexConstants.indexDir,
        NoteIndexConstants.tagsBackupFile,
        utf8.encode(raw),
      );
      appLog.warning('损坏的标签索引已备份为 ${NoteIndexConstants.tagsBackupFile}');
    } catch (e) {
      appLog.warning('备份损坏的标签索引失败：$e');
    }
  }

  void _clearAll() {
    _notes.clear();
    _tagMeta.clear();
    _displayNames.clear();
    _inverted.clear();
  }

  void _rebuildInverted() {
    _inverted.clear();
    for (final entry in _notes.entries) {
      for (final tag in entry.value.tags) {
        final key = tag.toLowerCase();
        _inverted.putIfAbsent(key, () => <String>{}).add(entry.key);
        _displayNames.putIfAbsent(key, () => tag);
      }
    }
  }

  // ===== 查询 =====

  /// 查询某篇笔记的标签（按录入顺序）。
  List<String> tagsOf(String noteId) =>
      List.unmodifiable(_notes[noteId]?.tags ?? const <String>[]);

  /// 全部标签及其笔记数，默认按笔记数降序、同数按名称升序。
  List<TagEntry> allTagsWithCount({bool sortByName = false}) {
    final result = <TagEntry>[];
    for (final entry in _inverted.entries) {
      if (entry.value.isEmpty) continue;
      final display = _displayNames[entry.key] ?? entry.key;
      result.add(
        TagEntry(
          name: display,
          color: _tagMeta[entry.key]?.color,
          count: entry.value.length,
        ),
      );
    }

    result.sort((a, b) {
      if (sortByName) return a.name.compareTo(b.name);
      final c = b.count.compareTo(a.count);
      return c != 0 ? c : a.name.compareTo(b.name);
    });
    return result;
  }

  /// 按标签集合筛选笔记 id。
  ///
  /// [matchAll] 为 true 时要求同时具备全部标签，否则任一即可。
  Set<String> notesOfTags(Set<String> tags, {bool matchAll = false}) {
    if (tags.isEmpty) return <String>{};

    final sets = tags
        .map((t) => _inverted[t.toLowerCase()] ?? const <String>{})
        .toList();

    if (matchAll) {
      if (sets.any((s) => s.isEmpty)) return <String>{};
      final result = sets.first.toSet();
      for (final s in sets.skip(1)) {
        result.retainAll(s);
      }
      return result;
    }

    final result = <String>{};
    for (final s in sets) {
      result.addAll(s);
    }
    return result;
  }

  /// 取标签颜色（未设置返回 null）。
  int? colorOf(String tag) => _tagMeta[tag.toLowerCase()]?.color;

  /// 是否存在该标签。
  bool hasTag(String tag) => _inverted.containsKey(tag.toLowerCase());

  // ===== 写入 =====

  /// 覆盖设置某篇笔记的标签。
  ///
  /// 会做归一化、去重、剔除空值；标签为空时移除该笔记记录。
  Future<void> setTags(String noteId, List<String> tags) async {
    // 先按原始值剔除非法字符（逗号、换行），再做归一化。
    // 顺序不能颠倒：normalizeTagName 会把换行折叠成空格，之后就检测不到了。
    final normalized = _dedupe(
      tags
          .where((t) => !t.contains(',') && !t.contains('\n') && !t.contains('\r'))
          .map(normalizeTagName)
          .where((t) => t.isNotEmpty)
          .toList(),
    );

    final old = _notes[noteId]?.tags ?? const <String>[];
    if (_sameTags(old, normalized)) return;

    // 从倒排表摘除旧标签。
    for (final t in old) {
      final key = t.toLowerCase();
      final set = _inverted[key];
      if (set != null) {
        set.remove(noteId);
        if (set.isEmpty) _inverted.remove(key);
      }
    }

    if (normalized.isEmpty) {
      _notes.remove(noteId);
    } else {
      _notes[noteId] = NoteTagRecord(normalized, DateTime.now().toUtc());
      for (final t in normalized) {
        final key = t.toLowerCase();
        _inverted.putIfAbsent(key, () => <String>{}).add(noteId);
        _displayNames.putIfAbsent(key, () => t);
        _tagMeta.putIfAbsent(key, () => TagMeta(null, DateTime.now().toUtc()));
      }
    }

    _scheduleSave();
  }

  bool _sameTags(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 为笔记追加一个标签。
  Future<void> addTag(String noteId, String tag) async {
    if (tag.contains(',') || tag.contains('\n') || tag.contains('\r')) return;
    final t = normalizeTagName(tag);
    if (t.isEmpty) return;
    final current = List<String>.from(tagsOf(noteId));
    if (current.any((e) => e.toLowerCase() == t.toLowerCase())) return;
    current.add(t);
    await setTags(noteId, current);
  }

  /// 从笔记移除一个标签。
  Future<void> removeTag(String noteId, String tag) async {
    final current = List<String>.from(tagsOf(noteId))
      ..removeWhere((e) => e.toLowerCase() == tag.toLowerCase());
    await setTags(noteId, current);
  }

  /// 全局重命名标签。
  Future<void> renameTag(String from, String to) async {
    final fromKey = from.toLowerCase();
    final newName = normalizeTagName(to);
    if (newName.isEmpty || fromKey == newName.toLowerCase()) return;

    final affected = _inverted[fromKey]?.toList() ?? const <String>[];
    if (affected.isEmpty) return;

    final now = DateTime.now().toUtc();
    for (final noteId in affected) {
      final record = _notes[noteId];
      if (record == null) continue;
      final replaced = <String>[];
      for (final t in record.tags) {
        replaced.add(t.toLowerCase() == fromKey ? newName : t);
      }
      record.tags = _dedupe(replaced);
      record.updatedAt = now;
    }

    final meta = _tagMeta.remove(fromKey);
    _displayNames.remove(fromKey);
    if (meta != null) {
      _tagMeta[newName.toLowerCase()] = meta;
    }
    _displayNames[newName.toLowerCase()] = newName;

    _rebuildInverted();
    _scheduleSave();
  }

  /// 全局删除标签（从所有笔记上摘除）。
  Future<void> deleteTag(String tag) async {
    final key = tag.toLowerCase();
    final affected = _inverted[key]?.toList() ?? const <String>[];
    if (affected.isEmpty) {
      // 仍可能存在孤立的元信息。
      if (_tagMeta.remove(key) != null) {
        _displayNames.remove(key);
        _scheduleSave();
      }
      return;
    }

    final now = DateTime.now().toUtc();
    for (final noteId in affected) {
      final record = _notes[noteId];
      if (record == null) continue;
      record.tags = record.tags.where((t) => t.toLowerCase() != key).toList();
      record.updatedAt = now;
      if (record.tags.isEmpty) _notes.remove(noteId);
    }

    _tagMeta.remove(key);
    _displayNames.remove(key);
    _rebuildInverted();
    _scheduleSave();
  }

  /// 设置标签颜色（[color] 为 null 表示恢复默认）。
  Future<void> setTagColor(String tag, int? color) async {
    final key = tag.toLowerCase();
    final meta = _tagMeta[key];
    if (meta == null) {
      _tagMeta[key] = TagMeta(color, DateTime.now().toUtc());
      _displayNames.putIfAbsent(key, () => normalizeTagName(tag));
    } else {
      if (meta.color == color) return;
      meta.color = color;
    }
    _scheduleSave();
  }

  // ===== 笔记生命周期同步 =====

  /// 笔记改名/移动：把标签迁移到新 id。
  Future<void> onNoteRenamed(String oldId, String newId) async {
    if (oldId == newId) return;
    final record = _notes.remove(oldId);
    if (record == null) return;
    record.updatedAt = DateTime.now().toUtc();
    _notes[newId] = record;
    _rebuildInverted();
    _scheduleSave();
  }

  /// 笔记删除：清掉其标签记录。
  Future<void> onNoteDeleted(String noteId) async {
    if (_notes.remove(noteId) == null) return;
    _rebuildInverted();
    _scheduleSave();
  }

  /// 笔记本删除：清掉该笔记本下所有笔记的标签记录。
  Future<void> onNotebookDeleted(String notebookName) async {
    final prefix = '$notebookName/';
    final removed = _notes.keys.where((k) => k.startsWith(prefix)).toList();
    if (removed.isEmpty) return;
    for (final id in removed) {
      _notes.remove(id);
    }
    _rebuildInverted();
    _scheduleSave();
  }

  /// 清理已不存在的笔记的标签记录（在全量重建后调用）。
  Future<void> pruneMissing(Set<String> existingIds) async {
    final stale = _notes.keys.where((k) => !existingIds.contains(k)).toList();
    if (stale.isEmpty) return;
    for (final id in stale) {
      _notes.remove(id);
    }
    appLog.info('清理了 ${stale.length} 条失效的标签记录');
    _rebuildInverted();
    _scheduleSave();
  }

  // ===== 同步合并 =====

  /// 生成当前内存状态的深拷贝快照。
  TagIndexSnapshot snapshot() {
    final notes = <String, NoteTagRecord>{};
    for (final e in _notes.entries) {
      notes[e.key] = NoteTagRecord(
        List<String>.from(e.value.tags),
        e.value.updatedAt,
      );
    }
    final meta = <String, TagMeta>{};
    for (final e in _tagMeta.entries) {
      meta[e.key] = TagMeta(e.value.color, e.value.createdAt);
    }
    return TagIndexSnapshot(notes, meta);
  }

  /// 与快照合并：按笔记条目比较 `updatedAt` 取新，tagMeta 取并集。
  ///
  /// 用于 Git pull 覆盖本地文件后，把本地未同步的改动合并回来。
  Future<void> mergeFrom(TagIndexSnapshot local) async {
    var changed = false;

    for (final entry in local.notes.entries) {
      final remote = _notes[entry.key];
      if (remote == null || entry.value.updatedAt.isAfter(remote.updatedAt)) {
        _notes[entry.key] = entry.value;
        changed = true;
      }
    }

    for (final entry in local.tagMeta.entries) {
      final existing = _tagMeta[entry.key];
      if (existing == null) {
        _tagMeta[entry.key] = entry.value;
        changed = true;
      } else if (existing.color == null && entry.value.color != null) {
        existing.color = entry.value.color;
        changed = true;
      }
    }

    if (changed) {
      _rebuildInverted();
      _scheduleSave();
    }
  }

  // ===== 持久化 =====

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(NoteIndexConstants.tagsSaveDebounce, () {
      unawaited(flush());
    });
  }

  /// 立即写盘（若内容无变化则跳过）。
  Future<void> flush() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;

    final root = _notesRootPath;
    if (root == null || root.isEmpty) return;

    final json = _encode();
    if (json == _lastWrittenJson) return;

    try {
      await FileUtil().createDirectory(root, NoteIndexConstants.indexDir);
      await FileUtil().saveFile(
        root,
        NoteIndexConstants.indexDir,
        NoteIndexConstants.tagsFile,
        utf8.encode(json),
      );
      _lastWrittenJson = json;
    } catch (e) {
      appLog.warning('写入标签索引失败：$e');
    }
  }

  String _encode() {
    final notes = <String, dynamic>{};
    // 按 key 排序，减少 Git diff 噪音。
    final keys = _notes.keys.toList()..sort();
    for (final k in keys) {
      notes[k] = _notes[k]!.toJson();
    }

    final meta = <String, dynamic>{};
    final metaKeys = _tagMeta.keys.toList()..sort();
    for (final k in metaKeys) {
      final display = _displayNames[k] ?? k;
      meta[display] = _tagMeta[k]!.toJson();
    }

    return const JsonEncoder.withIndent('  ').convert({
      'version': NoteIndexConstants.schemaVersion,
      'notes': notes,
      'tagMeta': meta,
    });
  }

  /// 仅用于测试：重置全部状态。
  void resetForTest() {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    _clearAll();
    _notesRootPath = null;
    _lastWrittenJson = null;
    _loaded = false;
  }

  /// 仅用于测试：直接注入 JSON 内容。
  void loadFromJsonForTest(String raw) {
    _applyJson(raw);
    _loaded = true;
  }

  /// 仅用于测试：导出当前 JSON。
  String encodeForTest() => _encode();
}
