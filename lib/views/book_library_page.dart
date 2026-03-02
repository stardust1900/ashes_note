import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:ashes_note/services/book_reader/book_reader_services.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:epub_plus/epub_plus.dart' hide Image;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'book_reader_page.dart';

/// 书籍元数据模型（用于缓存）
class BookMetadata {
  final String filePath;
  final String title;
  final String author;
  final String? coverPath;

  BookMetadata({
    required this.filePath,
    required this.title,
    required this.author,
    this.coverPath,
  });

  Map<String, dynamic> toJson() {
    return {
      'filePath': filePath,
      'title': title,
      'author': author,
      'coverPath': coverPath,
    };
  }

  factory BookMetadata.fromJson(Map<String, dynamic> json) {
    return BookMetadata(
      filePath: json['filePath'] as String,
      title: json['title'] as String,
      author: json['author'] as String,
      coverPath: json['coverPath'] as String?,
    );
  }
}

/// 书籍库页面 - 展示所有导入的书籍
class BookLibraryPage extends StatefulWidget {
  const BookLibraryPage({super.key});

  @override
  State<BookLibraryPage> createState() => _BookLibraryPageState();
}

class _BookLibraryPageState extends State<BookLibraryPage> {
  List<BookInfo> _books = [];

  @override
  void initState() {
    super.initState();
    _loadBooks();
    // 异步清理无效的元数据缓存
    _cleanMetadataCache();
  }

