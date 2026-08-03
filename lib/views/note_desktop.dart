import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ashes_note/logging.dart';
import 'package:ashes_note/utils/const.dart';
import 'package:ashes_note/utils/file_util.dart';
import 'package:ashes_note/utils/git_service.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:ashes_note/models/notes/note_index_models.dart';
import 'package:ashes_note/services/notes/notes_index_service.dart';
import 'package:ashes_note/services/notes/wiki_link_parser.dart' as wiki;
import 'package:ashes_note/views/notes/backlinks_panel.dart';
import 'package:ashes_note/views/notes/note_graph_view.dart';
import 'package:ashes_note/views/notes/tag_editor_bar.dart';
import 'package:ashes_note/views/notes/tag_filter_panel.dart';
import 'package:ashes_note/views/notes/wiki_link_autocomplete.dart';
import 'package:ashes_note/views/notes/wiki_markdown_view.dart';
import 'package:ashes_note/views/blog_export_dialog.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

/// 懒加载并缓存「注入了全角引号规则的 markdown 语言模式」。
///
/// 为全角引号/书名号/方头括号（“” ‘’ 「」『』 【】 《》）单独分配高亮作用域，
/// 在编辑器中与半角引号（" '）明显区分。
///
/// 关键设计：深克隆 re_highlight 的全局 `langMarkdown` 单例，再注入规则。
/// 绝不直接改动全局单例——否则一旦该单例被（任何代码路径）提前编译
/// （`isCompiled = true`），后续注入会静默失效；热重载 / 多编辑器实例时
/// 全局单例状态也不可控。克隆出独立副本后，注入与编译时机完全由本编辑器掌控。
Mode? _markdownFwCache;

