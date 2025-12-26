import 'dart:async';
import 'dart:convert';
import 'package:ashes_note/utils/const.dart';
import 'package:ashes_note/utils/file_util.dart';
import 'package:ashes_note/utils/git_service.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:ashes_note/views/note_detail_supereditor_view.dart'
    show NoteDetailPage;
// import 'package:ashes_note/views/note_detail_view.dart' show NoteDetailPage;
import 'package:flutter/material.dart';
import 'package:ashes_note/entity/entities_notebook.dart';

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

    workingDirectory = SPUtil.get<String>(PrefKeys.workingDirectory, '');
    String gitPlatform = SPUtil.get<String>(PrefKeys.gitPlatform, '');

    if (gitPlatform.isNotEmpty) {
      if (gitPlatform == GitPlatforms.gitee) {
        String token = SPUtil.get<String>(PrefKeys.giteeToken, '');
        remoteUrl = SPUtil.get<String>(PrefKeys.giteeRemoteUrl, '');
        git = GitFactory.getGitService(gitPlatform, token);
      }
      String lastPullTime = SPUtil.get(PrefKeys.lastPullTime, '');
      print('lastPullTime: $lastPullTime');
      var (owner, repo) = git!.getOwnerRepoFromUrl(remoteUrl!);
      if (lastPullTime == '') {
        git!.pull(owner, repo, workingDirectory).then((_) {
          SPUtil.set(PrefKeys.lastPullTime, DateTime.now().toIso8601String());
        });
        _loadNotebookList();
      } else {
        // 查看上一次pull后远程有没有提交记录
        git!.getCommits(owner, repo, since: lastPullTime).then((
          List<Map<String, dynamic>> commits,
        ) {
          if (commits.isNotEmpty) {
            git!.pull(owner, repo, workingDirectory).then((_) {
              SPUtil.set(
                PrefKeys.lastPullTime,
                DateTime.now().toIso8601String(),
              );
              _loadNotebookList();
            });
          }
        });
      }
    }
    _loadNotebookList();

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
    _notebooks.clear();
    for (var book in bookList) {
      final List<Note> notes = await FileUtil().listNotes(
        workingDirectory,
        book,
      );
      _notebooks.add(Notebook(name: book, notes: notes, color: Colors.blue));
    }

    setState(() {
      if (_notebooks.isNotEmpty) {
        String selectedNotebookName = SPUtil.get<String>(
          PrefKeys.selectedNotebook,
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
              final (owner, repo) = git!.getOwnerRepoFromUrl(remoteUrl!);
              FileUtil()
                  .listNotes(workingDirectory, notebookName)
                  .then((notes) {
                    print('notes: $notes');
                    for (var note in notes) {
                      git?.deleteFile(
                        owner,
                        repo,
                        note.id,
                        '删除笔记本 ${note.id}',
                        git!.hashObject(utf8.encode(note.content)),
                      );
                    }
                  })
                  .then((_) {
                    print("delete first then");
                    print(
                      'workingDirectory: $workingDirectory notebookName: $notebookName',
                    );
                    FileUtil().deleteDirectory(workingDirectory, notebookName);
                    print("delete second then");
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
    final note = _selectedNotebook!.notes.firstWhere(
      (note) => note.id == noteId,
    );
    setState(() {
      _selectedNotebook!.notes.removeWhere((note) => note.id == noteId);
    });

    final path = noteId.substring(0, noteId.lastIndexOf('/'));
    final filename = noteId.substring(noteId.lastIndexOf('/') + 1);
    String sha = git!.hashObject(utf8.encode(note.content));
    FileUtil().deleteFile(workingDirectory, path, filename);
    final (owner, repo) = git!.getOwnerRepoFromUrl(remoteUrl!);
    git?.deleteFile(owner, repo, noteId, 'Delete note $noteId', sha);

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
              final scaffoldMessenger = ScaffoldMessenger.of(context);
              if (git == null || remoteUrl == null) {
                scaffoldMessenger.showSnackBar(
                  SnackBar(content: Text('Git 服务未配置，无法同步')),
                );
                return;
              }
              var (owner, repo) = git!.getOwnerRepoFromUrl(remoteUrl!);
              if (_isSyncing) return;

              setState(() {
                _isSyncing = true;
              });

              // 拉取远程仓库的数据
              git!
                  .pull(owner, repo, workingDirectory)
                  .then((_) {
                    SPUtil.set(
                      PrefKeys.lastPullTime,
                      DateTime.now().toIso8601String(),
                    );
                    // 推送本地仓库的数据
                    //pull完成再push，远程有的文件本地不可能没有，所以不会删除远程文件
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
                          scaffoldMessenger.showSnackBar(
                            const SnackBar(content: Text('仓库同步完成')),
                          );
                        })
                        .catchError((error) {
                          setState(() {
                            _isSyncing = false;
                          });
                          scaffoldMessenger.showSnackBar(
                            SnackBar(content: Text('仓库同步push失败: $error')),
                          );
                        });
                  })
                  .catchError((error) {
                    setState(() {
                      _isSyncing = false;
                    });
                    scaffoldMessenger.showSnackBar(
                      SnackBar(content: Text('仓库同步pull失败: $error')),
                    );
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
                '搜索 "$_currentSearchQuery"',
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
                  ? '${note.content.substring(0, 100)}...'
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
                      SPUtil.set(PrefKeys.selectedNotebook, notebook.name);
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