  /// 获取元数据缓存文件路径
  Future<File> _getMetadataCacheFile() async {
    final workingDir = SPUtil.get<String>('workingDirectory', '');
    final cacheDir = Directory('$workingDir/books/.cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return File('${cacheDir.path}/books_metadata.json');
  }

  /// 从缓存加载书籍元数据
  Future<Map<String, BookMetadata>> _loadMetadataCache() async {
    try {
      final cacheFile = await _getMetadataCacheFile();
      if (!await cacheFile.exists()) return {};

      final jsonString = await cacheFile.readAsString();
      final jsonData = jsonDecode(jsonString) as List<dynamic>;

      final metadataMap = <String, BookMetadata>{};
      for (final item in jsonData) {
        final metadata = BookMetadata.fromJson(item as Map<String, dynamic>);
        metadataMap[metadata.filePath] = metadata;
      }

      return metadataMap;
    } catch (e) {
      print('[BookLibrary] 加载元数据缓存失败: $e');
      return {};
    }
  }

  /// 保存书籍元数据到缓存
  Future<void> _saveMetadataCache(Map<String, BookMetadata> metadataMap) async {
    try {
      final cacheFile = await _getMetadataCacheFile();
      final jsonData = metadataMap.values.map((m) => m.toJson()).toList();
      final jsonString = jsonEncode(jsonData);
      await cacheFile.writeAsString(jsonString);
      print('[BookLibrary] 元数据缓存已保存 (${metadataMap.length} 本书)');
    } catch (e) {
      print('[BookLibrary] 保存元数据缓存失败: $e');
    }
  }

  /// 更新单本书籍的元数据缓存
  Future<void> _updateBookMetadata(BookMetadata metadata) async {
    final metadataMap = await _loadMetadataCache();
    metadataMap[metadata.filePath] = metadata;
    await _saveMetadataCache(metadataMap);
  }

  /// 解析书籍元数据（带缓存）
  Future<BookMetadata> _parseBookMetadata(File file) async {
    // 先检查缓存
    final metadataMap = await _loadMetadataCache();

    if (metadataMap.containsKey(file.path)) {
      // 检查文件是否仍然存在
      final cached = metadataMap[file.path]!;
      final coverFile = cached.coverPath != null
          ? File(cached.coverPath!)
          : null;

      return BookMetadata(
        filePath: file.path,
        title: cached.title,
        author: cached.author,
        coverPath: coverFile?.path,
      );
    }

    // 缓存中没有，需要解析
    final filename = file.uri.pathSegments.last;
    String title = filename.replaceAll(
      RegExp(r'\.(epub|mobi|azw3|kfx|pdf)$'),
      '',
    );
    String author = '未知作者';
    File? coverFile;

    // 尝试使用 epub_plus 解析书籍元数据
    if (filename.toLowerCase().endsWith('.epub')) {
      try {
        final bytes = await file.readAsBytes();
        final epub = await EpubReader.readBook(bytes);

        if (epub.title != null && epub.title!.isNotEmpty) {
          title = epub.title!;
        }
        if (epub.author != null && epub.author!.isNotEmpty) {
          author = epub.author!;
        }

        // 提取封面
        if (epub.coverImage != null) {
          final workingDir = SPUtil.get<String>('workingDirectory', '');
          final cacheDir = Directory('$workingDir/books/.cache');
          if (!await cacheDir.exists()) {
            await cacheDir.create(recursive: true);
          }
          final coverFilePath =
              '${cacheDir.path}/cover_${file.path.hashCode}.jpg';
          final coverData = Uint8List.fromList(img.encodeJpg(epub.coverImage!));
          await File(coverFilePath).writeAsBytes(coverData);
          coverFile = File(coverFilePath);
        }

        print('[BookLibrary] 解析 EPUB 元数据成功: $title, $author');
      } catch (e) {
        print('[BookLibrary] 解析 EPUB 元数据失败: $e');
      }
    }

    final metadata = BookMetadata(
      filePath: file.path,
      title: title,
      author: author,
      coverPath: coverFile?.path,
    );

    // 保存到缓存
    await _updateBookMetadata(metadata);

    return metadata;
  }

  Future<void> _loadBooks() async {
    final workingDir = SPUtil.get<String>('workingDirectory', '');
    if (workingDir.isEmpty) return;

    final booksDir = Directory('$workingDir/books');
    if (!await booksDir.exists()) {
      await booksDir.create(recursive: true);
    }

    final files = await booksDir.list().toList();

    // 过滤出支持的电子书格式
    final supportedFiles = files
        .whereType<File>()
        .where(
          (f) =>
              f.path.endsWith('.epub') ||
              f.path.endsWith('.mobi') ||
              f.path.endsWith('.azw3') ||
              f.path.endsWith('.kfx') ||
              f.path.endsWith('.pdf'),
        )
        .toList();

    // 从缓存加载元数据，快速创建 BookInfo 对象
    final List<BookInfo> bookInfos = [];
    for (final file in supportedFiles) {
      final metadata = await _parseBookMetadata(file);
      final coverFile = metadata.coverPath != null
          ? File(metadata.coverPath!)
          : null;

      bookInfos.add(
        BookInfo(
          file: file,
          title: metadata.title,
          author: metadata.author,
          coverFile: coverFile,
        ),
      );
    }

    setState(() {
      _books = bookInfos;
    });
  }

  Future<void> _importBook() async {
    try {
      print('[BookLibrary] 开始导入书籍...');
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['epub', 'mobi', 'azw3', 'kfx', 'pdf'],
        allowMultiple: true,
      );

      if (result == null || result.files.isEmpty) {
        print('[BookLibrary] 未选择文件');
        return;
      }
      print('[BookLibrary] 选择了 ${result.files.length} 个文件');

      final workingDir = SPUtil.get<String>('workingDirectory', '');
      print('[BookLibrary] 工作目录: $workingDir');
      if (workingDir.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请先设置工作目录')));
        }
        return;
      }

      final booksDir = Directory('$workingDir/books');
      if (!await booksDir.exists()) {
        await booksDir.create(recursive: true);
        print('[BookLibrary] 创建书籍目录: $booksDir');
      }

      int importedCount = 0;
      for (var file in result.files) {
        print('[BookLibrary] 处理文件: ${file.name}, path: ${file.path}');
        if (file.path != null) {
          final sourceFile = File(file.path!);
          final destFile = File('${booksDir.path}/${file.name}');

          if (!await destFile.exists()) {
            print('[BookLibrary] 复制文件到: ${destFile.path}');
            await sourceFile.copy(destFile.path);
            importedCount++;
            print('[BookLibrary] 导入成功: ${file.name}');

            // 立即解析并缓存元数据
            try {
              final metadata = await _parseBookMetadata(destFile);
              print('[BookLibrary] 元数据已缓存: ${metadata.title}');
            } catch (e) {
              print('[BookLibrary] 缓存元数据失败: $e');
            }
          } else {
            print('[BookLibrary] 文件已存在: ${file.name}');
          }
        }
      }

      if (importedCount > 0) {
        await _loadBooks();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('成功导入 $importedCount 本书籍')));
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('选择的书籍已存在')));
        }
      }
    } catch (e, stackTrace) {
      print('[BookLibrary] 导入失败: $e');
      print('[BookLibrary] 堆栈: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    }
  }

  Future<void> _renameBook(BookInfo book, String newTitle) async {
    if (newTitle.isEmpty || newTitle == book.title) return;

    try {
      final oldFile = book.file;
      final oldCoverFile = book.coverFile;
      final oldTitle = book.title;

      // 获取文件扩展名
      final ext = oldFile.path.split('.').last;
      final dir = oldFile.parent.path;

      // 生成新文件名（去除特殊字符）
      final safeNewTitle = newTitle.replaceAll(RegExp(r'[<>"/\\|?*]'), '_');
      final newFileName = '$safeNewTitle.$ext';
      final newFilePath = '$dir${Platform.pathSeparator}$newFileName';

      // 检查新文件名是否已存在
      final newFile = File(newFilePath);
      if (await newFile.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('该名称的书籍已存在')));
        }
        return;
      }

      // 重命名书籍文件
      await oldFile.rename(newFilePath);

      // 更新书籍列表中的信息
      setState(() {
        book.title = newTitle;
        book.file = newFile;
      });

      // 迁移阅读进度（使用新的文件路径哈希）
      final oldBookKey = 'reading_position_${oldFile.path.hashCode}';
      final newBookKey = 'reading_position_${newFile.path.hashCode}';
      final position = SPUtil.get<String>(oldBookKey, '');
      if (position.isNotEmpty) {
        await SPUtil.set<String>(newBookKey, position);
        await SPUtil.remove(oldBookKey);
      }

      // 检查并更新 last_read_book
      final lastReadBook = SPUtil.get<String>('last_read_book', '');
      if (lastReadBook == oldFile.path) {
        await SPUtil.set<String>('last_read_book', newFile.path);
      }

      // 迁移页面缓存
      try {
        // final appDir = await getApplicationDocumentsDirectory();
        final workingDir = SPUtil.get<String>('workingDirectory', '');
        final cacheDir = Directory('$workingDir/books/.cache');
        if (await cacheDir.exists()) {
          final oldCacheKey = oldFile.path.hashCode.toString();
          final newCacheKey = newFile.path.hashCode.toString();
          final oldCacheFile = File('${cacheDir.path}/$oldCacheKey.json');
          final newCacheFile = File('${cacheDir.path}/$newCacheKey.json');
          if (await oldCacheFile.exists()) {
            await oldCacheFile.rename(newCacheFile.path);
          }
        }
      } catch (e) {
        // 缓存迁移失败不影响主流程
        print('[BookLibrary] 迁移页面缓存失败: $e');
      }

      // 迁移高亮和笔记数据（使用新的存储服务）
      try {
        await BookStorageService().migrateBookData(oldFile.path, newFile.path);
        print('[BookLibrary] 书籍数据已迁移');
      } catch (e) {
        // 数据迁移失败不影响主流程
        print('[BookLibrary] 迁移书籍数据失败: $e');
      }

      // 重命名封面文件（如果存在且是独立文件）
      if (oldCoverFile != null && await oldCoverFile.exists()) {
        final coverDir = oldCoverFile.parent.path;
        final coverExt = oldCoverFile.path.split('.').last;
        final newCoverFileName = '$safeNewTitle.$coverExt';
        final newCoverPath =
            '$coverDir${Platform.pathSeparator}$newCoverFileName';

        // 只有当旧封面文件名包含旧标题时才重命名
        if (oldCoverFile.path.contains(oldTitle)) {
          await oldCoverFile.rename(newCoverPath);
          setState(() {
            book.coverFile = File(newCoverPath);
          });
        }
      }

      // 更新元数据缓存
      try {
        final metadataMap = await _loadMetadataCache();
        if (metadataMap.containsKey(oldFile.path)) {
          final metadata = metadataMap[oldFile.path]!;
          metadataMap.remove(oldFile.path);
          metadataMap[newFile.path] = BookMetadata(
            filePath: newFile.path,
            title: newTitle,
            author: metadata.author,
            coverPath: book.coverFile?.path,
          );
          await _saveMetadataCache(metadataMap);
        }
      } catch (e) {
        print('[BookLibrary] 更新元数据缓存失败: $e');
      }

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已重命名为《$newTitle》')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('重命名失败: $e')));
      }
    }
  }

  Future<void> _deleteBook(BookInfo book) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除《${book.title}》吗？\n\n此操作将删除书籍文件及其缓存数据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      // 在删除书籍文件之前，先计算缓存键并删除页面缓存
      String cacheKey;
      try {
        final bytes = await book.file.readAsBytes();
        final digest = crypto.md5.convert(bytes);
        cacheKey = digest.toString();
        print('[BookLibrary] 缓存键: $cacheKey');
      } catch (e) {
        // 如果读取失败，使用路径和修改时间
        try {
          final stat = await book.file.stat();
          cacheKey =
              '${book.file.path.hashCode}_${stat.modified.millisecondsSinceEpoch}';
        } catch (e2) {
          print('[BookLibrary] 获取缓存键失败: $e2');
          cacheKey = book.file.path.hashCode.toString();
        }
      }

      // 删除页面缓存（在删除书籍文件之前）
      try {
        final workingDir = SPUtil.get<String>('workingDirectory', '');
        final cacheDir = Directory('$workingDir/books/.cache');
        if (await cacheDir.exists()) {
          final cacheFile = File('${cacheDir.path}/$cacheKey.json');
          if (await cacheFile.exists()) {
            await cacheFile.delete();
            print('[BookLibrary] 页面缓存已删除: $cacheKey');
          } else {
            print('[BookLibrary] 页面缓存文件不存在: $cacheKey.json');
          }
        }
      } catch (e) {
        print('[BookLibrary] 删除页面缓存失败: $e');
      }

      // 删除书籍文件
      if (await book.file.exists()) {
        await book.file.delete();
      }

      // 删除封面缓存（book.coverFile 应该已经指向缓存目录中的封面文件）
      if (book.coverFile != null && await book.coverFile!.exists()) {
        await book.coverFile!.delete();
      }

      // 删除阅读进度缓存
      final bookKey = 'reading_position_${book.file.path.hashCode}';
      await SPUtil.remove(bookKey);

      // 删除书签缓存
      final bookmarksKey = 'bookmarks_${book.file.path.hashCode}';
      await SPUtil.remove(bookmarksKey);

      // 删除高亮缓存
      final highlightsKey = 'book_highlights_${book.file.path.hashCode}';
      await SPUtil.remove(highlightsKey);

      // 删除字体大小缓存
      final fontSizeKey = 'book_font_size_${book.file.path.hashCode}';
      await SPUtil.remove(fontSizeKey);

      // 从元数据缓存中移除
      try {
        final metadataMap = await _loadMetadataCache();
        if (metadataMap.containsKey(book.file.path)) {
          metadataMap.remove(book.file.path);
          await _saveMetadataCache(metadataMap);
        }
      } catch (e) {
        print('[BookLibrary] 删除元数据缓存失败: $e');
      }

      // 检查并清理 last_read_book（如果删除的是最后阅读的书籍）
      final lastReadBook = SPUtil.get<String>('last_read_book', '');
      if (lastReadBook == book.file.path) {
        await SPUtil.remove('last_read_book');
      }

      // 刷新书籍列表
      await _loadBooks();

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('《${book.title}》已删除')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书籍库'),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file),
            onPressed: _importBook,
            tooltip: '导入书籍',
          ),
        ],
      ),
      body: _books.isEmpty
          ? _buildEmptyState()
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 0.7,
              ),
              itemCount: _books.length,
              itemBuilder: (context, index) {
                return _BookCard(
                  book: _books[index],
                  onTap: () => _openBook(_books[index]),
                  onDelete: () => _deleteBook(_books[index]),
                  onRename: (newTitle) => _renameBook(_books[index], newTitle),
                );
              },
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.library_books, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          const Text(
            '暂无书籍',
            style: TextStyle(fontSize: 16, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _importBook,
            icon: const Icon(Icons.upload_file),
            label: const Text('导入书籍'),
          ),
        ],
      ),
    );
  }

  /// 检查并清理无效的元数据缓存（文件已被删除）
  Future<void> _cleanMetadataCache() async {
    try {
      final metadataMap = await _loadMetadataCache();
      if (metadataMap.isEmpty) return;

      final workingDir = SPUtil.get<String>('workingDirectory', '');
      if (workingDir.isEmpty) return;

      final booksDir = Directory('$workingDir/books');
      if (!await booksDir.exists()) return;

      final files = await booksDir.list().toList();
      final validFilePaths = files.whereType<File>().map((f) => f.path).toSet();

      bool hasInvalid = false;
      final invalidKeys = metadataMap.keys
          .where((filePath) => !validFilePaths.contains(filePath))
          .toList();

      for (final invalidKey in invalidKeys) {
        metadataMap.remove(invalidKey);
        hasInvalid = true;
      }

      if (hasInvalid) {
        await _saveMetadataCache(metadataMap);
        print('[BookLibrary] 清理了 ${invalidKeys.length} 条无效的元数据缓存');
      }
    } catch (e) {
      print('[BookLibrary] 清理元数据缓存失败: $e');
    }
  }

  void _openBook(BookInfo book) {
    // TODO: 实现打开书籍功能
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => BookReaderPage(bookPath: book.file.path),
      ),
    );
  }
}

