// 基于 dart:js_interop 的可运行实现（兼容 Dart 3.9.2）
// 说明：使用 dart:js_interop 完全替代 dart:js_util
// 在浏览器首次调用时会弹出目录选择器（showDirectoryPicker），之后以该目录为根进行读写操作。
// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:ashes_note/utils/file_util.dart';

// 全局 JS 对象访问
@JS('showDirectoryPicker')
external JSPromise<DirectoryHandle>? _showDirectoryPicker(JSObject options);

// 创建 Uint8Array 的辅助函数
@JS('Uint8Array')
external JSUint8Array _createUint8Array(int length);

// 辅助函数：设置 Uint8Array 的元素
@JS()
external void _setUint8ArrayElement(JSUint8Array array, int index, int value);

@JS('FileSystemHandle')
extension type FileSystemHandle._(JSObject _) implements JSObject {
  external JSString get name;
  external JSString get kind;
}

@JS('DirectoryHandle')
extension type DirectoryHandle._(JSObject _) implements JSObject {
  external JSPromise<DirectoryHandle> getDirectoryHandle(
    String name, [
    JSObject options,
  ]);
  external JSPromise<FileHandle> getFileHandle(String name, [JSObject options]);
  external JSPromise<JSString> requestPermission([JSObject options]);
  external JSPromise<JSAny?> removeEntry(String name, [JSObject options]);
  external JSAny values();
}

@JS('FileHandle')
extension type FileHandle._(JSObject _) implements JSObject {
  external JSPromise<File> getFile();
  external JSPromise<FileSystemWritableFileStream> createWritable();
}

@JS('File')
extension type File._(JSObject _) implements JSObject {
  external JSPromise<JSString> text();
  external int get lastModified;
}

@JS('FileSystemWritableFileStream')
extension type FileSystemWritableFileStream._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSAny data);
  external JSPromise<JSAny?> close();
}

// 辅助函数：创建 JS 对象
JSObject createOptions([Map<String, dynamic>? map]) {
  if (map == null || map.isEmpty) {
    return JSObject();
  }
  final obj = JSObject();
  for (final entry in map.entries) {
    final key = entry.key;
    final value = _convertToJSAny(entry.value);
    obj[key] = value;
  }
  return obj;
}

/// 将 Dart 值转换为 JSAny
JSAny? _convertToJSAny(dynamic value) {
  if (value == null) {
    return null;
  } else if (value is String) {
    return value.toJS;
  } else if (value is bool) {
    return value.toJS;
  } else if (value is int || value is double) {
    return value.toJS;
  } else {
    throw ArgumentError('Unsupported type: ${value.runtimeType}');
  }
}

class FileUtilImpl implements FileUtil {
  DirectoryHandle? _rootDirectoryHandle;

  // ====================
  // 核心修复：使用 dart:js_interop 正确调用 showDirectoryPicker
  // ====================

