import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'git_service.dart';
import 'file_util.dart';

enum ConflictAction { remoteWins, localWins, createConflictCopy }

class SyncService {
  final GitService gitee;
  final FileUtil fileUtil;
  final String owner;
  final String repo;
  final String branch;
  final String workingDir; // 本地工作目录根（在 web 上可忽略，用户选择的 root 生效）

  SyncService({
    required this.gitee,
    required this.fileUtil,
    required this.owner,
    required this.repo,
    required this.workingDir,
    this.branch = 'master',
  });

  // 计算 bytes 的 sha1（用于快速比较）
  String _sha1Bytes(List<int> bytes) => sha1.convert(bytes).toString();

  // 将 remote 文件同步到本地（pull）
  // conflictAction 决定冲突时的处理策略
  Future<void> pull({
    ConflictAction conflictAction = ConflictAction.remoteWins,
  }) async {
    final remoteFiles = await gitee.listAllFiles(owner, repo, branch: branch);
    for (final f in remoteFiles) {
      final path = f['path'] as String;
      // 读取远程内容
      final fileInfo = await gitee.getFile(owner, repo, path, ref: branch);
      List<int>? remoteBytes = fileInfo['content_bytes'] as List<int>?;
      final remoteSha = fileInfo['sha'] as String?;
      if (remoteBytes == null) continue;

      // 读取本地内容（若存在）
      final localContent = await fileUtil.readFile(workingDir, "", path);

      final localBytes = utf8.encode(localContent);
      if (_sha1Bytes(localBytes) == _sha1Bytes(remoteBytes)) {
        // 相同，跳过
        continue;
      }

      // 冲突处理
      switch (conflictAction) {
        case ConflictAction.remoteWins:
          await fileUtil.saveFile(workingDir, "", path, remoteBytes);
          break;
        case ConflictAction.localWins:
          // 不做任何操作；后续可以 push 将本地覆盖远端
          break;
        case ConflictAction.createConflictCopy:
          final conflictPath = _conflictCopyPath(path);
          await fileUtil.saveFile(workingDir, "", conflictPath, remoteBytes);
          break;
      }
    }
  }

  // 将本地变更推送到远端（push）
  // deleteRemoteMissing: 若 true，会删除远端上不存在于本地的文件（危险，默认 false）
  Future<void> push({bool deleteRemoteMissing = false}) async {
    // 收集远端文件信息（path -> sha）
    final remoteFiles = await gitee.listAllFiles(owner, repo, branch: branch);
    final Map<String, String?> remoteMap = {
      for (final e in remoteFiles) e['path'] as String: e['sha'] as String?,
    };

    // 收集本地所有文件（相对路径 -> content）
    final Map<String, List<int>> localFiles = {};
    await _collectLocalFilesRecursively('', localFiles);

    // 上传或更新本地存在的文件
    for (final entry in localFiles.entries) {
      final path = entry.key;
      final localBytes = entry.value;
      // 获取远端对应文件内容（如果存在）用于比较
      String? remoteSha = remoteMap[path];
      bool needUpload = true;

      if (remoteSha != null) {
        final remoteInfo = await gitee.getFile(owner, repo, path, ref: branch);
        List<int>? remoteBytes = remoteInfo['content_bytes'] as List<int>?;
        if (remoteBytes != null &&
            _sha1Bytes(remoteBytes) == _sha1Bytes(localBytes)) {
          needUpload = false; // 内容相同，无需上传
        }
      }

      if (needUpload) {
        final message = 'Sync: update $path';
        try {
          await gitee.uploadFile(
            owner,
            repo,
            path,
            localBytes,
            message,
            branch: branch,
          );
        } catch (e) {
          // 可在此记录或抛出错误，当前简单继续
        }
      }
    }

    if (deleteRemoteMissing) {
      // 删除远端中不存在于本地的文件
      for (final remotePath in remoteMap.keys) {
        if (!localFiles.containsKey(remotePath)) {
          // 需要 sha 删除（Gitee API 要求）
          final remoteInfo = await gitee.getFile(
            owner,
            repo,
            remotePath,
            ref: branch,
          );
          final sha = remoteInfo['sha'] as String?;
          if (sha != null) {
            final message = 'Sync: delete $remotePath';
            await gitee.deleteFile(
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

  // 双向同步：先拉取（remote->local），再推送本地未上传项
  // conflictAction 决定拉取时的冲突处理（建议 createConflictCopy 或 remoteWins）
  Future<void> syncBidirectional({
    ConflictAction conflictAction = ConflictAction.createConflictCopy,
  }) async {
    await pull(conflictAction: conflictAction);
    await push();
  }

  // 将本地文件递归收集到 map 中（相对路径 -> bytes）
  Future<void> _collectLocalFilesRecursively(
    String relativeDir,
    Map<String, List<int>> out,
  ) async {
    final entries = await fileUtil.listFiles(
      workingDir,
      relativeDir,
      type: 'all',
    );
    // fileUtil.listFiles 在不同实现里可以支持 type 参数： 'file', 'directory', 'all'
    // 如果你的实现没有 'all'，可以分别调用 'file' 和 'directory' 两次或调整实现。
    for (final name in entries) {
      final candidate = relativeDir.isEmpty ? name : p.join(relativeDir, name);
      // 检查是否是目录 by asking listFiles for this path as directory
      final dirs = await fileUtil.listFiles(
        workingDir,
        candidate,
        type: 'directory',
      );
      final files = await fileUtil.listFiles(
        workingDir,
        candidate,
        type: 'file',
      );
      if (files.isNotEmpty) {
        // 文件存在：在某些 implementations listFiles(candidate) may return files directly
        for (final fn in files) {
          final rel = p.join(candidate, fn);
          final content = await fileUtil.readFile(workingDir, "", rel);
          if (content != null) out[rel] = utf8.encode(content);
        }
      }
      if (dirs.isNotEmpty) {
        // 递归目录：candidate 是父目录名，继续深入
        await _collectLocalFilesRecursively(candidate, out);
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
}
