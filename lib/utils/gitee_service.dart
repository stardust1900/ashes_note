import 'dart:async' show Completer;
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class GiteeService {
  // Gitee service implementation
  final String _baseUrl = 'https://gitee.com/api/v5';
  final String? accessToken;

  GiteeService({this.accessToken});

  /// 通过 Gitee API 获取仓库信息
  /// owner: 仓库所属用户或组织
  /// repo: 仓库名称
  /// 返回 Map 表示 JSON 对象，失败时抛出异常
  Future<Map<String, dynamic>> getRepoInfo(String owner, String repo) async {
    final query = accessToken != null ? '?access_token=$accessToken' : '';
    final uri = Uri.parse('$_baseUrl/repos/$owner/$repo$query');

    try {
      // 需要在文件顶部引入：
      // import 'package:http/http.dart' as http;
      // import 'dart:convert';
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      } else {
        throw Exception(
          'Failed to load repo info: ${response.statusCode} ${response.body}',
        );
      }
    } catch (e) {
      // 将错误向上抛出，调用方可捕获并处理
      rethrow;
    }
  }

  /// 创建仓库（用户或组织）
  /// name: 仓库名
  /// organization: 如果传入则在该组织下创建，否则在当前用户下创建
  /// isPrivate: 是否私有仓库
  Future<Map<String, dynamic>> createRepository(
    String name, {
    String? description,
    bool isPrivate = false,
    String? organization,
  }) async {
    final path = organization != null
        ? '/orgs/$organization/repos'
        : '/user/repos';
    final query = accessToken != null ? '?access_token=$accessToken' : '';
    final uri = Uri.parse('$_baseUrl$path$query');

    final body = <String, dynamic>{
      'name': name,
      if (description != null) 'description': description,
      'private': isPrivate,
    };

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );

    if (response.statusCode == 201 || response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception(
        'Failed to create repo: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// 下载仓库中所有文件到指定工作目录
  /// 返回 Map，键为文件路径，值为文件内容的字节数组
  /// 并发下载仓库所有文件并写入磁盘（不返回文件内容）
  /// concurrency: 最大并发请求数（默认为 CPU 核心数 * 2 或 8）
  Future<void> downloadAllFiles(
    String owner,
    String repo,
    String workingDirectory, {
    String? branch,
    int? concurrency,
  }) async {
    var usedBranch = branch;
    if (usedBranch == null) {
      final repoInfo = await getRepoInfo(owner, repo);
      usedBranch = (repoInfo['default_branch'] as String?) ?? 'master';
    }

    final files = await listAllFiles(owner, repo, branch: usedBranch);

    final int defaultConcurrency = (Platform.numberOfProcessors > 0)
        ? Platform.numberOfProcessors * 2
        : 8;
    final int maxConcurrent = (concurrency ?? defaultConcurrency).clamp(1, 64);

    final _Semaphore sem = _Semaphore(maxConcurrent);

    final List<String> failed = [];

    final List<Future<void>> tasks = files.map((entry) {
      return sem.withPermit(() async {
        final path = entry['path'] as String;
        try {
          final fileInfo = await getFile(owner, repo, path, ref: usedBranch);

          List<int>? bytes = fileInfo['content_bytes'] as List<int>?;
          if (bytes == null && fileInfo.containsKey('content')) {
            final raw = (fileInfo['content'] as String).replaceAll('\n', '');
            bytes = base64.decode(raw);
          }
          if (bytes == null) {
            throw Exception('No content for file: $path');
          }

          final sep = Platform.pathSeparator;
          final localPath = workingDirectory.endsWith(sep)
              ? '$workingDirectory$path'
              : '$workingDirectory$sep$path';
          final file = File(localPath);
          await file.create(recursive: true);
          await file.writeAsBytes(bytes, flush: true);
        } catch (e) {
          // 记录失败但继续下载其他文件
          failed.add('$path: $e');
        }
      });
    }).toList();

    await Future.wait(tasks);

    if (failed.isNotEmpty) {
      throw Exception(
        'Failed to download ${failed.length} files. First error: ${failed.first}',
      );
    }
  }

  Future<Map<String, List<int>>> _downloadAllFiles(
    String owner,
    String repo,
    String workingDirectory, {
    String? branch,
  }) async {
    // 需要导入：import 'dart:io';
    var usedBranch = branch;
    if (usedBranch == null) {
      final repoInfo = await getRepoInfo(owner, repo);
      usedBranch = (repoInfo['default_branch'] as String?) ?? 'master';
    }

    final files = await listAllFiles(owner, repo, branch: usedBranch);
    final Map<String, List<int>> result = {};

    for (final entry in files) {
      final path = entry['path'] as String;
      final fileInfo = await getFile(owner, repo, path, ref: usedBranch);

      List<int>? bytes = fileInfo['content_bytes'] as List<int>?;
      if (bytes == null && fileInfo.containsKey('content')) {
        final raw = (fileInfo['content'] as String).replaceAll('\n', '');
        bytes = base64.decode(raw);
      }
      if (bytes == null) {
        throw Exception('No content for file: $path');
      }

      // 写入到工作目录
      final sep = Platform.pathSeparator;
      final localPath = workingDirectory.endsWith(sep)
          ? '$workingDirectory$path'
          : '$workingDirectory$sep$path';
      final file = File(localPath);
      await file.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);

      result[path] = bytes;
    }

    return result;
  }

  /// 获取仓库中所有文件（递归列出 tree 中所有 blob）
  /// 返回 List<Map<String,dynamic>>，每项包含 path、mode、type、sha、size 等字段
  Future<List<Map<String, dynamic>>> listAllFiles(
    String owner,
    String repo, {
    String? branch,
  }) async {
    // 若未指定分支，读取仓库默认分支
    var usedBranch = branch;
    if (usedBranch == null) {
      final repoInfo = await getRepoInfo(owner, repo);
      usedBranch = (repoInfo['default_branch'] as String?) ?? 'master';
    }

    final params = <String, String>{'recursive': '1'};
    if (accessToken != null) params['access_token'] = accessToken!;
    final uri = Uri.parse(
      '$_baseUrl/repos/$owner/$repo/git/trees/$usedBranch',
    ).replace(queryParameters: params);

    final response = await http.get(uri);
    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      final tree = data['tree'] as List<dynamic>? ?? <dynamic>[];
      final files = tree
          .where((e) => e is Map<String, dynamic> && e['type'] == 'blob')
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      return files;
    } else {
      throw Exception(
        'Failed to list files: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// 获取仓库中文件的信息和内容（解码后）
  /// path: 文件在仓库中的路径（可以包含多级目录，例如 "dir/file.md"）
  /// ref: 分支或 tag（可选）
  Future<Map<String, dynamic>> getFile(
    String owner,
    String repo,
    String path, {
    String? ref,
  }) async {
    // 对 path 的每个段进行编码，保留斜杠
    final encodedPath = path.split('/').map(Uri.encodeComponent).join('/');
    final buffer = StringBuffer(
      '$_baseUrl/repos/$owner/$repo/contents/$encodedPath',
    );
    final params = <String, String>{};
    if (accessToken != null) params['access_token'] = accessToken!;
    if (ref != null) params['ref'] = ref;
    if (params.isNotEmpty) {
      buffer.write('?');
      buffer.write(
        params.entries
            .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
            .join('&'),
      );
    }
    final uri = Uri.parse(buffer.toString());

    final response = await http.get(uri);
    if (response.statusCode == 200) {
      final Map<String, dynamic> data =
          json.decode(response.body) as Map<String, dynamic>;
      if (data.containsKey('content')) {
        final raw = (data['content'] as String).replaceAll('\n', '');
        final bytes = base64.decode(raw);
        data['content_bytes'] = bytes;
        try {
          data['content_text'] = utf8.decode(bytes);
        } catch (_) {
          data['content_text'] = null;
        }
      }
      return data;
    } else {
      throw Exception(
        'Failed to get file: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// 创建或更新文件
  /// contentBytes: 文件内容的字节数组
  /// message: 提交信息
  /// sha: 如果是更新文件，需传入当前文件的 sha（可选，如果是更新应提供）
  Future<Map<String, dynamic>> uploadFile(
    String owner,
    String repo,
    String path,
    List<int> contentBytes,
    String message, {
    String? branch,
    String? sha,
  }) async {
    final encodedPath = path.split('/').map(Uri.encodeComponent).join('/');
    final query = accessToken != null ? '?access_token=$accessToken' : '';
    final uri = Uri.parse(
      '$_baseUrl/repos/$owner/$repo/contents/$encodedPath$query',
    );

    final payload = <String, dynamic>{
      'message': message,
      'content': base64.encode(contentBytes),
      if (branch != null) 'branch': branch,
      if (sha != null) 'sha': sha,
    };

    final response = await http.put(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode(payload),
    );

    if (response.statusCode == 201 || response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception(
        'Failed to upload file: ${response.statusCode} ${response.body}',
      );
    }
  }

  /// 删除仓库中文件
  /// path: 文件路径
  /// message: 提交信息
  /// sha: 要删除文件的当前 sha（必填）
  Future<void> deleteFile(
    String owner,
    String repo,
    String path,
    String message,
    String sha, {
    String? branch,
  }) async {
    final encodedPath = path.split('/').map(Uri.encodeComponent).join('/');
    final query = accessToken != null ? '?access_token=$accessToken' : '';
    final uri = Uri.parse(
      '$_baseUrl/repos/$owner/$repo/contents/$encodedPath$query',
    );

    final payload = <String, dynamic>{
      'message': message,
      'sha': sha,
      if (branch != null) 'branch': branch,
    };

    final response = await http.delete(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode(payload),
    );

    if (response.statusCode == 200 || response.statusCode == 204) {
      return;
    } else {
      throw Exception(
        'Failed to delete file: ${response.statusCode} ${response.body}',
      );
    }
  }
}

/// 简单异步信号量，限制并发数
class _Semaphore {
  final int _max;
  int _current = 0;
  final List<Completer<void>> _waiters = [];

  _Semaphore(this._max);

  Future<T> withPermit<T>(Future<T> Function() action) async {
    await _acquire();
    try {
      return await action();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_current < _max) {
      _current++;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      final c = _waiters.removeAt(0);
      // 唤醒下一个等待者，但不改变 _current（保持正在运行计数）
      c.complete();
    } else {
      _current--;
    }
  }
}
