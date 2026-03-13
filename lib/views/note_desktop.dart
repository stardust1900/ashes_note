import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ashes_note/utils/const.dart';
import 'package:ashes_note/utils/file_util.dart';
import 'package:ashes_note/utils/git_service.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:flutter/material.dart';
import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;

class NotebookDesktopPage extends StatefulWidget {
  const NotebookDesktopPage({super.key});

  @override
  State<NotebookDesktopPage> createState() => _NotebookDesktopPageState();
}

class _NotebookDesktopPageState extends State<NotebookDesktopPage> {
  final List<Notebook> _notebooks = [];
  late String workingDirectory;
  final TextEditingController _notebookNameController = TextEditingController();
  final TextEditingController _noteTitleController = TextEditingController();

  // 搜索相关变量
  final TextEditingController _searchController = TextEditingController();
  final List<GlobalSearchResult> _searchResults = [];
  String _currentSearchQuery = '';
  bool _showSearchResults = false;

  // 当前选中的笔记（用于右侧显示详情）
  Note? _selectedNote;
  Notebook? _selectedNotebook;

  // 笔记本展开状态（支持多个笔记本同时展开）
  final Set<String> _expandedNotebooks = <String>{};

  GitService? git;
  String? remoteUrl;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    workingDirectory = SPUtil.get<String>(PrefKeys.workingDirectory, '');
    String gitPlatform = SPUtil.get<String>(PrefKeys.gitPlatform, '');

    final notesDir = Directory('$workingDirectory/notes');