Mode get markdownWithFullwidthQuote {
  final cached = _markdownFwCache;
  if (cached != null) return cached;

  final quoteMode = Mode(
    // 注意：不能用原始字符串 r'...'，否则 \uXXXX 不会被解释成全角字符，
    // 而是被当成字面量的反斜杠+u+数字，导致全角引号永远匹配不上。
    // 用普通字符串让 \u 转义生效，同时避免源码直接写全角字符被「智能标点」改写。
    // 覆盖："" '' 「」『』 【】 《》 等常见全角引号/书名号/方头括号。
    //
    // 必须用 begin/end 形式而非 match-only：re_highlight 的 Dart 移植版不会把
    // match-only 规则应用到 begin/end 模式的内部内容（节点无法自闭合会被吞掉），
    // 但 begin/end 模式正常工作。这里用零宽断言 (?=) 作 end，使节点匹配单个
    // 引号字符后立即闭合，等价于「单字符 token」。
    begin:
        '[\u201c\u201d\u2018\u2019\u300c\u300d\u300e\u300f\u3010\u3011\u300a\u300b]',
    end: r'(?=)',
    scope: 'fullwidth-quote',
  );

  // 双链 [[...]]：整段（含双括号）作为一个 token 显色，与正文区分。
  final wikiLinkMode = Mode(
    begin: r'\[\[[^\[\]\n]*',
    end: r'\]\]',
    scope: 'wiki-link',
  );

  // 深克隆，断开与全局单例的所有共享引用（contains / refs / variants）。
  // 同时强制 isCompiled=false：copyWith 会原样拷贝单例的 isCompiled，
  // 若全局单例曾在任何路径下被提前编译，克隆会继承 isCompiled=true，
  // 导致 re_highlight 编译时直接跳过、注入静默失效。这里彻底清零。
  final visited = <Mode>{};
  Mode deepClone(Mode m) {
    if (!visited.add(m)) {
      // 理论上 markdown 无环，但保险起见：已访问则直接浅拷贝返回，避免无限递归。
      final shallow = m.copyWith();
      shallow.isCompiled = false;
      return shallow;
    }
    final c = m.copyWith();
    c.isCompiled = false;
    if (m.contains is List) {
      c.contains = (m.contains as List)
          .map((e) => e is Mode ? deepClone(e) : e)
          .toList();
    }
    if (m.refs is Map) {
      c.refs = (m.refs as Map).map(
        (k, v) => MapEntry(k, v is Mode ? deepClone(v) : v),
      );
    }
    if (m.variants is List) {
      c.variants = (m.variants as List)
          .map((e) => e is Mode ? deepClone(e) : e)
          .toList();
    }
    return c;
  }

  final cloned = deepClone(langMarkdown);

  // 把全角引号规则插入到「每一个」带 contains 的 mode 最前（最高优先级）。
  //
  // 关键点：markdown 的强调（*…* / **…**）、链接、标题等是「嵌套子模式」，
  // 它们通过 `ref` 引用 refs 映射里真正的 mode 定义；当前 mode 的 contains 中
  // 那些 `Mode(ref: '…')` 本身没有 contains，真正的规则在 cloned.refs[key] 中。
  // 编译期 extractRef 会按 language.refs 解析 ref，所以必须同时把引号规则注入到
  // refs 映射里的对应 mode。否则一旦文本进入未闭合的强调（例如命令里的 `*.jar`
  // 被当成斜体开头），后续引号就掉进强调子模式、因子模式无引号规则而不显色。
  final refsMap = (cloned.refs is Map)
      ? (cloned.refs as Map)
      : <String, dynamic>{};
  final injected = <Mode>{};
  void injectAll(Mode mode) {
    if (!injected.add(mode)) return; // 防止环（emphasis 与 strong 互相引用）
    if (mode.contains is List) {
      final list = mode.contains as List;
      // 插入前先拍快照，避免遍历到刚插入的引号模式自身
      final snapshot = List<dynamic>.from(list);
      // 每个父模式前插一个全新的引号模式副本，避免同一实例被多处共享、
      // 编译期 isCompiled / 正则状态互相污染。
      list.insert(0, wikiLinkMode.copyWith()..isCompiled = false);
      list.insert(0, quoteMode.copyWith()..isCompiled = false);
      for (final c in snapshot) {
        if (c is Mode) {
          if (c.ref != null) {
            final refMode = refsMap[c.ref];
            if (refMode is Mode) injectAll(refMode);
          } else {
            injectAll(c);
          }
        }
      }
    }
    // section（标题）等模式只有 variants 没有 contains，需单独处理其 variants，
    // 否则标题内的全角引号也不会显色。emphasis/strong 的 variants 多为纯
    // begin/end（无 contains），此处处理为 no-op，无副作用。
    if (mode.variants is List) {
      for (final v in List<dynamic>.from(mode.variants as List)) {
        if (v is Mode) injectAll(v);
      }
    }
  }

  injectAll(cloned);
  _markdownFwCache = cloned;
  return cloned;
}

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

  // 笔记排序模式：'name_asc'(名称升序), 'name_desc'(名称降序), 'modified_asc'(时间升序), 'modified_desc'(时间降序)
  String _noteSortMode = 'name_asc';

  // 打开的本地文件列表
  final List<_LocalFileInfo> _localFiles = [];

  // 标签筛选条件（左侧栏已无 tab，标签入口改为顶部按钮 + 弹窗）

  // 标签筛选条件
  Set<String> _selectedTags = <String>{};
  bool _tagMatchAll = false;

  /// 笔记索引（双向链接 + 标签），全局单例。
  final NotesIndexService _index = NotesIndexService();

  /// notes 目录路径，标签索引文件存于其下的 .ashes/。
  String get _notesRoot => '$workingDirectory/notes';

  @override
  void initState() {
    super.initState();
    workingDirectory = SPUtil.get<String>(PrefKeys.workingDirectory, '');
    String gitPlatform = SPUtil.get<String>(PrefKeys.gitPlatform, '');
    _noteSortMode = SPUtil.get<String>(PrefKeys.noteSortMode, 'name');

    // 恢复标签筛选条件
    _tagMatchAll = SPUtil.get<bool>(PrefKeys.noteTagFilterMatchAll, false);
    final savedTags = SPUtil.get<String>(PrefKeys.noteTagFilter, '');
    if (savedTags.isNotEmpty) {
      _selectedTags = savedTags.split(',').where((e) => e.isNotEmpty).toSet();
    }
    _index.addListener(_onIndexChanged);

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

      // 恢复未同步笔记 id 集合
      final saved = SPUtil.get<String>(PrefKeys.unsyncedNoteIds, '');
      if (saved.isNotEmpty) {
        _unsyncedNoteIds.addAll(saved.split(','));
      }

      String lastPullTime = SPUtil.get(PrefKeys.lastPullTime, '');
      var (owner, repo) = git!.getOwnerRepoFromUrl(remoteUrl!);
      if (lastPullTime == '') {
        git!
            .pull(owner, repo, notesDir.path, unsyncedIds: _unsyncedNoteIds)
            .then((_) {
              SPUtil.set(
                PrefKeys.lastPullTime,
                DateTime.now().toIso8601String(),
              );
            });
        _loadNotebookList();
      } else {
        git!.getCommits(owner, repo, since: lastPullTime).then((
          List<Map<String, dynamic>> commits,
        ) {
          if (commits.isNotEmpty) {
            git!
                .pull(owner, repo, notesDir.path, unsyncedIds: _unsyncedNoteIds)
                .then((_) {
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
    _index.removeListener(_onIndexChanged);
    // 退出前把标签索引落盘，避免防抖窗口内的改动丢失。
    _index.flushTags();
    super.dispose();
  }

  /// 索引变更后刷新界面（标签计数、反链数量等）。
  void _onIndexChanged() {
    if (mounted) setState(() {});
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

    // 解析 tag: 语法，例如 "tag:读书 卡片" = 有「读书」标签且含「卡片」关键字。
    final parsed = wiki.parseSearchQuery(query);
    final keyword = parsed.keyword.toLowerCase();

    // 有标签条件时先用倒排表取出候选集合，避免遍历全部笔记。
    Set<String>? tagMatchedIds;
    if (parsed.tags.isNotEmpty) {
      tagMatchedIds = _index.notesOfTags(parsed.tags, matchAll: true);
      if (tagMatchedIds.isEmpty) return;
    }

    for (final notebook in _notebooks) {
      for (final note in notebook.notes) {
        if (tagMatchedIds != null && !tagMatchedIds.contains(note.id)) {
          continue;
        }

        // 仅有标签条件时，命中标签即算命中。
        if (keyword.isEmpty) {
          if (tagMatchedIds != null) {
            _searchResults.add(
              GlobalSearchResult(
                note: note,
                notebookName: notebook.name,
                matchType: '标签',
              ),
            );
          }
          continue;
        }

        final titleMatch = note.title.toLowerCase().contains(keyword);
        final contentMatch = note.content.toLowerCase().contains(keyword);

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
    switch (_noteSortMode) {
      case 'name_asc':
        sortedNotes.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      case 'name_desc':
        sortedNotes.sort(
          (a, b) => b.title.toLowerCase().compareTo(a.title.toLowerCase()),
        );
      case 'modified_asc':
        sortedNotes.sort((a, b) => a.lastModified.compareTo(b.lastModified));
      case 'modified_desc':
        sortedNotes.sort((a, b) => b.lastModified.compareTo(a.lastModified));
      default:
        sortedNotes.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
    }
    return sortedNotes;
  }

  String _getSortTooltip() {
    switch (_noteSortMode) {
      case 'name_asc':
        return '按名称升序';
      case 'name_desc':
        return '按名称降序';
      case 'modified_asc':
        return '按时间升序';
      case 'modified_desc':
        return '按时间降序';
      default:
        return '按名称升序';
    }
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

    // 笔记全部载入内存后重建索引：链接图直接复用已读到的正文，无需二次 I/O。
    await _index.rebuild(_notebooks, notesRootPath: _notesRoot);
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
                  .then((notes) async {
                    for (var note in notes) {
                      try {
                        final fileInfo = await git!.getFile(
                          owner,
                          repo,
                          note.id,
                        );
                        final remoteSha = fileInfo['sha'] as String?;
                        if (remoteSha != null && remoteSha.isNotEmpty) {
                          await git?.deleteFile(
                            owner,
                            repo,
                            note.id,
                            '删除笔记本 ${note.id}',
                            remoteSha,
                          );
                        }
                      } catch (_) {
                        // 如果远端不存在或获取失败，跳过删除
                      }
                    }
                  })
                  .then((_) {
                    FileUtil().deleteDirectory(
                      '$workingDirectory/notes',
                      notebookName,
                    );
                  });

              // 同步清理该笔记本下所有笔记的链接与标签记录。
              _index.onNotebookDeleted(notebookName);

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
    _selectedNotebook!.notes.firstWhere((note) => note.id == noteId);
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

    // 摘除链接图中的出/入链，并清理该笔记的标签记录。
    _index.onNoteDeleted(noteId);

    if (git != null && remoteUrl != null) {
      final (owner, repo) = git!.getOwnerRepoFromUrl(remoteUrl!);
      git!
          .getFile(owner, repo, noteId)
          .then((fileInfo) {
            final remoteSha = fileInfo['sha'] as String?;
            if (remoteSha != null && remoteSha.isNotEmpty) {
              git!.deleteFile(
                owner,
                repo,
                noteId,
                'Delete note $noteId',
                remoteSha,
              );
            }
          })
          .catchError((_) {
            // 远端文件不存在或获取失败，忽略远端删除
          });
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('笔记已删除')));
  }

  void _persistUnsyncedIds() {
    SPUtil.set<String>(PrefKeys.unsyncedNoteIds, _unsyncedNoteIds.join(','));
  }

  void noteChanged(Note updatedNote, {String? newTitle}) {
    // 如果是本地文件，直接保存到磁盘
    if (updatedNote.notebookName == '__local_file__') {
      final fileInfo = _localFiles.cast<_LocalFileInfo?>().firstWhere(
        (lf) => lf?.filePath == updatedNote.id,
        orElse: () => null,
      );
      if (fileInfo != null) {
        _saveLocalFile(fileInfo, updatedNote.content);
      }
      return;
    }

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
      final newFileName = newTitle.endsWith('.md') ? newTitle : '$newTitle.md';

      final oldNoteId = '${_selectedNotebook!.name}/$oldTitle';

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

      // 如果 git 已配置，删除远程的旧笔记文件
      if (git != null && remoteUrl != null) {
        final (owner, repo) = git!.getOwnerRepoFromUrl(remoteUrl!);
        git!
            .getFile(owner, repo, oldNoteId)
            .then((fileInfo) {
              final remoteSha = fileInfo['sha'] as String?;
              if (remoteSha != null && remoteSha.isNotEmpty) {
                git!.deleteFile(
                  owner,
                  repo,
                  oldNoteId,
                  'Rename note to $newFileName',
                  remoteSha,
                );
              }
            })
            .catchError((_) {
              // 远端文件不存在或获取失败，忽略远端删除
            });
      }

      setState(() {
        final index = _selectedNotebook!.notes.indexWhere(
          (note) => note.id == oldNoteId,
        );
        if (index != -1) {
          _selectedNotebook!.notes[index] = updatedNote;
        }
        if (_selectedNote?.id == oldNoteId) {
          _selectedNote = updatedNote;
        }
        // 标记新笔记为未同步
        if (git != null && remoteUrl != null) {
          _unsyncedNoteIds.add(updatedNote.id);
          _persistUnsyncedIds();
        }
      });

      // 迁移标签、重算受影响的反链（指向旧标题的链接会变为未解析）。
      _index.onNoteRenamed(
        oldNoteId,
        updatedNote,
        notebookName: _selectedNotebook!.name,
      );
    } else {
      setState(() {
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

      // 增量重算本篇出链，反链表随之差分更新。
      _index.onNoteSaved(updatedNote, notebookName: _selectedNotebook!.name);
    }
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

  /// 左侧栏「笔记 / 标签」页签。
  Widget _buildTagPanel() {
    return TagFilterPanel(
      selectedTags: _selectedTags,
      matchAll: _tagMatchAll,
      onSelectionChanged: (tags) {
        setState(() => _selectedTags = tags);
        SPUtil.set<String>(PrefKeys.noteTagFilter, tags.join(','));
      },
      onMatchModeChanged: (matchAll) {
        setState(() => _tagMatchAll = matchAll);
        SPUtil.set<bool>(PrefKeys.noteTagFilterMatchAll, matchAll);
      },
    );
  }

  /// 以弹出窗口形式展示标签筛选面板。
  void _showTagFilterDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('标签筛选'),
        content: SizedBox(
          width: 360,
          child: _buildTagPanel(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  /// 按当前标签筛选条件过滤笔记列表。
  List<Note> _applyTagFilter(List<Note> notes) {
    if (_selectedTags.isEmpty) return notes;
    final allowed = _index.notesOfTags(_selectedTags, matchAll: _tagMatchAll);
    return notes.where((n) => allowed.contains(n.id)).toList();
  }

  /// 统一的笔记跳转入口：处理跨笔记本切换与不存在时的创建。
  ///
  /// 所有来自预览链接、反链面板、图谱的跳转都必须走这里，
  /// 以避免各处重复处理空值与笔记本切换逻辑。
  void _openNoteByRef(NoteRef ref) {
    for (final notebook in _notebooks) {
      for (final note in notebook.notes) {
        if (note.id != ref.id) continue;

        setState(() {
          _selectedNotebook = notebook;
          _selectedNote = note;
          _expandedNotebooks.add(notebook.name);
          // 跳转后关闭搜索结果，让左侧树定位到目标笔记。
          _showSearchResults = false;
          _searchController.clear();
        });
        SPUtil.set<String>(PrefKeys.selectedNotebook, notebook.name);
        SPUtil.set<String>(PrefKeys.selectedNote, note.id);
        return;
      }
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('未找到笔记：${ref.displayTitle}')));
  }

  /// 处理预览中点击 `[[...]]` 的跳转意图。
  Future<void> _handleOpenIntent(wiki.OpenNoteIntent intent) async {
    if (intent.ambiguous) {
      await _pickAmbiguousTarget(intent.rawTarget);
      return;
    }

    final noteId = intent.noteId;
    if (intent.exists && noteId != null) {
      _openNoteByRef(NoteRef.fromId(noteId));
      return;
    }

    await _confirmCreateLinkedNote(intent.rawTarget);
  }

  /// 同名笔记消歧：弹出候选让用户选择。
  Future<void> _pickAmbiguousTarget(String rawTarget) async {
    final resolution = _index.resolve(
      rawTarget,
      currentNotebook: _selectedNotebook?.name,
    );
    if (resolution is! LinkAmbiguous) {
      if (resolution is LinkResolved) _openNoteByRef(resolution.target);
      return;
    }

    final picked = await showDialog<NoteRef>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('「$rawTarget」有多篇同名笔记'),
        children: resolution.candidates
            .map(
              (c) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, c),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.description_outlined, size: 18),
                  title: Text(c.displayTitle),
                  subtitle: Text(c.notebookName),
                ),
              ),
            )
            .toList(),
      ),
    );

    if (picked != null) _openNoteByRef(picked);
  }

  /// 链接目标不存在时，确认后创建空笔记并跳转。
  Future<void> _confirmCreateLinkedNote(String rawTarget) async {
    final resolution = _index.resolve(
      rawTarget,
      currentNotebook: _selectedNotebook?.name,
    );
    final missing = resolution is LinkMissing
        ? resolution
        : LinkMissing(rawTarget, _selectedNotebook?.name);

    final targetNotebook =
        missing.suggestedNotebook ??
        _selectedNotebook?.name ??
        (_notebooks.isNotEmpty ? _notebooks.first.name : null);

    if (targetNotebook == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先创建一个笔记本')));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('创建笔记'),
        content: Text(
          '笔记「${missing.suggestedTitle}」不存在，是否在「$targetNotebook」中创建？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _createNoteAt(targetNotebook, missing.suggestedTitle);
  }

  /// 在指定笔记本下创建一篇空笔记，并选中它。
  Future<void> _createNoteAt(String notebookName, String rawTitle) async {
    final fileName = ensureMdSuffix(rawTitle);
    final noteId = '$notebookName/$fileName';

    final notebook = _notebooks.cast<Notebook?>().firstWhere(
      (n) => n?.name == notebookName,
      orElse: () => null,
    );
    if (notebook == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('笔记本「$notebookName」不存在')));
      return;
    }

    if (notebook.notes.any((n) => n.id == noteId)) {
      _openNoteByRef(NoteRef.fromId(noteId));
      return;
    }

    final newNote = Note(
      id: noteId,
      title: fileName,
      content: '',
      lastModified: DateTime.now(),
      notebookName: notebookName,
    );

    await FileUtil().saveFile(
      '$workingDirectory/notes',
      notebookName,
      fileName,
      utf8.encode(''),
    );

    if (!mounted) return;
    setState(() {
      notebook.notes.add(newNote);
      _selectedNotebook = notebook;
      _selectedNote = newNote;
      _expandedNotebooks.add(notebookName);
      if (git != null && remoteUrl != null) {
        _unsyncedNoteIds.add(noteId);
        _persistUnsyncedIds();
      }
    });

    // 新笔记可能让此前指向它的「未解析链接」立即生效。
    _index.onNoteSaved(newNote, notebookName: notebookName);
    SPUtil.set<String>(PrefKeys.selectedNote, noteId);
  }

  void _showGraph() {
    NoteGraphView.show(
      context,
      focusNoteId: _selectedNote?.id,
      onOpenNote: (ref) {
        Navigator.of(context).maybePop();
        _openNoteByRef(ref);
      },
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
              // 标签筛选按钮（与排序同排，点击弹出筛选框）
              Stack(
                alignment: Alignment.topRight,
                children: [
                  IconButton(
                    icon: const Icon(Icons.sell_outlined, size: 20),
                    onPressed: _showTagFilterDialog,
                    tooltip: '标签筛选',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                  if (_selectedTags.isNotEmpty)
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: theme.primaryColor,
                          shape: BoxShape.circle,
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 14,
                          minHeight: 14,
                        ),
                        child: Text(
                          _selectedTags.length.toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              ),
              // 排序按钮
              PopupMenuButton<String>(
                icon: Icon(
                  _noteSortMode.startsWith('name')
                      ? Icons.sort_by_alpha
                      : Icons.access_time,
                  size: 20,
                  color: theme.primaryColor,
                ),
                tooltip: _getSortTooltip(),
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(minWidth: 32, minHeight: 32),
                onSelected: (value) {
                  setState(() {
                    _noteSortMode = value;
                    SPUtil.set(PrefKeys.noteSortMode, _noteSortMode);
                  });
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'name_asc',
                    child: Row(
                      children: [
                        Icon(Icons.sort_by_alpha, size: 16),
                        SizedBox(width: 8),
                        Text('按名称升序'),
                        if (_noteSortMode == 'name_asc')
                          Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: Icon(
                              Icons.check,
                              size: 16,
                              color: theme.primaryColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'name_desc',
                    child: Row(
                      children: [
                        Icon(Icons.sort_by_alpha, size: 16),
                        SizedBox(width: 8),
                        Text('按名称降序'),
                        if (_noteSortMode == 'name_desc')
                          Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: Icon(
                              Icons.check,
                              size: 16,
                              color: theme.primaryColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'modified_asc',
                    child: Row(
                      children: [
                        Icon(Icons.access_time, size: 16),
                        SizedBox(width: 8),
                        Text('按时间升序'),
                        if (_noteSortMode == 'modified_asc')
                          Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: Icon(
                              Icons.check,
                              size: 16,
                              color: theme.primaryColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'modified_desc',
                    child: Row(
                      children: [
                        Icon(Icons.access_time, size: 16),
                        SizedBox(width: 8),
                        Text('按时间降序'),
                        if (_noteSortMode == 'modified_desc')
                          Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: Icon(
                              Icons.check,
                              size: 16,
                              color: theme.primaryColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              // 创建笔记 / 打开本地文件 合并为一个菜单
              PopupMenuButton<String>(
                icon: const Icon(Icons.add, size: 20),
                tooltip: '新建 / 打开',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onSelected: (value) {
                  if (value == 'note') {
                    _showCreateNoteDialog();
                  } else if (value == 'local') {
                    _openLocalFile();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'note',
                    enabled: _selectedNotebook != null,
                    child: const Row(
                      children: [
                        Icon(Icons.note_add, size: 18),
                        SizedBox(width: 8),
                        Text('创建笔记'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'local',
                    child: Row(
                      children: [
                        Icon(Icons.folder_open, size: 18),
                        SizedBox(width: 8),
                        Text('打开本地文件'),
                      ],
                    ),
                  ),
                ],
              ),
              IconButton(
                icon: Icon(Icons.hub_outlined, size: 20),
                onPressed: _showGraph,
                tooltip: '关系图谱',
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
            children: [
              ..._notebooks.map((notebook) {
                return _buildNotebookItem(notebook);
              }),
              if (_localFiles.isNotEmpty) _buildLocalFilesSection(),
            ],
          );
  }

  /// 构建本地文件区域
  Widget _buildLocalFilesSection() {
    final theme = Theme.of(context);
    return Container(
      margin: EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.attach_file, size: 16, color: Colors.orange),
                SizedBox(width: 8),
                Text(
                  '打开的本地文件',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.orange.shade700,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, indent: 12, endIndent: 12),
          ..._localFiles.map((file) => _buildLocalFileItem(file)),
        ],
      ),
    );
  }

  /// 构建单个本地文件项
  Widget _buildLocalFileItem(_LocalFileInfo fileInfo) {
    final theme = Theme.of(context);
    final isSelected =
        _selectedNote?.id == fileInfo.filePath &&
        _selectedNote?.notebookName == '__local_file__';

    return InkWell(
      onTap: () {
        _openLocalFileInEditor(fileInfo);
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.primaryColor.withValues(alpha: 0.1)
              : Colors.transparent,
        ),
        child: Row(
          children: [
            Icon(
              Icons.description_outlined,
              size: 16,
              color: isSelected ? theme.primaryColor : Colors.orange.shade400,
            ),
            SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileInfo.fileName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    fileInfo.filePath,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 10,
                      color: theme.disabledColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            InkWell(
              onTap: () => _closeLocalFile(fileInfo),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 14, color: theme.disabledColor),
              ),
            ),
          ],
        ),
      ),
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
                  ..._applyTagFilter(_sortNotes(notebook.notes)).map((note) {
                    final noteIsSelected = _selectedNote?.id == note.id;
                    final isUnsynced = _unsyncedNoteIds.contains(note.id);
                    return InkWell(
                      onTap: () {
                        final current = _selectedNote;
                        if (current != null) {
                          _detailPanelKey.currentState?._saveScrollPosition(
                            current.id,
                          );
                        }
                        setState(() {
                          _selectedNote = note;
                          SPUtil.set(PrefKeys.selectedNote, note.id);
                        });
                      },
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
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
                                  : theme.iconTheme.color?.withValues(
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

  /// 打开本地文件选择器
  Future<void> _openLocalFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['md', 'txt', 'markdown'],
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;

      for (final f in result.files) {
        if (f.path == null) continue;
        // 检查是否已经打开
        if (_localFiles.any((lf) => lf.filePath == f.path)) continue;

        final file = File(f.path!);
        if (!await file.exists()) continue;

        try {
          final content = await file.readAsString();
          setState(() {
            _localFiles.add(
              _LocalFileInfo(
                filePath: f.path!,
                fileName: f.name,
                content: content,
                lastModified: DateTime.now(),
              ),
            );
          });
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('无法读取文件：${f.name}')));
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打开文件失败：$e')));
      }
    }
  }

  /// 在编辑器中打开本地文件
  void _openLocalFileInEditor(_LocalFileInfo fileInfo) {
    // 创建一个虚拟 Note 用于编辑
    final virtualNote = Note(
      id: fileInfo.filePath,
      title: fileInfo.fileName,
      content: fileInfo.content,
      lastModified: fileInfo.lastModified,
      notebookName: '__local_file__',
    );
    setState(() {
      _selectedNote = virtualNote;
      _selectedNotebook = null;
    });
  }

  /// 关闭本地文件
  void _closeLocalFile(_LocalFileInfo fileInfo) {
    setState(() {
      _localFiles.remove(fileInfo);
      // 如果当前选中的是该文件，则清除选中状态
      if (_selectedNote?.id == fileInfo.filePath &&
          _selectedNote?.notebookName == '__local_file__') {
        _selectedNote = null;
      }
    });
  }

  /// 保存本地文件到磁盘
  Future<void> _saveLocalFile(_LocalFileInfo fileInfo, String content) async {
    try {
      final file = File(fileInfo.filePath);
      await file.writeAsString(content);
      setState(() {
        fileInfo.content = content;
        fileInfo.lastModified = DateTime.now();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存文件失败：$e')));
      }
    }
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
                  // 延迟触发详情面板的搜索功能
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _detailPanelKey.currentState?.triggerSearch(
                      _currentSearchQuery,
                    );
                  });
                },
              );
            },
          );
  }

  Widget _buildNoteDetail(Note note) {
    // 如果是本地文件，使用虚拟笔记本
    final notebook =
        _selectedNotebook ??
        Notebook(name: '本地文件', notes: [], color: Colors.orange);

    return _NoteDetailPanel(
      key: _detailPanelKey,
      note: note,
      notebook: notebook,
      onNoteChanged: noteChanged,
      saveNote: saveNote,
      onDeleteNote: _deleteNote,
      searchQuery: _currentSearchQuery,
      onTitleChanged: (newTitle) {
        noteChanged(note, newTitle: newTitle);
      },
      onOpenIntent: _handleOpenIntent,
      onOpenNote: _openNoteByRef,
      onCreateNote: _confirmCreateLinkedNote,
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

                final newTitle = _noteTitleController.text.endsWith('.md')
                    ? _noteTitleController.text
                    : '${_noteTitleController.text}.md';
                final newNote = Note(
                  id: '${_selectedNotebook!.name}/$newTitle',
                  title: newTitle,
                  content: '',
                  lastModified: DateTime.now(),
                );

                // 先更新本地状态
                setState(() {
                  _selectedNotebook!.notes.add(newNote);
                  _selectedNote = newNote;
                  // 展开笔记本并标记新笔记为未同步
                  _expandedNotebooks.add(_selectedNotebook!.name);
                  _unsyncedNoteIds.add(newNote.id);
                  SPUtil.set(
                    PrefKeys.selectedNotebook,
                    _selectedNotebook!.name,
                  );
                  SPUtil.set(PrefKeys.selectedNote, newNote.id);
                });

                // 保存到文件
                FileUtil().saveFile(
                  '$workingDirectory/notes',
                  _selectedNotebook!.name,
                  newTitle,
                  utf8.encode(''),
                );

                Navigator.pop(context);
              }
            },
            child: Text('创建'),
          ),
        ],
      ),
    );
  }

  Future<void> _performSync() async {
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

    // 同步前对标签索引做内存快照，pull 覆盖本地文件后按条目 LWW 合并
    await _index.beforeGitSync();

    try {
      await git!.pull(
        owner,
        repo,
        '$workingDirectory/notes',
        unsyncedIds: _unsyncedNoteIds,
      );
      SPUtil.set(PrefKeys.lastPullTime, DateTime.now().toIso8601String());
      // 合并远端标签索引，须在 push 之前完成，避免把旧数据推回远端
      await _index.afterGitSync();

      await git!.push(
        owner,
        repo,
        '$workingDirectory/notes',
        deleteRemoteMissing: true,
      );

      if (!mounted) return;
      setState(() {
        _isSyncing = false;
        _unsyncedNoteIds.clear();
        _persistUnsyncedIds();
      });
      scaffoldMessenger.showSnackBar(const SnackBar(content: Text('仓库同步完成')));
      _loadNotebookList();
    } catch (error) {
      appLog.warning('笔记仓库同步失败: $error');
      if (!mounted) return;
      setState(() {
        _isSyncing = false;
      });
      scaffoldMessenger.showSnackBar(SnackBar(content: Text('仓库同步失败: $error')));
    }
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

  /// 预览中点击 `[[...]]` 时的跳转意图回调。
  final void Function(wiki.OpenNoteIntent intent)? onOpenIntent;

  /// 反链/出链条目点击后的跳转回调。
  final void Function(NoteRef ref)? onOpenNote;

  /// 未解析链接点击后的「创建笔记」回调。
  final void Function(String rawTarget)? onCreateNote;

  const _NoteDetailPanel({
    super.key,
    required this.note,
    required this.notebook,
    required this.onNoteChanged,
    required this.saveNote,
    required this.onDeleteNote,
    required this.onTitleChanged,
    this.searchQuery = '',
    this.onOpenIntent,
    this.onOpenNote,
    this.onCreateNote,
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
  bool _autoWrap = true;
  double _editorFontSize = 14;
  Timer? _scrollSaveTimer;

  // 视图模式：edit(普通编辑), split(分栏预览), preview(预览)
  String _viewMode = 'edit';

  // 分栏比例（编辑区占比）
  double _splitRatio = 0.5;

  // 标题是否已修改
  bool _isTitleModified = false;
  // 标题确认按钮是否已点击（用于变灰效果）
  bool _isTitleConfirmClicked = false;

  // 双链自动补全控制器（仅 re_editor 编辑区使用）
  late WikiAutocompleteController _autocomplete;
  // 反向链接面板是否展开
  bool _showBacklinks = false;

  @override
  void initState() {
    super.initState();
    _autocomplete = WikiAutocompleteController(
      currentNotebook: widget.notebook.name,
    );
    // 快捷键绑定在 build 期读取 isActive，状态变化时必须重建
    _autocomplete.addListener(_onAutocompleteChanged);
    _titleController = TextEditingController(
      text: widget.note.title.replaceAll('.md', ''),
    );
    _titleController.addListener(_onTitleChanged);
    _contentController = CodeLineEditingController.fromText(
      widget.note.content,
    );
    _showLineNumbers = SPUtil.get<bool>(PrefKeys.showLineNumbers, true);
    _autoWrap = SPUtil.get<bool>(PrefKeys.autoWrap, true);
    _editorFontSize = SPUtil.get<double>(PrefKeys.editorFontSize, 14);
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
      _isTitleModified = false;
      // 切换笔记时重置新增子状态，避免串页
      _isTitleConfirmClicked = false;
      _showBacklinks = false;
      _autocomplete.dismiss();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _tryRestoreScrollPosition(widget.note.id, 0),
      );
    }
    // currentNotebook 是 final，跨笔记本时需重建控制器以保证「本本优先」正确
    if (oldWidget.notebook.name != widget.notebook.name) {
      _autocomplete.removeListener(_onAutocompleteChanged);
      _autocomplete.dispose();
      _autocomplete = WikiAutocompleteController(
        currentNotebook: widget.notebook.name,
      )..addListener(_onAutocompleteChanged);
    }
  }

  /// 补全状态变化需触发重建：快捷键绑定在 build 期读取 `isActive`。
  // 双链补全弹窗是否已打开，避免激活状态反复触发
  bool _autocompleteDialogOpen = false;

  void _onAutocompleteChanged() {
    if (!mounted) return;
    setState(() {});
    // 候选激活且弹窗未开时，弹出选择窗口（不在编辑区上方显示）
    if (_autocomplete.isActive && !_autocompleteDialogOpen) {
      _showAutocompleteDialog();
    }
  }

  void _showAutocompleteDialog() {
    final all = _autocomplete.candidates;
    if (all.isEmpty) {
      _autocomplete.dismiss();
      return;
    }
    _autocompleteDialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => _LinkPickDialog(
          all: all,
          notebookName: widget.notebook.name,
          onPick: (ref) {
            Navigator.of(ctx).pop();
            _acceptAutocomplete(ref);
          },
          onCancel: () {
            Navigator.of(ctx).pop();
            _autocomplete.dismiss();
          },
        ),
      ).then((_) {
        _autocompleteDialogOpen = false;
        if (_autocomplete.isActive) _autocomplete.dismiss();
      });
    });
  }

  @override
  void dispose() {
    // dispose 前 scroller 还有 clients，先保存位置
    _saveScrollPosition(widget.note.id);
    _saveTimer?.cancel();
    _scrollSaveTimer?.cancel();
    _contentController.removeListener(_onContentChanged);
    _titleController.removeListener(_onTitleChanged);
    _codeScrollController.verticalScroller.removeListener(_onEditorScrolled);
    _previewScrollController.removeListener(_onPreviewScrolled);
    _titleController.dispose();
    _contentController.dispose();
    _findController.dispose();
    _codeScrollController.verticalScroller.dispose();
    _codeScrollController.dispose();
    _previewScrollController.dispose();
    _autocomplete.removeListener(_onAutocompleteChanged);
    _autocomplete.dispose();
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
    _updateAutocomplete(newContent);
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

  /// 把补全上下文限制在当前行内计算。
  ///
  /// `re_editor` 的选区是「行索引 + 行内偏移」模型，没有全文线性偏移；
  /// 而 `[[...]]` 补全语法本身不跨行，因此按当前行做局部匹配既准确又廉价。
  void _updateAutocomplete(String fullText) {
    final sel = _contentController.selection;
    // 存在选区（非折叠）或跨行时不触发补全
    if (sel.baseIndex != sel.extentIndex ||
        sel.baseOffset != sel.extentOffset) {
      _autocomplete.dismiss();
      return;
    }
    final line = _currentLineText(sel.extentIndex);
    if (line == null) {
      _autocomplete.dismiss();
      return;
    }
    final caret = sel.extentOffset.clamp(0, line.length);
    _autocomplete.onTextChanged(line, caret);
  }

  /// 取指定行的文本；越界返回 null。
  String? _currentLineText(int index) {
    final lines = _contentController.codeLines;
    if (index < 0 || index >= lines.length) return null;
    return lines[index].text;
  }

  /// 应用补全：用新行文本整体替换当前行，并把光标移到 `]]` 之后。
  void _acceptAutocomplete(NoteRef ref) {
    final sel = _contentController.selection;
    final lineIndex = sel.extentIndex;
    final line = _currentLineText(lineIndex);
    if (line == null) {
      _autocomplete.dismiss();
      return;
    }

    final result = _autocomplete.buildResult(line, ref: ref);
    if (result == null) {
      _autocomplete.dismiss();
      return;
    }

    // 选中整行后替换，避免手工拼接全文导致偏移错乱
    _contentController.selection = CodeLineSelection(
      baseIndex: lineIndex,
      baseOffset: 0,
      extentIndex: lineIndex,
      extentOffset: line.length,
    );
    _contentController.replaceSelection(result.newText);
    _contentController.selection = CodeLineSelection.collapsed(
      index: lineIndex,
      offset: result.newCaret.clamp(0, result.newText.length),
    );
    _autocomplete.dismiss();
  }

  void _onTitleChanged() {
    final currentTitle = _titleController.text;
    final originalTitle = widget.note.title.replaceAll('.md', '');
    final isModified = currentTitle != originalTitle && currentTitle.isNotEmpty;

    if (isModified != _isTitleModified) {
      setState(() {
        _isTitleModified = isModified;
        _isTitleConfirmClicked = false;
      });
    }
  }

  void _saveContentToFile() {
    // 本地文件不通过 FileUtil 保存，已在 noteChanged 中处理
    if (widget.note.notebookName == '__local_file__') return;

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
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _titleController,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontSize: 14,
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
                                  setState(() {
                                    _isTitleModified = false;
                                  });
                                }
                              },
                            ),
                          ),
                          if (_isTitleModified)
                            IconButton(
                              icon: Icon(Icons.check, size: 20),
                              onPressed: () {
                                if (_titleController.text.isNotEmpty &&
                                    !_isTitleConfirmClicked) {
                                  setState(() {
                                    _isTitleConfirmClicked = true;
                                  });
                                  widget.onTitleChanged(_titleController.text);
                                  Future.delayed(
                                    Duration(milliseconds: 300),
                                    () {
                                      if (mounted) {
                                        setState(() {
                                          _isTitleModified = false;
                                          _isTitleConfirmClicked = false;
                                        });
                                      }
                                    },
                                  );
                                }
                              },
                              color: _isTitleConfirmClicked
                                  ? (isDark
                                        ? Colors.grey[700]
                                        : Colors.grey[400])
                                  : theme.primaryColor,
                              tooltip: '确认修改标题',
                              padding: EdgeInsets.zero,
                              constraints: BoxConstraints(
                                minWidth: 28,
                                minHeight: 28,
                              ),
                            ),
                        ],
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
                // 标签编辑条（紧凑模式，与右上角工具按钮同处一行）
                Expanded(
                  child: TagEditorBar(
                    noteId: widget.note.id,
                    dense: true,
                    editable: true,
                  ),
                ),
                SizedBox(width: 8),
                // 自动换行按钮
                IconButton(
                  icon: Icon(
                    Icons.wrap_text,
                    color: _autoWrap
                        ? theme.primaryColor
                        : (isDark ? theme.disabledColor : Colors.grey),
                  ),
                  onPressed: () {
                    setState(() {
                      _autoWrap = !_autoWrap;
                      SPUtil.set(PrefKeys.autoWrap, _autoWrap);
                    });
                  },
                  tooltip: _autoWrap ? '自动换行' : '取消自动换行',
                ),
                // 编辑器字号：减/增合并为一个菜单
                PopupMenuButton<double>(
                  icon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.format_size),
                      const SizedBox(width: 2),
                      Text(
                        _editorFontSize.toInt().toString(),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.primaryColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  tooltip: '调整字号',
                  onSelected: _changeEditorFontSize,
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: -1,
                      child: const Row(
                        children: [
                          Icon(Icons.text_decrease, size: 18),
                          SizedBox(width: 8),
                          Text('减小字号'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 1,
                      child: const Row(
                        children: [
                          Icon(Icons.text_increase, size: 18),
                          SizedBox(width: 8),
                          Text('增大字号'),
                        ],
                      ),
                    ),
                  ],
                ),
                // 视图模式：编辑 / 分栏 / 预览 合并为一个菜单
                PopupMenuButton<String>(
                  icon: Icon(
                    _viewMode == 'edit'
                        ? Icons.edit_note
                        : (_viewMode == 'split'
                              ? Icons.vertical_split
                              : Icons.preview),
                    color: theme.primaryColor,
                  ),
                  tooltip: '视图模式',
                  onSelected: _switchViewMode,
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(Icons.edit_note, size: 18),
                          SizedBox(width: 8),
                          Text('编辑'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'split',
                      child: Row(
                        children: [
                          Icon(Icons.vertical_split, size: 18),
                          SizedBox(width: 8),
                          Text('分栏'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'preview',
                      child: Row(
                        children: [
                          Icon(Icons.preview, size: 18),
                          SizedBox(width: 8),
                          Text('预览'),
                        ],
                      ),
                    ),
                  ],
                ),
                // 反向链接面板开关
                ListenableBuilder(
                  listenable: NotesIndexService(),
                  builder: (context, _) {
                    final count = NotesIndexService()
                        .backlinksOf(widget.note.id)
                        .length;
                    return IconButton(
                      icon: Badge(
                        isLabelVisible: count > 0,
                        largeSize: 10,
                        padding: const EdgeInsets.all(2),
                        alignment: Alignment.topRight,
                        offset: const Offset(4, -4),
                        label: Text(
                          '$count',
                          style: const TextStyle(fontSize: 9, height: 1),
                        ),
                        child: Icon(
                          Icons.call_received,
                          color: _showBacklinks
                              ? theme.primaryColor
                              : (isDark ? theme.disabledColor : Colors.grey),
                        ),
                      ),
                      onPressed: () =>
                          setState(() => _showBacklinks = !_showBacklinks),
                      tooltip: '反向链接',
                    );
                  },
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
                IconButton(
                  icon: Icon(Icons.send),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) =>
                          BlogExportDialog(note: widget.note),
                    );
                  },
                  tooltip: '保存为博客 (Jekyll post)',
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
              child: _buildContentArea(theme),
            ),
          ),
          // 反向链接面板（可折叠，默认收起）
          if (_showBacklinks)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  border: Border(top: BorderSide(color: theme.dividerColor)),
                ),
                child: SingleChildScrollView(
                  child: BacklinksPanel(
                    noteId: widget.note.id,
                    onOpenNote: widget.onOpenNote,
                    onCreateNote: widget.onCreateNote,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMarkdownPreview(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return WikiMarkdownView(
      data: _contentController.text,
      currentNotebook: widget.notebook.name,
      onOpenNote: widget.onOpenIntent,
      selectable: true,
      controller: _previewScrollController,
      imageDirectory: SPUtil.get<String>(PrefKeys.workingDirectory, ''),
      styleSheet:
          applyWikiLinkStyle(
            fm.MarkdownStyleSheet.fromTheme(theme),
            theme,
          ).copyWith(
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
              color: isDark ? const Color(0xFFADB5BD) : const Color(0xFF6C757D),
              fontStyle: FontStyle.italic,
            ),
            blockquoteDecoration: BoxDecoration(
              color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF8F9FA),
              border: Border(
                left: BorderSide(
                  color: isDark
                      ? const Color(0xFF4A5568)
                      : const Color(0xFFCED4DA),
                  width: 3,
                ),
              ),
            ),
            blockquotePadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 4,
            ),
            del: theme.textTheme.bodyMedium?.copyWith(
              decoration: TextDecoration.lineThrough,
              decorationColor: isDark ? Colors.red[300] : Colors.red[600],
              decorationThickness: 2,
            ),
          ),
    );
  }

  Widget _buildContentArea(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        const dividerWidth = 6.0;
        final isSplit = _viewMode == 'split';
        final isPreview = _viewMode == 'preview';

        final editorWidth = isSplit
            ? (totalWidth - dividerWidth) * _splitRatio
            : totalWidth;

        return Stack(
          children: [
            // 编辑器始终在树中，始终有正确宽度，不会被 deactivate
            Row(
              children: [
                SizedBox(width: editorWidth, child: _buildEditor(theme)),
                if (isSplit) ...[
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
                      child: SizedBox(
                        width: dividerWidth,
                        child: Center(
                          child: Container(width: 1, color: theme.dividerColor),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: totalWidth - editorWidth - dividerWidth,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: _buildMarkdownPreview(theme),
                    ),
                  ),
                ],
              ],
            ),
            // preview 模式：全屏预览覆盖在编辑器上方
            if (isPreview)
              Positioned.fill(
                child: ColoredBox(
                  color: theme.scaffoldBackgroundColor,
                  child: _buildMarkdownPreview(theme),
                ),
              ),
          ],
        );
      },
    );
  }

  void _joinSelectedLines() {
    final controller = _contentController;
    final text = controller.text;
    if (text.isEmpty) return;

    final sel = controller.selection;
    final lines = text.split('\n');

    final startLine = sel.start.index;
    final endLine = sel.end.index;

    if (startLine >= endLine) return; // 只有一行，无需合并

    // 合并选中行：每行 trim 后用空格连接
    final merged = lines
        .sublist(startLine, endLine + 1)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .join(' ');

    // 计算替换范围（整行范围）
    int rangeStart = 0;
    for (int i = 0; i < startLine; i++) {
      rangeStart += lines[i].length + 1;
    }
    int rangeEnd = rangeStart;
    for (int i = startLine; i <= endLine; i++) {
      rangeEnd += lines[i].length;
      if (i < endLine) rangeEnd += 1; // '\n'
    }
    if (rangeEnd > text.length) rangeEnd = text.length;

    final newText = text.replaceRange(rangeStart, rangeEnd, merged);
    controller.text = newText;
  }

  void _changeEditorFontSize(double delta) {
    final next = (_editorFontSize + delta).clamp(10.0, 32.0);
    if (next == _editorFontSize) return;
    setState(() {
      _editorFontSize = next;
    });
    SPUtil.set(PrefKeys.editorFontSize, _editorFontSize);
  }

  Widget _buildEditor(ThemeData theme) {
    return Column(
      children: [
        // 双链候选以弹出窗口呈现，不再在编辑区上方显示补全栏
        Expanded(child: _buildCodeEditor(theme)),
      ],
    );
  }

  Widget _buildCodeEditor(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(
          LogicalKeyboardKey.keyJ,
          control: true,
          shift: true,
        ): _joinSelectedLines,
        // 补全激活且弹窗未打开时接管方向键/回车/Esc；弹窗打开时由对话框处理。
        // 未激活时回调内部为空操作，但 CallbackShortcuts 仍会吞掉按键，
        // 故仅在激活且弹窗未开时才注册。
        if (_autocomplete.isActive && !_autocompleteDialogOpen)
          ...buildAutocompleteShortcuts(
            controller: _autocomplete,
            onAccept: () {
              final ref = _autocomplete.selected;
              if (ref != null) _acceptAutocomplete(ref);
            },
          ),
      },
      child: CodeEditor(
        controller: _contentController,
        scrollController: _codeScrollController,
        findController: _findController,
        wordWrap: _autoWrap,
        padding: const EdgeInsets.only(bottom: 300),
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
          fontSize: _editorFontSize,
          fontHeight: 1.6,
          fontFamily: 'monospace',
          textColor: isDark ? const Color(0xFFE8E8E8) : const Color(0xFF1A1A1A),
          backgroundColor: isDark
              ? Color.fromARGB(255, 48, 48, 48)
              : const Color(0xFFFFFFFF),
          highlightColor: Colors.yellow.withValues(alpha: 0.5),
          selectionColor: Colors.orange.withValues(alpha: 0.6),
          codeTheme: CodeHighlightTheme(
            languages: {
              'markdown': CodeHighlightThemeMode(
                mode: markdownWithFullwidthQuote,
              ),
            },
            theme: {
              // 移除编辑器内所有斜体样式（斜体下空格/引号不易辨识）
              for (final entry
                  in (isDark ? atomOneDarkTheme : atomOneLightTheme).entries)
                entry.key: entry.value.copyWith(fontStyle: FontStyle.normal),
              // blockquote (quote token) 颜色覆盖，提升对比度
              'quote': TextStyle(
                color: isDark
                    ? const Color(0xFF9ECBFF)
                    : const Color(0xFF5C6370),
              ),
              // 全角引号：醒目颜色，与半角引号（默认字符串色）明显区分
              'fullwidth-quote': TextStyle(
                color: isDark
                    ? const Color(0xFFFF79C6)
                    : const Color(0xFFD6336C),
                fontWeight: FontWeight.bold,
              ),
              // 双链 [[...]]：整段换色，与正文区分
              'wiki-link': TextStyle(
                color: isDark
                    ? const Color(0xFF7EE787)
                    : const Color(0xFF0969DA),
                fontWeight: FontWeight.w600,
              ),
            },
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
                            color: theme.textTheme.bodySmall?.color?.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ),
                      )
                    : Container(width: 12, color: Colors.transparent),
              );
            },
      ),
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

  // 从外部触发搜索功能（如从笔记本搜索跳转过来）
  void triggerSearch(String query) {
    if (query.isEmpty) {
      _findController.close();
      return;
    }
    // 打开搜索面板
    _findController.findMode();
    // 延迟设置搜索文本并聚焦，让编辑器处理搜索
    Future.delayed(Duration(milliseconds: 100), () {
      _findController.findInputController.text = query;
      _findController.findInputController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: query.length,
      );
      _findController.focusOnFindInput();
    });
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

