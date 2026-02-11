import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
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
    final bookInfos = files
        .whereType<File>()
        .where((f) => f.path.endsWith('.epub') ||
                    f.path.endsWith('.mobi') ||
                    f.path.endsWith('.azw3') ||
                    f.path.endsWith('.kfx') ||
                    f.path.endsWith('.pdf'))
        .map((f) => BookInfo.fromFile(f))
        .toList();

    // 为 EPUB 文件提取封面（使用 Future.wait 并行处理）
    final epubBooks = bookInfos.where((b) => b.file.path.endsWith('.epub')).toList();
    final coverFutures = epubBooks.map((book) async {
      final coverFile = await _extractEpubCover(book.file);
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请先设置工作目录')),
          );
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('成功导入 $importedCount 本书籍')),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('选择的书籍已存在')),
          );
        }
      }
    } catch (e, stackTrace) {
      print('[BookLibrary] 导入失败: $e');
      print('[BookLibrary] 堆栈: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该名称的书籍已存在')),
          );
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
        final appDir = await getApplicationDocumentsDirectory();
        final cacheDir = Directory('${appDir.path}/book_cache');
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

      // 重命名封面文件（如果存在且是独立文件）
      if (oldCoverFile != null && await oldCoverFile.exists()) {
        final coverDir = oldCoverFile.parent.path;
        final coverExt = oldCoverFile.path.split('.').last;
        final newCoverFileName = '$safeNewTitle.$coverExt';
        final newCoverPath = '$coverDir${Platform.pathSeparator}$newCoverFileName';
        
        // 只有当旧封面文件名包含旧标题时才重命名
        if (oldCoverFile.path.contains(oldTitle)) {
          await oldCoverFile.rename(newCoverPath);
          setState(() {
            book.coverFile = File(newCoverPath);
          });
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已重命名为《$newTitle》')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('重命名失败: $e')),
        );
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
      // 删除书籍文件
      if (await book.file.exists()) {
        await book.file.delete();
      }

      // 删除封面缓存
      if (book.coverFile != null && await book.coverFile!.exists()) {
        await book.coverFile!.delete();
      }

      // 删除阅读进度缓存
      final bookKey = 'reading_position_${book.file.path.hashCode}';
      await SPUtil.remove(bookKey);

      // 检查并清理 last_read_book（如果删除的是最后阅读的书籍）
      final lastReadBook = SPUtil.get<String>('last_read_book', '');
      if (lastReadBook == book.file.path) {
        await SPUtil.remove('last_read_book');
      }

      // 删除页面缓存（使用缓存键直接删除，避免遍历所有文件）
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final cacheDir = Directory('${appDir.path}/book_cache');
        if (await cacheDir.exists()) {
          // 根据书籍路径生成缓存键（与阅读器页面逻辑一致）
          final cacheKey = book.file.path.hashCode.toString();
          final cacheFile = File('${cacheDir.path}/$cacheKey.json');
          if (await cacheFile.exists()) {
            await cacheFile.delete();
          }
        }
      } catch (e) {
        // 缓存删除失败不影响主流程
        print('[BookLibrary] 删除页面缓存失败: $e');
      }

      // 刷新书籍列表
      await _loadBooks();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('《${book.title}》已删除')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
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
      final archive = ZipDecoder().decodeBytes(bytes);

      // 查找封面图片
      Uint8List? coverData;

      // 首先尝试查找名称中包含 cover 或 front 的图片
      for (var file in archive) {
        final name = file.name.toLowerCase();
        if (name.endsWith('.jpg') || name.endsWith('.jpeg') ||
            name.endsWith('.png') || name.endsWith('.webp')) {
          if (name.contains('cover') || name.contains('front')) {
            final content = file.content as List<int>;
            coverData = Uint8List.fromList(content);
            break;
          }
        }
      }

      // 如果没找到，尝试第一张图片
      if (coverData == null) {
        for (var file in archive) {
          final name = file.name.toLowerCase();
          if (name.endsWith('.jpg') || name.endsWith('.jpeg') ||
              name.endsWith('.png') || name.endsWith('.webp')) {
            final content = file.content as List<int>;
            coverData = Uint8List.fromList(content);
            break;
          }
        }
      }

      if (coverData != null && coverData.isNotEmpty) {
        // 保存封面到缓存目录
        final cacheDir = Directory('${epubFile.parent.path}/.cache');
        if (!await cacheDir.exists()) {
          await cacheDir.create(recursive: true);
        }
        // 使用安全的文件名（去除特殊字符）
        final safeFileName = epubFile.uri.pathSegments.last
            .replaceAll(RegExp(r'[<>"/\\|?*]'), '_');
        final coverFile = File('${cacheDir.path}/$safeFileName.jpg');
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

  factory BookInfo.fromFile(File file) {
    final filename = file.uri.pathSegments.last;
    // 简单的文件名作为标题
    String title = filename.replaceAll(RegExp(r'\.(epub|mobi|azw3|kfx|pdf)$'), '');
    String author = '未知作者';
    File? coverFile;

    // 尝试查找对应的封面图片
    final bookDir = file.parent;
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
      if (coverFileCandidate.existsSync()) {
        coverFile = coverFileCandidate;
        break;
      }
    }

    // TODO: 解析书籍元数据获取真实标题、作者和封面

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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          onTap: widget.onTap,
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
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        widget.book.title,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.book.author,
                        style: TextStyle(
                          fontSize: 8,
                          color: Colors.grey[600],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
            style: FilledButton.styleFrom(
              backgroundColor: Colors.blue,
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
