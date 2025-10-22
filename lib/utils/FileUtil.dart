// 文件操作工具类，判断运行环境，如果是web环境使用 File System Access API 实现，其他环境用 dart:io 实现。
// 提供读取/创建/删除目录、读取/写入/删除文件、列出目录等方法。
import 'dart:async';
import 'dart:io' as io;
import 'package:flutter/foundation.dart' show kIsWeb;

/// Web-only imports (used via conditional runtime check)
/// We import these lazily inside web branches to avoid analyzer warnings on non-web.
import 'dart:html' as html;
import 'dart:js_util' as js_util;

class FileUtil {
  // In web environment we keep an in-memory directory handle for the session.
  // User will be prompted to pick a directory on first use.
  static dynamic _webRootHandle;

  // Normalize path separators and trim leading '/'
  static List<String> _segments(String path) {
    var np = path.replaceAll('\\', '/');
    if (np.startsWith('/')) np = np.substring(1);
    if (np.isEmpty) return <String>[];
    return np.split('/');
  }

  // Ensure we have a root directory handle on web (prompts user once per session)
  static Future<dynamic> _ensureWebRoot() async {
    if (_webRootHandle != null) return _webRootHandle;
    // call window.showDirectoryPicker()
    final dirHandlePromise = js_util.callMethod(
      html.window,
      'showDirectoryPicker',
      <Object>[],
    );
    _webRootHandle = await js_util.promiseToFuture(dirHandlePromise);
    return _webRootHandle;
  }

  // Navigate to directory handle given path segments; create option controls creation
  static Future<dynamic> _webGetDirectoryHandle(
    dynamic startHandle,
    List<String> segments, {
    bool create = false,
  }) async {
    var handle = startHandle;
    for (var seg in segments) {
      // getDirectoryHandle(seg, {create: create})
      final args = <Object>[
        seg,
        js_util.jsify({'create': create}),
      ];
      final nextPromise = js_util.callMethod(
        handle,
        'getDirectoryHandle',
        args,
      );
      handle = await js_util.promiseToFuture(nextPromise);
    }
    return handle;
  }

  // Get parent directory handle and final name (for files)
  static Future<Map<String, dynamic>> _webResolveParentHandle(
    String path, {
    bool createDirs = false,
  }) async {
    final segs = _segments(path);
    if (segs.isEmpty) {
      final root = await _ensureWebRoot();
      return {'parent': root, 'name': ''};
    }
    final name = segs.removeLast();
    final root = await _ensureWebRoot();
    final parent = await _webGetDirectoryHandle(root, segs, create: createDirs);
    return {'parent': parent, 'name': name};
  }

  // ----- Public API -----

  /// 保存文件（覆盖）
  static Future<void> saveFile(String path, String content) async {
    if (kIsWeb) {
      final resolved = await _webResolveParentHandle(
        path,
        createDirs: true,
      ); // create dirs
      final parent = resolved['parent'];
      final name = resolved['name'];
      // getFileHandle(name, {create: true})
      final fileHandlePromise = js_util.callMethod(
        parent,
        'getFileHandle',
        <Object>[
          name,
          js_util.jsify({'create': true}),
        ],
      );
      final fileHandle = await js_util.promiseToFuture(fileHandlePromise);

      // createWritable(), write(content), close()
      final writablePromise = js_util.callMethod(
        fileHandle,
        'createWritable',
        <Object>[],
      );
      final writable = await js_util.promiseToFuture(writablePromise);
      // write can accept a string directly
      await js_util.promiseToFuture(
        js_util.callMethod(writable, 'write', <Object>[content]),
      );
      await js_util.promiseToFuture(
        js_util.callMethod(writable, 'close', <Object>[]),
      );
      return;
    } else {
      final file = io.File(path);
      await file.create(recursive: true);
      await file.writeAsString(content);
    }
  }

