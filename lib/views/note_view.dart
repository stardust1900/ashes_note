import 'dart:convert';

import 'package:ashes_note/utils/file_util.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:flutter/material.dart';

class NoteView extends StatefulWidget {
  const NoteView({super.key});

  @override
  State<StatefulWidget> createState() {
    return NoteViewState();
  }
}

class NoteViewState extends State<NoteView> {
  final FileUtil fileUtil = FileUtil();

  String? _selectedNotebook;
  String? _selectedNote;
  String? _content;
  late String workingDirectory;

  double _navigationWidthRatio = 0.3; // 导航栏初始宽度比例 (30%)
  double _maxNavigationWidth = 400; // 导航栏最大宽度
  double _minNavigationWidthRatio = 0.15; // 最小宽度比例 (15%)
  double _maxNavigationWidthRatio = 0.5; // 最大宽度比例 (50%)

  @override
  void initState() {
    super.initState();
    workingDirectory = SPUtil.get<String>('workingDirectory', '');
  }

  void _onNoteSelected(String selectedNotebook, String selectedNote) {
    fileUtil.readFile(workingDirectory, selectedNotebook, selectedNote).then((
      String content,
    ) {
      print('content: $content');
      setState(() {
        _selectedNotebook = selectedNotebook;
        _selectedNote = selectedNote;
        _content = content;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth > 600) {
          // Tablet/Desktop layout
          return Row(
            children: [
              // 导航栏
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: NavigationPanel(
                  fileUtil: fileUtil,
                  onNoteSelected: _onNoteSelected,
                  selectedNotebook: _selectedNotebook,
                  selectedNote: _selectedNote,
                ),
              ),

              Expanded(
                child: ContentArea(
                  _selectedNotebook,
                  _selectedNote,
                  _content,
                  fileUtil,
                ),
              ),
            ],
          );
        } else {
          // Mobile layout
          return ContentArea(
            _selectedNotebook,
            _selectedNote,
            _content,
            fileUtil,
          );
        }
      },
    );
  }
}

class NavigationPanel extends StatefulWidget {
  final FileUtil fileUtil;
  final Function(String selectedNotebook, String selectedNote) onNoteSelected;
  final String? selectedNotebook, selectedNote;
  const NavigationPanel({
    super.key,
    required this.fileUtil,
    required this.onNoteSelected,
    this.selectedNotebook,
    this.selectedNote,
  });
  @override
  State<StatefulWidget> createState() {
    return NavigationPanelState();
  }
}

class NavigationPanelState extends State<NavigationPanel> {
  final TextEditingController _textEditingController = TextEditingController();

  late String workingDirectory;
  List<String> _notebookList = [];
  final Map<String, List<String>> _notebookMap = {};
  @override
  void initState() {
    super.initState();
    _loadNotebookList();
  }

  Future<void> _loadNotebookList() async {
    workingDirectory = SPUtil.get<String>('workingDirectory', '');
    final List<String> list = await widget.fileUtil.listFiles(
      workingDirectory,
      '',
      type: 'directory',
    );
    setState(() {
      _notebookList = list;
    });
    for (var notebook in _notebookList) {
      final List<String> list = await widget.fileUtil.listFiles(
        workingDirectory,
        notebook,
        type: 'file',
      );
      setState(() {
        _notebookMap[notebook] = list;
      });
    }
  }

