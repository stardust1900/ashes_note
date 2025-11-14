import 'package:flutter/material.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flyme Notebook',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: NotebookHomePage(),
    );
  }
}

// 笔记本数据模型
class Notebook {
  final String id;
  final String name;
  final List<Note> notes;
  final Color color;

  Notebook({
    required this.id,
    required this.name,
    required this.notes,
    this.color = Colors.blue,
  });
}

// 笔记数据模型
class Note {
  final String id;
  final String title;
  final String content;
  final DateTime createTime;

  Note({
    required this.id,
    required this.title,
    required this.content,
    required this.createTime,
  });
}

class NotebookHomePage extends StatefulWidget {
  @override
  _NotebookHomePageState createState() => _NotebookHomePageState();
}

class _NotebookHomePageState extends State<NotebookHomePage> {
  // 模拟数据
  List<Notebook> _notebooks = [
    Notebook(
      id: '1',
      name: '工作笔记',
      color: Colors.blue,
      notes: [
        Note(
          id: '1',
          title: '项目会议记录',
          content: '今天讨论了项目进度和下一步计划...',
          createTime: DateTime.now(),
        ),
        Note(
          id: '2',
          title: '技术方案',
          content: '关于新功能的技术实现方案...',
          createTime: DateTime.now().subtract(Duration(days: 1)),
        ),
      ],
    ),
    Notebook(
      id: '2',
      name: '学习笔记',
      color: Colors.green,
      notes: [
        Note(
          id: '3',
          title: 'Flutter学习',
          content: '今天学习了Flutter布局...',
          createTime: DateTime.now().subtract(Duration(days: 2)),
        ),
      ],
    ),
    Notebook(
      id: '3',
      name: '生活随笔',
      color: Colors.orange,
      notes: [
        Note(
          id: '4',
          title: '读书笔记',
          content: '《设计心理学》读后感...',
          createTime: DateTime.now().subtract(Duration(days: 3)),
        ),
      ],
    ),
    Notebook(
      id: '4',
      name: '旅行计划',
      color: Colors.purple,
      notes: [
        Note(
          id: '5',
          title: '日本行程',
          content: '东京-大阪-京都的旅行计划...',
          createTime: DateTime.now().subtract(Duration(days: 4)),
        ),
      ],
    ),
  ];

