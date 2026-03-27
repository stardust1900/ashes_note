import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:ashes_note/services/book_reader/book_reader_services.dart';
import 'package:ashes_note/utils/const.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:ashes_note/views/book_reader/storage_manager.dart';
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

  Map<String, dynamic> toJson() => {
    'filePath': filePath,
    'title': title,
    'author': author,
    'coverPath': coverPath,
  };

  factory BookMetadata.fromJson(Map<String, dynamic> json) => BookMetadata(
    filePath: (json['filePath'] as String).replaceAll('\\', '/'),
    title: json['title'] as String,
    author: json['author'] as String,
    coverPath: json['coverPath'] as String?,
  );
}

/// 书籍信息模型
class BookInfo {
  File file;
  String title;
  final String author;
  File? coverFile;
  double readingProgress;
  DateTime? importedAt; // 导入时间（文件修改时间）

  BookInfo({
    required this.file,
    required this.title,
    required this.author,
    this.coverFile,
    this.readingProgress = -1,
    this.importedAt,
  });
}

/// 书籍库页面
class BookLibraryPage extends StatefulWidget {
  const BookLibraryPage({super.key});

  @override
  State<BookLibraryPage> createState() => _BookLibraryPageState();
}

class _BookLibraryPageState extends State<BookLibraryPage> {
  List<BookInfo> _books = [];
  String _viewMode = 'grid'; // grid / list
  String _gridSize = 'medium'; // small / medium / large
  String _sortMode = 'name'; // name / imported

  @override
  void initState() {
    super.initState();
    _viewMode = SPUtil.get<String>(PrefKeys.bookViewMode, 'grid');
    _gridSize = SPUtil.get<String>(PrefKeys.bookGridSize, 'medium');
    _sortMode = SPUtil.get<String>(PrefKeys.bookSortMode, 'name');
    _loadBooks();
    _cleanMetadataCache();
  }

  Future<File> _getMetadataCacheFile() async {
    final workingDir = SPUtil.get<String>('workingDirectory', '');
    final cacheDir = Directory('$workingDir/books/.cache');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    return File('${cacheDir.path}/books_metadata.json');
  }

