import 'dart:async';

import 'package:ashes_note/utils/file_util.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:flutter/material.dart';
import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

class NotebookHomePage extends StatefulWidget {
  @override
  _NotebookHomePageState createState() => _NotebookHomePageState();
}

class _NotebookHomePageState extends State<NotebookHomePage> {
  // 模拟数据
  final List<Notebook> _notebooks = [];
  late String workingDirectory;
  Notebook? _selectedNotebook;
  bool _isNotebookListExpanded = false;
  final TextEditingController _notebookNameController = TextEditingController();
  final TextEditingController _noteTitleController = TextEditingController();
  final TextEditingController _noteContentController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadNotebookList().then((_) {
      setState(() {
        if (_notebooks.isNotEmpty) {
          _selectedNotebook = _notebooks[0];
        }
      });
    });
    // 默认选择第一个笔记本
  }

  Future<void> _loadNotebookList() async {
    workingDirectory = SPUtil.get<String>('workingDirectory', '');
    if (workingDirectory.isEmpty) {
      print('工作目录未设置，无法加载笔记本列表');
      return;
    }
    final List<String> bookList = await FileUtil().listFiles(
      workingDirectory,
      '/',
      type: 'directory',
    );
    for (var book in bookList) {
      final List<Note> notes = await FileUtil().listNotes(
        workingDirectory,
        book,
      );
      print('notebookes: $book , notes: $notes');
      _notebooks.add(Notebook(name: book, notes: notes, color: Colors.blue));
    }
  }

  // 删除笔记本
  void _deleteNotebook(String notebookName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除笔记本'),
        content: Text('确定要删除这个笔记本吗？笔记本中的所有笔记也将被删除。此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _notebooks.removeWhere(
                  (notebook) => notebook.name == notebookName,
                );
                // 如果删除的是当前选中的笔记本，则选择第一个笔记本（如果存在）
                if (_selectedNotebook?.name == notebookName) {
                  _selectedNotebook = _notebooks.isNotEmpty
                      ? _notebooks[0]
                      : null;
                }
                _isNotebookListExpanded = false;
              });
              Navigator.pop(context);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('笔记本已删除')));

              FileUtil().deleteDirectory(workingDirectory, notebookName);
            },
            child: Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // 删除笔记
  void _deleteNote(String noteId) {
    if (_selectedNotebook == null) return;

    setState(() {
      _selectedNotebook!.notes.removeWhere((note) => note.id == noteId);
    });
    // TODO : 将笔记移动到垃圾箱，而不是直接删除
    FileUtil().deleteFile(
      workingDirectory,
      noteId.substring(0, noteId.lastIndexOf('/')),
      noteId.substring(noteId.lastIndexOf('/') + 1),
    );
    // 显示SnackBar提示
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('笔记已删除'),
        //action: SnackBarAction(
        //label: '撤销',
        // onPressed: () {
        // 这里可以添加撤销删除的逻辑
        //},
        // ),
      ),
    );
  }

  void noteChanged(Note updatedNote, {String? newTitle}) {
    setState(() {
      if (newTitle != null && newTitle != updatedNote.title) {
        //判断同名笔记本是否存在
        final exists = _selectedNotebook!.notes.any(
          (note) => note.title == newTitle || note.title == '$newTitle.md',
        );
        if (exists) {
          // 提示用户笔记已存在
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('笔记已存在，请使用不同的标题')));
          return;
        }

        // 保存旧 id 和生成新文件名
        final oldTitle = updatedNote.title.endsWith('.md')
            ? updatedNote.title
            : '${updatedNote.title}.md';

        final newFileName = newTitle.endsWith('.md')
            ? newTitle
            : '$newTitle.md';

        updatedNote.title = newTitle;
        // FileUtil 中可能没有 renameFile 方法，改为先保存新文件再删除旧文件以模拟重命名
        FileUtil()
            .saveFile(
              workingDirectory,
              _selectedNotebook!.name,
              newFileName,
              updatedNote.content,
            )
            .then((_) {
              // 删除旧文件（oldId 可能是完整路径，也可能是文件名，依实现而定）
              FileUtil().deleteFile(
                workingDirectory,
                _selectedNotebook!.name,
                oldTitle,
              );
            });

        // 更新 note 的 id 为新的路径或文件标识（根据项目中 id 的格式进行调整）
        updatedNote.id = '${_selectedNotebook!.name}/$newFileName';
      }
      final index = _selectedNotebook!.notes.indexWhere(
        (note) => note.id == updatedNote.id,
      );
      if (index != -1) {
        _selectedNotebook!.notes[index] = updatedNote;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('草灰笔记', style: Theme.of(context).textTheme.headlineMedium),
        backgroundColor: Theme.of(context).canvasColor,
        foregroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: Column(
        children: [
          // 笔记本选择区域
          _buildNotebookSelector(),
          // 笔记列表区域
          Expanded(child: _buildNoteList()),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateNoteDialog,
        backgroundColor: Colors.blue,
        child: Icon(Icons.add),
      ),
    );
  }

  // 构建笔记本选择器
  Widget _buildNotebookSelector() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).canvasColor,
        boxShadow: [
          BoxShadow(color: Colors.white, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        children: [
          // 笔记本标题栏
          GestureDetector(
            onTap: () {
              setState(() {
                _isNotebookListExpanded = !_isNotebookListExpanded;
              });
            },
            child: Container(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    _isNotebookListExpanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: Theme.of(context).primaryColor,
                  ),
                  SizedBox(width: 8),
                  Text(
                    '笔记本',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  Spacer(),
                  if (_selectedNotebook != null)
                    Text(
                      _selectedNotebook!.name,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                ],
              ),
            ),
          ),
          // 可展开的笔记本列表
          if (_isNotebookListExpanded)
            Container(
              constraints: BoxConstraints(maxHeight: 200),
              child: _buildNotebookList(),
            ),
        ],
      ),
    );
  }

  // 构建笔记本列表
  Widget _buildNotebookList() {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.only(bottom: 8),
            itemCount: _notebooks.length,
            itemBuilder: (context, index) {
              final notebook = _notebooks[index];
              return Dismissible(
                key: Key(notebook.name),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Colors.red,
                  alignment: Alignment.centerRight,
                  padding: EdgeInsets.only(right: 20),
                  child: Icon(Icons.delete, color: Colors.white),
                ),
                confirmDismiss: (direction) async {
                  return await showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text('删除笔记本'),
                      content: Text('确定要删除笔记本"${notebook.name}"吗？'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: Text('取消'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: Text(
                            '删除',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  );
                },
                onDismissed: (direction) {
                  _deleteNotebook(notebook.name);
                },
                child: ListTile(
                  leading: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      // color: Theme.of(context).primaryColorDark,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Icon(
                      Icons.folder,
                      color: Theme.of(context).primaryColor,
                      size: 18,
                    ),
                  ),
                  title: Text(
                    notebook.name,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  trailing: _selectedNotebook?.name == notebook.name
                      ? Icon(
                          Icons.check,
                          color: Theme.of(context).primaryColor,
                          size: 20,
                        )
                      : null,
                  onTap: () {
                    setState(() {
                      _selectedNotebook = notebook;
                      _isNotebookListExpanded = false;
                    });
                  },
                ),
              );
            },
          ),
        ),
        // 创建笔记本按钮
        Divider(height: 1),
        ListTile(
          leading: Icon(
            Icons.create_new_folder,
            color: Theme.of(context).primaryColor,
          ),
          title: Text(
            '创建新笔记本',
            style: TextStyle(color: Theme.of(context).primaryColor),
          ),
          onTap: _showCreateNotebookDialog,
        ),
      ],
    );
  }

  // 构建笔记列表
  Widget _buildNoteList() {
    final notes = _selectedNotebook?.notes ?? [];

    if (notes.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.note_add, size: 64, color: Colors.grey[300]),
            SizedBox(height: 16),
            Text(
              '暂无笔记',
              style: TextStyle(fontSize: 16, color: Colors.grey[500]),
            ),
            SizedBox(height: 8),
            Text(
              '点击右下角按钮创建新笔记',
              style: TextStyle(fontSize: 14, color: Colors.grey[400]),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: notes.length,
      itemBuilder: (context, index) {
        final note = notes[index];
        return Dismissible(
          key: Key(note.id),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Colors.red,
            alignment: Alignment.centerRight,
            padding: EdgeInsets.only(right: 20),
            child: Icon(Icons.delete, color: Colors.white),
          ),
          confirmDismiss: (direction) async {
            return await showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: Text('删除笔记'),
                content: Text('确定要删除笔记"${note.title}"吗？'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text('删除', style: TextStyle(color: Colors.red)),
                  ),
                ],
              ),
            );
          },
          onDismissed: (direction) {
            _deleteNote(note.id);
          },
          child: Card(
            color: Theme.of(context).canvasColor,
            margin: EdgeInsets.symmetric(horizontal: 0, vertical: 2),
            elevation: 1,
            child: ListTile(
              title: Text(
                note.title,
                style: Theme.of(context).textTheme.headlineSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(height: 4),
                  Text(
                    note.content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '${note.lastModified.year}-${note.lastModified.month.toString().padLeft(2, '0')}-${note.lastModified.day.toString().padLeft(2, '0')}',
                    style: TextStyle(fontSize: 10, color: Colors.grey[400]),
                  ),
                ],
              ),
              trailing: Icon(Icons.chevron_right, color: Colors.grey[400]),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        NoteDetailPage(note: note, onNoteChanged: noteChanged),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  // 显示创建笔记本对话框
  void _showCreateNotebookDialog() {
    _notebookNameController.clear();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('创建新笔记本'),
        content: TextField(
          controller: _notebookNameController,
          style: Theme.of(context).textTheme.bodyMedium,
          decoration: InputDecoration(
            hintText: '输入笔记本名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (_notebookNameController.text.isNotEmpty) {
                FileUtil().createDirectory(
                  workingDirectory,
                  _notebookNameController.text,
                );
                setState(() {
                  _notebooks.add(
                    Notebook(
                      name: _notebookNameController.text,
                      notes: [],
                      color:
                          Colors.primaries[_notebooks.length %
                              Colors.primaries.length],
                    ),
                  );
                });
                Navigator.pop(context);
              }
            },
            child: Text('创建'),
          ),
        ],
      ),
    );
  }

  // 显示创建笔记对话框
  void _showCreateNoteDialog() {
    _noteTitleController.clear();
    _noteContentController.clear();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).canvasColor,
        title: Text('创建新笔记'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _noteTitleController,
                style: Theme.of(context).textTheme.bodyMedium,
                decoration: InputDecoration(
                  hintText: '笔记标题',
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 16),
            ],
          ),
        ),
        actions: [
          TextButton(
            style: Theme.of(context).textButtonTheme.style,
            onPressed: () => Navigator.pop(context),
            child: Text('取消'),
          ),
          TextButton(
            style: Theme.of(context).textButtonTheme.style,
            onPressed: () {
              print(_noteTitleController.text);
              if (_noteTitleController.text.isNotEmpty &&
                  _selectedNotebook != null) {
                //判断同名笔记本是否存在
                final exists = _selectedNotebook!.notes.any(
                  (note) =>
                      note.title == _noteTitleController.text ||
                      note.title == '${_noteTitleController.text}.md',
                );
                if (exists) {
                  // 提示用户笔记已存在
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('笔记已存在，请使用不同的标题')));
                  return;
                }

                FileUtil()
                    .saveFile(
                      workingDirectory,
                      _selectedNotebook!.name,
                      _noteTitleController.text.endsWith('.md')
                          ? _noteTitleController.text
                          : '${_noteTitleController.text}.md',
                      '',
                    )
                    .then((value) {
                      print('note saved: $value');
                      FileUtil()
                          .listNotes(workingDirectory, _selectedNotebook!.name)
                          .then((notes) {
                            print(
                              '${_selectedNotebook!.name} notes loaded: $notes',
                            );
                            setState(() {
                              final notebookIndex = _notebooks.indexWhere(
                                (n) => n.name == _selectedNotebook!.name,
                              );
                              _notebooks[notebookIndex].notes.clear();
                              _notebooks[notebookIndex].notes.addAll(notes);
                            });
                          });
                    });
                Navigator.pop(context);
              }
            },
            child: Text('创建'),
          ),
        ],
      ),
    );
  }
}

