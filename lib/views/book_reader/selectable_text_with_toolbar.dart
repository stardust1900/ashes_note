import 'package:flutter/material.dart';

/// 带工具栏的可选择文本组件
/// 捕获文本选择时的位置，使工具栏贴近选择区域
class SelectableTextWithToolbar extends StatefulWidget {
  final String text;
  final TextStyle style;
  final int textStartOffset; // 文本在章节中的起始偏移
  final int chapterIndex;
  final int pageIndex;
  final List<TextSpan> spans; // 带高亮的文本片段
  final Function(
    String selectedText,
    Offset position,
    int startOffset,
    int endOffset,
  )
  onTextSelected;
  final VoidCallback onSelectionCleared;

  const SelectableTextWithToolbar({
    required this.text,
    required this.style,
    required this.textStartOffset,
    required this.chapterIndex,
    required this.pageIndex,
    required this.spans,
    required this.onTextSelected,
    required this.onSelectionCleared,
  });

  @override
  State<SelectableTextWithToolbar> createState() =>
      SelectableTextWithToolbarState();
}

class SelectableTextWithToolbarState
    extends State<SelectableTextWithToolbar> {
  final GlobalKey _selectableKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return SelectableText.rich(
      key: _selectableKey,
      TextSpan(children: widget.spans, style: widget.style),
      onSelectionChanged: (selection, cause) {
        if (selection.isValid && !selection.isCollapsed) {
          // 用户选择了文本
          // 获取选中的原始文本
          final selectedText = widget.text.substring(
            selection.start.clamp(0, widget.text.length),
            selection.end.clamp(0, widget.text.length),
          );

          if (selectedText.isNotEmpty) {
            // 计算在章节中的实际偏移位置
            final startOffset = widget.textStartOffset + selection.start;
            final endOffset = widget.textStartOffset + selection.end;

            // 计算选中文本的实际位置
            final position = _calculateSelectionPosition(selection);
            widget.onTextSelected(
              selectedText,
              position,
              startOffset,
              endOffset,
            );
          }
        } else if (selection.isCollapsed) {
          // 选择被取消
          widget.onSelectionCleared();
        }
      },
      // 禁用默认上下文菜单，使用自定义工具栏
      contextMenuBuilder: (context, editableTextState) {
        return const SizedBox.shrink();
      },
    );
  }

  /// 计算选中文本的位置（使用 RenderBox 获取实际边界）
  Offset _calculateSelectionPosition(TextSelection selection) {
    final RenderBox? renderBox =
        _selectableKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return _calculateCenterPosition();
    }

    // 获取文本的渲染信息
    final TextPainter textPainter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
    )..layout(maxWidth: renderBox.size.width);

    // 获取选中文本的坐标
    final startRect = textPainter.getBoxesForSelection(
      TextSelection(
        baseOffset: selection.start,
        extentOffset: selection.start + 1,
      ),
    );
    final endRect = textPainter.getBoxesForSelection(
      TextSelection(baseOffset: selection.end - 1, extentOffset: selection.end),
    );

    // 计算选中区域的中点
    double top;
    double left;

    if (startRect.isNotEmpty && endRect.isNotEmpty) {
      top = (startRect.first.toRect().top + endRect.last.toRect().bottom) / 2;
      left = (startRect.first.toRect().left + endRect.last.toRect().right) / 2;
    } else {
      return _calculateCenterPosition();
    }

    // 转换为全局坐标
    final localPosition = Offset(left, top);
    final globalPosition = renderBox.localToGlobal(localPosition);

    return globalPosition;
  }

  /// 计算屏幕中央位置（作为备选）
  Offset _calculateCenterPosition() {
    final screenSize = MediaQuery.of(context).size;
    return Offset(screenSize.width / 2, screenSize.height * 0.4);
  }
}
