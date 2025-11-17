import 'package:ashes_note/entity/entities_notebook.dart';

import 'file_util_io.dart' if (dart.library.js_interop) 'file_util_web.dart';
// 统一入口：按平台选择实现（web 使用 file_util_web.dart）
// export 'file_util_io.dart' if (dart.library.js_interop) 'file_util_web.dart';

// 定义所有平台都必须实现的公共接口
abstract class FileUtil {
  // 文件读写操作
  Future<String> saveFile(String path, String filename, String content);
  Future<String> readFile(String path, String filename);
  Future<void> deleteFile(String path);
  Future<List<String>> listFiles(
    String rootPath,
    String path, {
    String type = 'directory',
  });

  Future<List<Note>> listNotes(String rootPath, String path);

  // 目录操作
  Future<String> getApplicationDocumentsPath();
  Future<void> createDirectory(String path);
  Future<void> deleteDirectory(String path);

  // 手动重置目录句柄（允许用户重新选择）
  void resetDirectoryHandle();

  factory FileUtil() => FileUtilImpl();
}
