import 'dart:convert';
import 'dart:io';

import 'package:ashes_note/models/rss/rss_models.dart';
import 'package:ashes_note/utils/const.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:path/path.dart' as p;

/// RSS 数据存储服务
/// 持久化在工作目录下的 rss/feeds.json（不参与 Git 同步）。
class RssStorageService {
  static final RssStorageService _instance = RssStorageService._internal();
  factory RssStorageService() => _instance;
  RssStorageService._internal();

  String _workingDir() =>
      SPUtil.get<String>(PrefKeys.workingDirectory, '').replaceAll('\\', '/');

  /// 确保 rss 目录存在，返回目录路径；若工作目录未设置返回 null
  Future<String?> ensureRssDir() async {
    final root = _workingDir();
    if (root.isEmpty) return null;
    final dir = Directory(p.join(root, RssConstants.rssDir));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  Future<File> _feedsFile() async {
    final dir = await ensureRssDir();
    return File(p.join(dir!, RssConstants.feedsFile));
  }

  /// 读取全部订阅源（文件不存在或损坏时返回空列表）
  Future<List<RssFeed>> loadFeeds() async {
    try {
      final file = await _feedsFile();
      if (!await file.exists()) return [];
      final text = await file.readAsString();
      if (text.isEmpty) return [];
      final list = jsonDecode(text) as List<dynamic>;
      return list
          .map((e) => RssFeed.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  /// 原子写入全部订阅源（先写临时文件再重命名，防止写入中途崩溃损坏数据）
  Future<void> saveFeeds(List<RssFeed> feeds) async {
    try {
      final file = await _feedsFile();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode(feeds.map((f) => f.toJson()).toList()),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (e) {
      // 存储失败不应导致 UI 崩溃，仅忽略
    }
  }

  /// OPML 导出目录（确保存在）
  Future<String?> ensureOpmlDir() async {
    final root = _workingDir();
    if (root.isEmpty) return null;
    final dir = Directory(p.join(root, RssConstants.rssDir, RssConstants.opmlDir));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }
}
