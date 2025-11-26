import 'dart:convert';

import 'package:http/http.dart' as http;

class GitHubService {
  // GitHub service methods would be here
  final String token;
  final String _apiBase = 'https://api.github.com';

  GitHubService(this.token);

  Map<String, String> get _headers => {
    'Authorization': 'token $token',
    'Accept': 'application/vnd.github.v3+json',
    'Content-Type': 'application/json',
  };

  Future<Map<String, dynamic>> getRepo(String owner, String repo) async {
    final url = '$_apiBase/repos/$owner/$repo';
    final res = await http.get(Uri.parse(url), headers: _headers);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    throw Exception('Get repo failed: ${res.statusCode} ${res.body}');
  }

  /// Lists all files (blobs) in the repository tree for [branch] (recursive).
  Future<List<Map<String, dynamic>>> listAllFiles(
    String owner,
    String repo, {
    String branch = 'main',
  }) async {
    final url = '$_apiBase/repos/$owner/$repo/git/trees/$branch?recursive=1';
    final res = await http.get(Uri.parse(url), headers: _headers);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final tree = (data['tree'] as List).cast<Map<String, dynamic>>();
      return tree.where((e) => e['type'] == 'blob').toList();
    }
    throw Exception('List files failed: ${res.statusCode} ${res.body}');
  }

  /// Returns file metadata (and content when requested) for a path on [branch].
  Future<Map<String, dynamic>> getFile(
    String owner,
    String repo,
    String path, {
    String branch = 'main',
  }) async {
    final url =
        '$_apiBase/repos/$owner/$repo/contents/${Uri.encodeComponent(path)}?ref=$branch';
    final res = await http.get(Uri.parse(url), headers: _headers);
    if (res.statusCode == 200) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    } else if (res.statusCode == 404) {
      throw Exception('File not found: $path');
    }
    throw Exception('Get file failed: ${res.statusCode} ${res.body}');
  }

  /// Uploads or updates a file using base64-encoded [contentBase64].
  /// If the file exists it will be updated, otherwise created.
  Future<Map<String, dynamic>> uploadFile(
    String owner,
    String repo,
    String path,
    String contentBase64,
    String commitMessage, {
    String branch = 'main',
  }) async {
    String? sha;
    try {
      final existing = await getFile(owner, repo, path, branch: branch);
      sha = existing['sha'] as String?;
    } catch (_) {
      sha = null;
    }

    final body = <String, dynamic>{
      'message': commitMessage,
      'content': contentBase64,
      'branch': branch,
      if (sha != null) 'sha': sha,
    };

    final url =
        '$_apiBase/repos/$owner/$repo/contents/${Uri.encodeComponent(path)}';
    final res = await http.put(
      Uri.parse(url),
      headers: _headers,
      body: jsonEncode(body),
    );
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    throw Exception('Upload failed: ${res.statusCode} ${res.body}');
  }

  /// Helper to upload from plain string (will be encoded as UTF-8 + base64).
  Future<Map<String, dynamic>> uploadFileFromString(
    String owner,
    String repo,
    String path,
    String content,
    String commitMessage, {
    String branch = 'main',
  }) {
    final contentBase64 = base64Encode(utf8.encode(content));
    return uploadFile(
      owner,
      repo,
      path,
      contentBase64,
      commitMessage,
      branch: branch,
    );
  }

  /// Deletes a file at [path]. [commitMessage] is required.
  Future<Map<String, dynamic>> deleteFile(
    String owner,
    String repo,
    String path,
    String commitMessage, {
    String branch = 'main',
  }) async {
    final existing = await getFile(owner, repo, path, branch: branch);
    final sha = existing['sha'] as String?;
    if (sha == null) {
      throw Exception('Cannot delete file without sha: $path');
    }

    final body = {'message': commitMessage, 'sha': sha, 'branch': branch};
    final url =
        '$_apiBase/repos/$owner/$repo/contents/${Uri.encodeComponent(path)}';
    final res = await http.delete(
      Uri.parse(url),
      headers: _headers,
      body: jsonEncode(body),
    );
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    throw Exception('Delete failed: ${res.statusCode} ${res.body}');
  }
}
