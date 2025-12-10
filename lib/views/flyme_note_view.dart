import 'dart:async';
import 'dart:convert';
import 'package:ashes_note/utils/file_util.dart';
import 'package:ashes_note/utils/git_service.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:flutter/material.dart';
import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

class NotebookHomePage extends StatefulWidget {
  const NotebookHomePage({super.key});

  @override
  NotebookHomePageState createState() => NotebookHomePageState();
}

class NotebookHomePageState extends State<NotebookHomePage> {
  final List<Notebook> _notebooks = [];
  late String workingDirectory;
  Notebook? _selectedNotebook;
  bool _isNotebookListExpanded = false;
  final TextEditingController _notebookNameController = TextEditingController();
  final TextEditingController _noteTitleController = TextEditingController();
  final TextEditingController _noteContentController = TextEditingController();

  // 搜索相关变量
  final TextEditingController _searchController = TextEditingController();
  bool _isGlobalSearch = false;
  bool _showSearchResults = false;
  final List<GlobalSearchResult> _searchResults = [];
  String _currentSearchQuery = '';

  GitService? git;
  String? remoteUrl;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    print('NotebookHomePageState initState');
    workingDirectory = SPUtil.get<String>('workingDirectory', '');
    String gitPlatform = SPUtil.get<String>('gitPlatform', '');

    if (gitPlatform.isNotEmpty) {
      if (gitPlatform == 'gitee') {
        String token = SPUtil.get<String>('giteeToken', '');
        remoteUrl = SPUtil.get<String>('giteeRemoteUrl', '');
        git = GitFactory.getGitService(gitPlatform, token);
      }

      String lastPullTime = SPUtil.get('lastPullTime', '');
      if (lastPullTime == '' ||
          DateTime.now().difference(DateTime.parse(lastPullTime)).inHours >=
              1) {
        var (owner, repo) = git!.getOwnerRepoFromUrl(remoteUrl!);
        git!.pull(owner, repo, workingDirectory);
        SPUtil.set("lastPullTime", DateTime.now().toIso8601String());
      }
    }

