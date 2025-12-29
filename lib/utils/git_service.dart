import 'dart:async' show Completer;
import 'dart:convert';
import 'dart:io';
import 'package:ashes_note/utils/const.dart' show GitPlatforms;
import 'package:crypto/crypto.dart';
import 'package:ashes_note/utils/file_util.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class GitFactory {
  static GitService getGitService(String gitPlatform, String accessToken) {
    if (gitPlatform == GitPlatforms.gitee) {
      return GiteeService(accessToken: accessToken);
    } else if (gitPlatform == GitPlatforms.github) {
      return GitHubService(accessToken: accessToken);
    }
    throw UnimplementedError();
  }
}

enum ConflictAction { remoteWins, localWins, createConflictCopy }

abstract class GitService {
  Future<Map<String, dynamic>> getRepoInfo(String owner, String repo);
  Future<List<Map<String, dynamic>>> listAllFiles(
    String owner,
    String repo, {
    String branch,
  });
  Future<Map<String, dynamic>> getFile(
    String owner,
    String repo,
    String path, {
    String ref,
  });
  Future<void> uploadFile(
    String owner,
    String repo,
    String path,
    List<int> content,
    String message, {
    String branch,
  });

  Future<void> deleteFile(
    String owner,
    String repo,
    String path,
    String message,
    String sha, {
    String? branch,
  });

  Future<void> pull(
    String owner,
    String repo,
    String workingDir, {
    ConflictAction conflictAction = ConflictAction.remoteWins,
    String? branch,
  });
  Future<void> push(
    String owner,
    String repo,
    String workingDir, {
    bool deleteRemoteMissing = false,
    String? branch,
  });

  (String, String) getOwnerRepoFromUrl(String url);

  String _sha1Bytes(List<int> bytes) => sha1.convert(bytes).toString();

  String hashObject(List<int> bytes) {
    // git blob header: "blob {size}\0"
    final header = utf8.encode('blob ${bytes.length}\u0000');
    final payload = <int>[...header, ...bytes];
    return sha1.convert(payload).toString();
  }

  //获取仓库的提交记录
  Future<List<Map<String, dynamic>>> getCommits(
    String owner,
    String repo, {
    String branch,
    String? since,
    String? until,
    int page = 1,
    int perPage = 10,
  });
}

class GiteeService extends GitService {
  // Gitee service implementation
  final String _baseUrl = 'https://gitee.com/api/v5';
  final String? accessToken;

  GiteeService({this.accessToken});

  // 计算 bytes 的 sha1（用于快速比较）
  // String _sha1Bytes(List<int> bytes) => sha1.convert(bytes).toString();