  // 弹出对话框的方法
  Future<void> _showNotebookNameDialog() async {
    // 重置控制器内容
    _textEditingController.clear();

    // 使用 showDialog 显示对话框
    final String? result = await showDialog<String>(
      context: context,
      barrierDismissible: false, // 点击对话框外部不可关闭
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('输入笔记本名称'), // 对话框标题
          content: Column(
            mainAxisSize: MainAxisSize.min, // 内容高度根据子组件决定
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Text('请输入您的笔记本名称:'),
              SizedBox(height: 10), // 添加间距
              TextField(
                controller: _textEditingController, // 使用控制器管理输入
                decoration: InputDecoration(
                  //hintText: '例如：我的办公笔记本', // 提示文本
                  border: OutlineInputBorder(),
                  labelText: '笔记本名称', // 标签文本
                ),
                autofocus: true, // 自动获取焦点
                onChanged: (value) {
                  // 可以在此处实时处理输入变化
                },
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              child: Text('取消'),
              onPressed: () {
                Navigator.of(context).pop(); // 关闭对话框，返回 null
              },
            ),
            TextButton(
              child: Text('确定'),
              onPressed: () {
                String inputText = _textEditingController.text.trim();
                if (inputText.isNotEmpty) {
                  Navigator.of(context).pop(inputText); // 返回用户输入
                } else {
                  // 可选：输入为空时的提示
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('请输入笔记本名称')));
                }
              },
            ),
          ],
        );
      },
    );

    // print("result: $result");
    // 处理对话框返回的结果
    if (result != null && result.isNotEmpty) {
      // 这里可以添加其他处理逻辑，比如保存到本地等
      print('用户输入的笔记本名称: $result');

      await widget.fileUtil.createDirectory(workingDirectory, result);
      _loadNotebookList();
    }
  }

  // 添加笔记 弹出对话框
  Future<void> _showNoteDialog(String noteBook) async {
    // 重置控制器内容
    _textEditingController.clear();

    // 使用 showDialog 显示对话框
    final String? result = await showDialog<String>(
      context: context,
      barrierDismissible: false, // 点击对话框外部不可关闭
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('输入笔记名称'), // 对话框标题
          content: Column(
            mainAxisSize: MainAxisSize.min, // 内容高度根据子组件决定
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Text('请输入您的笔记名称:'),
              SizedBox(height: 10), // 添加间距
              TextField(
                controller: _textEditingController, // 使用控制器管理输入
                decoration: InputDecoration(
                  //hintText: '例如：我的办公笔记本', // 提示文本
                  border: OutlineInputBorder(),
                  labelText: '笔记名称', // 标签文本
                ),
                autofocus: true, // 自动获取焦点
                onChanged: (value) {
                  // 可以在此处实时处理输入变化
                },
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              child: Text('取消'),
              onPressed: () {
                Navigator.of(context).pop(); // 关闭对话框，返回 null
              },
            ),
            TextButton(
              child: Text('确定'),
              onPressed: () {
                String inputText = _textEditingController.text.trim();
                if (inputText.isNotEmpty) {
                  Navigator.of(context).pop(inputText); // 返回用户输入
                } else {
                  // 可选：输入为空时的提示
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('请输入笔记名称')));
                }
              },
            ),
          ],
        );
      },
    );

    // print("result: $result");
    // 处理对话框返回的结果
    if (result != null && result.isNotEmpty) {
      widget.fileUtil
          .saveFile(workingDirectory, noteBook, result, utf8.encode(""))
          .then((value) {
            setState(() {
              _notebookMap[noteBook]?.add(result);
            });
          });
      // 这里可以添加其他处理逻辑，比如保存到本地等
      print('用户输入的笔记名称: $result');
    }
  }

  @override
  Widget build(BuildContext context) {
    //fileUtil.listFiles('').then((value) => _notebookList = value);
    return Column(
      children: [
        Expanded(
          child: Container(
            width: 250,
            color: Colors.grey[200],
            child: ListView(
              children: [
                ..._notebookList.map(
                  (notebook) => Dismissible(
                    key: Key(notebook),
                    direction: DismissDirection.endToStart, // 设置从右向左滑动
                    onDismissed: (direction) {
                      widget.fileUtil.deleteDirectory(
                        workingDirectory,
                        notebook,
                      );
                      setState(() {
                        _notebookList.remove(notebook);
                        _notebookMap.remove(notebook);
                      });
                    },
                    confirmDismiss: (direction) {
                      return showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text('删除笔记本'),
                          content: Text('确定要删除笔记本 "$notebook" 吗?'),
                          actions: [
                            TextButton(
                              child: Text('取消'),
                              onPressed: () => Navigator.pop(context, false),
                            ),
                            TextButton(
                              child: Text('确定'),
                              onPressed: () => Navigator.pop(context, true),
                            ),
                          ],
                        ),
                      );
                    },
                    background: _buildDeleteBackground(),
                    child: ExpansionTile(
                      title: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(notebook),
                          IconButton(
                            icon: Icon(Icons.add),
                            onPressed: () => _showNoteDialog(notebook),
                          ),
                        ],
                      ),
                      children: [
                        ..._notebookMap[notebook]?.map(
                              (note) => ListTile(
                                title: Text(note),
                                onTap: () {
                                  print("select note: $note");
                                  widget.onNoteSelected(notebook, note);
                                },
                                titleTextStyle:
                                    widget.selectedNote == note &&
                                        widget.selectedNotebook == notebook
                                    ? Theme.of(context).textTheme.titleLarge
                                    : Theme.of(context).textTheme.titleSmall,
                              ),
                            ) ??
                            [],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(
          width: 250,
          color: Colors.grey[300],
          child: TextButton.icon(
            icon: Icon(Icons.add),
            label: Text('新建笔记本'),
            onPressed: _showNotebookNameDialog,
          ),
        ),
      ],
    );
  }

  Widget? _buildDeleteBackground() {
    return Container(
      alignment: Alignment.centerRight,
      padding: EdgeInsets.only(right: 20.0),
      color: Colors.red,
      child: Icon(Icons.delete, color: Colors.white, size: 30),
    );
  }
}

class ContentArea extends StatefulWidget {
  final String? selectedNotebook, selectedNote, content;
  final FileUtil fileUtil;

  const ContentArea(
    this.selectedNotebook,
    this.selectedNote,
    this.content,
    this.fileUtil, {
    super.key,
  });

  @override
  State<StatefulWidget> createState() {
    return ContentAreaState();
  }
}

class ContentAreaState extends State<ContentArea> {
  //late MutableDocument _document;
  //late MutableDocumentComposer _composer;
  // late Editor _editor;
  bool _isEditing = true;
  bool _isLoading = true;
  late String workingDirectory;

  @override
  void initState() {
    super.initState();
    final initialContent = widget.content ?? '';
    _updateDocument(initialContent);
    workingDirectory = SPUtil.get<String>('workingDirectory', '');
  }

  // 更新文档的核心方法
  void _updateDocument(String content) {
    // 将 Markdown 转换为 SuperEditor 的 Document
    // _document = deserializeMarkdownToDocument(content);
    // _document.addListener(_onDocumentChange);
    // _composer = MutableDocumentComposer();
    // _editor = createDefaultDocumentEditor(
    //   document: _document,
    //   composer: _composer,
    // );

    setState(() {
      _isLoading = false;
    });
  }

  // void _onDocumentChange(DocumentChangeLog changeLog) {
  //   final newContent = serializeDocumentToMarkdown(_document);
  //   print('新的文档内容: $newContent');
  // }

  @override
  void didUpdateWidget(ContentArea oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 关键：当 content 发生变化时更新文档
    if (oldWidget.selectedNotebook != widget.selectedNotebook ||
        oldWidget.selectedNote != widget.selectedNote) {
      print('切换笔记，重新初始化编辑器');
      //保存当前文档
      // final editedContent = serializeDocumentToMarkdown(_document);
      final editedContent = '';
      if (editedContent != oldWidget.content &&
          oldWidget.selectedNotebook != null &&
          oldWidget.selectedNote != null) {
        widget.fileUtil.saveFile(
          workingDirectory,
          oldWidget.selectedNotebook!,
          oldWidget.selectedNote!,
          utf8.encode(editedContent),
        );
      }

      final newContent = widget.content ?? '';
      _updateDocument(newContent);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Center(child: CircularProgressIndicator());
    }
    return Padding(
      padding: EdgeInsets.only(left: 1.0, top: 8.0, right: 8.0, bottom: 8.0),
      //child: SuperEditor(editor: _editor),
    );
  }
}
