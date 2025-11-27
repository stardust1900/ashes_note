// 基于 dart:js_interop 的可运行实现（兼容 Dart 3.9.2）
// 说明：使用 dart:js_interop 声明全局 self，并使用 dart:js_util 进行方法调用 & Promise->Future 转换。
// 在浏览器首次调用时会弹出目录选择器（showDirectoryPicker），之后以该目录为根进行读写操作。
// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:js_interop';
// ignore: deprecated_member_use
import 'dart:js_util' as js_util;

import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:ashes_note/utils/file_util.dart';

class FileUtilImpl implements FileUtil {
  JSObject? _rootDirectoryHandle;

  // ====================
  // 核心修复：使用 JS 互操作正确调用 showDirectoryPicker
  // ====================

  /// 确保已获取根目录的访问权限
  Future<void> _ensureRootDirectory() async {
    if (_rootDirectoryHandle == null) {
      try {
        // 方法1：使用 dart:js_util 直接调用（最可靠）
        final options = js_util.jsify({
          'id': 'ashes_note_path_id',
          'mode': 'readwrite',
        });

        final promise = js_util.callMethod(
          js_util.globalThis,
          'showDirectoryPicker',
          [options],
        );

        // 验证权限
        final permissionStatus = await _checkPermission();
        print('Permission status: $permissionStatus');
        if (permissionStatus != 'granted' && permissionStatus != 'prompt') {
          throw Exception('用户未授予文件系统访问权限');
        }
        _rootDirectoryHandle = await js_util.promiseToFuture(promise);
      } catch (e) {
        if (e.toString().contains('AbortError')) {
          throw Exception('用户取消了目录选择');
        }
        throw Exception('文件系统访问失败: $e');
      }
    }
  }

  /// 检查目录访问权限
  Future<String> _checkPermission() async {
    try {
      if (_rootDirectoryHandle != null) {
        final permissionPromise = js_util.callMethod(
          _rootDirectoryHandle!,
          'requestPermission',
          [
            js_util.jsify({'mode': 'readwrite'}),
          ],
        );
        return await js_util.promiseToFuture(permissionPromise);
      }
      return 'prompt';
    } catch (e) {
      return 'denied';
    }
  }

  // ====================
  // FileUtil 接口实现
  // ====================

  @override
  Future<String> saveFile(
    String rootPath,
    String path,
    String filename,
    List<int>? content,
  ) async {
    await _ensureRootDirectory();
    try {
      final getDirHandlePromise = js_util.callMethod(
        _rootDirectoryHandle!,
        'getDirectoryHandle',
        [
          path,
          js_util.jsify({'create': true}),
        ],
      );
      final dirHandle = await js_util.promiseToFuture(getDirHandlePromise);
      // 获取或创建文件句柄
      final getFileHandlePromise = js_util.callMethod(
        dirHandle!,
        'getFileHandle',
        [
          filename,
          js_util.jsify({'create': true}),
        ],
      );
      final fileHandle = await js_util.promiseToFuture(getFileHandlePromise);

      // 创建可写流并写入内容
      final createWritablePromise = js_util.callMethod(
        fileHandle,
        'createWritable',
        [],
      );
      final writableStream = await js_util.promiseToFuture(
        createWritablePromise,
      );

      await js_util.promiseToFuture(
        js_util.callMethod(writableStream, 'write', content ?? []),
      );
      await js_util.promiseToFuture(
        js_util.callMethod(writableStream, 'close', []),
      );
    } catch (e) {
      throw Exception('保存文件 "$path" 失败: $e');
    }
    return filename;
  }

  @override
  Future<String> readFile(String rootPath, String path, String filename) async {
    // String fullPath = '$path/$filename';
    await _ensureRootDirectory();
    try {
      final getDirHandlePromise = js_util.callMethod(
        _rootDirectoryHandle!,
        'getDirectoryHandle',
        [path],
      );
      final dirHandle = await js_util.promiseToFuture(getDirHandlePromise);
      // 检查文件是否存在：调用 getFileHandle(create: false)，若被拒绝则认为不存在
      final getFileHandlePromise = js_util.callMethod(
        dirHandle!,
        'getFileHandle',
        [
          filename,
          js_util.jsify({'create': false}),
        ],
      );
      final fileHandle = await js_util.promiseToFuture(getFileHandlePromise);
      final getFilePromise = js_util.callMethod(fileHandle, 'getFile', [
        js_util.jsify({'create': false}),
      ]);
      final file = await js_util.promiseToFuture(getFilePromise);

      final textPromise = js_util.callMethod(file, 'text', []);
      return await js_util.promiseToFuture(textPromise);
    } catch (e) {
      throw Exception('读取文件 "$path" 失败: $e');
    }
  }

  @override
  Future<void> deleteFile(String rootPath, String path, String filename) async {
    await _ensureRootDirectory();
    try {
      final getDirHandlePromise = js_util.callMethod(
        _rootDirectoryHandle!,
        'getDirectoryHandle',
        [path],
      );
      final dirHandle = await js_util.promiseToFuture(getDirHandlePromise);
      await js_util.promiseToFuture(
        js_util.callMethod(dirHandle!, 'removeEntry', [filename]),
      );
    } catch (e) {
      throw Exception('删除文件 "$path" 失败: $e');
    }
  }

