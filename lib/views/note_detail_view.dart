import 'dart:async';
import 'dart:convert';
import 'package:ashes_note/utils/const.dart';
import 'package:ashes_note/utils/file_util.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:flutter/material.dart';
import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox, RenderEditable;
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

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
          SPUtil.get<String>(PrefKeys.workingDirectory, ''),
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

  final _selectableTextKey = GlobalKey();
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
