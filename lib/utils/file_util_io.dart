// 非 web 平台实现：使用 dart:io
import 'dart:async';
import 'dart:io' as io;
import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ashes_note/utils/file_util.dart';
import 'package:path/path.dart' as p;

class FileUtilImpl implements FileUtil {
  @override
  Future<String> saveFile(String path, String filename, String content) async {
    final file = io.File(path);
    await file.create(recursive: true);
    await file.writeAsString(content);
    return filename;
  }

  @override
  Future<String> readFile(String path, String filename) async {
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
  Future<List<String>> listFiles(
    String rootPath,
    String path, {
    String type = 'directory',
  }) async {
    final dir = io.Directory('$rootPath/$path');
    if (!await dir.exists()) return <String>[];
    final entities = await dir.list().toList();
    if (type == 'file') {
      return entities.whereType<io.File>().map((f) {
        f.lastModified().then(
          (s) => print('f.modified: $s ${p.basename(f.path)}'),
        );
        return p.basename(f.path);
      }).toList();
    }
    if (type == 'directory') {
      return entities.whereType<io.Directory>().map((f) {
        f.stat().then((s) => print('s.modified: ${s.modified}'));
        return p.basename(f.path);
      }).toList();
    }
    return <String>[];
  }

  @override
  Future<String> getApplicationDocumentsPath() {
    // 调用此方法会打开系统原生的目录选择对话框
    return FilePicker.platform.getDirectoryPath().then((value) => value!);
  }

  FileUtilImpl._internal(); // 私有构造函数
  static final FileUtilImpl _instance = FileUtilImpl._internal();
  factory FileUtilImpl() => FileUtilImpl._instance;

  @override
  void resetDirectoryHandle() {
    // TODO: implement resetDirectoryHandle
  }

  @override
  Future<List<Note>> listNotes(String rootPath, String path) {
    // TODO: implement listNotes
    throw UnimplementedError();
  }
}
