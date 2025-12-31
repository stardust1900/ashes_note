import 'dart:async';
import 'dart:convert';
import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:ashes_note/logging.dart';
import 'package:ashes_note/utils/const.dart';
import 'package:ashes_note/utils/file_util.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:ashes_note/views/_toolbar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:super_editor/super_editor.dart';

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
  final GlobalKey _docLayoutKey = GlobalKey();
  late MutableDocument _doc;
  late final MutableDocumentComposer _composer;
  late final Editor _docEditor;
  late CommonEditorOperations _docOps;
  final _docChangeSignal = SignalNotifier();
  late FocusNode _editorFocusNode;
  late ScrollController _scrollController;

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

  // Search functionality variables
  final TextEditingController _searchController = TextEditingController();
  late List<DocumentSelection> _searchResults;
  int _currentSearchIndex = -1;
  bool _isSearchVisible = false;
  String _currentSearchTerm = '';
  final FocusNode _searchFocusNode = FocusNode();
  double targetPosition = 0.0;
  DocumentSelection? targetSelection;
  ThemeData? mainTheme;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _brightness.value = Theme.of(context).brightness;
      // mainTheme = Theme.of(context);
    });

    note = widget.note;
    _titleController.text = note.title.replaceAll('.md', '');
    _doc = deserializeMarkdownToDocument(note.content)
      ..addListener(_onDocumentChange);
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
          _docLayoutKey.currentState as DocumentLayout,
    );
    _editorFocusNode = FocusNode();
    _scrollController = ScrollController()..addListener(_hideOrShowToolbar);
    _iosControlsController = SuperEditorIosControlsController();

    _searchResults = [];
  }

  @override
  void dispose() {
    _iosControlsController.dispose();
    _scrollController.dispose();
    _editorFocusNode.dispose();
    _composer.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _titleController.dispose();
    super.dispose();
  }

  void _onDocumentChange(_) {
    _hideOrShowToolbar();
    _docChangeSignal.notifyListeners();
    // If we're searching, re-run the search after document changes
    if (_isSearchVisible && _currentSearchTerm.isNotEmpty) {
      _performSearch(_currentSearchTerm);
    }

    if (note.content != serializeDocumentToMarkdown(_doc)) {
      // 延迟保存，避免频繁写文件
      Timer(const Duration(seconds: 1), () {
        FileUtil().saveFile(
          SPUtil.get<String>(PrefKeys.workingDirectory, ''),
          note.id.substring(0, note.id.lastIndexOf('/')),
          note.title,
          utf8.encode(note.content),
        );
      });
    }
  }

  void _performSearch(String searchTerm) {
    if (searchTerm.isEmpty) {
      _clearSearch();
      return;
    }

    _currentSearchTerm = searchTerm;
    _searchResults = [];

    // Search through all text nodes in the document
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

          // Create a selection for this occurrence
          final start = DocumentPosition(
            nodeId: node.id,
            nodePosition: TextNodePosition(offset: index),
          );
          final end = DocumentPosition(
            nodeId: node.id,
            nodePosition: TextNodePosition(offset: index + searchTerm.length),
          );

          _searchResults.add(DocumentSelection(base: start, extent: end));

          startIndex = index + 1; // Move past this match to find the next
        }
      }
    }

    if (_searchResults.isNotEmpty) {
      _currentSearchIndex = 0;
      _jumpToSearchResult(_currentSearchIndex);
    } else {
      _currentSearchIndex = -1;
    }

    setState(() {});
  }

  void _jumpToSearchResult(int index) {
    if (index >= 0 && index < _searchResults.length) {
      final selection = _searchResults[index];
      PausableValueNotifier notifier =
          _composer.selectionNotifier as PausableValueNotifier;
      notifier.value = selection;
      targetSelection = selection;
      // Scroll to the found text
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final layout = _docLayoutKey.currentState as DocumentLayout;
        final rect = layout.getRectForSelection(
          selection.base,
          selection.extent,
        );
        if (rect != null) {
          targetPosition = rect.top - 100;
          _scrollController.animateTo(
            rect.top - 100, // Add some padding at the top
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
      });
    }
  }

  void _nextSearchResult() {
    if (_searchResults.isEmpty) return;

    _currentSearchIndex = (_currentSearchIndex + 1) % _searchResults.length;
    _jumpToSearchResult(_currentSearchIndex);
    setState(() {});
  }

  void _previousSearchResult() {
    if (_searchResults.isEmpty) return;

    _currentSearchIndex = _currentSearchIndex <= 0
        ? _searchResults.length - 1
        : _currentSearchIndex - 1;
    _jumpToSearchResult(_currentSearchIndex);
    setState(() {});
  }

  void _clearSearch() {
    setState(() {
      _currentSearchTerm = '';
      _searchResults = [];
      _currentSearchIndex = -1;
      // _isSearchVisible = false;
      _searchController.clear();
      _composer.clearSelection();
    });
  }

  void _toggleSearch() {
    targetPosition = 0.0;
    targetSelection = null;
    _hideEditorToolbar();
    _hideImageToolbar();
    setState(() {
      _isSearchVisible = !_isSearchVisible;
      if (!_isSearchVisible) {
        _clearSearch();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _searchFocusNode.requestFocus();
        });
      }
    });
  }

  void _showImageToolbar() {
    // Schedule a callback after this frame to locate the selection
    // bounds on the screen and display the toolbar near the selected
    // text.
    // TODO: switch to a Leader and Follower for this
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      final docBoundingBox = (_docLayoutKey.currentState as DocumentLayout)
          .getRectForSelection(
            _composer.selection!.base,
            _composer.selection!.extent,
          )!;
      final renderObject = _docLayoutKey.currentContext?.findRenderObject();
      RenderBox? docBox;
      if (renderObject is RenderBox) {
        docBox = renderObject;
      } else if (renderObject is RenderSliverToBoxAdapter) {
        final child = renderObject.child;
        if (child is RenderBox) {
          docBox = child;
        } else {
          return;
        }
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
    // TODO: switch this to use a Leader and Follower
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      final layout = _docLayoutKey.currentState as DocumentLayout;
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

  void _hideOrShowToolbar() {
    if (_gestureMode != DocumentGestureMode.mouse) {
      // We only add our own toolbar when using mouse. On mobile, a bar
      // is rendered for us.
      return;
    }

    if (_isSearchVisible) {
      // Don't show toolbars when searching
      _hideEditorToolbar();
      _hideImageToolbar();
      return;
    }

    final selection = _composer.selection;
    if (selection == null) {
      // Nothing is selected. We don't want to show a toolbar
      // in this case.
      _hideEditorToolbar();

      return;
    }
    if (selection.base.nodeId != selection.extent.nodeId) {
      // More than one node is selected. We don't want to show
      // a toolbar in this case.
      _hideEditorToolbar();
      _hideImageToolbar();

      return;
    }
    if (selection.isCollapsed) {
      // We only want to show the toolbar when a span of text
      // is selected. Therefore, we ignore collapsed selections.
      _hideEditorToolbar();
      _hideImageToolbar();

      return;
    }

    final selectedNode = _doc.getNodeById(selection.extent.nodeId);

    if (selectedNode is ImageNode) {
      appLog.fine("Showing image toolbar");
      // Show the editor's toolbar for image sizing.
      _showImageToolbar();
      _hideEditorToolbar();
      return;
    } else {
      // The currently selected content is not an image. We don't
      // want to show the image toolbar.
      _hideImageToolbar();
    }

    if (selectedNode is TextNode) {
      // Show the editor's toolbar for text styling.
      _showEditorToolbar();
      _hideImageToolbar();
      return;
    } else {
      // The currently selected content is not a paragraph. We don't
      // want to show a toolbar in this case.
      _hideEditorToolbar();
    }
  }

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

  final GlobalKey _viewportKey = GlobalKey();

  final SelectionLayerLinks _selectionLayerLinks = SelectionLayerLinks();

  Widget _buildFloatingToolbar(BuildContext context) {
    return EditorToolbar(
      editorViewportKey: _viewportKey,
      anchor: _selectionLayerLinks.expandedSelectionBoundsLink,
      editorFocusNode: _editorFocusNode,
      editor: _docEditor,
      document: _doc,
      composer: _composer,
      closeToolbar: _hideEditorToolbar,
    );
  }

  void _hideEditorToolbar() {
    // Null out the selection anchor so that when it re-appears,
    // the bar doesn't momentarily "flash" at its old anchor position.
    _textSelectionAnchor.value = null;

    _textFormatBarOverlayController.hide();

    // Ensure that focus returns to the editor.
    //
    // I tried explicitly unfocus()'ing the URL textfield
    // in the toolbar but it didn't return focus to the
    // editor. I'm not sure why.
    //
    // Only do that if the primary focus is not at the root focus scope because
    // this might signify that the app is going to the background. Removing
    // the focus from the root focus scope in that situation prevents the editor
    // from re-gaining focus when the app is brought back to the foreground.
    //
    // See https://github.com/superlistapp/super_editor/issues/2279 for details.
    if (FocusManager.instance.primaryFocus != FocusManager.instance.rootScope) {
      _editorFocusNode.requestFocus();
    }
  }

  void _hideImageToolbar() {
    // Null out the selection anchor so that when the bar re-appears,
    // it doesn't momentarily "flash" at its old anchor position.
    _imageSelectionAnchor.value = null;

    _imageFormatBarOverlayController.hide();

    // Ensure that focus returns to the editor.
    //
    // Only do that if the primary focus is not at the root focus scope because
    // this might signify that the app is going to the background. Removing
    // the focus from the root focus scope in that situation prevents the editor
    // from re-gaining focus when the app is brought back to the foreground.
    //
    // See https://github.com/superlistapp/super_editor/issues/2279 for details.
    if (FocusManager.instance.primaryFocus != FocusManager.instance.rootScope) {
      _editorFocusNode.requestFocus();
    }
  }

  Widget _buildImageToolbar(BuildContext context) {
    return ImageFormatToolbar(
      anchor: _imageSelectionAnchor,
      composer: _composer,
      setWidth: (nodeId, width) {
        print("Applying width $width to node $nodeId");
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

  Widget _buildSearchBar() {
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
                  _clearSearch();
                  return;
                }
                _performSearch(value);
              },
              onSubmitted: (value) {
                _performSearch(value);
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
            onPressed: _searchResults.isEmpty ? null : _previousSearchResult,
            tooltip: 'Previous match',
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: _searchResults.isEmpty ? null : _nextSearchResult,
            tooltip: 'Next match',
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () {
              _clearSearch();
              _isSearchVisible = false;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _scrollController.animateTo(
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

  Widget _buildEditor(BuildContext context) {
    final isLight = mainTheme?.brightness == Brightness.light;
    return ColoredBox(
      color: Theme.of(context).canvasColor,
      // color: Color.fromARGB(255, 48, 48, 48),
      child: SuperEditorDebugVisuals(
        // config: _debugConfig ?? const SuperEditorDebugVisualsConfig(),
        child: KeyedSubtree(
          key: _viewportKey,
          child: SuperEditorIosControlsScope(
            controller: _iosControlsController,
            child: _isSearchVisible
                ? SuperReader(
                    editor: _docEditor,
                    scrollController: _scrollController,
                    documentLayoutKey: _docLayoutKey,
                    stylesheet: defaultStylesheet.copyWith(
                      addRulesAfter: [
                        if (!isLight) ..._darkModeStyles,
                        taskStyles,
                      ],
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
                    scrollController: _scrollController,
                    documentLayoutKey: _docLayoutKey,
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
                        taskStyles,
                        StyleRule(BlockSelector.all, (doc, docNode) {
                          return {
                            Styles.backgroundColor: Theme.of(
                              context,
                            ).canvasColor,
                          };
                        }),
                      ],
                    ),
                    componentBuilders: [
                      TaskComponentBuilder(_docEditor),
                      ...defaultComponentBuilders,
                    ],
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
    mainTheme = Theme.of(context); // 为主题赋值，以便在其他地方使用
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, bool? result) {
        print(
          "onPopInvokedWithResult called with didPop=$didPop, result=$result",
        );
        if (didPop) {
          return;
        }
        final content = serializeDocumentToMarkdown(_doc);
        if (note.content != content) {
          note.content = content;
          widget.saveNote(note);
          Navigator.pop(context, true);
          // Future.microtask(() {
          //   if (mounted) {
          //     Navigator.pop(context, true);
          //   }
          // });
        } else {
          Navigator.pop(context, false);
          // Future.microtask(() {
          //   Navigator.pop(context, false);
          // });
        }
      },
      child: Scaffold(
        appBar: AppBar(
          // backgroundColor: Theme.of(context).canvasColor,
          // foregroundColor: Theme.of(context).scaffoldBackgroundColor,
          leading: IconButton(
            icon: Icon(Icons.arrow_back),
            onPressed: () {
              final content = serializeDocumentToMarkdown(_doc);
              if (note.content != content) {
                note.content = content;
                widget.saveNote(note);
                Navigator.pop(context, true);
              } else {
                Navigator.pop(context, false);
              }
            },
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _titleController,
                onEditingComplete: () {
                  widget.onNoteChanged(note, newTitle: _titleController.text);
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
                    constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                    child: FittedBox(
                      alignment: Alignment.centerLeft,
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '修改时间: ${note.lastModified.toString().substring(0, 16)}',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: _toggleSearch,
              tooltip: 'Search',
            ),
            IconButton(
              icon: Icon(Icons.save),
              onPressed: () {
                note.content = serializeDocumentToMarkdown(_doc);
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
            if (_isSearchVisible) _buildSearchBar(),
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: _brightness,
                builder: (context, brightness, child) {
                  return Theme(data: mainTheme!, child: child!);
                },
                child: Builder(
                  // This builder captures the new theme
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
                                Expanded(child: _buildEditor(builderContext)),
                                if (_isMobile) //
                                  _buildMountedToolbar(),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Makes text light, for use during dark mode styling.
final _darkModeStyles = [
  StyleRule(BlockSelector.all, (doc, docNode) {
    return {Styles.textStyle: const TextStyle(color: Color(0xFFCCCCCC))};
  }),
  StyleRule(const BlockSelector("header1"), (doc, docNode) {
    return {Styles.textStyle: const TextStyle(color: Color(0xFF888888))};
  }),
  StyleRule(const BlockSelector("header2"), (doc, docNode) {
    return {Styles.textStyle: const TextStyle(color: Color(0xFF888888))};
  }),
];
