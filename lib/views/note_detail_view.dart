import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ashes_note/utils/const.dart';
import 'package:ashes_note/utils/file_util.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox, RenderEditable;
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:super_editor/super_editor.dart';
import 'package:ashes_note/views/_toolbar.dart';

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

  // 视图模式：edit(普通编辑), preview(预览), superEditor(SuperEditor)
  String _viewMode = 'edit';

  // SuperEditor 相关变量
  late MutableDocument _doc;
  late final MutableDocumentComposer _composer;
  late final Editor _docEditor;
  late CommonEditorOperations _docOps;
  final _docChangeSignal = SignalNotifier();
  late FocusNode _editorFocusNode;
  late ScrollController _superEditorScrollController;
  late final SuperEditorIosControlsController _iosControlsController;

  final _brightness = ValueNotifier<Brightness>(Brightness.light);
  final _textFormatBarOverlayController = OverlayPortalController();
  final _textSelectionAnchor = ValueNotifier<Offset?>(null);
  final _imageFormatBarOverlayController = OverlayPortalController();
  final _imageSelectionAnchor = ValueNotifier<Offset?>(null);
  final _overlayController =
      MagnifierAndToolbarController() //
        ..screenPadding = const EdgeInsets.all(20.0);
  final MarkdownInlineUpstreamSyntaxPlugin _markdownPlugin =
      MarkdownInlineUpstreamSyntaxPlugin();

  // SuperEditor 查找功能变量
  final TextEditingController _searchController = TextEditingController();
  late List<DocumentSelection> _searchResults;
  int _currentSearchIndex = -1;
  bool _isSearchVisible = false;
  String _currentSearchTerm = '';
  final FocusNode _searchFocusNode = FocusNode();
  double targetPosition = 0.0;
  DocumentSelection? targetSelection;

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

    // 初始化 SuperEditor
    _initSuperEditor();

    _searchResults = [];
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
    _superEditorScrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _iosControlsController.dispose();
    _editorFocusNode.dispose();
    _composer.dispose();
    super.dispose();
  }

  // SuperEditor 初始化
  void _initSuperEditor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _brightness.value = Theme.of(context).brightness;
    });

    _doc = deserializeMarkdownToDocument(note.content)
      ..addListener(_onSuperDocumentChange);
    _composer = MutableDocumentComposer();
    _composer.selectionNotifier.addListener(_hideOrShowToolbar);
    _docEditor = createDefaultDocumentEditor(
      document: _doc,
      composer: _composer,
      isHistoryEnabled: true,
    );
    _docOps = CommonEditorOperations(
      editor: _docEditor,
      document: _doc,
      composer: _composer,
      documentLayoutResolver: () =>
          _superDocLayoutKey.currentState as DocumentLayout,
    );
    _editorFocusNode = FocusNode();
    _superEditorScrollController = ScrollController()
      ..addListener(_hideOrShowToolbar);
    _iosControlsController = SuperEditorIosControlsController();
  }

  // SuperEditor 文档变化监听
  void _onSuperDocumentChange(_) {
    _hideOrShowToolbar();
    _docChangeSignal.notifyListeners();
    // 如果在 SuperEditor 中搜索，文档变化后重新搜索
    if (_isSearchVisible && _currentSearchTerm.isNotEmpty) {
      _performSuperSearch(_currentSearchTerm);
    }

    final newContent = serializeDocumentToMarkdown(_doc);
    if (note.content != newContent) {
      note.content = newContent;
      widget.onNoteChanged(note);
      // 延迟保存到文件，避免频繁写文件
      Timer(const Duration(seconds: 1), () {
        _saveContentToFile();
      });
    }
  }

  // 切换视图模式前保存当前内容
  void _saveBeforeSwitch() {
    if (_viewMode == 'edit') {
      // 从普通编辑器保存到文件（不上传到git）
      note.content = _textController.text;
      _saveContentToFile();
      widget.onNoteChanged(note);
    } else if (_viewMode == 'superEditor') {
      // 从 SuperEditor 保存到文件（不上传到git）
      note.content = serializeDocumentToMarkdown(_doc);
      _saveContentToFile();
      widget.onNoteChanged(note);
    }
    // preview 模式是只读的，不需要保存
  }

  // 只保存到文件，不上传到git
  void _saveContentToFile() {
    final workingDir = SPUtil.get<String>(PrefKeys.workingDirectory, '');
    FileUtil().saveFile(
      '$workingDir/notes',
      note.id.substring(0, note.id.lastIndexOf('/')),
      note.title,
      utf8.encode(note.content),
    );
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
        final workingDir = SPUtil.get<String>(PrefKeys.workingDirectory, '');
        FileUtil().saveFile(
          '$workingDir/notes',
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
      _scrollToMatchWithTextPainter();
    }
  }

  void _findNext() {
    if (_totalMatches == 0) return;

    setState(() {
      _currentFindIndex = (_currentFindIndex + 1) % _totalMatches;
      _updateHighlightedText();
    });

    // 在下一帧执行滚动，确保布局已完成
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToMatchWithTextPainter();
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
      _scrollToMatchWithTextPainter();
    });
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
          style: TextStyle(color: Colors.white, fontSize: 14, height: 1.4),
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
          style: TextStyle(color: Colors.white, fontSize: 14, height: 1.4),
        ),
      );
    }

    _highlightedSpans = spans;
  }

  RenderEditable? _findRenderEditable(RenderObject? object) {
    RenderObject? current = object;
    while (current != null) {
      if (current is RenderEditable) {
        return current;
      }
      if (current is RenderProxyBox) {
        current = current.child;
      } else {
        // 大多数装饰层都是 proxy box，非 proxy 则停止
        break;
      }
    }
    return null;
  }

  void _scrollToMatchWithTextPainter() {
    if (_currentFindIndex < 0 || _currentFindIndex >= _matches.length) return;

    final match = _matches[_currentFindIndex];
    final text = _textController.text;

    final renderObject = _selectableTextKey.currentContext?.findRenderObject();
    print('SelectableText renderObject: $renderObject');
    final editable = _findRenderEditable(renderObject);
    final boxes1 = editable?.getBoxesForSelection(match);
    var clampedOffset = boxes1?.first.top;
    print('SelectableText editable: $editable boxoffset: $clampedOffset');
    if (clampedOffset == null) {
      // 使用TextPainter精确计算文本布局
      final textStyle = TextStyle(fontSize: 14, height: 1.4);
      final textBeforeMatch = text.substring(0, match.start);

      final textPainter = TextPainter(
        text: TextSpan(text: textBeforeMatch, style: textStyle),
        textDirection: TextDirection.ltr,
        maxLines: null,
      );

      // 获取滚动视图的实际宽度（考虑padding）
      final screenWidth = MediaQuery.of(context).size.width;
      final padding = MediaQuery.of(context).padding;
      final horizontalPadding = 32; // 左右各16px 啊用44是最终测试出来的效果更好...
      final availableWidth =
          screenWidth - horizontalPadding - padding.left - padding.right;
      textPainter.layout(maxWidth: availableWidth);

      // 计算匹配文本前的行数
      final lineMetrics = textPainter.computeLineMetrics();
      final lineCount = lineMetrics.length;

      // 计算精确的垂直偏移量
      //lineMetrics[0].height = 20 但是实际测试发现有点偏差，所以乘以一个系数1.02
      double totalHeight = 20.0 * lineCount;
      print('Total lines: $lineCount Approx height: $totalHeight');
      final boxes = textPainter.getBoxesForSelection(match);
      if (boxes.isNotEmpty) {
        final box = boxes.first;
        totalHeight = box.top;
        print('Total height to match: $totalHeight');
      }
      // 添加一些边距确保匹配项可见
      final verticalPadding = 20.0;
      final targetOffset = totalHeight - verticalPadding;

      // 确保滚动位置在合理范围内
      final maxScrollExtent = _scrollController.position.maxScrollExtent;
      clampedOffset = targetOffset.clamp(0.0, maxScrollExtent);
    }

    print('Scrolling to offset: $clampedOffset');
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

  // ==================== SuperEditor 相关方法 ====================

  // SuperEditor 搜索功能
  void _performSuperSearch(String searchTerm) {
    if (searchTerm.isEmpty) {
      _clearSuperSearch();
      return;
    }

    _currentSearchTerm = searchTerm;
    _searchResults = [];

    // 遍历文档中的所有文本节点
    final it = _doc.iterator;
    while (it.moveNext()) {
      final node = it.current;
      if (node is TextNode) {
        final text = node.text.toPlainText();
        int startIndex = 0;

        while (startIndex < text.length) {
          final index = text.toLowerCase().indexOf(
            searchTerm.toLowerCase(),
            startIndex,
          );
          if (index == -1) break;

          // 为此匹配创建选择区域
          final start = DocumentPosition(
            nodeId: node.id,
            nodePosition: TextNodePosition(offset: index),
          );
          final end = DocumentPosition(
            nodeId: node.id,
            nodePosition: TextNodePosition(offset: index + searchTerm.length),
          );

          _searchResults.add(DocumentSelection(base: start, extent: end));

          startIndex = index + 1; // 移过此匹配以查找下一个
        }
      }
    }

    if (_searchResults.isNotEmpty) {
      _currentSearchIndex = 0;
      _jumpToSuperSearchResult(_currentSearchIndex);
    } else {
      _currentSearchIndex = -1;
    }

    setState(() {});
  }

  void _jumpToSuperSearchResult(int index) {
    if (index >= 0 && index < _searchResults.length) {
      final selection = _searchResults[index];
      PausableValueNotifier notifier =
          _composer.selectionNotifier as PausableValueNotifier;
      notifier.value = selection;
      targetSelection = selection;
      // 滚动到找到的文本
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final layout = _superDocLayoutKey.currentState as DocumentLayout;
        final rect = layout.getRectForSelection(
          selection.base,
          selection.extent,
        );
        if (rect != null) {
          targetPosition = rect.top - 100;
          _superEditorScrollController.animateTo(
            rect.top - 100, // 在顶部添加一些边距
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
      });
    }
  }

  void _nextSuperSearchResult() {
    if (_searchResults.isEmpty) return;

    _currentSearchIndex = (_currentSearchIndex + 1) % _searchResults.length;
    _jumpToSuperSearchResult(_currentSearchIndex);
    setState(() {});
  }

  void _previousSuperSearchResult() {
    if (_searchResults.isEmpty) return;

    _currentSearchIndex = _currentSearchIndex <= 0
        ? _searchResults.length - 1
        : _currentSearchIndex - 1;
    _jumpToSuperSearchResult(_currentSearchIndex);
    setState(() {});
  }

  void _clearSuperSearch() {
    setState(() {
      _currentSearchTerm = '';
      _searchResults = [];
      _currentSearchIndex = -1;
      _searchController.clear();
      _composer.clearSelection();
    });
  }

  void _toggleSuperSearch() {
    targetPosition = 0.0;
    targetSelection = null;
    _hideEditorToolbar();
    _hideImageToolbar();
    setState(() {
      _isSearchVisible = !_isSearchVisible;
      if (!_isSearchVisible) {
        _clearSuperSearch();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _searchFocusNode.requestFocus();
        });
      }
    });
  }

  // SuperEditor 工具栏相关
  final _superDocLayoutKey = GlobalKey();
  final _superViewportKey = GlobalKey();
  final SelectionLayerLinks _selectionLayerLinks = SelectionLayerLinks();

  DocumentGestureMode get _gestureMode {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return DocumentGestureMode.android;
      case TargetPlatform.iOS:
        return DocumentGestureMode.iOS;
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return DocumentGestureMode.mouse;
    }
  }

  TextInputSource get _inputSource {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return TextInputSource.ime;
    }
  }

  Widget _buildFloatingToolbar(BuildContext context) {
    return EditorToolbar(
      editorViewportKey: _superViewportKey,
      anchor: _selectionLayerLinks.expandedSelectionBoundsLink,
      editorFocusNode: _editorFocusNode,
      editor: _docEditor,
      document: _doc,
      composer: _composer,
      closeToolbar: _hideEditorToolbar,
    );
  }

  void _showImageToolbar() {
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      final docBoundingBox = (_superDocLayoutKey.currentState as DocumentLayout)
          .getRectForSelection(
            _composer.selection!.base,
            _composer.selection!.extent,
          )!;
      final renderObject = _superDocLayoutKey.currentContext
          ?.findRenderObject();
      RenderBox? docBox;
      if (renderObject is RenderBox) {
        docBox = renderObject;
      } else {
        return;
      }

      final overlayBoundingBox = Rect.fromPoints(
        docBox.localToGlobal(docBoundingBox.topLeft),
        docBox.localToGlobal(docBoundingBox.bottomRight),
      );

      _imageSelectionAnchor.value = overlayBoundingBox.center;
    });

    _imageFormatBarOverlayController.show();
  }

  void _showEditorToolbar() {
    _textFormatBarOverlayController.show();

    // Schedule a callback after this frame to locate the selection
    // bounds on the screen and display the toolbar near the selected
    // text.
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      final layout = _superDocLayoutKey.currentState as DocumentLayout;
      final docBoundingBox = layout.getRectForSelection(
        _composer.selection!.base,
        _composer.selection!.extent,
      )!;
      final globalOffset = layout.getGlobalOffsetFromDocumentOffset(
        Offset.zero,
      );
      final overlayBoundingBox = docBoundingBox.shift(globalOffset);

      _textSelectionAnchor.value = overlayBoundingBox.topCenter;
    });
  }

  void _hideEditorToolbar() {
    _textSelectionAnchor.value = null;
    _textFormatBarOverlayController.hide();

    if (FocusManager.instance.primaryFocus != FocusManager.instance.rootScope) {
      _editorFocusNode.requestFocus();
    }
  }

  void _hideImageToolbar() {
    _imageSelectionAnchor.value = null;
    _imageFormatBarOverlayController.hide();

    if (FocusManager.instance.primaryFocus != FocusManager.instance.rootScope) {
      _editorFocusNode.requestFocus();
    }
  }

  void _hideOrShowToolbar() {
    if (_gestureMode != DocumentGestureMode.mouse) {
      // We only add our own toolbar when using mouse. On mobile, a bar
      // is rendered for us.
      return;
    }

    if (_isSearchVisible) {
      _hideEditorToolbar();
      _hideImageToolbar();
      return;
    }

    final selection = _composer.selection;
    if (selection == null) {
      _hideEditorToolbar();
      return;
    }
    if (selection.base.nodeId != selection.extent.nodeId) {
      _hideEditorToolbar();
      _hideImageToolbar();
      return;
    }
    if (selection.isCollapsed) {
      _hideEditorToolbar();
      _hideImageToolbar();
      return;
    }

    final selectedNode = _doc.getNodeById(selection.extent.nodeId);

    if (selectedNode is ImageNode) {
      _showImageToolbar();
      _hideEditorToolbar();
      return;
    } else {
      _hideImageToolbar();
    }

    if (selectedNode is TextNode) {
      _showEditorToolbar();
      _hideImageToolbar();
      return;
    } else {
      _hideEditorToolbar();
    }
  }

  void _cut() {
    _docOps.cut();
    _overlayController.hideToolbar();
    _iosControlsController.hideToolbar();
  }

  void _copy() {
    _docOps.copy();
    _overlayController.hideToolbar();
    _iosControlsController.hideToolbar();
  }

  void _paste() {
    _docOps.paste();
    _overlayController.hideToolbar();
    _iosControlsController.hideToolbar();
  }

  void _selectAll() => _docOps.selectAll();

  Widget _buildAndroidFloatingToolbar() {
    return ListenableBuilder(
      listenable: _brightness,
      builder: (context, _) {
        return Theme(
          data: ThemeData(brightness: _brightness.value),
          child: AndroidTextEditingFloatingToolbar(
            onCutPressed: _cut,
            onCopyPressed: _copy,
            onPastePressed: _paste,
            onSelectAllPressed: _selectAll,
          ),
        );
      },
    );
  }

  Widget _buildImageToolbar(BuildContext context) {
    return ImageFormatToolbar(
      anchor: _imageSelectionAnchor,
      composer: _composer,
      setWidth: (nodeId, width) {
        final node = _doc.getNodeById(nodeId)!;
        final currentStyles = SingleColumnLayoutComponentStyles.fromMetadata(
          node,
        );

        _docEditor.execute([
          ChangeSingleColumnLayoutComponentStylesRequest(
            nodeId: nodeId,
            styles: SingleColumnLayoutComponentStyles(
              width: width,
              padding: currentStyles.padding,
            ),
          ),
        ]);
      },
      closeToolbar: _hideImageToolbar,
    );
  }

  bool get _isMobile => _gestureMode != DocumentGestureMode.mouse;

  Widget _buildMountedToolbar() {
    return MultiListenableBuilder(
      listenables: <Listenable>{_docChangeSignal, _composer.selectionNotifier},
      builder: (_) {
        final selection = _composer.selection;

        if (selection == null) {
          return const SizedBox();
        }

        return KeyboardEditingToolbar(
          editor: _docEditor,
          document: _doc,
          composer: _composer,
          commonOps: _docOps,
        );
      },
    );
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
                  // 返回前保存当前视图的内容到文件
                  _saveBeforeSwitch();
                  // 通知父组件笔记已更新
                  widget.onNoteChanged(note);
                  // 上传到git
                  widget.saveNote(note);
                  // 返回并传递 true 表示笔记已更新
                  Navigator.pop(context, true);
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
                  SizedBox(height: 4),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      return ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth,
                        ),
                        child: FittedBox(
                          alignment: Alignment.centerLeft,
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '修改时间: ${note.lastModified.toString().substring(0, 16)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
              actions: [
                // 查找按钮：普通编辑模式或 SuperEditor 模式
                if (_viewMode == 'edit' || _viewMode == 'superEditor')
                  IconButton(
                    icon: Icon(Icons.find_in_page),
                    onPressed: _viewMode == 'superEditor'
                        ? _toggleSuperSearch
                        : _toggleFindPanel,
                    tooltip: '查找 (Ctrl+F)',
                  ),
                // 普通编辑模式按钮
                IconButton(
                  icon: Icon(
                    Icons.edit_note,
                    color: _viewMode == 'edit' ? Colors.blue : Colors.grey,
                  ),
                  onPressed: () {
                    // 切换到普通编辑模式前，先保存当前内容
                    _saveBeforeSwitch();
                    setState(() {
                      _viewMode = 'edit';
                      // 从 SuperEditor 或 preview 切换到 edit 时，更新 textController
                      _textController.text = note.content;
                      if (_findController.text.isNotEmpty) {
                        _findMatches();
                      }
                    });
                  },
                  tooltip: '普通编辑',
                ),
                // 预览模式按钮
                IconButton(
                  icon: Icon(
                    Icons.preview,
                    color: _viewMode == 'preview' ? Colors.blue : Colors.grey,
                  ),
                  onPressed: () {
                    // 切换到预览模式前，先保存当前内容
                    _saveBeforeSwitch();
                    setState(() {
                      _viewMode = 'preview';
                      if (_showFindPanel) {
                        _closeFindPanel();
                      }
                    });
                  },
                  tooltip: '预览',
                ),
                // SuperEditor 模式按钮
                IconButton(
                  icon: Icon(
                    Icons.format_paint,
                    color: _viewMode == 'superEditor'
                        ? Colors.blue
                        : Colors.grey,
                  ),
                  onPressed: () {
                    // 切换到 SuperEditor 模式前，先保存当前内容
                    _saveBeforeSwitch();
                    setState(() {
                      _viewMode = 'superEditor';
                      if (_showFindPanel) {
                        _closeFindPanel();
                      }
                    });
                  },
                  tooltip: 'SuperEditor',
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
                // 查找面板
                if (_viewMode == 'edit' && _showFindPanel) _buildFindPanel(),
                if (_viewMode == 'superEditor' && _isSearchVisible)
                  _buildSuperSearchBar(),
                Expanded(
                  child: _viewMode == 'edit'
                      ? _buildEditor()
                      : _viewMode == 'preview'
                      ? _buildPreview()
                      : _buildSuperEditorView(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // SuperEditor 视图构建器（包含 Overlay）
  Widget _buildSuperEditorView() {
    return ValueListenableBuilder(
      valueListenable: _brightness,
      builder: (context, brightness, child) {
        return Theme(data: Theme.of(context), child: child!);
      },
      child: Builder(
        builder: (builderContext) {
          return OverlayPortal(
            controller: _textFormatBarOverlayController,
            overlayChildBuilder: _buildFloatingToolbar,
            child: OverlayPortal(
              controller: _imageFormatBarOverlayController,
              overlayChildBuilder: _buildImageToolbar,
              child: Stack(
                children: [
                  Column(
                    children: [
                      Expanded(child: _buildSuperEditor()),
                      if (_isMobile) _buildMountedToolbar(),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
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

  final _selectableTextKey = GlobalKey();

  // SuperEditor 搜索栏
  Widget _buildSuperSearchBar() {
    return Container(
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: Theme.of(context).appBarTheme.backgroundColor,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              decoration: const InputDecoration(
                hintText: 'Search...',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              onChanged: (value) {
                if (value.isEmpty) {
                  _clearSuperSearch();
                  return;
                }
                _performSuperSearch(value);
              },
              onSubmitted: (value) {
                _performSuperSearch(value);
              },
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _searchResults.isEmpty || _currentSearchIndex == -1
                ? '0/0'
                : '${_currentSearchIndex + 1}/${_searchResults.length}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up),
            onPressed: _searchResults.isEmpty
                ? null
                : _previousSuperSearchResult,
            tooltip: 'Previous match',
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: _searchResults.isEmpty ? null : _nextSuperSearchResult,
            tooltip: 'Next match',
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () {
              _clearSuperSearch();
              _isSearchVisible = false;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _superEditorScrollController.animateTo(
                  targetPosition,
                  duration: const Duration(milliseconds: 30),
                  curve: Curves.easeInOut,
                );
                PausableValueNotifier notifier =
                    _composer.selectionNotifier as PausableValueNotifier;
                notifier.value = targetSelection;
              });
            },
            tooltip: 'Clear search',
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
              ? LayoutBuilder(
                  builder: (context, constraints) {
                    return SelectableText.rich(
                      key: _selectableTextKey,
                      TextSpan(children: _highlightedSpans),
                      style: TextStyle(fontSize: 14, height: 1.4),
                    );
                  },
                )
              : TextField(
                  controller: _textController,
                  maxLines: null,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: '开始输入内容...',
                    hintStyle: TextStyle(color: Colors.white30),
                  ),
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    height: 1.4,
                  ),
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

  // SuperEditor 构建方法
  Widget _buildSuperEditor() {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return LayoutBuilder(
      builder: (context, constraints) {
        return ColoredBox(
          color: Theme.of(context).canvasColor,
          child: SuperEditorDebugVisuals(
            child: KeyedSubtree(
              key: _superViewportKey,
              child: SuperEditorIosControlsScope(
                controller: _iosControlsController,
                child: _isSearchVisible
                    ? SuperReader(
                        editor: _docEditor,
                        scrollController: _superEditorScrollController,
                        documentLayoutKey: _superDocLayoutKey,
                        stylesheet: defaultStylesheet.copyWith(
                          addRulesAfter: [if (!isLight) ..._darkModeStyles],
                        ),
                        selectionLayerLinks: _selectionLayerLinks,
                        selectionStyle: isLight
                            ? defaultSelectionStyle
                            : SelectionStyles(
                                selectionColor: Colors.yellow.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                      )
                    : SuperEditor(
                        editor: _docEditor,
                        focusNode: _editorFocusNode,
                        scrollController: _superEditorScrollController,
                        documentLayoutKey: _superDocLayoutKey,
                        documentOverlayBuilders: [
                          DefaultCaretOverlayBuilder(
                            caretStyle: const CaretStyle().copyWith(
                              color: isLight ? Colors.black : Colors.redAccent,
                            ),
                          ),
                          if (defaultTargetPlatform == TargetPlatform.iOS) ...[
                            SuperEditorIosHandlesDocumentLayerBuilder(),
                            SuperEditorIosToolbarFocalPointDocumentLayerBuilder(),
                          ],
                          if (defaultTargetPlatform == TargetPlatform.android) ...[
                            SuperEditorAndroidToolbarFocalPointDocumentLayerBuilder(),
                            SuperEditorAndroidHandlesDocumentLayerBuilder(),
                          ],
                        ],
                        selectionLayerLinks: _selectionLayerLinks,
                        selectionStyle: isLight
                            ? defaultSelectionStyle
                            : SelectionStyles(
                                selectionColor: Colors.red.withValues(alpha: 0.3),
                              ),
                        stylesheet: defaultStylesheet.copyWith(
                          addRulesAfter: [
                            if (!isLight) ..._darkModeStyles,
                            StyleRule(BlockSelector.all, (doc, docNode) {
                              return {
                                Styles.backgroundColor: Theme.of(
                                  context,
                                ).canvasColor,
                              };
                            }),
                            StyleRule(BlockSelector.all, (doc, docNode) {
                              return {
                                Styles.maxWidth: constraints.maxWidth,
                              };
                            }),
                          ],
                        ),
                        componentBuilders: defaultComponentBuilders,
                        gestureMode: _gestureMode,
                        inputSource: _inputSource,
                        keyboardActions: _inputSource == TextInputSource.ime
                            ? defaultImeKeyboardActions
                            : defaultKeyboardActions,
                        androidToolbarBuilder: (_) =>
                            _buildAndroidFloatingToolbar(),
                        overlayController: _overlayController,
                        plugins: {_markdownPlugin},
                      ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPreview() {
    // 使用flutter_markdown包实现真正的Markdown预览
    return fm.Markdown(
      data: note.content,
      selectable: true,
      imageDirectory: SPUtil.get<String>(PrefKeys.workingDirectory, ''),
      // 添加图片显示相关配置
      imageBuilder: (uri, title, alt) {
        final path = uri.toString();

        // 判断是否为网络路径
        if (path.contains('://') && !path.startsWith('file://')) {
          return _buildNetworkImage(path);
        }
        // 本地路径（相对或绝对）
        return _buildLocalImage(path);
      },
      styleSheet: fm.MarkdownStyleSheet(
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

  // 构建网络图片
  Widget _buildNetworkImage(String path) {
    final screenWidth = MediaQuery.of(context).size.width;
    final maxWidth = screenWidth * 0.68;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Image.network(
        path,
        fit: BoxFit.contain,
        width: maxWidth,
        errorBuilder: (context, error, stackTrace) =>
            _buildErrorWidget('图片加载失败', path),
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Container(
            height: 200,
            child: Center(
              child: CircularProgressIndicator(
                value: loadingProgress.expectedTotalBytes != null
                    ? loadingProgress.cumulativeBytesLoaded /
                          loadingProgress.expectedTotalBytes!
                    : null,
              ),
            ),
          );
        },
      ),
    );
  }

  // 构建本地图片
  Widget _buildLocalImage(String path) {
    return FutureBuilder<File>(
      future: _resolveLocalImagePath(path),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            height: 200,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return _buildErrorWidget('图片未找到', path);
        }

        return Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: FutureBuilder<double>(
            future: _calculateDisplayWidth(snapshot.data!),
            builder: (context, widthSnapshot) {
              final displayWidth =
                  widthSnapshot.data ??
                  MediaQuery.of(context).size.width * 0.68;

              return Image.file(
                snapshot.data!,
                fit: BoxFit.contain,
                width: displayWidth,
                errorBuilder: (context, error, stackTrace) =>
                    _buildErrorWidget('图片加载失败', snapshot.data!.path),
              );
            },
          ),
        );
      },
    );
  }

  // 计算图片显示宽度（异步避免阻塞UI）
  Future<double> _calculateDisplayWidth(File file) async {
    final screenWidth = MediaQuery.of(context).size.width;
    final maxWidth = screenWidth * 0.68;

    try {
      final bytes = await file.readAsBytes();
      final decodedImage = await decodeImageFromList(bytes);
      final imageWidth = decodedImage.width.toDouble();
      return imageWidth < maxWidth ? imageWidth : maxWidth;
    } catch (e) {
      return maxWidth;
    }
  }

  // 统一的错误显示组件
  Widget _buildErrorWidget(String message, String path) {
    return Container(
      padding: EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey[850],
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image, color: Colors.grey[600], size: 48),
          SizedBox(height: 8),
          Text(
            message,
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
          SizedBox(height: 4),
          Text(
            path,
            style: TextStyle(color: Colors.grey[600], fontSize: 10),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // 解析本地图片路径
  Future<File> _resolveLocalImagePath(String path) async {
    final workingDir = SPUtil.get<String>(PrefKeys.workingDirectory, '');
    final noteDir = note.id.substring(0, note.id.lastIndexOf('/'));
    final basePath = '$workingDir/$noteDir';

    // 移除 file:// 前缀
    path = path.replaceFirst('file://', '');

    // 绝对路径直接返回
    if (path.startsWith('/') || (path.length > 2 && path[1] == ':')) {
      return File(path);
    }

    // 移除 ./ 前缀
    if (path.startsWith('./') || path.startsWith('.\\')) {
      path = path.substring(2);
    }

    final fullPath = '$basePath/$path';
    final file = File(fullPath);

    if (!await file.exists()) {
      throw Exception('File not found: $fullPath');
    }

    return file;
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

// SuperEditor 暗色模式样式（与预览模式保持一致）
final _darkModeStyles = [
  StyleRule(BlockSelector.all, (doc, docNode) {
    return {
      Styles.textStyle: const TextStyle(
        color: Color(0xFFFFFFFF),
        fontSize: 14,
        height: 1.4,
      ),
      Styles.padding: const EdgeInsets.all(16),
    };
  }),
  StyleRule(const BlockSelector("header1"), (doc, docNode) {
    return {
      Styles.textStyle: const TextStyle(
        color: Color(0xFFFFFFFF),
        fontSize: 26,
        fontWeight: FontWeight.bold,
      ),
    };
  }),
  StyleRule(const BlockSelector("header2"), (doc, docNode) {
    return {
      Styles.textStyle: const TextStyle(
        color: Color(0xFFFFFFFF),
        fontSize: 22,
        fontWeight: FontWeight.bold,
      ),
    };
  }),
  StyleRule(const BlockSelector("header3"), (doc, docNode) {
    return {
      Styles.textStyle: const TextStyle(
        color: Color(0xFFFFFFFF),
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
    };
  }),
  StyleRule(const BlockSelector("paragraph"), (doc, docNode) {
    return {
      Styles.textStyle: const TextStyle(
        color: Color(0xFFB3B3B3),
        fontSize: 14,
        height: 1.6,
      ),
    };
  }),
];