  Notebook? _selectedNotebook;
  bool _isNotebookListExpanded = false;
  final TextEditingController _notebookNameController = TextEditingController();
  final TextEditingController _noteTitleController = TextEditingController();
  final TextEditingController _noteContentController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 默认选择第一个笔记本
    if (_notebooks.isNotEmpty) {
      _selectedNotebook = _notebooks[0];
    }
  }

  // 删除笔记本
  void _deleteNotebook(String notebookId) {
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
                _notebooks.removeWhere((notebook) => notebook.id == notebookId);
                // 如果删除的是当前选中的笔记本，则选择第一个笔记本（如果存在）
                if (_selectedNotebook?.id == notebookId) {
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

    // 显示SnackBar提示
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('笔记已删除'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () {
            // 这里可以添加撤销删除的逻辑
          },
        ),
      ),
    );
  }

  // 带确认的删除笔记对话框
  void _showDeleteNoteDialog(String noteId, String noteTitle) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除笔记'),
        content: Text('确定要删除笔记"$noteTitle"吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () {
              _deleteNote(noteId);
              Navigator.pop(context);
            },
            child: Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Flyme Notebook'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
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
        child: Icon(Icons.add),
        backgroundColor: Colors.blue,
      ),
    );
  }

  // 构建笔记本选择器
  Widget _buildNotebookSelector() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2)),
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
                    color: Colors.grey[600],
                  ),
                  SizedBox(width: 8),
                  Text(
                    '笔记本',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[800],
                    ),
                  ),
                  Spacer(),
                  if (_selectedNotebook != null)
                    Text(
                      _selectedNotebook!.name,
                      style: TextStyle(fontSize: 14, color: Colors.grey[600]),
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
                key: Key(notebook.id),
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
                  _deleteNotebook(notebook.id);
                },
                child: ListTile(
                  leading: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: notebook.color.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Icon(Icons.folder, color: notebook.color, size: 16),
                  ),
                  title: Text(notebook.name),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${notebook.notes.length}',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                      SizedBox(width: 8),
                      _selectedNotebook?.id == notebook.id
                          ? Icon(Icons.check, color: Colors.blue, size: 20)
                          : SizedBox(),
                    ],
                  ),
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
          leading: Icon(Icons.create_new_folder, color: Colors.blue),
          title: Text('创建新笔记本', style: TextStyle(color: Colors.blue)),
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
            margin: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            elevation: 1,
            child: ListTile(
              title: Text(
                note.title,
                style: TextStyle(fontWeight: FontWeight.bold),
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
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '${note.createTime.year}-${note.createTime.month.toString().padLeft(2, '0')}-${note.createTime.day.toString().padLeft(2, '0')}',
                    style: TextStyle(fontSize: 10, color: Colors.grey[400]),
                  ),
                ],
              ),
              trailing: PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: Colors.grey[400]),
                onSelected: (value) {
                  if (value == 'delete') {
                    _showDeleteNoteDialog(note.id, note.title);
                  } else if (value == 'edit') {
                    _showEditNoteDialog(note);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('删除', style: TextStyle(color: Colors.red)),
                  ),
                ],
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => NoteDetailPage(
                      note: note,
                      onDelete: () {
                        _deleteNote(note.id);
                        Navigator.pop(context);
                      },
                    ),
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
                setState(() {
                  _notebooks.add(
                    Notebook(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
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
        title: Text('创建新笔记'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _noteTitleController,
                decoration: InputDecoration(
                  hintText: '笔记标题',
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 16),
              TextField(
                controller: _noteContentController,
                maxLines: 5,
                decoration: InputDecoration(
                  hintText: '笔记内容',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (_noteTitleController.text.isNotEmpty &&
                  _selectedNotebook != null) {
                setState(() {
                  final notebookIndex = _notebooks.indexWhere(
                    (n) => n.id == _selectedNotebook!.id,
                  );
                  if (notebookIndex != -1) {
                    _notebooks[notebookIndex].notes.add(
                      Note(
                        id: DateTime.now().millisecondsSinceEpoch.toString(),
                        title: _noteTitleController.text,
                        content: _noteContentController.text,
                        createTime: DateTime.now(),
                      ),
                    );
                  }
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

  // 显示编辑笔记对话框
  void _showEditNoteDialog(Note note) {
    _noteTitleController.text = note.title;
    _noteContentController.text = note.content;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('编辑笔记'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _noteTitleController,
                decoration: InputDecoration(
                  hintText: '笔记标题',
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 16),
              TextField(
                controller: _noteContentController,
                maxLines: 5,
                decoration: InputDecoration(
                  hintText: '笔记内容',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (_noteTitleController.text.isNotEmpty &&
                  _selectedNotebook != null) {
                setState(() {
                  final notebookIndex = _notebooks.indexWhere(
                    (n) => n.id == _selectedNotebook!.id,
                  );
                  if (notebookIndex != -1) {
                    final noteIndex = _notebooks[notebookIndex].notes
                        .indexWhere((n) => n.id == note.id);
                    if (noteIndex != -1) {
                      _notebooks[notebookIndex].notes[noteIndex] = Note(
                        id: note.id,
                        title: _noteTitleController.text,
                        content: _noteContentController.text,
                        createTime: note.createTime,
                      );
                    }
                  }
                });
                Navigator.pop(context);
              }
            },
            child: Text('保存'),
          ),
        ],
      ),
    );
  }
}

// 笔记详情页面
class NoteDetailPage extends StatelessWidget {
  final Note note;
  final VoidCallback? onDelete;

  const NoteDetailPage({Key? key, required this.note, this.onDelete})
    : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('笔记详情'),
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.delete, color: Colors.red),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('删除笔记'),
                  content: Text('确定要删除这个笔记吗？此操作不可撤销。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text('取消'),
                    ),
                    TextButton(
                      onPressed: () {
                        onDelete?.call();
                        Navigator.pop(context);
                      },
                      child: Text('删除', style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              note.title,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              '创建时间: ${note.createTime.toString().substring(0, 16)}',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            SizedBox(height: 24),
            Text(note.content, style: TextStyle(fontSize: 16, height: 1.6)),
          ],
        ),
      ),
    );
  }
}
