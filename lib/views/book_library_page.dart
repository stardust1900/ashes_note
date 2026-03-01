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

    // 异步创建 BookInfo 对象（使用 epub_plus 解析元数据）
    final List<Future<BookInfo>> bookInfoFutures = supportedFiles
        .map((f) => BookInfo.fromFile(f))
        .toList();
    final bookInfos = await Future.wait(bookInfoFutures, eagerError: true);

    // 为 EPUB 文件提取封面（使用 Future.wait 并行处理）
    final epubBooks = bookInfos
        .where((b) => b.file.path.endsWith('.epub'))
        .toList();
    final List<Future<void>> coverFutures = epubBooks.map((book) async {
      File? coverFile;
      final existingCoverFile = File(
        '${booksDir.path}/.cache/cover_${book.file.path.hashCode}.jpg',
      );
      //已经提取的不要重复提取
      if (await existingCoverFile.exists()) {
        coverFile = existingCoverFile;
      } else {
        coverFile = await _extractEpubCover(book.file);
      }
      if (coverFile != null) {
        book.coverFile = coverFile;
      }
    }).toList();
    await Future.wait(coverFutures, eagerError: false);

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

  Future<File?> _extractEpubCover(File epubFile) async {
    try {
      final bytes = await epubFile.readAsBytes();
      final epub = await EpubReader.readBook(bytes);

      if (epub.coverImage != null) {
        // 保存封面到缓存目录
        final cacheDir = Directory('${epubFile.parent.path}/.cache');
        if (!await cacheDir.exists()) {
          await cacheDir.create(recursive: true);
        }
        // 使用书籍文件路径的哈希值作为封面图片名，避免重名和特殊字符问题
        final coverFile = File(
          '${cacheDir.path}/cover_${epubFile.path.hashCode}.jpg',
        );
        final coverData = Uint8List.fromList(img.encodeJpg(epub.coverImage!));
        await coverFile.writeAsBytes(coverData);
        return coverFile;
      }
    } catch (e) {
      print('[BookLibrary] 提取 EPUB 封面失败: $e');
    }
    return null;
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
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Card(
        elevation: 2,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: InkWell(
          onTap: widget.onTap,
          onLongPress: () => _showActionMenu(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 封面区域
              Expanded(
                flex: 4,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(
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
                    // 编辑和删除按钮（悬停时显示）
                    if (_isHovered)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 编辑按钮
                            Material(
                              color: Colors.blue.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(16),
                              child: InkWell(
                                onTap: () => _showRenameDialog(context),
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  child: const Icon(
                                    Icons.edit,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            // 删除按钮
                            Material(
                              color: Colors.red.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(16),
                              child: InkWell(
                                onTap: widget.onDelete,
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  child: const Icon(
                                    Icons.delete,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              // 书籍信息
              Expanded(
                flex: 2,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
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
                            fontSize: 8,
                            color: Colors.grey[600],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 显示操作菜单（用于手机端长按）
  void _showActionMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                widget.book.title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.blue),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(context);
                _showRenameDialog(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('删除'),
              onTap: () {
                Navigator.pop(context);
                widget.onDelete();
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
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