    _loadNotebookList().then((_) {
      setState(() {
        if (_notebooks.isNotEmpty) {
          String selectedNotebookName = SPUtil.get<String>(
            'selectedNotebook',
            '',
          );
          if (selectedNotebookName.isNotEmpty) {
            _selectedNotebook = _notebooks.firstWhere(
              (notebook) => notebook.name == selectedNotebookName,
              orElse: () => _notebooks[0],
            );
          } else {
            _selectedNotebook = _notebooks[0];
          }
        }
      });
    });

    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _notebookNameController.dispose();
    _noteTitleController.dispose();
    _noteContentController.dispose();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim();
    if (query != _currentSearchQuery) {
      setState(() {
        _currentSearchQuery = query;
        _showSearchResults = query.isNotEmpty;
        if (_showSearchResults) {
          _performSearch(query);
        }
      });
    }
  }

  void _performSearch(String query) {
    _searchResults.clear();

    for (final notebook in _notebooks) {
      for (final note in notebook.notes) {
        final titleMatch = note.title.toLowerCase().contains(
          query.toLowerCase(),
        );
        final contentMatch = note.content.toLowerCase().contains(
          query.toLowerCase(),
        );

        if (titleMatch || contentMatch) {
          _searchResults.add(
            GlobalSearchResult(
              note: note,
              notebookName: notebook.name,
              matchType: titleMatch ? '标题' : '内容',
            ),
          );
        }
      }
    }
  }

  Future<void> _loadNotebookList() async {
    if (workingDirectory.isEmpty) {
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
    FileUtil().deleteFile(
      workingDirectory,
      noteId.substring(0, noteId.lastIndexOf('/')),
      noteId.substring(noteId.lastIndexOf('/') + 1),
    );
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('笔记已删除')));
  }

  void noteChanged(Note updatedNote, {String? newTitle}) {
    setState(() {
      if (newTitle != null && newTitle != updatedNote.title) {
        final exists = _selectedNotebook!.notes.any(
          (note) => note.title == newTitle || note.title == '$newTitle.md',
        );
        if (exists) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('笔记已存在，请使用不同的标题')));
          return;
        }

        final oldTitle = updatedNote.title.endsWith('.md')
            ? updatedNote.title
            : '${updatedNote.title}.md';
        final newFileName = newTitle.endsWith('.md')
            ? newTitle
            : '$newTitle.md';

        updatedNote.title = newTitle;
        FileUtil()
            .saveFile(
              workingDirectory,
              _selectedNotebook!.name,
              newFileName,
              utf8.encode(updatedNote.content),
            )
            .then((_) {
              FileUtil().deleteFile(
                workingDirectory,
                _selectedNotebook!.name,
                oldTitle,
              );
            });

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

  void saveNote(Note note) {
    if (git == null || remoteUrl == null) return;
    var (owner, repo) = git!.getOwnerRepoFromUrl(remoteUrl!);
    String path = note.id;
    git?.uploadFile(
      owner,
      repo,
      path,
      utf8.encode(note.content),
      'Update note ${note.title}',
    );
  }

  void _onSearchResultTap(GlobalSearchResult result) {
    // 找到对应的笔记本
    final targetNotebook = _notebooks.firstWhere(
      (notebook) => notebook.name == result.notebookName,
      orElse: () => _selectedNotebook!,
    );

    setState(() {
      _selectedNotebook = targetNotebook;
      _showSearchResults = false;
      _searchController.clear();
    });

    // 跳转到笔记详情页
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => NoteDetailPage(
          note: result.note,
          onNoteChanged: noteChanged,
          saveNote: saveNote,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('草灰笔记', style: Theme.of(context).textTheme.headlineMedium),
        backgroundColor: Theme.of(context).canvasColor,
        foregroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
        actions: [
          // 搜索框
          SizedBox(
            width: 200,
            height: 40,
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    _isGlobalSearch ? Icons.search : Icons.folder,
                    color: _isGlobalSearch ? Colors.blue : Colors.white54,
                    size: 20,
                  ),
                  onPressed: () {
                    setState(() {
                      _isGlobalSearch = !_isGlobalSearch;
                    });
                  },
                  tooltip: _isGlobalSearch ? '全局搜索' : '当前笔记本搜索',
                ),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: _isGlobalSearch ? '搜索所有笔记本...' : '搜索当前笔记本...',
                      hintStyle: TextStyle(color: Colors.white54),
                      border: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white),
                      ),
                      contentPadding: EdgeInsets.symmetric(horizontal: 8),
                      isDense: true,
                    ),
                  ),
                ),
                if (_currentSearchQuery.isNotEmpty)
                  IconButton(
                    icon: Icon(Icons.clear, size: 16, color: Colors.white54),
                    onPressed: () {
                      _searchController.clear();
                    },
                  ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.sync),
            color: _isSyncing ? Colors.grey : Colors.blue,
            onPressed: () {
              if (git == null || remoteUrl == null) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('Git 服务未配置，无法同步')));
                return;
              }
              var (owner, repo) = git!.getOwnerRepoFromUrl(remoteUrl!);
              if (_isSyncing) return;

              setState(() {
                _isSyncing = true;
              });
              git!
                  .push(
                    owner,
                    repo,
                    workingDirectory,
                    deleteRemoteMissing: true,
                  )
                  .then((_) {
                    setState(() {
                      _isSyncing = false;
                    });
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('仓库同步完成')));
                  })
                  .catchError((error) {
                    setState(() {
                      _isSyncing = false;
                    });
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('仓库同步失败: $error')));
                  });
            },
          ),
        ],
      ),
      body: _showSearchResults ? _buildSearchResults() : _buildNormalView(),
      floatingActionButton: _showSearchResults
          ? null
          : FloatingActionButton(
              onPressed: _showCreateNoteDialog,
              backgroundColor: Colors.blue,
              child: Icon(Icons.add),
            ),
    );
  }

  Widget _buildNormalView() {
    return Column(
      children: [
        _buildNotebookSelector(),
        Expanded(child: _buildNoteList()),
      ],
    );
  }

  Widget _buildSearchResults() {
    return Column(
      children: [
        // 搜索头部信息
        Container(
          padding: EdgeInsets.all(16),
          color: Colors.grey[100],
          child: Row(
            children: [
              Icon(Icons.search, color: Colors.grey[600]),
              SizedBox(width: 8),
              Text(
                '搜索 "${_currentSearchQuery}"',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              Spacer(),
              Text(
                '找到 ${_searchResults.length} 个结果',
                style: TextStyle(color: Colors.grey[600]),
              ),
            ],
          ),
        ),
        // 搜索结果列表
        Expanded(
          child: _searchResults.isEmpty
              ? _buildEmptySearchState()
              : ListView.builder(
                  itemCount: _searchResults.length,
                  itemBuilder: (context, index) {
                    final result = _searchResults[index];
                    return _buildSearchResultItem(result);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildEmptySearchState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 64, color: Colors.grey[300]),
          SizedBox(height: 16),
          Text(
            '未找到相关笔记',
            style: TextStyle(fontSize: 16, color: Colors.grey[500]),
          ),
          SizedBox(height: 8),
          Text(
            '尝试使用其他关键词搜索',
            style: TextStyle(fontSize: 14, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResultItem(GlobalSearchResult result) {
    final note = result.note;
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: Icon(Icons.note, color: Colors.blue),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHighlightedText(note.title, _currentSearchQuery),
            SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.folder_open, size: 12, color: Colors.grey),
                SizedBox(width: 4),
                Text(
                  result.notebookName,
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                SizedBox(width: 8),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    result.matchType,
                    style: TextStyle(fontSize: 10, color: Colors.blue),
                  ),
                ),
              ],
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: 4),
            _buildHighlightedText(
              note.content.length > 100
                  ? note.content.substring(0, 100) + '...'
                  : note.content,
              _currentSearchQuery,
              maxLines: 2,
            ),
            SizedBox(height: 4),
            Text(
              '修改时间: ${note.lastModified.toString().substring(0, 10)}',
              style: TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ],
        ),
        trailing: Icon(Icons.chevron_right, color: Colors.grey),
        onTap: () => _onSearchResultTap(result),
      ),
    );
  }

  Widget _buildHighlightedText(String text, String query, {int maxLines = 1}) {
    if (query.isEmpty) {
      return Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 14),
      );
    }

    final textSpans = <TextSpan>[];
    final pattern = RegExp(
      query.replaceAllMapped(
        RegExp(r'[.*+?^${}()|[\]\\]'),
        (match) => '\\${match.group(0)}',
      ),
      caseSensitive: false,
    );
    final matches = pattern.allMatches(text);

    if (matches.isEmpty) {
      return Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 14),
      );
    }

    int currentStart = 0;
    for (final match in matches) {
      if (match.start > currentStart) {
        textSpans.add(
          TextSpan(
            text: text.substring(currentStart, match.start),
            style: TextStyle(fontSize: 14, color: Colors.black87),
          ),
        );
      }

      textSpans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: TextStyle(
            fontSize: 14,
            backgroundColor: Colors.yellow,
            color: Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
      );

      currentStart = match.end;
    }

    if (currentStart < text.length) {
      textSpans.add(
        TextSpan(
          text: text.substring(currentStart),
          style: TextStyle(fontSize: 14, color: Colors.black87),
        ),
      );
    }

    return RichText(
      text: TextSpan(children: textSpans),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }

  // 其余方法保持不变（_buildNotebookSelector, _buildNotebookList, _buildNoteList等）
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
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                ],
              ),
            ),
          ),
          if (_isNotebookListExpanded)
            Container(
              constraints: BoxConstraints(maxHeight: 200),
              child: _buildNotebookList(),
            ),
        ],
      ),
    );
  }

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
                onDismissed: (direction) => _deleteNotebook(notebook.name),
                child: ListTile(
                  leading: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
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
                      SPUtil.set("selectedNotebook", notebook.name);
                    });
                  },
                ),
              );
            },
          ),
        ),
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
          onDismissed: (direction) => _deleteNote(note.id),
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
                    builder: (context) => NoteDetailPage(
                      note: note,
                      onNoteChanged: noteChanged,
                      saveNote: saveNote,
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
              if (_noteTitleController.text.isNotEmpty &&
                  _selectedNotebook != null) {
                final exists = _selectedNotebook!.notes.any(
                  (note) =>
                      note.title == _noteTitleController.text ||
                      note.title == '${_noteTitleController.text}.md',
                );
                if (exists) {
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
                      utf8.encode(''),
                    )
                    .then((value) {
                      FileUtil()
                          .listNotes(workingDirectory, _selectedNotebook!.name)
                          .then((notes) {
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

// 全局搜索结果类
class GlobalSearchResult {
  final Note note;
  final String notebookName;
  final String matchType; // '标题' 或 '内容'

  GlobalSearchResult({
    required this.note,
    required this.notebookName,
    required this.matchType,
  });
}

// 笔记详情页面（包含查找功能）
class NoteDetailPage extends StatefulWidget {
  final Note note;
  final Function(Note, {String? newTitle}) onNoteChanged;
  final Function(Note) saveNote;

  const NoteDetailPage({
    super.key,
    required this.note,
    required this.onNoteChanged,
    required this.saveNote,
  });

  @override
  State<StatefulWidget> createState() => NoteDetailState();
}

class NoteDetailState extends State<NoteDetailPage> {
  late Note note;
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _textController = TextEditingController();

  // 查找功能相关变量
  final TextEditingController _findController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _showFindPanel = false;
  int _currentFindIndex = -1;
  int _totalMatches = 0;
  List<TextSelection> _matches = [];
  final FocusNode _findFocusNode = FocusNode();
  bool _isEditing = true;

  // 快捷键支持
  final Map<LogicalKeySet, Intent> _shortcuts = {
    LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyF):
        const ToggleFindIntent(),
    LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyF):
        const ToggleFindIntent(),
    LogicalKeySet(LogicalKeyboardKey.f3): const FindNextIntent(),
    LogicalKeySet(LogicalKeyboardKey.shift, LogicalKeyboardKey.f3):
        const FindPreviousIntent(),
  };

  @override
  void initState() {
    super.initState();
    note = widget.note;
    _titleController.text = note.title.replaceAll('.md', '');
    _textController.text = note.content;

    _textController.addListener(_onTextChanged);
    _findController.addListener(_onFindTextChanged);

    // 初始化高亮文本
    _updateHighlightedText();
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _findController.removeListener(_onFindTextChanged);
    _titleController.dispose();
    _textController.dispose();
    _findController.dispose();
    _scrollController.dispose();
    _findFocusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (_textController.text != note.content) {
      setState(() {
        note.content = _textController.text;
        widget.onNoteChanged(note);
        // 如果正在查找，更新高亮
        if (_findController.text.isNotEmpty) {
          _findMatches();
        }
      });
      // 延迟保存，避免频繁写文件
      Timer(const Duration(seconds: 1), () {
        FileUtil().saveFile(
          SPUtil.get<String>('workingDirectory', ''),
          note.id.substring(0, note.id.lastIndexOf('/')),
          note.title,
          utf8.encode(note.content),
        );
      });
    }
  }

  void _onFindTextChanged() {
    _findMatches();
  }

  void _findMatches() {
    final query = _findController.text.trim();

    if (query.isEmpty) {
      setState(() {
        _matches.clear();
        _currentFindIndex = -1;
        _totalMatches = 0;
        _updateHighlightedText();
      });
      return;
    }

    final text = _textController.text;
    final pattern = RegExp(RegExp.escape(query), caseSensitive: false);
    final matches = pattern.allMatches(text).toList();

    setState(() {
      _matches = matches
          .map(
            (match) =>
                TextSelection(baseOffset: match.start, extentOffset: match.end),
          )
          .toList();
      _totalMatches = _matches.length;
      _currentFindIndex = _matches.isNotEmpty ? 0 : -1;
      _updateHighlightedText();
    });

    if (_matches.isNotEmpty) {
      _scrollToCurrentMatch();
    }
  }

  void _findNext() {
    if (_totalMatches == 0) return;

    setState(() {
      _currentFindIndex = (_currentFindIndex + 1) % _totalMatches;
      _updateHighlightedText();
    });

    _scrollToCurrentMatch();
  }

  void _findPrevious() {
    if (_totalMatches == 0) return;

    setState(() {
      _currentFindIndex =
          (_currentFindIndex - 1 + _totalMatches) % _totalMatches;
      _updateHighlightedText();
    });

    _scrollToCurrentMatch();
  }

  // 构建高亮文本的TextSpan列表
  List<TextSpan> _highlightedSpans = [];

  void _updateHighlightedText() {
    final text = _textController.text;
    final query = _findController.text.trim();

    if (query.isEmpty || _matches.isEmpty) {
      _highlightedSpans = [
        TextSpan(
          text: text,
          style: TextStyle(color: Colors.white, fontSize: 14),
        ),
      ];
      return;
    }

    final spans = <TextSpan>[];
    int currentStart = 0;

    for (int i = 0; i < _matches.length; i++) {
      final match = _matches[i];

      // 添加匹配前的文本
      if (match.start > currentStart) {
        spans.add(
          TextSpan(
            text: text.substring(currentStart, match.start),
            style: TextStyle(color: Colors.white, fontSize: 14),
          ),
        );
      }

      // 添加匹配的文本，当前匹配项用不同颜色
      final isCurrent = i == _currentFindIndex;
      spans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: TextStyle(
            backgroundColor: isCurrent ? Colors.orange : Colors.yellow,
            color: isCurrent ? Colors.black : Colors.black87,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      );

      currentStart = match.end;
    }

    // 添加剩余文本
    if (currentStart < text.length) {
      spans.add(
        TextSpan(
          text: text.substring(currentStart),
          style: TextStyle(color: Colors.white, fontSize: 14),
        ),
      );
    }

    _highlightedSpans = spans;
  }

  void _scrollToCurrentMatch() {
    if (_currentFindIndex < 0 || _currentFindIndex >= _matches.length) return;

    final match = _matches[_currentFindIndex];
    final text = _textController.text;

    // 计算匹配文本的大致行号（简单估算）
    final textBeforeMatch = text.substring(0, match.start);
    final linesBefore = textBeforeMatch.split('\n');
    final lineCount = linesBefore.length;

    // 估算行高（根据字体大小估算）
    const estimatedLineHeight = 20.0;
    final targetOffset = (lineCount - 1) * estimatedLineHeight;

    // 确保滚动位置在合理范围内
    final maxScrollExtent = _scrollController.position.maxScrollExtent;
    final clampedOffset = targetOffset.clamp(0.0, maxScrollExtent);

    _scrollController.animateTo(
      clampedOffset,
      duration: Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _toggleFindPanel() {
    setState(() {
      _showFindPanel = !_showFindPanel;
      if (!_showFindPanel) {
        _findController.clear();
        _findMatches(); // 清除高亮
      } else {
        // 打开查找面板时自动聚焦
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _findFocusNode.requestFocus();
        });
      }
    });
  }

  void _closeFindPanel() {
    setState(() {
      _showFindPanel = false;
      _findController.clear();
      _findMatches(); // 清除高亮
    });
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: _shortcuts,
      child: Actions(
        actions: {
          ToggleFindIntent: ToggleFindAction(_toggleFindPanel),
          FindNextIntent: FindNextAction(_findNext),
          FindPreviousIntent: FindPreviousAction(_findPrevious),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              leading: IconButton(
                icon: Icon(Icons.arrow_back),
                onPressed: () {
                  widget.saveNote(note);
                  Navigator.pop(context);
                },
              ),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _titleController,
                    onEditingComplete: () {
                      widget.onNoteChanged(
                        note,
                        newTitle: _titleController.text,
                      );
                    },
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      isDense: true,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    '修改时间: ${note.lastModified.toString().substring(0, 16)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
              actions: [
                // 只在编辑模式下显示查找按钮
                if (_isEditing)
                  IconButton(
                    icon: Icon(Icons.find_in_page),
                    onPressed: _toggleFindPanel,
                    tooltip: '查找 (Ctrl+F)',
                  ),
                IconButton(
                  icon: Icon(
                    Icons.edit,
                    color: _isEditing ? Colors.blue : Colors.grey,
                  ),
                  onPressed: () => setState(() {
                    _isEditing = true;
                    // 切换到编辑模式时，如果查找面板是打开的，确保高亮更新
                    if (_findController.text.isNotEmpty) {
                      _findMatches();
                    }
                  }),
                  tooltip: '编辑',
                ),
                IconButton(
                  icon: Icon(
                    Icons.preview,
                    color: !_isEditing ? Colors.blue : Colors.grey,
                  ),
                  onPressed: () => setState(() {
                    _isEditing = false;
                    // 切换到预览模式时，关闭查找面板
                    if (_showFindPanel) {
                      _closeFindPanel();
                    }
                  }),
                  tooltip: '预览',
                ),
                IconButton(
                  icon: Icon(Icons.save),
                  onPressed: () {
                    widget.saveNote(note);
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('笔记已保存')));
                  },
                  tooltip: '保存',
                ),
              ],
            ),
            body: Column(
              children: [
                // 查找面板只在编辑模式下显示
                Visibility(
                  visible: _isEditing && _showFindPanel,
                  child: _buildFindPanel(),
                ),
                Expanded(child: _isEditing ? _buildEditor() : _buildPreview()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFindPanel() {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        border: Border(bottom: BorderSide(color: Colors.grey.shade700)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _findController,
              focusNode: _findFocusNode,
              style: TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: '查找...',
                hintStyle: TextStyle(color: Colors.white54),
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                isDense: true,
              ),
            ),
          ),
          SizedBox(width: 12),
          Text(
            _totalMatches > 0
                ? '${_currentFindIndex + 1}/$_totalMatches'
                : '无匹配',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.keyboard_arrow_up, size: 20),
            onPressed: _findPrevious,
            tooltip: '上一个 (Shift+F3)',
            color: _totalMatches > 0 ? Colors.white : Colors.grey,
          ),
          IconButton(
            icon: Icon(Icons.keyboard_arrow_down, size: 20),
            onPressed: _findNext,
            tooltip: '下一个 (F3)',
            color: _totalMatches > 0 ? Colors.white : Colors.grey,
          ),
          IconButton(
            icon: Icon(Icons.close, size: 20),
            onPressed: _closeFindPanel,
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }

  Widget _buildEditor() {
    return Stack(
      children: [
        SingleChildScrollView(
          controller: _scrollController,
          padding: EdgeInsets.all(16),
          child: _findController.text.isNotEmpty && _matches.isNotEmpty
              ? SelectableText.rich(
                  TextSpan(children: _highlightedSpans),
                  style: TextStyle(fontSize: 14),
                )
              : TextField(
                  controller: _textController,
                  maxLines: null,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: '开始输入内容...',
                    hintStyle: TextStyle(color: Colors.white30),
                  ),
                  style: TextStyle(fontSize: 14, color: Colors.white),
                ),
        ),
        // 在右下角显示查找状态（只在编辑模式且有匹配时显示）
        if (_findController.text.isNotEmpty && _totalMatches > 0)
          Positioned(
            right: 16,
            bottom: 16,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${_currentFindIndex + 1}/$_totalMatches',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPreview() {
    // 使用flutter_markdown包实现真正的Markdown预览[1,2,5](@ref)
    return Markdown(
      data: note.content,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(fontSize: 14, color: Colors.white70, height: 1.6),
        h1: TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
        h2: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
        h3: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
        code: TextStyle(
          backgroundColor: Colors.grey[850],
          color: Colors.orangeAccent,
          fontFamily: 'Monospace',
          fontSize: 13,
        ),
        codeblockPadding: EdgeInsets.all(12),
        codeblockDecoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(8),
        ),
        blockquote: TextStyle(
          color: Colors.grey[300],
          fontStyle: FontStyle.italic,
        ),
        blockquoteDecoration: BoxDecoration(
          color: Colors.grey[900],
          border: Border(left: BorderSide(color: Colors.blueAccent, width: 4)),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      shrinkWrap: true,
    );
  }
}

// 快捷键相关的Intent类
class ToggleFindIntent extends Intent {
  const ToggleFindIntent();
}

class FindNextIntent extends Intent {
  const FindNextIntent();
}

class FindPreviousIntent extends Intent {
  const FindPreviousIntent();
}

// 快捷键相关的Action类
class ToggleFindAction extends Action<ToggleFindIntent> {
  final VoidCallback onToggle;

  ToggleFindAction(this.onToggle);

  @override
  void invoke(covariant ToggleFindIntent intent) {
    onToggle();
  }
}

class FindNextAction extends Action<FindNextIntent> {
  final VoidCallback onFindNext;

  FindNextAction(this.onFindNext);

  @override
  void invoke(covariant FindNextIntent intent) {
    onFindNext();
  }
}

class FindPreviousAction extends Action<FindPreviousIntent> {
  final VoidCallback onFindPrevious;

  FindPreviousAction(this.onFindPrevious);

  @override
  void invoke(covariant FindPreviousIntent intent) {
    onFindPrevious();
  }
}