/// 书籍信息模型
class BookInfo {
  File file;
  String title;
  final String author;
  File? coverFile;

  BookInfo({
    required this.file,
    required this.title,
    required this.author,
    this.coverFile,
  });

  static Future<BookInfo> fromFile(File file) async {
    final filename = file.uri.pathSegments.last;
    // 默认使用文件名作为标题
    String title = filename.replaceAll(
      RegExp(r'\.(epub|mobi|azw3|kfx|pdf)$'),
      '',
    );
    String author = '未知作者';

    // 尝试使用 epub_plus 解析书籍元数据
    if (filename.toLowerCase().endsWith('.epub')) {
      try {
        final bytes = await file.readAsBytes();
        final epub = await EpubReader.readBook(bytes);
        print('[BookLibrary] 解析 EPUB 元数据成功: ${epub.title}, ${epub.author}');
        if (epub.title != null && epub.title!.isNotEmpty) {
          title = epub.title!;
        }
        if (epub.author != null && epub.author!.isNotEmpty) {
          author = epub.author!;
        }
      } catch (e) {
        print('[BookLibrary] 解析 EPUB 元数据失败: $e');
      }
    }

    // 尝试查找对应的封面图片
    final bookDir = file.parent;
    File? coverFile;
    final possibleCoverNames = [
      '${title}.jpg',
      '${title}.png',
      '${title}.jpeg',
      '${title}.webp',
      'cover.jpg',
      'cover.png',
    ];

    for (var coverName in possibleCoverNames) {
      final coverFileCandidate = File('${bookDir.path}/$coverName');
      if (await coverFileCandidate.exists()) {
        coverFile = coverFileCandidate;
        break;
      }
    }

    return BookInfo(
      file: file,
      title: title,
      author: author,
      coverFile: coverFile,
    );
  }
}

