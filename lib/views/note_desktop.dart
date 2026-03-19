import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ashes_note/utils/const.dart';
import 'package:ashes_note/utils/file_util.dart';
import 'package:ashes_note/utils/git_service.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

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
  final GlobalKey<_NoteDetailPanelState> _detailPanelKey = GlobalKey();

  // 笔记本展开状态（支持多个笔记本同时展开）
  final Set<String> _expandedNotebooks = <String>{};

  // 未同步到 git 的笔记 id 集合
  final Set<String> _unsyncedNoteIds = <String>{};

  GitService? git;
  String? remoteUrl;
  bool _isSyncing = false;
  double _sidebarWidth = 300;

  // 笔记排序模式：'name'(名称), 'modified'(修改时间)
  String _noteSortMode = 'name';

  @override
  void initState() {
    super.initState();
    workingDirectory = SPUtil.get<String>(PrefKeys.workingDirectory, '');
    String gitPlatform = SPUtil.get<String>(PrefKeys.gitPlatform, '');
    _noteSortMode = SPUtil.get<String>(PrefKeys.noteSortMode, 'name');

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

  List<Note> _sortNotes(List<Note> notes) {
    final sortedNotes = List<Note>.from(notes);
    if (_noteSortMode == 'name') {
      sortedNotes.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    } else {
      sortedNotes.sort((a, b) => b.lastModified.compareTo(a.lastModified));
    }
    return sortedNotes;
  }

  String _formatModifiedTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays == 0) {
      return '今天';
    } else if (difference.inDays == 1) {
      return '昨天';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}天前';
    } else if (difference.inDays < 30) {
      return '${difference.inDays ~/ 7}周前';
    } else if (difference.inDays < 365) {
      return '${difference.inDays ~/ 30}月前';
    } else {
      return '${dateTime.year}/${dateTime.month.toString().padLeft(2, '0')}/${dateTime.day.toString().padLeft(2, '0')}';
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
        // 恢复上次选中的笔记
        if (_selectedNotebook != null && _selectedNotebook!.notes.isNotEmpty) {
          _expandedNotebooks.add(_selectedNotebook!.name);
          final lastNoteId = SPUtil.get<String>(PrefKeys.selectedNote, '');
          _selectedNote = lastNoteId.isNotEmpty
              ? _selectedNotebook!.notes.firstWhere(
                  (n) => n.id == lastNoteId,
                  orElse: () => _selectedNotebook!.notes.first,
                )
              : _selectedNotebook!.notes.first;
        }
        // 恢复未同步笔记 id 集合
        final saved = SPUtil.get<String>(PrefKeys.unsyncedNoteIds, '');
        if (saved.isNotEmpty) {
          _unsyncedNoteIds.addAll(saved.split(','));
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
    FileUtil().deleteFile('$workingDirectory/notes', path, filename);

    if (git != null && remoteUrl != null) {
      String sha = git!.hashObject(utf8.encode(note.content));
      final (owner, repo) = git!.getOwnerRepoFromUrl(remoteUrl!);
      git!.deleteFile(owner, repo, noteId, 'Delete note $noteId', sha);
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('笔记已删除')));
  }

  void _persistUnsyncedIds() {
    SPUtil.set<String>(PrefKeys.unsyncedNoteIds, _unsyncedNoteIds.join(','));
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
      // 标记为未同步
      if (git != null && remoteUrl != null) {
        _unsyncedNoteIds.add(updatedNote.id);
        _persistUnsyncedIds();
      }
    });
  }

  void saveNote(Note note) {
    if (git == null || remoteUrl == null) return;
    var (owner, repo) = git!.getOwnerRepoFromUrl(remoteUrl!);
    String path = note.id;
    git
        ?.uploadFile(
          owner,
          repo,
          path,
          utf8.encode(note.content),
          'Update note ${note.title}',
        )
        .then((_) {
          setState(() {
            _unsyncedNoteIds.remove(note.id);
            _persistUnsyncedIds();
          });
        });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // 左侧面板：笔记本和笔记树形列表
          SizedBox(
            width: _sidebarWidth,
            child: Container(
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
          ),
          // 可拖动分隔线
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragUpdate: (details) {
              setState(() {
                _sidebarWidth = (_sidebarWidth + details.delta.dx).clamp(
                  160.0,
                  600.0,
                );
              });
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: Container(
                width: 6,
                color: Colors.transparent,
                child: Center(
                  child: Container(
                    width: 1,
                    color: Theme.of(context).dividerColor,
                  ),
                ),
              ),
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
      padding: EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
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
              // 排序按钮
              IconButton(
                icon: Icon(
                  _noteSortMode == 'name' ? Icons.sort_by_alpha : Icons.access_time,
                  size: 20,
                  color: theme.primaryColor,
                ),
                onPressed: () {
                  setState(() {
                    _noteSortMode = _noteSortMode == 'name' ? 'modified' : 'name';
                    SPUtil.set(PrefKeys.noteSortMode, _noteSortMode);
                  });
                },
                tooltip: _noteSortMode == 'name' ? '按名称排序' : '按时间排序',
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(minWidth: 32, minHeight: 32),
              ),
              if (_selectedNotebook != null)
                IconButton(
                  icon: Icon(Icons.add, size: 20),
                  onPressed: _showCreateNoteDialog,
                  tooltip: '创建笔记',
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              IconButton(
                icon: Icon(Icons.sync, size: 20),
                color: _isSyncing ? Colors.grey : theme.primaryColor,
                onPressed: _performSync,
                tooltip: '同步',
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
          SizedBox(height: 6),
          TextField(
            controller: _searchController,
            style: theme.textTheme.bodySmall,
            decoration: InputDecoration(
              hintText: '搜索所有笔记本...',
              hintStyle: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
              prefixIcon: Icon(Icons.search, size: 16),
              suffixIcon: _currentSearchQuery.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear, size: 14),
                      onPressed: () => _searchController.clear(),
                      padding: EdgeInsets.zero,
                      constraints: BoxConstraints(minWidth: 28, minHeight: 28),
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
              ),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoteTree() {
    return _notebooks.isEmpty
        ? _buildEmptySidebar()
        : ListView(
            padding: EdgeInsets.only(top: 4, bottom: 4),
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
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                children: [
                  ..._sortNotes(notebook.notes).map((note) {
                    final noteIsSelected = _selectedNote?.id == note.id;
                    final isUnsynced = _unsyncedNoteIds.contains(note.id);
                    return InkWell(
                      onTap: () {
                        _detailPanelKey.currentState?._saveScrollPosition(
                          _selectedNote!.id,
                        );
                        setState(() {
                          _selectedNote = note;
                          SPUtil.set(PrefKeys.selectedNote, note.id);
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
                              color: isUnsynced
                                  ? Colors.orange
                                  : theme.iconTheme.color?.withValues(alpha: 0.6),
                            ),
                            SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                note.title,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: noteIsSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: isUnsynced ? Colors.orange : null,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (_noteSortMode == 'modified')
                              Padding(
                                padding: EdgeInsets.only(left: 4),
                                child: Text(
                                  _formatModifiedTime(note.lastModified),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.disabledColor,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                            if (isUnsynced)
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: Colors.orange,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          if (isExpanded && notebook.notes.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 36, vertical: 4),
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
    return _searchResults.isEmpty
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
                  final notebook = _notebooks.firstWhere(
                    (nb) => nb.name == result.notebookName,
                  );
                  final actualNote = notebook.notes.firstWhere(
                    (n) => n.id == result.note.id,
                    orElse: () => result.note,
                  );
                  _detailPanelKey.currentState?._saveScrollPosition(
                    _selectedNote!.id,
                  );
                  setState(() {
                    _selectedNotebook = notebook;
                    _selectedNote = actualNote;
                    SPUtil.set(PrefKeys.selectedNote, actualNote.id);
                    _expandedNotebooks.add(notebook.name);
                  });
                },
              );
            },
          );
  }

  Widget _buildNoteDetail(Note note) {
    return _NoteDetailPanel(
      key: _detailPanelKey,
      note: note,
      notebook: _selectedNotebook!,
      onNoteChanged: noteChanged,
      saveNote: saveNote,
      onDeleteNote: _deleteNote,
      searchQuery: _currentSearchQuery,
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
                              // 展开笔记本并标记新笔记为未同步
                              _expandedNotebooks.add(_selectedNotebook!.name);
                              _unsyncedNoteIds.add(notes.last.id);
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
                  _unsyncedNoteIds.clear();
                  _persistUnsyncedIds();
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
  final String searchQuery;

  const _NoteDetailPanel({
    super.key,
    required this.note,
    required this.notebook,
    required this.onNoteChanged,
    required this.saveNote,
    required this.onDeleteNote,
    required this.onTitleChanged,
    this.searchQuery = '',
  });

  @override
  State<_NoteDetailPanel> createState() => _NoteDetailPanelState();
}

class _NoteDetailPanelState extends State<_NoteDetailPanel> {
  late TextEditingController _titleController;
  late CodeLineEditingController _contentController;
  late CodeFindController _findController;
  Timer? _saveTimer;

  late CodeScrollController _codeScrollController;
  final ScrollController _previewScrollController = ScrollController();
  bool _isSyncingScroll = false;
  bool _showLineNumbers = true;
  Timer? _scrollSaveTimer;

  // 视图模式：edit(普通编辑), split(分栏预览), preview(预览)
  String _viewMode = 'edit';

  // 分栏比例（编辑区占比）
  double _splitRatio = 0.5;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: widget.note.title.replaceAll('.md', ''),
    );
    _contentController = CodeLineEditingController.fromText(
      widget.note.content,
    );
    _showLineNumbers = SPUtil.get<bool>(PrefKeys.showLineNumbers, true);
    _findController = CodeFindController(_contentController);
    _codeScrollController = CodeScrollController(
      verticalScroller: ScrollController(),
    );
    _contentController.addListener(_onContentChanged);
    _codeScrollController.verticalScroller.addListener(_onEditorScrolled);
    _previewScrollController.addListener(_onPreviewScrolled);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 等 scroller 有 clients 后再恢复位置
      _tryRestoreScrollPosition(widget.note.id, 0);
    });
  }

  @override
  void didUpdateWidget(_NoteDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.note.id != widget.note.id) {
      _titleController.text = widget.note.title.replaceAll('.md', '');
      _contentController.text = widget.note.content;
      _viewMode = 'edit';
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _tryRestoreScrollPosition(widget.note.id, 0),
      );
    }
  }

  @override
  void dispose() {
    // dispose 前 scroller 还有 clients，先保存位置
    _saveScrollPosition(widget.note.id);
    _saveTimer?.cancel();
    _scrollSaveTimer?.cancel();
    _contentController.removeListener(_onContentChanged);
    _codeScrollController.verticalScroller.removeListener(_onEditorScrolled);
    _previewScrollController.removeListener(_onPreviewScrolled);
    _titleController.dispose();
    _contentController.dispose();
    _findController.dispose();
    _codeScrollController.verticalScroller.dispose();
    _codeScrollController.dispose();
    _previewScrollController.dispose();
    super.dispose();
  }

  String _scrollKey(String noteId) =>
      '${PrefKeys.scrollPosPrefix}${noteId.replaceAll('/', '_')}';

  // 行高 = fontSize * fontHeight = 14 * 1.6
  static const double _lineHeight = 14 * 1.6;

  void _tryRestoreScrollPosition(String noteId, int attempt) {
    if (!mounted) return;
    final scroller = _codeScrollController.verticalScroller;
    if (!scroller.hasClients) {
      // 还没渲染好，最多重试 10 次
      if (attempt < 10) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _tryRestoreScrollPosition(noteId, attempt + 1),
        );
      }
      return;
    }
    _restoreScrollPosition(noteId);
  }

  void _saveScrollPosition(String noteId) {
    final scroller = _codeScrollController.verticalScroller;
    if (!scroller.hasClients) return;
    final firstVisibleLine = (scroller.offset / _lineHeight).floor();
    if (firstVisibleLine > 0) {
      SPUtil.set<int>(_scrollKey(noteId), firstVisibleLine);
    }
  }

  void _restoreScrollPosition(String noteId) {
    final line = SPUtil.get<int>(_scrollKey(noteId), 0);
    if (line <= 0) return;
    final scroller = _codeScrollController.verticalScroller;
    if (!scroller.hasClients) return;
    final targetOffset = line * _lineHeight;
    scroller.jumpTo(targetOffset);
  }

  void _onEditorScrolled() {
    if (_isSyncingScroll) {
      return;
    }
    final vertScroller = _codeScrollController.verticalScroller;
    if (!vertScroller.hasClients || !_previewScrollController.hasClients) {
      return;
    }
    final editorMax = vertScroller.position.maxScrollExtent;
    if (editorMax <= 0) return;
    final ratio = vertScroller.offset / editorMax;
    final previewMax = _previewScrollController.position.maxScrollExtent;
    _isSyncingScroll = true;
    _previewScrollController.jumpTo(ratio * previewMax);
    _isSyncingScroll = false;

    // 节流保存滚动位置（2秒内只写一次）
    _scrollSaveTimer?.cancel();
    _scrollSaveTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) _saveScrollPosition(widget.note.id);
    });
  }

  void _onPreviewScrolled() {
    if (_isSyncingScroll) {
      return;
    }
    final vertScroller = _codeScrollController.verticalScroller;
    if (!vertScroller.hasClients || !_previewScrollController.hasClients) {
      return;
    }
    final previewMax = _previewScrollController.position.maxScrollExtent;
    if (previewMax <= 0) return;
    final ratio = _previewScrollController.offset / previewMax;
    final editorMax = vertScroller.position.maxScrollExtent;
    _isSyncingScroll = true;
    vertScroller.jumpTo(ratio * editorMax);
    _isSyncingScroll = false;
  }

  void _onContentChanged() {
    final newContent = _contentController.text;
    if (newContent != widget.note.content) {
      widget.note.content = newContent;
      widget.note.lastModified = DateTime.now();

      // 延迟到 build 完成后再通知父级，避免在 build 阶段触发父级 setState
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onNoteChanged(widget.note);
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

  void _switchViewMode(String newMode) {
    if (_viewMode == newMode) return;

    // 保存当前内容（仅内容有变化时才标记未同步）
    if (_viewMode == 'edit') {
      final newContent = _contentController.text;
      final changed = newContent != widget.note.content;
      widget.note.content = newContent;
      _saveContentToFile();
      if (changed) widget.onNoteChanged(widget.note);
    }

    setState(() {
      _viewMode = newMode;
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
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
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
                // 分栏预览按钮
                IconButton(
                  icon: Icon(
                    Icons.vertical_split,
                    color: _viewMode == 'split'
                        ? theme.primaryColor
                        : (isDark ? theme.disabledColor : Colors.grey),
                  ),
                  onPressed: () => _switchViewMode('split'),
                  tooltip: '分栏预览',
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
                  tooltip: '保存 (Ctrl+S)',
                ),
                if (_viewMode == 'preview' || _viewMode == 'split')
                  IconButton(
                    icon: Icon(Icons.copy_all),
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: widget.note.content),
                      );
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('已复制全文')));
                    },
                    tooltip: '复制全文',
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
          // 笔记内容编辑区
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: _viewMode == 'edit'
                  ? _buildEditor(theme)
                  : _viewMode == 'split'
                  ? _buildSplitView(theme)
                  : _buildPreview(theme),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditor(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight;
        return CodeEditor(
          controller: _contentController,
          scrollController: _codeScrollController,
          findController: _findController,
          wordWrap: true,
          padding: EdgeInsets.only(bottom: viewportHeight),
          shortcutOverrideActions: <Type, Action<Intent>>{
            CodeShortcutSaveIntent: CallbackAction<CodeShortcutSaveIntent>(
              onInvoke: (intent) {
                widget.saveNote(widget.note);
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('笔记已保存')));
                return null;
              },
            ),
          },
          style: CodeEditorStyle(
            fontSize: 14,
            fontHeight: 1.6,
            fontFamily: 'monospace',
            textColor: isDark
                ? const Color(0xFFE8E8E8)
                : const Color(0xFF1A1A1A),
            backgroundColor: isDark
                ? Color.fromARGB(255, 48, 48, 48)
                : const Color(0xFFFFFFFF),
            highlightColor: Colors.yellow.withValues(alpha: 0.5),
            selectionColor: Colors.orange.withValues(alpha: 0.6),
            codeTheme: CodeHighlightTheme(
              languages: {
                'markdown': CodeHighlightThemeMode(mode: langMarkdown),
              },
              theme: isDark ? atomOneDarkTheme : atomOneLightTheme,
            ),
          ),
          findBuilder: (context, controller, readOnly) =>
              _FindPanel(controller: controller),
          indicatorBuilder:
              (context, editingController, chunkController, notifier) {
                return GestureDetector(
                  onSecondaryTapUp: (details) =>
                      _showLineNumberMenu(details.globalPosition),
                  child: _showLineNumbers
                      ? Container(
                          padding: const EdgeInsets.only(right: 8),
                          child: DefaultCodeLineNumber(
                            controller: editingController,
                            notifier: notifier,
                            textStyle: TextStyle(
                              fontSize: 12,
                              color: theme.textTheme.bodySmall?.color
                                  ?.withValues(alpha: 0.5),
                            ),
                          ),
                        )
                      : Container(width: 12, color: Colors.transparent),
                );
              },
        );
      },
    );
  }

  void _showLineNumberMenu(Offset position) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<bool>(
          value: true,
          child: Row(
            children: [
              Icon(
                _showLineNumbers ? Icons.visibility_off : Icons.visibility,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(_showLineNumbers ? '隐藏行号' : '显示行号'),
            ],
          ),
        ),
      ],
    ).then((selected) {
      if (selected == true) {
        setState(() => _showLineNumbers = !_showLineNumbers);
        SPUtil.set(PrefKeys.showLineNumbers, _showLineNumbers);
      }
    });
  }

  Widget _buildSplitView(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final dividerWidth = 6.0;
        final editWidth = (totalWidth - dividerWidth) * _splitRatio;
        final previewWidth = (totalWidth - dividerWidth) * (1 - _splitRatio);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: editWidth, child: _buildEditor(theme)),
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (details) {
                setState(() {
                  _splitRatio =
                      ((_splitRatio * (totalWidth - dividerWidth) +
                                  details.delta.dx) /
                              (totalWidth - dividerWidth))
                          .clamp(0.2, 0.8);
                });
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: Container(
                  width: dividerWidth,
                  color: Colors.transparent,
                  child: Center(
                    child: Container(width: 1, color: theme.dividerColor),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: previewWidth,
              child: Padding(
                padding: EdgeInsets.only(left: 12),
                child: fm.Markdown(
                  data: _contentController.text,
                  selectable: true,
                  controller: _previewScrollController,
                  imageDirectory: SPUtil.get<String>(
                    PrefKeys.workingDirectory,
                    '',
                  ),
                  styleSheet: fm.MarkdownStyleSheet.fromTheme(theme).copyWith(
                    p: theme.textTheme.bodyMedium,
                    h1: theme.textTheme.headlineMedium,
                    h2: theme.textTheme.titleLarge,
                    h3: theme.textTheme.titleMedium,
                    code: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                    ),
                    codeblockDecoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
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

// 查找面板 UI
class _FindPanel extends StatefulWidget implements PreferredSizeWidget {
  final CodeFindController controller;

  const _FindPanel({required this.controller});

  @override
  Size get preferredSize =>
      controller.value != null ? const Size.fromHeight(52) : Size.zero;

  @override
  State<_FindPanel> createState() => _FindPanelState();
}

class _FindPanelState extends State<_FindPanel> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<CodeFindValue?>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        if (value == null) return const SizedBox.shrink();
        final result = value.result;
        final total = result?.matches.length ?? 0;
        final current = result != null && total > 0 ? (result.index + 1) : 0;
        return Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.cardColor,
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 220,
                child: TextField(
                  controller: widget.controller.findInputController,
                  focusNode: widget.controller.findInputFocusNode,
                  style: theme.textTheme.bodySmall,
                  decoration: InputDecoration(
                    hintText: '查找...',
                    hintStyle: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                total > 0 ? '$current/$total' : '无匹配',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                onPressed: widget.controller.previousMatch,
                tooltip: '上一个',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                onPressed: widget.controller.nextMatch,
                tooltip: '下一个',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: widget.controller.close,
                tooltip: '关闭',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ],
          ),
        );
      },
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