/// 本地文件信息模型
class _LocalFileInfo {
  final String filePath;
  final String fileName;
  String content;
  DateTime lastModified;

  _LocalFileInfo({
    required this.filePath,
    required this.fileName,
    required this.content,
    required this.lastModified,
  });
}

/// 双链选择弹窗：顶部搜索框过滤候选，无匹配时提供「创建新笔记」入口。
class _LinkPickDialog extends StatefulWidget {
  final List<NoteRef> all;
  final String notebookName;
  final ValueChanged<NoteRef> onPick;
  final VoidCallback onCancel;

  const _LinkPickDialog({
    required this.all,
    required this.notebookName,
    required this.onPick,
    required this.onCancel,
  });

  @override
  State<_LinkPickDialog> createState() => _LinkPickDialogState();
}

class _LinkPickDialogState extends State<_LinkPickDialog> {
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  late List<NoteRef> _filtered;

  @override
  void initState() {
    super.initState();
    _filtered = widget.all;
    _queryController.addListener(_applyFilter);
    // 弹窗打开后自动聚焦搜索框
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  void _applyFilter() {
    final q = _queryController.text.trim().toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? widget.all
          : widget.all
                .where((r) => r.title.toLowerCase().contains(q))
                .toList();
    });
  }

  void _pick(NoteRef ref) => widget.onPick(ref);

  @override
  void dispose() {
    _queryController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _queryController.text.trim();
    final showCreate =
        q.isNotEmpty && !widget.all.any((r) => r.title.toLowerCase() == q.toLowerCase());

    return AlertDialog(
      title: const Text('选择链接目标'),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          children: [
            TextField(
              controller: _queryController,
              focusNode: _focusNode,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索笔记标题…',
                prefixIcon: const Icon(Icons.search, size: 18),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (showCreate)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.add_circle_outline, size: 18),
                      title: Text('创建「$q」'),
                      onTap: () => _pick(
                        NoteRef.of(widget.notebookName, q, exists: false),
                      ),
                    ),
                  for (final ref in _filtered)
                    ListTile(
                      dense: true,
                      title: Text(ref.displayTitle),
                      subtitle: ref.notebookName.isNotEmpty &&
                              ref.notebookName != '笔记'
                          ? Text(ref.notebookName)
                          : null,
                      onTap: () => _pick(ref),
                    ),
                  if (_filtered.isEmpty && !showCreate)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(child: Text('无匹配结果')),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: widget.onCancel,
          child: const Text('取消'),
        ),
      ],
    );
  }
}