  Future<Map<String, BookMetadata>> _loadMetadataCache() async {
    try {
      final cacheFile = await _getMetadataCacheFile();
      if (!await cacheFile.exists()) return {};
      final jsonData =
          jsonDecode(await cacheFile.readAsString()) as List<dynamic>;
      final map = <String, BookMetadata>{};
      for (final item in jsonData) {
        final m = BookMetadata.fromJson(item as Map<String, dynamic>);
        map[m.filePath] = m;
      }
      return map;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveMetadataCache(Map<String, BookMetadata> map) async {
    try {
      final cacheFile = await _getMetadataCacheFile();
      await cacheFile.writeAsString(
        jsonEncode(map.values.map((m) => m.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('保存元数据缓存失败：$e');
    }
  }

  Future<BookMetadata> _parseBookMetadata(File file) async {
    final metadataMap = await _loadMetadataCache();
    final normalizedPath = file.path.replaceAll('\\', '/');
    if (metadataMap.containsKey(normalizedPath))
      return metadataMap[normalizedPath]!;

    final filename = file.uri.pathSegments.last;
    String title = filename.replaceAll(RegExp(r'\.epub$'), '');
    String author = '未知作者';
    File? coverFile;

    if (filename.toLowerCase().endsWith('.epub')) {
      try {
        final bytes = await file.readAsBytes();
        final epub = await EpubReader.readBook(bytes);
        if (epub.title != null && epub.title!.isNotEmpty) title = epub.title!;
        if (epub.author != null && epub.author!.isNotEmpty)
          author = epub.author!;
        if (epub.coverImage != null) {
          final workingDir = SPUtil.get<String>('workingDirectory', '');
          final cacheDir = Directory('$workingDir/books/.cache');
          if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
          final coverPath =
              '${cacheDir.path}/cover_${normalizedPath.hashCode}.jpg';
          try {
            await File(
              coverPath,
            ).writeAsBytes(Uint8List.fromList(img.encodeJpg(epub.coverImage!)));
            coverFile = File(coverPath);
          } catch (e) {
            debugPrint('封面提取失败（忽略）：$e');
          }
        }
      } catch (e) {
        // epub 解析失败时降级：用文件名，不抛出异常
        debugPrint('EPUB 元数据解析失败，使用文件名：$e');
      }
    } else {
      throw Exception('不支持的文件格式，仅支持 EPUB 格式');
    }

    final metadata = BookMetadata(
      filePath: normalizedPath,
      title: title,
      author: author,
      coverPath: coverFile?.path.replaceAll('\\', '/'),
    );
    metadataMap[normalizedPath] = metadata;
    await _saveMetadataCache(metadataMap);
    return metadata;
  }

  Future<void> _loadBooks() async {
    final workingDir = SPUtil.get<String>('workingDirectory', '');
    if (workingDir.isEmpty) return;
    final booksDir = Directory('$workingDir/books');
    if (!await booksDir.exists()) await booksDir.create(recursive: true);

    final files = (await booksDir.list().toList())
        .whereType<File>()
        .where((f) => f.path.endsWith('.epub'))
        .toList();

    if (files.isEmpty) {
      setState(() => _books = []);
      return;
    }

    final metadataMap = await _loadMetadataCache();
    final List<BookInfo> bookInfos = [];

    for (final file in files) {
      final normalizedPath = file.path.replaceAll('\\', '/');
      final progress = await _getReadingProgress(file);
      final stat = await file.stat();
      BookMetadata metadata;
      if (metadataMap.containsKey(normalizedPath)) {
        metadata = metadataMap[normalizedPath]!;
      } else {
        metadata = await _parseBookMetadata(file);
      }
      bookInfos.add(
        BookInfo(
          file: file,
          title: metadata.title,
          author: metadata.author,
          coverFile: metadata.coverPath != null
              ? File(metadata.coverPath!)
              : null,
          readingProgress: progress,
          importedAt: stat.modified,
        ),
      );
    }
    setState(() => _books = bookInfos);
  }

  Future<double> _getReadingProgress(File file) async {
    try {
      final position = await StorageManager.loadReadingPosition(file.path);
      if (position == null) return -1;
      final pageIndex = position['pageIndex'] as int? ?? 0;
      final totalPages = position['totalPages'] as int? ?? 0;
      if (pageIndex <= 0 || totalPages <= 0) return -1;
      return (pageIndex / totalPages).clamp(0.0, 1.0);
    } catch (_) {
      return -1;
    }
  }

  Future<void> _cleanMetadataCache() async {
    try {
      final metadataMap = await _loadMetadataCache();
      if (metadataMap.isEmpty) return;
      final workingDir = SPUtil.get<String>('workingDirectory', '');
      if (workingDir.isEmpty) return;
      final booksDir = Directory('$workingDir/books');
      if (!await booksDir.exists()) return;
      final validPaths = (await booksDir.list().toList())
          .whereType<File>()
          .where((f) => f.path.endsWith('.epub'))
          .map((f) => f.path.replaceAll('\\', '/'))
          .toSet();
      final invalid = metadataMap.keys
          .where((k) => !validPaths.contains(k))
          .toList();
      if (invalid.isNotEmpty) {
        for (final k in invalid) metadataMap.remove(k);
        await _saveMetadataCache(metadataMap);
      }
    } catch (e) {
      debugPrint('清理元数据缓存失败：$e');
    }
  }

  Future<void> _importBook() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['epub'],
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;
      final workingDir = SPUtil.get<String>('workingDirectory', '');
      if (workingDir.isEmpty) {
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请先设置工作目录')));
        return;
      }
      final booksDir = Directory('$workingDir/books');
      if (!await booksDir.exists()) await booksDir.create(recursive: true);

      int imported = 0;
      for (final f in result.files) {
        if (f.path == null) continue;
        final dest = File('${booksDir.path}/${f.name}');
        if (!await dest.exists()) {
          await File(f.path!).copy(dest.path);
          imported++;
          try {
            await _parseBookMetadata(dest);
          } catch (e) {
            debugPrint('元数据解析失败（不影响导入）：$e');
          }
        }
      }
      await _loadBooks();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(imported > 0 ? '成功导入 $imported 本书籍' : '选择的书籍已存在'),
          ),
        );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  Future<void> _renameBook(BookInfo book, String newTitle) async {
    if (newTitle.isEmpty || newTitle == book.title) return;
    try {
      final oldFile = book.file;
      final ext = oldFile.path.split('.').last;
      final safeTitle = newTitle.replaceAll(RegExp(r'[<>"/\\|?*]'), '_');
      final newFile = File(
        '${oldFile.parent.path}${Platform.pathSeparator}$safeTitle.$ext',
      );
      if (await newFile.exists()) {
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('该名称的书籍已存在')));
        return;
      }
      await oldFile.rename(newFile.path);
      setState(() {
        book.title = newTitle;
        book.file = newFile;
      });

      // 迁移阅读进度
      final oldKey = 'reading_position_${oldFile.path.hashCode}';
      final newKey = 'reading_position_${newFile.path.hashCode}';
      final pos = SPUtil.get<String>(oldKey, '');
      if (pos.isNotEmpty) {
        await SPUtil.set<String>(newKey, pos);
        await SPUtil.remove(oldKey);
      }
      if (SPUtil.get<String>('last_read_book', '') == oldFile.path) {
        await SPUtil.set<String>('last_read_book', newFile.path);
      }

      // 迁移缓存
      try {
        final workingDir = SPUtil.get<String>('workingDirectory', '');
        final cacheDir = Directory('$workingDir/books/.cache');
        if (await cacheDir.exists()) {
          final oldCache = File(
            '${cacheDir.path}/${oldFile.path.hashCode}.json',
          );
          final newCache = File(
            '${cacheDir.path}/${newFile.path.hashCode}.json',
          );
          if (await oldCache.exists()) await oldCache.rename(newCache.path);
        }
      } catch (_) {}

      try {
        await BookStorageService().migrateBookData(oldFile.path, newFile.path);
      } catch (_) {}

      // 更新元数据缓存
      final metadataMap = await _loadMetadataCache();
      final oldNorm = oldFile.path.replaceAll('\\', '/');
      final newNorm = newFile.path.replaceAll('\\', '/');
      if (metadataMap.containsKey(oldNorm)) {
        final m = metadataMap.remove(oldNorm)!;
        metadataMap[newNorm] = BookMetadata(
          filePath: newNorm,
          title: newTitle,
          author: m.author,
          coverPath: m.coverPath,
        );
        await _saveMetadataCache(metadataMap);
      }
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已重命名为《$newTitle》')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('重命名失败：$e')));
    }
  }

  Future<void> _deleteBook(BookInfo book) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除《${book.title}》吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      // 删除页面缓存
      try {
        String cacheKey;
        try {
          cacheKey = crypto.md5
              .convert(await book.file.readAsBytes())
              .toString();
        } catch (_) {
          cacheKey = book.file.path.hashCode.toString();
        }
        final workingDir = SPUtil.get<String>('workingDirectory', '');
        final cf = File('$workingDir/books/.cache/$cacheKey.json');
        if (await cf.exists()) await cf.delete();
      } catch (_) {}

      if (await book.file.exists()) await book.file.delete();
      if (book.coverFile != null && await book.coverFile!.exists())
        await book.coverFile!.delete();

      try {
        await BookStorageService().deleteBookData(book.file.path);
      } catch (_) {}
      try {
        await StorageManager.deleteBookData(book.file.path);
      } catch (_) {}

      final metadataMap = await _loadMetadataCache();
      final norm = book.file.path.replaceAll('\\', '/');
      if (metadataMap.containsKey(norm)) {
        metadataMap.remove(norm);
        if (metadataMap.isEmpty) {
          final cf = await _getMetadataCacheFile();
          if (await cf.exists()) await cf.delete();
        } else {
          await _saveMetadataCache(metadataMap);
        }
      }
      if (SPUtil.get<String>('last_read_book', '') == book.file.path)
        await SPUtil.remove('last_read_book');
      await _loadBooks();
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('《${book.title}》已删除')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败: $e')));
    }
  }

  void _openBook(BookInfo book) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookReaderPage(bookPath: book.file.path),
      ),
    ).then((_) => _loadBooks());
  }

  List<BookInfo> get _sortedBooks {
    final list = List<BookInfo>.from(_books);
    if (_sortMode == 'name') {
      list.sort((a, b) => a.title.compareTo(b.title));
    } else {
      // 按导入时间降序（最新在前）
      list.sort((a, b) {
        final ta = a.importedAt ?? DateTime(0);
        final tb = b.importedAt ?? DateTime(0);
        return tb.compareTo(ta);
      });
    }
    return list;
  }

  int get _crossAxisCount {
    switch (_gridSize) {
      case 'small':
        return 5;
      case 'large':
        return 2;
      default:
        return 3;
    }
  }

  @override
  Widget build(BuildContext context) {
    final books = _sortedBooks;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('书籍库'),
        actions: [
          // 排序
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            tooltip: '排序',
            initialValue: _sortMode,
            onSelected: (v) {
              setState(() => _sortMode = v);
              SPUtil.set(PrefKeys.bookSortMode, v);
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'name',
                child: Row(
                  children: [
                    Icon(
                      Icons.sort_by_alpha,
                      size: 18,
                      color: _sortMode == 'name' ? theme.primaryColor : null,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '按名称',
                      style: TextStyle(
                        color: _sortMode == 'name' ? theme.primaryColor : null,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'imported',
                child: Row(
                  children: [
                    Icon(
                      Icons.access_time,
                      size: 18,
                      color: _sortMode == 'imported'
                          ? theme.primaryColor
                          : null,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '按导入时间',
                      style: TextStyle(
                        color: _sortMode == 'imported'
                            ? theme.primaryColor
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // 图标大小（仅网格模式）
          if (_viewMode == 'grid')
            PopupMenuButton<String>(
              icon: const Icon(Icons.photo_size_select_large),
              tooltip: '图标大小',
              initialValue: _gridSize,
              onSelected: (v) {
                setState(() => _gridSize = v);
                SPUtil.set(PrefKeys.bookGridSize, v);
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'small',
                  child: Row(
                    children: [
                      Icon(
                        Icons.grid_view,
                        size: 14,
                        color: _gridSize == 'small' ? theme.primaryColor : null,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '小',
                        style: TextStyle(
                          color: _gridSize == 'small'
                              ? theme.primaryColor
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'medium',
                  child: Row(
                    children: [
                      Icon(
                        Icons.grid_view,
                        size: 18,
                        color: _gridSize == 'medium'
                            ? theme.primaryColor
                            : null,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '中',
                        style: TextStyle(
                          color: _gridSize == 'medium'
                              ? theme.primaryColor
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'large',
                  child: Row(
                    children: [
                      Icon(
                        Icons.grid_view,
                        size: 22,
                        color: _gridSize == 'large' ? theme.primaryColor : null,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '大',
                        style: TextStyle(
                          color: _gridSize == 'large'
                              ? theme.primaryColor
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          // 视图切换
          IconButton(
            icon: Icon(_viewMode == 'grid' ? Icons.view_list : Icons.grid_view),
            tooltip: _viewMode == 'grid' ? '列表视图' : '网格视图',
            onPressed: () {
              final next = _viewMode == 'grid' ? 'list' : 'grid';
              setState(() => _viewMode = next);
              SPUtil.set(PrefKeys.bookViewMode, next);
            },
          ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            onPressed: _importBook,
            tooltip: '导入 EPUB',
          ),
        ],
      ),
      body: books.isEmpty
          ? _buildEmptyState()
          : _viewMode == 'grid'
          ? GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _crossAxisCount,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 0.62,
              ),
              itemCount: books.length,
              itemBuilder: (_, i) => _BookCard(
                book: books[i],
                onTap: () => _openBook(books[i]),
                onDelete: () => _deleteBook(books[i]),
                onRename: (t) => _renameBook(books[i], t),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: books.length,
              itemBuilder: (_, i) => _BookListTile(
                book: books[i],
                onTap: () => _openBook(books[i]),
                onDelete: () => _deleteBook(books[i]),
                onRename: (t) => _renameBook(books[i], t),
              ),
            ),
    );
  }

  Widget _buildEmptyState() => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.library_books, size: 64, color: Colors.grey[400]),
        const SizedBox(height: 16),
        const Text('暂无书籍', style: TextStyle(fontSize: 16, color: Colors.grey)),
        const SizedBox(height: 8),
        Text(
          '仅支持导入 EPUB 格式',
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
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

/// 列表视图项
class _BookListTile extends StatelessWidget {
  final BookInfo book;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final Function(String) onRename;

  const _BookListTile({
    required this.book,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 56,
                  height: 80,
                  child: book.coverFile != null
                      ? Image.file(
                          book.coverFile!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _defaultCover(),
                        )
                      : _defaultCover(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      book.author,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (book.readingProgress >= 0) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: book.readingProgress,
                                minHeight: 4,
                                backgroundColor: theme.dividerColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${(book.readingProgress * 100).round()}%',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 18),
                onSelected: (v) {
                  if (v == 'rename') _showRenameDialog(context);
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'rename',
                    child: Row(
                      children: [
                        Icon(Icons.edit, size: 16),
                        SizedBox(width: 8),
                        Text('重命名'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete, size: 16, color: Colors.red),
                        SizedBox(width: 8),
                        Text('删除', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _defaultCover() => Container(
    color: Colors.blue.withValues(alpha: 0.1),
    child: const Center(child: Icon(Icons.menu_book, color: Colors.blue)),
  );

  void _showRenameDialog(BuildContext context) {
    final ctrl = TextEditingController(text: book.title);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改书名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '书名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final t = ctrl.text.trim();
              Navigator.pop(ctx);
              if (t.isNotEmpty) onRename(t);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}

/// 网格卡片组件
class _BookCard extends StatelessWidget {
  final BookInfo book;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final Function(String) onRename;

  const _BookCard({
    required this.book,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 4,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    color: Colors.blue.withValues(alpha: 0.1),
                    child: book.coverFile != null
                        ? Image.file(
                            book.coverFile!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _buildDefaultCover(),
                          )
                        : _buildDefaultCover(),
                  ),
                  if (book.readingProgress >= 0)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${(book.readingProgress * 100).round()}%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
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
                            book.title,
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
                            book.author,
                            style: TextStyle(
                              fontSize: 9,
                              color: Theme.of(
                                context,
                              ).textTheme.bodyMedium?.color,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
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

  Widget _buildDefaultCover() => Center(
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
          book.file.path.split('.').last.toUpperCase(),
          style: TextStyle(
            fontSize: 8,
            color: Colors.grey[600],
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    ),
  );

  void _showActionMenu(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(
          book.title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _showRenameDialog(context);
            },
            icon: const Icon(Icons.edit, size: 18),
            label: const Text('重命名'),
            style: TextButton.styleFrom(foregroundColor: Colors.blue),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              onDelete();
            },
            icon: const Icon(Icons.delete, size: 18),
            label: const Text('删除'),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(BuildContext context) {
    final ctrl = TextEditingController(text: book.title);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改书名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '书名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final t = ctrl.text.trim();
              Navigator.pop(ctx);
              if (t.isNotEmpty) onRename(t);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