  /// 读取文件内容，文件不存在抛出异常
  static Future<String> readFile(String path) async {
    if (kIsWeb) {
      final resolved = await _webResolveParentHandle(path, createDirs: false);
      final parent = resolved['parent'];
      final name = resolved['name'];
      try {
        final fileHandlePromise = js_util.callMethod(
          parent,
          'getFileHandle',
          <Object>[name],
        );
        final fileHandle = await js_util.promiseToFuture(fileHandlePromise);
        final filePromise = js_util.callMethod(
          fileHandle,
          'getFile',
          <Object>[],
        );
        final file = await js_util.promiseToFuture(filePromise);
        final textPromise = js_util.callMethod(file, 'text', <Object>[]);
        final text = await js_util.promiseToFuture(textPromise);
        return text as String;
      } catch (e) {
        throw Exception('File not found: $path');
      }
    } else {
      final file = io.File(path);
      if (!await file.exists()) {
        throw io.FileSystemException('File not found', path);
      }
      return await file.readAsString();
    }
  }

  /// 删除文件（如果存在）
  static Future<void> deleteFile(String path) async {
    if (kIsWeb) {
      final resolved = await _webResolveParentHandle(path, createDirs: false);
      final parent = resolved['parent'];
      final name = resolved['name'];
      try {
        // removeEntry(name)
        await js_util.promiseToFuture(
          js_util.callMethod(parent, 'removeEntry', <Object>[name]),
        );
      } catch (e) {
        // ignore if not exist or operation denied
      }
    } else {
      final file = io.File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  /// 创建目录（递归）
  static Future<void> createDirectory(String path) async {
    if (kIsWeb) {
      final segs = _segments(path);
      if (segs.isEmpty) return;
      final root = await _ensureWebRoot();
      await _webGetDirectoryHandle(root, segs, create: true);
    } else {
      final directory = io.Directory(path);
      if (!(await directory.exists())) {
        await directory.create(recursive: true);
      }
    }
  }

  /// 删除目录（递归）
  static Future<void> deleteDirectory(String path) async {
    if (kIsWeb) {
      final segs = _segments(path);
      if (segs.isEmpty) {
        // cannot delete root chosen by user
        throw Exception('Refusing to delete root directory');
      }
      final name = segs.removeLast();
      final root = await _ensureWebRoot();
      final parent = await _webGetDirectoryHandle(root, segs, create: false);
      try {
        await js_util.promiseToFuture(
          js_util.callMethod(parent, 'removeEntry', <Object>[
            name,
            js_util.jsify({'recursive': true}),
          ]),
        );
      } catch (e) {
        // ignore or rethrow based on needs
      }
    } else {
      final directory = io.Directory(path);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }

  /// 列出目录下的文件路径（不递归子目录）
  static Future<List<String>> listFiles(String path) async {
    if (kIsWeb) {
      final segs = _segments(path);
      final root = await _ensureWebRoot();
      final dirHandle = await _webGetDirectoryHandle(root, segs, create: false);
      final entriesIterator = js_util.callMethod(
        dirHandle,
        'entries',
        <Object>[],
      );
      final results = <String>[];
      while (true) {
        final next = await js_util.promiseToFuture(
          js_util.callMethod(entriesIterator, 'next', <Object>[]),
        );
        final done = js_util.getProperty(next, 'done') as bool;
        if (done) break;
        final value = js_util.getProperty(next, 'value');
        // value is a JS array [name, handle]
        final name = js_util.getProperty(value, '0') as String;
        final handle = js_util.getProperty(value, '1');
        // Only include files (kind === 'file' for FileSystemFileHandle)
        final kind = js_util.getProperty(handle, 'kind') as String?;
        if (kind == 'file') {
          final joined = segs.isEmpty ? name : '${segs.join('/')}/$name';
          results.add(joined);
        }
      }
      return results;
    } else {
      final directory = io.Directory(path);
      if (await directory.exists()) {
        final entities = directory.listSync();
        return entities.whereType<io.File>().map((f) => f.path).toList();
      } else {
        return [];
      }
    }
  }
}
