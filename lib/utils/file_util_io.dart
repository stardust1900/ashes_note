// 非 web 平台实现：使用 dart:io
import 'dart:async';
import 'dart:io' as io;
import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ashes_note/utils/file_util.dart';
import 'package:path/path.dart' as p;

class FileUtilImpl implements FileUtil {
  @override
  Future<String> saveFile(
    String rootPath,
    String path,
    String filename,
    List<int>? content,
  ) async {
    final file = io.File('$rootPath/$path/$filename');
    await file.create(recursive: true);
    await file.writeAsBytes(content ?? []);
    return filename;
  }

  @override
  Future<String> readFile(String rootPath, String path, String filename) async {
    final file = io.File('$rootPath/$path/$filename');
    if (!await file.exists()) {
      throw io.FileSystemException('File not found', filename);
    }
    return await file.readAsString();
  }

  @override
  Future<void> deleteFile(String rootPath, String path, String filename) async {
    final file = io.File('$rootPath/$path/$filename');
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<void> createDirectory(String rootPath, String path) async {
    final dir = io.Directory('$rootPath/$path');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  @override
  Future<void> deleteDirectory(String rootPath, String path) async {
    final dir = io.Directory('$rootPath/$path');
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
      return entities.whereType<io.File>()
      // .where((f) => p.basename(f.path).endsWith('.md'))
      .map((f) {
        // f.lastModified().then(
        //   (s) => print('f.modified: $s ${p.basename(f.path)}'),
        // );
        return p.basename(f.path);
      }).toList();
    }
    if (type == 'directory') {
      return entities
          .whereType<io.Directory>()
          .where((f) {
            return !p.basename(f.path).startsWith('.');
          })
          .map((f) {
            // f.stat().then(
            //   (s) => print('s.modified: ${s.modified} ${p.basename(f.path)}'),
            // );
            return p.basename(f.path);
          })
          .toList();
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
  Future<List<Note>> listNotes(String rootPath, String path) async {
    final notes = <Note>[];
    final dir = io.Directory('$rootPath/$path');
    if (!await dir.exists()) return <Note>[];
    final entities = await dir.list().toList();
    // 按最后修改时间降序排序
    final pairs = await Future.wait(
      entities.map((e) async {
        final lm = e is io.File
            ? await e.lastModified()
            : DateTime.fromMillisecondsSinceEpoch(0);
        return MapEntry(e, lm);
      }),
    );
    pairs.sort((a, b) => b.value.compareTo(a.value));
    entities
      ..clear()
      ..addAll(pairs.map((p) => p.key).toList());

    for (var entity in entities) {
      if (entity is io.File) {
        final content = await entity.readAsString();
        final lastModified = await entity.lastModified();
        final note = Note(
          id: '$path/${p.basename(entity.path)}',
          title: p.basename(entity.path),
          content: content,
          lastModified: lastModified,
        );
        notes.add(note);
      }
    }

    return notes;
  }

  @override
  bool isHandleGot() {
    return true;
  }
}