  /// 确保已获取根目录的访问权限
  Future<void> _ensureRootDirectory() async {
    if (_rootDirectoryHandle == null) {
      try {
        final options = createOptions({
          'id': 'ashes_note_path_id',
          'mode': 'readwrite',
        });

        final promise = _showDirectoryPicker(options);
        if (promise == null) {
          throw Exception('showDirectoryPicker 返回 null');
        }
        _rootDirectoryHandle = await promise.toDart;

        // 验证权限
        final permissionStatus = await _checkPermission();
        if (permissionStatus != 'granted') {
          throw Exception('用户未授予文件系统访问权限');
        }
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
        final options = createOptions({'mode': 'readwrite'});
        final permissionPromise = _rootDirectoryHandle!.requestPermission(
          options,
        );
        return (await permissionPromise.toDart).toDart;
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
      final dirHandle = await _rootDirectoryHandle!
          .getDirectoryHandle(path, createOptions({'create': true}))
          .toDart;
      final fileHandle = await dirHandle
          .getFileHandle(filename, createOptions({'create': true}))
          .toDart;
      final writableStream = await fileHandle.createWritable().toDart;

      try {
        // 创建 Uint8Array 并使用 js_interop_unsafe 设置数据
        final jsArray = content != null
            ? _createUint8Array(content.length)
            : _createUint8Array(0);
        if (content != null) {
          // 使用外部函数设置元素
          for (var i = 0; i < content.length; i++) {
            _setUint8ArrayElement(jsArray, i, content[i]);
          }
        }
        await writableStream.write(jsArray).toDart;
      } finally {
        await writableStream.close().toDart;
      }
    } catch (e) {
      throw Exception('保存文件 "$path" 失败: $e');
    }
    return filename;
  }

  @override
  Future<String> readFile(String rootPath, String path, String filename) async {
    await _ensureRootDirectory();
    try {
      final dirHandle = await _rootDirectoryHandle!
          .getDirectoryHandle(path)
          .toDart;
      final fileHandle = await dirHandle.getFileHandle(filename).toDart;
      final file = await fileHandle.getFile().toDart;
      return (await file.text().toDart).toDart;
    } catch (e) {
      throw Exception('读取文件 "$path" 失败: $e');
    }
  }

  @override
  Future<void> deleteFile(String rootPath, String path, String filename) async {
    await _ensureRootDirectory();
    try {
      final dirHandle = await _rootDirectoryHandle!
          .getDirectoryHandle(path)
          .toDart;
      await dirHandle.removeEntry(filename).toDart;
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
      var targetHandle = _rootDirectoryHandle!;
      if (path.isNotEmpty && path != '.' && path != '/') {
        targetHandle = await _rootDirectoryHandle!
            .getDirectoryHandle(path)
            .toDart;
      }

      // 修复迭代逻辑，正确处理 JavaScript 异步迭代器
      final entriesIterator = _createAsyncIterator(targetHandle.values());
      await for (final entry in entriesIterator) {
        final handle = entry;
        final name = handle.name.toDart;
        final kind = handle.kind.toDart;
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
    return (_rootDirectoryHandle!['name'] as JSString).toDart;
  }

  @override
  Future<void> createDirectory(String rootPath, String path) async {
    await _ensureRootDirectory();
    try {
      await _rootDirectoryHandle!
          .getDirectoryHandle(path, createOptions({'create': true}))
          .toDart;
    } catch (e) {
      throw Exception('创建目录 "$path" 失败: $e');
    }
  }

  @override
  Future<void> deleteDirectory(String rootPath, String path) async {
    await _ensureRootDirectory();
    try {
      await _rootDirectoryHandle!
          .removeEntry(path, createOptions({'recursive': true}))
          .toDart;
    } catch (e) {
      throw Exception('删除目录 "$path" 失败: $e');
    }
  }

  // ====================
  // 工具方法：浏览器兼容性检查
  // ====================

  static Future<bool> isSupported() async {
    return globalContext.hasProperty('showDirectoryPicker'.toJS).toDart;
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
      var targetHandle = _rootDirectoryHandle!;
      if (path.isNotEmpty && path != '.' && path != '/') {
        targetHandle = await _rootDirectoryHandle!
            .getDirectoryHandle(path)
            .toDart;
      }

      // 修复迭代逻辑，正确处理 JavaScript 异步迭代器
      final entriesIterator = _createAsyncIterator(targetHandle.values());
      await for (final entry in entriesIterator) {
        final handle = entry;
        final name = handle.name.toDart;
        final kind = handle.kind.toDart;
        if (kind == 'file') {
          try {
            final fileHandle = await targetHandle.getFileHandle(name).toDart;
            final file = await fileHandle.getFile().toDart;
            final lastModifiedMs = file.lastModified;
            final lastModified = lastModifiedMs > 0
                ? DateTime.fromMillisecondsSinceEpoch(lastModifiedMs)
                : DateTime.now();
            final content = (await file.text().toDart).toDart;
            notes.add(
              Note(
                id: '$path/$name',
                title: name,
                content: content,
                lastModified: lastModified,
              ),
            );
          } catch (e) {
            // 忽略无法读取的文件
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

  /// 创建异步迭代器以处理 JavaScript 异步迭代
  Stream<FileSystemHandle> _createAsyncIterator(JSAny jsIterable) {
    final iterator = jsIterable as JSObject;
    return _asyncIteratorToStream(iterator);
  }

  /// 将 JavaScript 异步迭代器转换为 Dart Stream
  Stream<FileSystemHandle> _asyncIteratorToStream(JSObject iterator) async* {
    final nextMethod = iterator['next'] as JSFunction;
    var result =
        await (nextMethod.callAsFunction(iterator) as JSPromise<JSObject>)
            .toDart;

    while (!((result['done'] as JSBoolean).toDart)) {
      yield result['value'] as FileSystemHandle;
      result =
          await (nextMethod.callAsFunction(iterator) as JSPromise<JSObject>)
              .toDart;
    }
  }
}