    if (gitPlatform.isNotEmpty) {
      if (gitPlatform == GitPlatforms.gitee) {
        String token = SPUtil.get<String>(PrefKeys.giteeToken, '');
        remoteUrl = SPUtil.get<String>(PrefKeys.giteeRemoteUrl, '');
        git = GitFactory.getGitService(gitPlatform, token);
      } else if (gitPlatform == GitPlatforms.github) {
        String token = SPUtil.get<String>(PrefKeys.githubToken, '');
        remoteUrl = SPUtil.get<String>(PrefKeys.githubRemoteUrl, '');
        git = GitFactory.getGitService(gitPlatform, token);
      }

      String lastPullTime = SPUtil.get(PrefKeys.lastPullTime, '');
      var (owner, repo) = git!.getOwnerRepoFromUrl(remoteUrl!);
      if (lastPullTime == '') {
        git!.pull(owner, repo, notesDir.path).then((_) {
          SPUtil.set(PrefKeys.lastPullTime, DateTime.now().toIso8601String());
        });
        _loadNotebookList();
      } else {
        git!.getCommits(owner, repo, since: lastPullTime).then((
          List<Map<String, dynamic>> commits,
        ) {
          if (commits.isNotEmpty) {
            git!.pull(owner, repo, notesDir.path).then((_) {
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
    final notesDir = Directory('$workingDirectory/notes');
    if (!await notesDir.exists()) {
      await notesDir.create(recursive: true);
    }

    final List<String> bookList = await FileUtil().listFiles(
      '$workingDirectory/notes',
      '',
      type: 'directory',
    );
    _notebooks.clear();
    for (var book in bookList) {
      final List<Note> notes = await FileUtil().listNotes(
        '$workingDirectory/notes',
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
        // 默认选中第一个笔记
        if (_selectedNotebook != null && _selectedNotebook!.notes.isNotEmpty) {
          _selectedNote = _selectedNotebook!.notes.first;
        }
      }
    });
  }

  void _deleteNotebook(String notebookName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).dialogTheme.backgroundColor,
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
                  _selectedNote =
                      _selectedNotebook != null &&
                          _selectedNotebook!.notes.isNotEmpty
                      ? _selectedNotebook!.notes.first
                      : null;
                }
              });
              final (owner, repo) = git!.getOwnerRepoFromUrl(remoteUrl!);
              FileUtil()
                  .listNotes('$workingDirectory/notes', notebookName)
                  .then((notes) {
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
                    FileUtil().deleteDirectory(
                      '$workingDirectory/notes',
                      notebookName,
                    );
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

  void _deleteNote(String noteId) {
    if (_selectedNotebook == null) return;
    final note = _selectedNotebook!.notes.firstWhere(
      (note) => note.id == noteId,
    );
    setState(() {
      _selectedNotebook!.notes.removeWhere((note) => note.id == noteId);
      if (_selectedNote?.id == noteId) {
        _selectedNote = _selectedNotebook!.notes.isNotEmpty
            ? _selectedNotebook!.notes.first
            : null;
      }
    });

    final path = noteId.substring(0, noteId.lastIndexOf('/'));
    final filename = noteId.substring(noteId.lastIndexOf('/') + 1);
    String sha = git!.hashObject(utf8.encode(note.content));
    FileUtil().deleteFile('$workingDirectory/notes', path, filename);
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
              '$workingDirectory/notes',
              _selectedNotebook!.name,
              newFileName,
              utf8.encode(updatedNote.content),
            )
            .then((_) {
              FileUtil().deleteFile(
                '$workingDirectory/notes',
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
      if (_selectedNote?.id == updatedNote.id) {
        _selectedNote = updatedNote;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // 左侧面板：笔记本和笔记树形列表
          Container(
            width: 300,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Column(
              children: [
                _buildSidebarHeader(),
                Expanded(
                  child: _showSearchResults
                      ? _buildSearchResults()
                      : _buildNoteTree(),
                ),
              ],
            ),
          ),
          // 右侧面板：笔记详情
          Expanded(
            child: _selectedNote != null
                ? _buildNoteDetail(_selectedNote!)
                : _buildEmptyDetail(),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarHeader() {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Icon(Icons.note, size: 20, color: theme.primaryColor),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '笔记本',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (_selectedNotebook != null)
            IconButton(
              icon: Icon(Icons.add, size: 20),
              onPressed: _showCreateNoteDialog,
              tooltip: '创建笔记',
            ),
          IconButton(
            icon: Icon(Icons.sync, size: 20),
            color: _isSyncing ? Colors.grey : theme.primaryColor,
            onPressed: _performSync,
            tooltip: '同步',
          ),
        ],
      ),
    );
  }

  Widget _buildNoteTree() {
    return _notebooks.isEmpty
        ? _buildEmptySidebar()
        : ListView(
            padding: EdgeInsets.symmetric(vertical: 8),
            children: _notebooks.map((notebook) {
              return _buildNotebookItem(notebook);
            }).toList(),
          );
  }

  Widget _buildNotebookItem(Notebook notebook) {
    final theme = Theme.of(context);
    final isSelected = _selectedNotebook?.name == notebook.name;
    final isExpanded = _expandedNotebooks.contains(notebook.name);

    return Container(
      margin: EdgeInsets.only(left: 8, right: 8, top: 0, bottom: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                // 切换展开/收起状态
                if (_expandedNotebooks.contains(notebook.name)) {
                  _expandedNotebooks.remove(notebook.name);
                } else {
                  _expandedNotebooks.add(notebook.name);
                }
                // 同时设置为选中笔记本
                _selectedNotebook = notebook;
                SPUtil.set(PrefKeys.selectedNotebook, notebook.name);
              });
            },
            borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    isExpanded ? Icons.expand_more : Icons.chevron_right,
                    size: 16,
                    color: theme.iconTheme.color,
                  ),
                  SizedBox(width: 4),
                  Icon(Icons.folder, size: 18, color: notebook.color),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      notebook.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                  if (isSelected)
                    PopupMenuButton<String>(
                      icon: Icon(Icons.more_vert, size: 16),
                      padding: EdgeInsets.zero,
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'create_note',
                          child: Row(
                            children: [
                              Icon(Icons.note_add, size: 16),
                              SizedBox(width: 8),
                              Text('创建笔记'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
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
                      onSelected: (value) {
                        if (value == 'create_note') {
                          _showCreateNoteDialog();
                        } else if (value == 'delete') {
                          _deleteNotebook(notebook.name);
                        }
                      },
                    ),
                ],
              ),
            ),
          ),
          if (isExpanded && notebook.notes.isNotEmpty)
            Container(
              padding: EdgeInsets.only(left: 36, right: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: notebook.notes.map((note) {
                  final noteIsSelected = _selectedNote?.id == note.id;
                  return InkWell(
                    onTap: () {
                      setState(() {
                        _selectedNote = note;
                      });
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: noteIsSelected
                            ? theme.colorScheme.secondaryContainer.withValues(
                                alpha: 0.3,
                              )
                            : null,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.description,
                            size: 14,
                            color: theme.iconTheme.color?.withValues(
                              alpha: 0.6,
                            ),
                          ),
                          SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              note.title,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: noteIsSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          if (isExpanded && notebook.notes.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 36, vertical: 8),
              child: Text(
                '暂无笔记',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.disabledColor,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptySidebar() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.folder_open, size: 48, color: theme.disabledColor),
          SizedBox(height: 12),
          Text(
            '暂无笔记本',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.disabledColor,
            ),
          ),
          SizedBox(height: 8),
          TextButton.icon(
            onPressed: _showCreateNotebookDialog,
            icon: Icon(Icons.add),
            label: Text('创建笔记本'),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults() {
    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: TextField(
            controller: _searchController,
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: InputDecoration(
              hintText: '搜索所有笔记本...',
              prefixIcon: Icon(Icons.search),
              suffixIcon: _currentSearchQuery.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear),
                      onPressed: () => _searchController.clear(),
                    )
                  : null,
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
        ),
        Expanded(
          child: _searchResults.isEmpty
              ? Center(child: Text('无搜索结果'))
              : ListView.builder(
                  itemCount: _searchResults.length,
                  itemBuilder: (context, index) {
                    final result = _searchResults[index];
                    return ListTile(
                      leading: Icon(Icons.note),
                      title: Text(result.note.title),
                      subtitle: Text(
                        '${result.notebookName} · ${result.matchType}',
                        style: TextStyle(fontSize: 12),
                      ),
                      onTap: () {
                        // 找到对应的笔记本和笔记
                        final notebook = _notebooks.firstWhere(
                          (nb) => nb.name == result.notebookName,
                        );
                        setState(() {
                          _selectedNotebook = notebook;
                          _selectedNote = result.note;
                          _showSearchResults = false;
                          _searchController.clear();
                        });
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildNoteDetail(Note note) {
    return _NoteDetailPanel(
      key: ValueKey(note.id),
      note: note,
      notebook: _selectedNotebook!,
      onNoteChanged: noteChanged,
      saveNote: saveNote,
      onDeleteNote: _deleteNote,
      onTitleChanged: (newTitle) {
        noteChanged(note, newTitle: newTitle);
      },
    );
  }

  Widget _buildEmptyDetail() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.description_outlined,
            size: 64,
            color: theme.disabledColor,
          ),
          SizedBox(height: 16),
          Text(
            '选择一个笔记开始编辑',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.disabledColor,
            ),
          ),
          SizedBox(height: 8),
          Text(
            '从左侧选择笔记本和笔记',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.disabledColor,
            ),
          ),
        ],
      ),
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
                  '$workingDirectory/notes',
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
                  _selectedNotebook = _notebooks.last;
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
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('创建新笔记'),
        content: TextField(
          controller: _noteTitleController,
          decoration: InputDecoration(
            hintText: '笔记标题',
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
                      '$workingDirectory/notes',
                      _selectedNotebook!.name,
                      _noteTitleController.text.endsWith('.md')
                          ? _noteTitleController.text
                          : '${_noteTitleController.text}.md',
                      utf8.encode(''),
                    )
                    .then((value) {
                      FileUtil()
                          .listNotes(
                            '$workingDirectory/notes',
                            _selectedNotebook!.name,
                          )
                          .then((notes) {
                            setState(() {
                              final notebookIndex = _notebooks.indexWhere(
                                (n) => n.name == _selectedNotebook!.name,
                              );
                              _notebooks[notebookIndex].notes.clear();
                              _notebooks[notebookIndex].notes.addAll(notes);
                              _selectedNote = notes.last;
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

  void _performSync() {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    if (git == null || remoteUrl == null) {
      scaffoldMessenger.showSnackBar(SnackBar(content: Text('Git 服务未配置，无法同步')));
      return;
    }
    var (owner, repo) = git!.getOwnerRepoFromUrl(remoteUrl!);
    if (_isSyncing) return;

    setState(() {
      _isSyncing = true;
    });

    git!
        .pull(owner, repo, '$workingDirectory/notes')
        .then((_) {
          SPUtil.set(PrefKeys.lastPullTime, DateTime.now().toIso8601String());
          git!
              .push(
                owner,
                repo,
                '$workingDirectory/notes',
                deleteRemoteMissing: true,
              )
              .then((_) {
                setState(() {
                  _isSyncing = false;
                });
                scaffoldMessenger.showSnackBar(
                  const SnackBar(content: Text('仓库同步完成')),
                );
                _loadNotebookList();
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
  }
}

// 笔记详情面板（简化版，嵌入在桌面版中）
class _NoteDetailPanel extends StatefulWidget {
  final Note note;
  final Notebook notebook;
  final Function(Note, {String? newTitle}) onNoteChanged;
  final Function(Note) saveNote;
  final Function(String) onDeleteNote;
  final Function(String) onTitleChanged;

  const _NoteDetailPanel({
    super.key,
    required this.note,
    required this.notebook,
    required this.onNoteChanged,
    required this.saveNote,
    required this.onDeleteNote,
    required this.onTitleChanged,
  });

  @override
  State<_NoteDetailPanel> createState() => _NoteDetailPanelState();
}

class _NoteDetailPanelState extends State<_NoteDetailPanel> {
  late TextEditingController _titleController;
  late TextEditingController _contentController;
  Timer? _saveTimer;

  // 查找功能相关变量
  final TextEditingController _findController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _showFindPanel = false;
  int _currentFindIndex = -1;
  int _totalMatches = 0;
  List<TextSelection> _matches = [];
  final FocusNode _findFocusNode = FocusNode();

  // 视图模式：edit(普通编辑), preview(预览)
  String _viewMode = 'edit';

  // 高亮文本的 TextSpan 列表
  List<TextSpan> _highlightedSpans = [];

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: widget.note.title.replaceAll('.md', ''),
    );
    _contentController = TextEditingController(text: widget.note.content);
    _contentController.addListener(_onContentChanged);
    _findController.addListener(_onFindTextChanged);
  }

  @override
  void didUpdateWidget(_NoteDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.note.id != widget.note.id) {
      _titleController.text = widget.note.title.replaceAll('.md', '');
      _contentController.text = widget.note.content;
      _findController.clear();
      _matches.clear();
      _currentFindIndex = -1;
      _totalMatches = 0;
      _showFindPanel = false;
      _viewMode = 'edit';
      _updateHighlightedText();
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _contentController.removeListener(_onContentChanged);
    _findController.removeListener(_onFindTextChanged);
    _titleController.dispose();
    _contentController.dispose();
    _findController.dispose();
    _scrollController.dispose();
    _findFocusNode.dispose();
    super.dispose();
  }

  void _onContentChanged() {
    if (_contentController.text != widget.note.content) {
      setState(() {
        widget.note.content = _contentController.text;
        widget.note.lastModified = DateTime.now();
        widget.onNoteChanged(widget.note);
        // 如果正在查找，更新高亮
        if (_findController.text.isNotEmpty) {
          _findMatches();
        }
      });

      // 延迟保存
      _saveTimer?.cancel();
      _saveTimer = Timer(const Duration(seconds: 1), () {
        _saveContentToFile();
      });
    }
  }

  void _saveContentToFile() {
    final workingDir = SPUtil.get<String>(PrefKeys.workingDirectory, '');
    FileUtil().saveFile(
      '$workingDir/notes',
      widget.note.id.substring(0, widget.note.id.lastIndexOf('/')),
      widget.note.title,
      utf8.encode(widget.note.content),
    );
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

    final text = _contentController.text;
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
      _scrollToMatch();
    }
  }

  void _findNext() {
    if (_totalMatches == 0) return;

    setState(() {
      _currentFindIndex = (_currentFindIndex + 1) % _totalMatches;
      _updateHighlightedText();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToMatch();
    });
  }

  void _findPrevious() {
    if (_totalMatches == 0) return;

    setState(() {
      _currentFindIndex =
          (_currentFindIndex - 1 + _totalMatches) % _totalMatches;
      _updateHighlightedText();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToMatch();
    });
  }

  void _updateHighlightedText() {
    final theme = Theme.of(context);
    final text = _contentController.text;
    final query = _findController.text.trim();
    final textColor = theme.textTheme.bodyMedium?.color;

    if (query.isEmpty || _matches.isEmpty) {
      _highlightedSpans = [
        TextSpan(
          text: text,
          style: TextStyle(
            fontSize: 14,
            height: 1.6,
            color: textColor ?? Colors.black87,
          ),
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
            style: TextStyle(fontSize: 14, color: textColor),
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
          style: TextStyle(fontSize: 14, height: 1.6, color: textColor),
        ),
      );
    }

    _highlightedSpans = spans;
  }

  void _scrollToMatch() {
    if (_currentFindIndex < 0 || _currentFindIndex >= _matches.length) return;

    final match = _matches[_currentFindIndex];
    // 使用简单滚动（使用 TextPainter 可能需要更复杂的实现）
    final linesBeforeMatch = _contentController.text
        .substring(0, match.start)
        .split('\n')
        .length;
    final lineHeight = 22.0; // 估算的行高
    final targetOffset = (linesBeforeMatch - 1) * lineHeight;

    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _toggleFindPanel() {
    setState(() {
      _showFindPanel = !_showFindPanel;
      if (_showFindPanel) {
        _findFocusNode.requestFocus();
      } else {
        _findController.clear();
        _matches.clear();
        _currentFindIndex = -1;
        _totalMatches = 0;
        _updateHighlightedText();
      }
    });
  }

  void _switchViewMode(String newMode) {
    if (_viewMode == newMode) return;

    // 保存当前内容
    if (_viewMode == 'edit') {
      widget.note.content = _contentController.text;
      _saveContentToFile();
      widget.onNoteChanged(widget.note);
    }

    setState(() {
      _viewMode = newMode;
      if (_showFindPanel) {
        _showFindPanel = false;
        _findController.clear();
        _matches.clear();
        _currentFindIndex = -1;
        _totalMatches = 0;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Column(
        children: [
          // 笔记标题栏
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: _titleController,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        decoration: InputDecoration(
                          hintText: '笔记标题',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          isDense: true,
                        ),
                        onSubmitted: (value) {
                          if (value.isNotEmpty) {
                            widget.onTitleChanged(value);
                          }
                        },
                      ),
                      SizedBox(height: 4),
                      Text(
                        '修改时间: ${widget.note.lastModified.toString().substring(0, 16)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isDark ? Colors.grey[400] : Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 16),
                // 查找按钮
                if (_viewMode == 'edit')
                  IconButton(
                    icon: Icon(Icons.find_in_page),
                    onPressed: _toggleFindPanel,
                    tooltip: '查找 (Ctrl+F)',
                  ),
                // 普通编辑模式按钮
                IconButton(
                  icon: Icon(
                    Icons.edit_note,
                    color: _viewMode == 'edit'
                        ? theme.primaryColor
                        : (isDark ? theme.disabledColor : Colors.grey),
                  ),
                  onPressed: () => _switchViewMode('edit'),
                  tooltip: '普通编辑',
                ),
                // 预览模式按钮
                IconButton(
                  icon: Icon(
                    Icons.preview,
                    color: _viewMode == 'preview'
                        ? theme.primaryColor
                        : (isDark ? theme.disabledColor : Colors.grey),
                  ),
                  onPressed: () => _switchViewMode('preview'),
                  tooltip: '预览',
                ),
                IconButton(
                  icon: Icon(Icons.save),
                  onPressed: () {
                    widget.saveNote(widget.note);
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('笔记已保存')));
                  },
                  tooltip: '保存',
                ),
                IconButton(
                  icon: Icon(Icons.delete, color: Colors.red),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text('删除笔记'),
                        content: Text('确定要删除笔记"${widget.note.title}"吗？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: Text('取消'),
                          ),
                          TextButton(
                            onPressed: () {
                              widget.onDeleteNote(widget.note.id);
                              Navigator.pop(context);
                            },
                            child: Text(
                              '删除',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                  tooltip: '删除',
                ),
              ],
            ),
          ),
          // 查找面板
          if (_showFindPanel && _viewMode == 'edit') _buildFindPanel(),
          // 笔记内容编辑区
          Expanded(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: _viewMode == 'edit'
                  ? _buildEditor(theme)
                  : _buildPreview(theme),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFindPanel() {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _findController,
              focusNode: _findFocusNode,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.textTheme.bodyMedium?.color,
              ),
              decoration: InputDecoration(
                hintText: '查找...',
                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.textTheme.bodyMedium?.color?.withValues(
                    alpha: 0.5,
                  ),
                ),
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
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
            ),
          ),
          SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.keyboard_arrow_up, size: 20),
            onPressed: _findPrevious,
            tooltip: '上一个',
            color: _totalMatches > 0
                ? theme.iconTheme.color
                : theme.disabledColor,
          ),
          IconButton(
            icon: Icon(Icons.keyboard_arrow_down, size: 20),
            onPressed: _findNext,
            tooltip: '下一个',
            color: _totalMatches > 0
                ? theme.iconTheme.color
                : theme.disabledColor,
          ),
          IconButton(
            icon: Icon(Icons.close, size: 20),
            onPressed: _toggleFindPanel,
            tooltip: '关闭',
            color: theme.iconTheme.color,
          ),
        ],
      ),
    );
  }

  Widget _buildEditor(ThemeData theme) {
    return _highlightedSpans.isEmpty
        ? TextField(
            controller: _contentController,
            scrollController: _scrollController,
            maxLines: null,
            expands: true,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: 14,
              height: 1.6,
              fontFamily: 'monospace',
            ),
            decoration: InputDecoration(
              hintText: '开始编写笔记内容...',
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            textAlignVertical: TextAlignVertical.top,
          )
        : SingleChildScrollView(
            controller: _scrollController,
            child: RichText(text: TextSpan(children: _highlightedSpans)),
          );
  }

  Widget _buildPreview(ThemeData theme) {
    return fm.Markdown(
      data: widget.note.content,
      selectable: true,
      imageDirectory: SPUtil.get<String>(PrefKeys.workingDirectory, ''),
      styleSheet: fm.MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: theme.textTheme.bodyMedium,
        h1: theme.textTheme.headlineMedium,
        h2: theme.textTheme.titleLarge,
        h3: theme.textTheme.titleMedium,
        code: theme.textTheme.bodyMedium?.copyWith(
          fontFamily: 'monospace',
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
        codeblockDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        blockquote: theme.textTheme.bodyMedium?.copyWith(
          fontStyle: FontStyle.italic,
          color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.8),
        ),
        listBullet: theme.textTheme.bodyMedium?.copyWith(
          color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: theme.primaryColor, width: 4)),
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.3,
          ),
        ),
      ),
    );
  }
}

// 全局搜索结果类
class GlobalSearchResult {
  final Note note;
  final String notebookName;
  final String matchType;

  GlobalSearchResult({
    required this.note,
    required this.notebookName,
    required this.matchType,
  });
}