// 笔记详情页面
class NoteDetailPage extends StatefulWidget {
  final Note note;
  final Function(Note, {String? newTitle}) onNoteChanged;
  const NoteDetailPage({
    super.key,
    required this.note,
    required this.onNoteChanged,
  });
  @override
  State<StatefulWidget> createState() => NoteDetailState();
}

class NoteDetailState extends State<NoteDetailPage> {
  late Note note = widget.note;

  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _textController = TextEditingController();

  bool _isEditing = true; // 切换编辑/预览模式
  @override
  void initState() {
    super.initState();
    // 2. 在初始化时为控制器设置文本，这将成为默认值
    _titleController.text = note.title.endsWith('.md')
        ? note.title.substring(0, note.title.length - 3)
        : note.title;
    _textController.text = note.content;

    // 3. 监听文本变化 定时保存文本
    _textController.addListener(() {
      //刷新父页面，更新笔记列表中note内容
      note.content = _textController.text;
      // widget.onNoteChanged(note);
      widget.onNoteChanged(note);
      // 延迟保存，避免频繁写文件
      Timer(const Duration(seconds: 1), () {
        FileUtil().saveFile(
          SPUtil.get<String>('workingDirectory', ''),
          note.id.substring(0, note.id.lastIndexOf('/')),
          note.title,
          note.content,
        );
      });
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              onEditingComplete: () {
                print('new title: ${_titleController.text}');
                widget.onNoteChanged(note, newTitle: _titleController.text);
              },
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                border: InputBorder.none,
                focusedBorder: InputBorder.none,
                enabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                isDense: true, // 减少内部边距
                contentPadding: EdgeInsets.zero, // 去除内边距
              ),
            ),
            SizedBox(height: 2), // 添加小间距
            Text(
              note.lastModified.toString().substring(0, 16),
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: 0.0),
            child: IconButton(
              icon: Icon(
                Icons.edit,
                size: 16,
                color: _isEditing ? Colors.blue : Colors.grey,
              ),
              onPressed: () {
                setState(() {
                  _isEditing = true;
                });
              },
              tooltip: '编辑',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(right: 32.0),
            child: IconButton(
              icon: Icon(
                Icons.preview,
                size: 16,
                color: !_isEditing ? Colors.blue : Colors.grey,
              ),
              onPressed: () {
                setState(() {
                  _isEditing = false;
                });
              },
              tooltip: '预览',
            ),
          ),
        ],
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 代码编辑器区域
            _isEditing ? _buildEditor() : _buildPreview(),
          ],
        ),
      ),
    );
  }

  Widget _buildEditor() {
    return Container(
      padding: EdgeInsets.only(left: 16, top: 8, right: 16, bottom: 8),
      child: TextField(
        controller: _textController,
        maxLines: null, // 允许多行
        // expands: true, // 填充可用空间
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: '开始输入内容...',
          hintStyle: TextStyle(color: Colors.white30),
        ),
        style: TextStyle(
          // fontFamily: 'Monospace',
          fontSize: 14,
          color: Colors.white,
        ),
        onChanged: (text) {
          // 实时更新文件内容
          setState(() {
            note.content = text;
          });
        },
      ),
    );
  }

  Widget _buildPreview() {
    return SelectionArea(
      child: Container(
        padding: EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Markdown(
            data: note.content,
            selectable: false,
            styleSheet: MarkdownStyleSheet(
              p: TextStyle(fontSize: 14, color: Colors.white70),
              h1: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              h2: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              h3: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              code: TextStyle(
                backgroundColor: Colors.grey[800],
                color: Colors.orange,
                fontFamily: 'Monospace',
              ),
              codeblockPadding: EdgeInsets.all(8),
              codeblockDecoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            shrinkWrap: true,
          ),
        ),
      ),
    );
  }
}
