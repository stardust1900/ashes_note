// 非 web 平台实现：使用 dart:io
import 'dart:async';
import 'dart:io' as io;

import 'package:ashes_note/utils/file_util.dart';

class FileUtilIO implements FileUtil {
  @override
  Future<void> saveFile(String path, String filename, String content) async {
    final file = io.File(path);
    await file.create(recursive: true);
    await file.writeAsString(content);
  }

  @override
  Future<String> readFile(String path) async {
    final file = io.File(path);
    if (!await file.exists()) {
      throw io.FileSystemException('File not found', path);
    }
    return await file.readAsString();
  }

  @override
  Future<void> deleteFile(String path) async {
    final file = io.File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<void> createDirectory(String path) async {
    final dir = io.Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  @override
  Future<void> deleteDirectory(String path) async {
    final dir = io.Directory(path);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  @override
  Future<List<String>> listFiles(String path) async {
    final dir = io.Directory(path);
    if (!await dir.exists()) return <String>[];
    final entities = await dir.list().toList();
    final files = entities.whereType<io.File>().map((f) => f.path).toList();
    return files;
  }

  @override
  Future<String> getApplicationDocumentsPath() {
    throw UnimplementedError();
  }

  FileUtilIO._internal(); // 私有构造函数
  static final FileUtilIO _instance = FileUtilIO._internal();
  factory FileUtilIO() => FileUtilIO._instance;

  @override
  void resetDirectoryHandle() {
    // TODO: implement resetDirectoryHandle
  }
}