  /// 通过 Gitee API 获取仓库信息
  /// owner: 仓库所属用户或组织
  /// repo: 仓库名称
  /// 返回 Map 表示 JSON 对象，失败时抛出异常
  @override
  Future<Map<String, dynamic>> getRepoInfo(String owner, String repo) async {
    final query = accessToken != null ? '?access_token=$accessToken' : '';
    final uri = Uri.parse('$_baseUrl/repos/$owner/$repo$query');

    try {
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

  @override
  Future<void> pull(
    String owner,
    String repo,
    String workingDir, {
    ConflictAction conflictAction = ConflictAction.remoteWins,
    String? branch,
  }) async {
    print('DateTime now: ${DateTime.now().toIso8601String()} pull start');
    var usedBranch = branch;
    if (usedBranch == null) {
      final repoInfo = await getRepoInfo(owner, repo);
      usedBranch = (repoInfo['default_branch'] as String?) ?? 'master';
    }

    final remoteFiles = await listAllFiles(owner, repo, branch: branch);

    final _Semaphore sem = _Semaphore.getInstance();

    // 并发分块拉取，限制同时运行任务数，完成后清空 remoteFiles 避免后续重复处理
    final int calculatedConcurrency = (Platform.numberOfProcessors > 0)
        ? Platform.numberOfProcessors * 2
        : 8;
    final int maxConcurrent = (calculatedConcurrency.clamp(1, 64)); // 控制最大并发
    final List<String> errors = [];

    // 分块执行，保证内存占用受控：每个批次最多 _maxConcurrent 个并发请求
    for (var i = 0; i < remoteFiles.length; i += maxConcurrent) {
      final end = (i + maxConcurrent) > remoteFiles.length
          ? remoteFiles.length
          : (i + maxConcurrent);
      final chunk = remoteFiles.sublist(i, end);

      final futures = <Future<void>>[];
      for (final entry in chunk) {
        futures.add(
          sem.withPermit(() async {
            String path;
            try {
              path = (entry['path'] as String);
            } catch (e) {
              errors.add('Invalid entry format: $e');
              return;
            }

            try {
              print('同步文件（并发）: $path');

              // 拉取远端内容并立即处理（写盘后尽快释放内存）
              final fileInfo = await getFile(
                owner,
                repo,
                path,
                ref: usedBranch,
              );
              List<int>? remoteBytes = fileInfo['content_bytes'] as List<int>?;
              if (remoteBytes == null && fileInfo.containsKey('content')) {
                final raw = (fileInfo['content'] as String).replaceAll(
                  '\n',
                  '',
                );
                remoteBytes = base64.decode(raw);
              }
              if (remoteBytes == null) {
                throw Exception('No content for file: $path');
              }

              // 检查本地是否存在；使用 readFile 抛异常判断
              bool localExists = true;
              String localText = '';
              try {
                localText = await FileUtil().readFile(
                  workingDir,
                  p.dirname(path),
                  p.basename(path),
                );
              } catch (_) {
                localExists = false;
              }

              if (!localExists) {
                // 直接写入远端内容
                await FileUtil().saveFile(
                  workingDir,
                  p.dirname(path),
                  p.basename(path),
                  remoteBytes,
                );
                // 释放内存引用
                remoteBytes = <int>[];
                return;
              }

              // 比较 sha1，若相同则跳过
              final localBytes = utf8.encode(localText);
              final localSha = _sha1Bytes(localBytes);
              if (localSha == _sha1Bytes(remoteBytes)) {
                // 相同，跳过
                remoteBytes = <int>[];
                return;
              }

              // 冲突处理
              switch (conflictAction) {
                case ConflictAction.remoteWins:
                  await FileUtil().saveFile(
                    workingDir,
                    p.dirname(path),
                    p.basename(path),
                    remoteBytes,
                  );
                  break;
                case ConflictAction.localWins:
                  // 不修改本地，后续可 push 覆盖远端
                  break;
                case ConflictAction.createConflictCopy:
                  final conflictPath = _conflictCopyPath(path);
                  await FileUtil().saveFile(
                    workingDir,
                    p.dirname(path),
                    p.basename(conflictPath),
                    remoteBytes,
                  );
                  break;
              }

              // 及时释放对大字节数组的引用，帮助 GC 回收
              remoteBytes = <int>[];
            } catch (e, st) {
              errors.add('$path: $e\n$st');
            }
          }),
        );
      }

      // 等待当前批次完成后再继续下一批，避免过多未完成 Future 占用内存
      await Future.wait(futures);
    }

    // 清理已处理列表，避免后面的同步逻辑重复工作
    remoteFiles.clear();

    // 若有失败，抛出第一个错误以便上层知晓（也可改为记录日志）
    if (errors.isNotEmpty) {
      print('Failed to pull ${errors.length} files. First: ${errors.first}');
    }
    print('DateTime now: ${DateTime.now().toIso8601String()} pull end');
  }

  // 将本地变更推送到远端（push）
  // deleteRemoteMissing: 若 true，会删除远端上不存在于本地的文件（危险，默认 false）
  @override
  Future<void> push(
    String owner,
    String repo,
    String workingDir, {
    bool deleteRemoteMissing = false,
    String? branch,
  }) async {
    // 收集远端文件信息（path -> sha）
    final remoteFiles = await listAllFiles(owner, repo, branch: branch);

    final Map<String, String?> remoteMap = {
      for (final e in remoteFiles) e['path'] as String: e['sha'] as String?,
    };
    // 仅保留多级路径文件，忽略根目录文件
    remoteMap.removeWhere((key, value) => !key.contains('/'));
    // remoteMap.forEach((key, value) {
    //   print('remote file: $key, sha: $value');
    // });

    // 收集本地所有文件（相对路径 -> content）
    final Map<String, List<int>> localFiles = {};
    await _collectLocalFilesRecursively(workingDir, '', localFiles);

    // localFiles.forEach((key, value) {
    //   print('local file: $key, size: ${value.length}');
    // });
    // 上传或更新本地存在的文件
    for (final entry in localFiles.entries) {
      final path = entry.key;
      final localBytes = entry.value;
      // 获取远端对应文件内容（如果存在）用于比较
      String? remoteSha = remoteMap[path];
      bool needUpload = true;

      if (remoteSha != null) {
        //使用和git相同方法计算sha值，不需要再次拉文件
        if (remoteSha == hashObject(localBytes)) {
          needUpload = false; // 内容相同，无需上传
        }

        if (needUpload) {
          final message = 'Sync: update $path';
          print(message);
          try {
            await uploadFile(
              owner,
              repo,
              path,
              localBytes,
              message,
              branch: branch,
              // sha: remoteSha,
            );
          } catch (e) {
            print('Failed to upload $path: $e');
          }
        }
      } else {
        //对于本地有 远程没有的老文件
      }
    }

    if (deleteRemoteMissing) {
      // 删除远端中不存在于本地的文件
      for (final remotePath in remoteMap.keys) {
        // print('remotePath: $remotePath');
        if (!localFiles.containsKey(remotePath)) {
          print('准备删除远端文件: $remotePath');
          // 需要 sha 删除（Gitee API 要求）
          final remoteInfo = await getFile(
            owner,
            repo,
            remotePath,
            ref: branch,
          );
          final sha = remoteInfo['sha'] as String?;
          if (sha != null) {
            final message = 'Sync: delete $remotePath';
            await deleteFile(
              owner,
              repo,
              remotePath,
              message,
              sha,
              branch: branch,
            );
          }
        }
      }
    }
  }

  // 将本地文件递归收集到 map 中（相对路径 -> bytes）
  Future<void> _collectLocalFilesRecursively(
    String workingDir,
    String relativeDir,
    Map<String, List<int>> out,
  ) async {
    final entries = await FileUtil().listFiles(
      workingDir,
      relativeDir,
      type: 'directory',
    );

    print('listFiles entries: $entries');
    // fileUtil.listFiles 在不同实现里可以支持 type 参数： 'file', 'directory', 'all'
    // 如果你的实现没有 'all'，可以分别调用 'file' 和 'directory' 两次或调整实现。
    for (final name in entries) {
      final candidate = relativeDir.isEmpty ? name : p.join(relativeDir, name);
      print('candidate: $candidate');
      // 检查是否是目录 by asking listFiles for this path as directory
      final dirs = await FileUtil().listFiles(
        workingDir,
        candidate,
        type: 'directory',
      );
      print('dirs: $dirs');
      final files = await FileUtil().listFiles(
        workingDir,
        candidate,
        type: 'file',
      );
      if (files.isNotEmpty) {
        // 文件存在：在某些 implementations listFiles(candidate) may return files directly
        for (final fn in files) {
          final rel = '$candidate/$fn';
          final content = await FileUtil().readFile(workingDir, "", rel);
          out[rel] = utf8.encode(content);
        }
      }
      if (dirs.isNotEmpty) {
        // 递归目录：candidate 是父目录名，继续深入
        await _collectLocalFilesRecursively(workingDir, candidate, out);
      }
      // 如果 implementation returns file names directly in entries, above handles it.
    }
  }

  String _conflictCopyPath(String original) {
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final dir = p.dirname(original);
    final base = p.basename(original);
    final conflictName = '$base.conflict.$ts';
    return dir == '.' ? conflictName : p.join(dir, conflictName);
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

  /// 获取仓库中所有文件（递归列出 tree 中所有 blob）
  /// 返回 List<Map<String, dynamic>>，每项包含 path、mode、type、sha、size 等字段
  @override
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
  @override
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
      final data = json.decode(response.body);
      if (data is! Map<String, dynamic>) {
        print('Unexpected response format: ${response.body}');
        return {};
      }

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
  @override
  Future<Map<String, dynamic>> uploadFile(
    String owner,
    String repo,
    String path,
    List<int> contentBytes,
    String message, {
    String? branch,
  }) async {
    Map<String, dynamic> existingFile = await getFile(owner, repo, path);
    if (existingFile.isNotEmpty) {
      final existingSha = existingFile['sha'] as String?;
      if (existingSha != null && existingSha.isNotEmpty) {
        print('File $path exists, updating existing file.');
        final localSha = hashObject(contentBytes);
        if (localSha == existingSha) {
          print('File $path content is identical, skipping upload.');
          return existingFile; // 内容相同，跳过上传
        }
        // 更新文件时需要提供 sha
        //https://gitee.com/api/v5/repos/{owner}/{repo}/contents/{path}
        return await _updateFile(
          owner,
          repo,
          path,
          contentBytes,
          message,
          existingSha,
          branch: branch,
        );
      }
    }

    final encodedPath = path.split('/').map(Uri.encodeComponent).join('/');
    // final query = accessToken != null ? '?access_token=$accessToken' : '';
    final uri = Uri.parse('$_baseUrl/repos/$owner/$repo/contents/$encodedPath');

    print('Uploading file to $uri with message: $message');

    final payload = <String, dynamic>{
      'access_token': accessToken,
      'message': message,
      'content': base64.encode(contentBytes),
      if (branch != null) 'branch': branch,
    };

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json;charset=UTF-8'},
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
  @override
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

  @override
  (String, String) getOwnerRepoFromUrl(String url) {
    // 示例 URL: https://gitee.com/owner/repo.git
    final uri = Uri.parse(url);
    final segments = uri.pathSegments;
    if (segments.length < 2) {
      throw Exception('Invalid Gitee repository URL: $url');
    }
    final owner = segments[0];
    var repo = segments[1];
    if (repo.endsWith('.git')) {
      repo = repo.substring(0, repo.length - 4);
    }
    return (owner, repo);
  }

  Future<Map<String, dynamic>> _updateFile(
    String owner,
    String repo,
    String path,
    List<int> contentBytes,
    String message,
    String existingSha, {
    String? branch,
  }) async {
    final encodedPath = path.split('/').map(Uri.encodeComponent).join('/');
    final uri = Uri.parse('$_baseUrl/repos/$owner/$repo/contents/$encodedPath');

    print('Updating file at $uri with message: $message');

    final payload = <String, dynamic>{
      'access_token': accessToken,
      'message': message,
      'content': base64.encode(contentBytes),
      'sha': existingSha,
      if (branch != null) 'branch': branch,
    };

    final response = await http.put(
      uri,
      headers: {'Content-Type': 'application/json;charset=UTF-8'},
      body: json.encode(payload),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception(
        'Failed to update file: ${response.statusCode} ${response.body}',
      );
    }
  }

  @override
  Future<List<Map<String, dynamic>>> getCommits(
    String owner,
    String repo, {
    String? branch,
    String? since,
    String? until,
    int page = 1,
    int perPage = 10,
  }) async {
    // 若未指定分支，读取仓库默认分支
    var usedBranch = branch;
    if (usedBranch == null) {
      final repoInfo = await getRepoInfo(owner, repo);
      usedBranch = (repoInfo['default_branch'] as String?) ?? 'master';
    }
    //curl -X GET --header 'Content-Type: application/json;charset=UTF-8' 'https://gitee.com/api/v5/repos/wangyidao/onlynote/commits?access_token=47ff3896a60337244662241db90ba171&page=1&per_page=20'
    final params = <String, String>{
      'sha': usedBranch,
      if (since != null) 'since': since,
      if (until != null) 'until': until,
      'page': page.toString(),
      'per_page': perPage.toString(),
    };
    if (accessToken != null) params['access_token'] = accessToken!;
    final uri = Uri.parse(
      '$_baseUrl/repos/$owner/$repo/commits',
    ).replace(queryParameters: params);

    final response = await http.get(uri);
    if (response.statusCode == 200) {
      final data = json.decode(response.body) as List;
      return data.map((e) => e as Map<String, dynamic>).toList();
    } else {
      throw Exception(
        'Failed to get commits: ${response.statusCode} ${response.body}',
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

  static _Semaphore getInstance() {
    final int defaultConcurrency = (Platform.numberOfProcessors > 0)
        ? Platform.numberOfProcessors * 2
        : 8;
    final int maxConcurrent = (defaultConcurrency).clamp(1, 64);
    return _Semaphore(maxConcurrent);
  }

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

class GitHubService extends GitService {
  final String _baseUrl = 'https://api.github.com';
  final String? accessToken;

  GitHubService({this.accessToken});

  Map<String, String> _headers({bool json = false}) {
    final h = <String, String>{
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'ashes_note',
    };
    if (accessToken != null && accessToken!.isNotEmpty) {
      h['Authorization'] = 'Bearer $accessToken';
    }
    if (json) {
      h['Content-Type'] = 'application/json; charset=utf-8';
    }
    return h;
  }

  @override
  Future<Map<String, dynamic>> getRepoInfo(String owner, String repo) async {
    final uri = Uri.parse('$_baseUrl/repos/$owner/$repo');
    final resp = await http.get(uri, headers: _headers());
    if (resp.statusCode == 200) {
      return json.decode(resp.body) as Map<String, dynamic>;
    }
    throw Exception(
      'Failed to load repo info: ${resp.statusCode} ${resp.body}',
    );
  }

  Future<String> _resolveTreeSha(String owner, String repo, String ref) async {
    // Try branches endpoint first
    final branchUri = Uri.parse('$_baseUrl/repos/$owner/$repo/branches/$ref');
    var resp = await http.get(branchUri, headers: _headers());
    if (resp.statusCode == 200) {
      final data = json.decode(resp.body) as Map<String, dynamic>;
      try {
        final commit = data['commit'];
        if (commit is Map<String, dynamic>) {
          if (commit.containsKey('commit') &&
              commit['commit'] is Map &&
              (commit['commit'] as Map).containsKey('tree')) {
            final tree =
                (commit['commit'] as Map)['tree'] as Map<String, dynamic>?;
            final sha = tree != null ? tree['sha'] as String? : null;
            if (sha != null) return sha;
          }
          if (commit.containsKey('tree') && (commit['tree'] is Map)) {
            final sha = (commit['tree'] as Map)['sha'] as String?;
            if (sha != null) return sha;
          }
        }
      } catch (_) {}
    }

    // Fallback to commit object (if ref is a commit SHA)
    final commitUri = Uri.parse(
      '$_baseUrl/repos/$owner/$repo/git/commits/$ref',
    );
    resp = await http.get(commitUri, headers: _headers());
    if (resp.statusCode == 200) {
      final data = json.decode(resp.body) as Map<String, dynamic>;
      final tree = data['tree'] as Map<String, dynamic>?;
      final sha = tree != null ? tree['sha'] as String? : null;
      if (sha != null) return sha;
    }

    // Final fallback: use default branch
    final repoInfo = await getRepoInfo(owner, repo);
    final defaultBranch = (repoInfo['default_branch'] as String?) ?? 'main';
    if (defaultBranch != ref) {
      return await _resolveTreeSha(owner, repo, defaultBranch);
    }

    throw Exception('Unable to resolve tree sha for $owner/$repo@$ref');
  }

  @override
  Future<List<Map<String, dynamic>>> listAllFiles(
    String owner,
    String repo, {
    String? branch,
  }) async {
    var usedBranch = branch;
    if (usedBranch == null) {
      final repoInfo = await getRepoInfo(owner, repo);
      usedBranch = (repoInfo['default_branch'] as String?) ?? 'main';
    }
    final treeSha = await _resolveTreeSha(owner, repo, usedBranch);
    final uri = Uri.parse(
      '$_baseUrl/repos/$owner/$repo/git/trees/$treeSha',
    ).replace(queryParameters: {'recursive': '1'});
    final resp = await http.get(uri, headers: _headers());
    if (resp.statusCode == 200) {
      final data = json.decode(resp.body) as Map<String, dynamic>;
      final tree = data['tree'] as List<dynamic>? ?? <dynamic>[];
      final files = tree
          .where((e) => e is Map<String, dynamic> && e['type'] == 'blob')
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      return files;
    }
    throw Exception('Failed to list files: ${resp.statusCode} ${resp.body}');
  }

  @override
  Future<Map<String, dynamic>> getFile(
    String owner,
    String repo,
    String path, {
    String? ref,
  }) async {
    final encodedPath = path.split('/').map(Uri.encodeComponent).join('/');
    final params = <String, String>{};
    if (ref != null) params['ref'] = ref;
    final uri = Uri.parse(
      '$_baseUrl/repos/$owner/$repo/contents/$encodedPath',
    ).replace(queryParameters: params.isEmpty ? null : params);
    final resp = await http.get(uri, headers: _headers());
    if (resp.statusCode == 200) {
      final data = json.decode(resp.body);
      if (data is Map<String, dynamic>) {
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
      }
      return {};
    } else if (resp.statusCode == 404) {
      return <String, dynamic>{};
    }
    throw Exception('Failed to get file: ${resp.statusCode} ${resp.body}');
  }

  @override
  Future<Map<String, dynamic>> uploadFile(
    String owner,
    String repo,
    String path,
    List<int> contentBytes,
    String message, {
    String? branch,
  }) async {
    final encodedPath = path.split('/').map(Uri.encodeComponent).join('/');
    final uri = Uri.parse('$_baseUrl/repos/$owner/$repo/contents/$encodedPath');

    String? existingSha;
    try {
      final existing = await getFile(owner, repo, path, ref: branch);
      if (existing.isNotEmpty) {
        existingSha = existing['sha'] as String?;
      }
    } catch (_) {
      // ignore
    }

    final payload = <String, dynamic>{
      'message': message,
      'content': base64.encode(contentBytes),
      if (branch != null) 'branch': branch,
      if (existingSha != null) 'sha': existingSha,
    };

    final resp = await http.put(
      uri,
      headers: _headers(json: true),
      body: json.encode(payload),
    );
    if (resp.statusCode == 201 || resp.statusCode == 200) {
      return json.decode(resp.body) as Map<String, dynamic>;
    }
    throw Exception('Failed to upload file: ${resp.statusCode} ${resp.body}');
  }

  @override
  Future<void> deleteFile(
    String owner,
    String repo,
    String path,
    String message,
    String sha, {
    String? branch,
  }) async {
    final encodedPath = path.split('/').map(Uri.encodeComponent).join('/');
    final uri = Uri.parse('$_baseUrl/repos/$owner/$repo/contents/$encodedPath');

    final payload = <String, dynamic>{
      'message': message,
      'sha': sha,
      if (branch != null) 'branch': branch,
    };

    final resp = await http.delete(
      uri,
      headers: _headers(json: true),
      body: json.encode(payload),
    );
    if (resp.statusCode == 200 || resp.statusCode == 204) {
      return;
    }
    throw Exception('Failed to delete file: ${resp.statusCode} ${resp.body}');
  }

  @override
  (String, String) getOwnerRepoFromUrl(String url) {
    final uri = Uri.parse(url);
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) {
      throw Exception('Invalid GitHub repository URL: $url');
    }
    var owner = segments[0];
    var repo = segments[1];
    if (repo.endsWith('.git')) repo = repo.substring(0, repo.length - 4);
    return (owner, repo);
  }

  @override
  Future<List<Map<String, dynamic>>> getCommits(
    String owner,
    String repo, {
    String? branch,
    String? since,
    String? until,
    int page = 1,
    int perPage = 10,
  }) async {
    var usedBranch = branch;
    if (usedBranch == null) {
      final repoInfo = await getRepoInfo(owner, repo);
      usedBranch = (repoInfo['default_branch'] as String?) ?? 'main';
    }
    final params = <String, String>{
      'sha': usedBranch,
      if (since != null) 'since': since,
      if (until != null) 'until': until,
      'page': page.toString(),
      'per_page': perPage.toString(),
    };
    final uri = Uri.parse(
      '$_baseUrl/repos/$owner/$repo/commits',
    ).replace(queryParameters: params);
    final resp = await http.get(uri, headers: _headers());
    if (resp.statusCode == 200) {
      final data = json.decode(resp.body) as List;
      return data.map((e) => e as Map<String, dynamic>).toList();
    }
    throw Exception('Failed to get commits: ${resp.statusCode} ${resp.body}');
  }

  // --- 添加缺失的 pull 和 push 实现，以及辅助方法 ----

  @override
  Future<void> pull(
    String owner,
    String repo,
    String workingDir, {
    ConflictAction conflictAction = ConflictAction.remoteWins,
    String? branch,
  }) async {
    var usedBranch = branch;
    if (usedBranch == null) {
      final repoInfo = await getRepoInfo(owner, repo);
      usedBranch = (repoInfo['default_branch'] as String?) ?? 'main';
    }

    final remoteFiles = await listAllFiles(owner, repo, branch: usedBranch);

    final _Semaphore sem = _Semaphore.getInstance();

    final int calculatedConcurrency = (Platform.numberOfProcessors > 0)
        ? Platform.numberOfProcessors * 2
        : 8;
    final int maxConcurrent = (calculatedConcurrency.clamp(1, 64));
    final List<String> errors = [];

    for (var i = 0; i < remoteFiles.length; i += maxConcurrent) {
      final end = (i + maxConcurrent) > remoteFiles.length
          ? remoteFiles.length
          : (i + maxConcurrent);
      final chunk = remoteFiles.sublist(i, end);

      final futures = <Future<void>>[];
      for (final entry in chunk) {
        futures.add(
          sem.withPermit(() async {
            String path;
            try {
              path = (entry['path'] as String);
            } catch (e) {
              errors.add('Invalid entry format: $e');
              return;
            }
            print('同步文件（并发）: $path');
            try {
              final fileInfo = await getFile(
                owner,
                repo,
                path,
                ref: usedBranch,
              );
              List<int>? remoteBytes = fileInfo['content_bytes'] as List<int>?;
              if (remoteBytes == null && fileInfo.containsKey('content')) {
                final raw = (fileInfo['content'] as String).replaceAll(
                  '\n',
                  '',
                );
                remoteBytes = base64.decode(raw);
              }
              if (remoteBytes == null) {
                throw Exception('No content for file: $path');
              }

              bool localExists = true;
              String localText = '';
              try {
                localText = await FileUtil().readFile(
                  workingDir,
                  p.dirname(path),
                  p.basename(path),
                );
              } catch (_) {
                localExists = false;
              }

              if (!localExists) {
                await FileUtil().saveFile(
                  workingDir,
                  p.dirname(path),
                  p.basename(path),
                  remoteBytes,
                );
                remoteBytes = <int>[];
                return;
              }

              final localBytes = utf8.encode(localText);
              final localSha = _sha1Bytes(localBytes);
              if (localSha == _sha1Bytes(remoteBytes)) {
                remoteBytes = <int>[];
                return;
              }

              switch (conflictAction) {
                case ConflictAction.remoteWins:
                  await FileUtil().saveFile(
                    workingDir,
                    p.dirname(path),
                    p.basename(path),
                    remoteBytes,
                  );
                  break;
                case ConflictAction.localWins:
                  break;
                case ConflictAction.createConflictCopy:
                  final conflictPath = _conflictCopyPath(path);
                  await FileUtil().saveFile(
                    workingDir,
                    p.dirname(path),
                    p.basename(conflictPath),
                    remoteBytes,
                  );
                  break;
              }

              remoteBytes = <int>[];
            } catch (e, st) {
              errors.add('$path: $e\n$st');
            }
          }),
        );
      }

      await Future.wait(futures);
    }

    remoteFiles.clear();

    if (errors.isNotEmpty) {
      print('Failed to pull ${errors.length} files. First: ${errors.first}');
    }
  }

  @override
  Future<void> push(
    String owner,
    String repo,
    String workingDir, {
    bool deleteRemoteMissing = false,
    String? branch,
  }) async {
    final remoteFiles = await listAllFiles(owner, repo, branch: branch);

    final Map<String, String?> remoteMap = {
      for (final e in remoteFiles) e['path'] as String: e['sha'] as String?,
    };
    remoteMap.removeWhere((key, value) => !key.contains('/'));

    final Map<String, List<int>> localFiles = {};
    await _collectLocalFilesRecursively(workingDir, '', localFiles);

    for (final entry in localFiles.entries) {
      final path = entry.key;
      final localBytes = entry.value;
      String? remoteSha = remoteMap[path];
      bool needUpload = true;

      if (remoteSha != null) {
        if (remoteSha == hashObject(localBytes)) {
          needUpload = false;
        }

        if (needUpload) {
          final message = 'Sync: update $path';
          try {
            await uploadFile(
              owner,
              repo,
              path,
              localBytes,
              message,
              branch: branch,
            );
          } catch (e) {
            print('Failed to upload $path: $e');
          }
        }
      } else {
        // remote doesn't have it, create
        final message = 'Sync: add $path';
        try {
          await uploadFile(
            owner,
            repo,
            path,
            localBytes,
            message,
            branch: branch,
          );
        } catch (e) {
          print('Failed to upload new file $path: $e');
        }
      }
    }

    if (deleteRemoteMissing) {
      for (final remotePath in remoteMap.keys) {
        if (!localFiles.containsKey(remotePath)) {
          print('准备删除远端文件: $remotePath');
          final remoteInfo = await getFile(
            owner,
            repo,
            remotePath,
            ref: branch,
          );
          final sha = remoteInfo['sha'] as String?;
          if (sha != null) {
            final message = 'Sync: delete $remotePath';
            await deleteFile(
              owner,
              repo,
              remotePath,
              message,
              sha,
              branch: branch,
            );
          }
        }
      }
    }
  }

  // 辅助：递归收集本地文件（相对路径 -> bytes）
  Future<void> _collectLocalFilesRecursively(
    String workingDir,
    String relativeDir,
    Map<String, List<int>> out,
  ) async {
    final entries = await FileUtil().listFiles(
      workingDir,
      relativeDir,
      type: 'directory',
    );

    for (final name in entries) {
      final candidate = relativeDir.isEmpty ? name : p.join(relativeDir, name);

      final dirs = await FileUtil().listFiles(
        workingDir,
        candidate,
        type: 'directory',
      );
      final files = await FileUtil().listFiles(
        workingDir,
        candidate,
        type: 'file',
      );
      if (files.isNotEmpty) {
        for (final fn in files) {
          final rel = '$candidate/$fn';
          final content = await FileUtil().readFile(workingDir, "", rel);
          out[rel] = utf8.encode(content);
        }
      }
      if (dirs.isNotEmpty) {
        await _collectLocalFilesRecursively(workingDir, candidate, out);
      }
    }
  }

  String _conflictCopyPath(String original) {
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final dir = p.dirname(original);
    final base = p.basename(original);
    final conflictName = '$base.conflict.$ts';
    return dir == '.' ? conflictName : p.join(dir, conflictName);
  }
}