  @override
  Future<List<String>> listFiles(
    String rootPath,
    String path, {
    String type = 'directory',
  }) async {
    await _ensureRootDirectory();
    final files = <String>[];
    try {
      // 处理子目录路径
      var targetHandle = _rootDirectoryHandle!;
      if (path.isNotEmpty && path != '.' && path != '/') {
        final getDirHandlePromise = js_util.callMethod(
          _rootDirectoryHandle!,
          'getDirectoryHandle',
          [path],
        );
        targetHandle = await js_util.promiseToFuture(getDirHandlePromise);
      }
      // 获取目录条目迭代器
      final iterator = js_util.callMethod(targetHandle, 'values', []);
      // final iterator = await js_util.promiseToFuture(valuesPromise);

      // 遍历目录内容
      while (true) {
        final nextPromise = js_util.callMethod(iterator, 'next', []);
        final result = await js_util.promiseToFuture(nextPromise);
        final done = js_util.getProperty(result, 'done');
        print('done: $done');
        if (done == true) break;

        final value = js_util.getProperty(result, 'value');
        print('value: $value');
        final name = js_util.getProperty(value, 'name') as String;
        final kind = js_util.getProperty(value, 'kind') as String;
        if (kind == 'file' && type == 'file') {
          files.add(name);
        }
        if (kind == 'directory' && type == 'directory') {
          if (!name.startsWith(".")) files.add(name);
        }
      }
    } catch (e) {
      throw Exception('列出路径 "$path" 下的文件失败: $e');
    }
    return files;
  }

  @override
  Future<String> getApplicationDocumentsPath() async {
    await _ensureRootDirectory();
    final name = js_util.getProperty(_rootDirectoryHandle!, 'name') as String;
    return name;
  }

  @override
  Future<void> createDirectory(String rootPath, String path) async {
    await _ensureRootDirectory();
    try {
      await js_util.promiseToFuture(
        js_util.callMethod(_rootDirectoryHandle!, 'getDirectoryHandle', [
          path,
          js_util.jsify({'create': true}),
        ]),
      );
    } catch (e) {
      throw Exception('创建目录 "$path" 失败: $e');
    }
  }

  @override
  Future<void> deleteDirectory(String rootPath, String path) async {
    await _ensureRootDirectory();
    try {
      await js_util.promiseToFuture(
        js_util.callMethod(_rootDirectoryHandle!, 'removeEntry', [
          path,
          js_util.jsify({'recursive': true}),
        ]),
      );
    } catch (e) {
      throw Exception('删除目录 "$path" 失败: $e');
    }
  }

  // ====================
  // 工具方法：浏览器兼容性检查
  // ====================

  static Future<bool> isSupported() async {
    return js_util.hasProperty(js_util.globalThis, 'showDirectoryPicker');
  }

  /// 手动重置目录句柄（允许用户重新选择）
  /// TODO 需要考虑重置后用户未授予文件系统访问权限的情况
  @override
  void resetDirectoryHandle() {
    _rootDirectoryHandle = null;
  }

  FileUtilImpl._internal();
  static final FileUtilImpl _instance = FileUtilImpl._internal();
  factory FileUtilImpl() => FileUtilImpl._instance;

  @override
  Future<List<Note>> listNotes(String rootPath, String path) async {
    await _ensureRootDirectory();
    final notes = <Note>[];
    try {
      // 处理子目录路径
      var targetHandle = _rootDirectoryHandle!;
      if (path.isNotEmpty && path != '.' && path != '/') {
        final getDirHandlePromise = js_util.callMethod(
          _rootDirectoryHandle!,
          'getDirectoryHandle',
          [path],
        );
        targetHandle = await js_util.promiseToFuture(getDirHandlePromise);
      }
      // 获取目录条目迭代器
      final iterator = js_util.callMethod(targetHandle, 'values', []);
      // final iterator = await js_util.promiseToFuture(valuesPromise);

      // 遍历目录内容
      while (true) {
        final nextPromise = js_util.callMethod(iterator, 'next', []);
        final result = await js_util.promiseToFuture(nextPromise);
        final done = js_util.getProperty(result, 'done');
        print('done: $done');
        if (done == true) break;

        final value = js_util.getProperty(result, 'value');
        print('value: $value');
        final name = js_util.getProperty(value, 'name') as String;
        final kind = js_util.getProperty(value, 'kind') as String;
        if (kind == 'file') {
          try {
            final getFileHandlePromise = js_util.callMethod(
              targetHandle,
              'getFileHandle',
              [name],
            );
            final fileHandle = await js_util.promiseToFuture(
              getFileHandlePromise,
            );

            final getFilePromise = js_util.callMethod(
              fileHandle,
              'getFile',
              [],
            );
            final file = await js_util.promiseToFuture(getFilePromise);
            final lastModifiedMs = js_util.getProperty(file, 'lastModified');
            var lastModified = DateTime.now();
            if (lastModifiedMs != null) {
              lastModified = DateTime.fromMillisecondsSinceEpoch(
                lastModifiedMs as int,
              );
              //displayName = '$name (${lastModified.toLocal()})';
            }
            final textPromise = js_util.callMethod(file, 'text', []);
            String content = await js_util.promiseToFuture(textPromise);
            notes.add(
              Note(
                id: '$path/$name',
                title: name,
                content: content,
                lastModified: lastModified,
              ),
            );
          } catch (e) {
            print('无法获取文件 $name 的详细信息: $e');
          }
        }
      }
    } catch (e) {
      throw Exception('列出路径 "$path" 下的文件失败: $e');
    }
    return notes;
  }

  @override
  bool isHandleGot() {
    return _rootDirectoryHandle != null;
  }
}