/// 书籍卡片组件
class _BookCard extends StatefulWidget {
  final BookInfo book;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final Function(String newTitle) onRename;

  const _BookCard({
    required this.book,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
  });

  @override
  State<_BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<_BookCard> {
  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: InkWell(
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面区域
            Expanded(
              flex: 4,
              child: Container(
                width: double.infinity,
                color: Colors.blue.withValues(alpha: 0.1),
                child: widget.book.coverFile != null
                    ? Image.file(
                        widget.book.coverFile!,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return _buildDefaultCover();
                        },
                      )
                    : _buildDefaultCover(),
              ),
            ),
            // 书籍信息
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Stack(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            widget.book.title,
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Flexible(
                          child: Text(
                            widget.book.author,
                            style: TextStyle(
                              fontSize: 9,
                              color: Theme.of(context).textTheme.bodyMedium?.color,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    // 右下角三个水平点菜单按钮
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Material(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          onTap: () => _showActionMenu(context),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            child: const Icon(
                              Icons.more_horiz,
                              color: Colors.white,
                              size: 16,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 显示操作菜单
  void _showActionMenu(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        titlePadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        title: Text(
          widget.book.title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _showRenameDialog(context);
            },
            icon: const Icon(Icons.edit, size: 18),
            label: const Text('重命名'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.blue,
            ),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              widget.onDelete();
            },
            icon: const Icon(Icons.delete, size: 18),
            label: const Text('删除'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultCover() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.menu_book,
            size: 24,
            color: Colors.blue.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 4),
          Text(
            _getFileIcon(),
            style: TextStyle(
              fontSize: 8,
              color: Colors.grey[600],
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  String _getFileIcon() {
    final ext = widget.book.file.path.split('.').last.toLowerCase();
    switch (ext) {
      case 'epub':
        return 'EPUB';
      case 'mobi':
        return 'MOBI';
      case 'azw3':
        return 'AZW3';
      case 'kfx':
        return 'KFX';
      case 'pdf':
        return 'PDF';
      default:
        return ext.toUpperCase();
    }
  }

  /// 显示重命名对话框
  void _showRenameDialog(BuildContext context) {
    final controller = TextEditingController(text: widget.book.title);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.edit, color: Colors.blue),
            SizedBox(width: 12),
            Text('修改书名', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '请输入新的书名：',
              style: TextStyle(fontSize: 14, color: Colors.black87),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '书名',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              style: const TextStyle(fontSize: 14),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final newTitle = controller.text.trim();
              Navigator.pop(context);
              if (newTitle.isNotEmpty) {
                widget.onRename(newTitle);
              }
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.blue),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
