import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/book_reader/dictionary_entry.dart';

/// 字典服务，管理本地词库
/// 参考 KoReader 和 Anx-Reader 的词典功能设计
class DictionaryService {
  static const String _dictionaryPrefix = 'dict_entry_';
  static const String _dictionaryIndexKey = 'dict_index';
  static const String _dictionaryStatsKey = 'dict_stats';

  /// 保存字典条目
  Future<void> saveEntry(DictionaryEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_dictionaryPrefix${entry.word.toLowerCase()}';
    
    // 读取现有条目的统计信息
    final existingEntryJson = prefs.getString(key);
    int lookupCount = 1;
    
    if (existingEntryJson != null) {
      final existing = DictionaryEntry.fromJson(jsonDecode(existingEntryJson));
      lookupCount = existing.lookupCount + 1;
    }
    
    // 更新条目
    final updatedEntry = entry.copyWith(
      updatedAt: DateTime.now(),
    );
    
    await prefs.setString(key, jsonEncode(updatedEntry.toJson()));

    // 更新索引
    final index = await getIndex();
    index[entry.word.toLowerCase()] = {
      'word': entry.word,
      'lookupCount': lookupCount,
      'lastLookup': DateTime.now().toIso8601String(),
    };
    await prefs.setString(_dictionaryIndexKey, jsonEncode(index));

    // 更新统计
    await _updateStats();
  }

  /// 获取字典条目
  Future<DictionaryEntry?> getEntry(String word) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_dictionaryPrefix${word.toLowerCase()}';
    final json = prefs.getString(key);
    if (json == null) return null;
    return DictionaryEntry.fromJson(jsonDecode(json));
  }

  /// 获取所有字典条目
  Future<List<DictionaryEntry>> getAllEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final index = await getIndex();
    final entries = <DictionaryEntry>[];

    for (final wordKey in index.keys) {
      final entry = await getEntry(wordKey);
      if (entry != null) {
        entries.add(entry);
      }
    }

    // 按最后查询时间降序排序
    entries.sort((a, b) {
      final aLookup = _getLookupInfo(a.word, index);
      final bLookup = _getLookupInfo(b.word, index);
      return bLookup['lastLookup'].compareTo(aLookup['lastLookup']);
    });
    
    return entries;
  }

  /// 删除字典条目
  Future<void> deleteEntry(String word) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_dictionaryPrefix${word.toLowerCase()}';
    await prefs.remove(key);

    // 更新索引
    final index = await getIndex();
    index.remove(word.toLowerCase());
    await prefs.setString(_dictionaryIndexKey, jsonEncode(index));

    // 更新统计
    await _updateStats();
  }

  /// 搜索字典条目（支持模糊搜索）
  Future<List<DictionaryEntry>> searchEntries(String query) async {
    final allEntries = await getAllEntries();
    final lowerQuery = query.toLowerCase();

    return allEntries.where((entry) {
      return entry.word.toLowerCase().contains(lowerQuery) ||
          entry.definition.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// 获取字典统计信息
  Future<Map<String, dynamic>> getStats() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_dictionaryStatsKey);
    if (json == null) return await _updateStats();
    return Map<String, dynamic>.from(jsonDecode(json));
  }

  /// 清空所有字典条目
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final index = await getIndex();

    for (final key in index.keys) {
      await prefs.remove('$_dictionaryPrefix$key');
    }

    await prefs.remove(_dictionaryIndexKey);
    await prefs.remove(_dictionaryStatsKey);
  }

  /// 导出字典数据（用于备份）
  Future<String> exportData() async {
    final entries = await getAllEntries();
    final index = await getIndex();
    final stats = await getStats();
    
    final export = {
      'version': '1.0',
      'exportDate': DateTime.now().toIso8601String(),
      'entries': entries.map((e) => e.toJson()).toList(),
      'index': index,
      'stats': stats,
    };
    
    return jsonEncode(export);
  }

  /// 导入字典数据
  Future<void> importData(String jsonData) async {
    final data = jsonDecode(jsonData);
    final entries = (data['entries'] as List).cast<Map<String, dynamic>>();
    
    final prefs = await SharedPreferences.getInstance();
    final index = <String, dynamic>{};
    
    for (final entryJson in entries) {
      final entry = DictionaryEntry.fromJson(entryJson);
      final key = '$_dictionaryPrefix${entry.word.toLowerCase()}';
      await prefs.setString(key, jsonEncode(entry.toJson()));
      
      index[entry.word.toLowerCase()] = {
        'word': entry.word,
        'lookupCount': 1,
        'lastLookup': entry.createdAt.toIso8601String(),
      };
    }
    
    await prefs.setString(_dictionaryIndexKey, jsonEncode(index));
    await _updateStats();
  }

  /// 获取字典索引
  Future<Map<String, dynamic>> getIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_dictionaryIndexKey);
    if (json == null) return {};
    return Map<String, dynamic>.from(jsonDecode(json));
  }

  /// 获取字典条目数量
  Future<int> getCount() async {
    final index = await getIndex();
    return index.length;
  }

  /// 检查单词是否已在字典中
  Future<bool> containsWord(String word) async {
    final entry = await getEntry(word);
    return entry != null;
  }

  /// 获取热门单词（按查询次数排序）
  Future<List<DictionaryEntry>> getPopularWords({int limit = 20}) async {
    final allEntries = await getAllEntries();
    final index = await getIndex();
    
    allEntries.sort((a, b) {
      final aLookup = _getLookupInfo(a.word, index);
      final bLookup = _getLookupInfo(b.word, index);
      return (bLookup['lookupCount'] as int).compareTo(aLookup['lookupCount']);
    });
    
    return allEntries.take(limit).toList();
  }

  /// 获取最近添加的单词
  Future<List<DictionaryEntry>> getRecentWords({int limit = 20}) async {
    final allEntries = await getAllEntries();
    allEntries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return allEntries.take(limit).toList();
  }

  /// 更新统计信息
  Future<Map<String, dynamic>> _updateStats() async {
    final index = await getIndex();
    final stats = <String, dynamic>{
      'totalWords': index.length,
      'lastUpdated': DateTime.now().toIso8601String(),
    };
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dictionaryStatsKey, jsonEncode(stats));
    
    return stats;
  }

  /// 获取索引中的单词信息
  Map<String, dynamic> _getLookupInfo(String word, Map<String, dynamic> index) {
    final key = word.toLowerCase();
    return index[key] ?? {'lookupCount': 0, 'lastLookup': DateTime.now().toIso8601String()};
  }
}

/// DictionaryEntry 的扩展方法
extension DictionaryEntryExtension on DictionaryEntry {
  /// 获取查询次数
  int get lookupCount => 0; // 从索引中获取
  
  /// 是否最近添加（7天内）
  bool get isRecentlyAdded {
    return DateTime.now().difference(createdAt).inDays < 7;
  }
}
