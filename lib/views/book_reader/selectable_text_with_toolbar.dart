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
    super.key,
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
  TextPainter? _cachedTextPainter;
  String? _cachedText;
  TextStyle? _cachedStyle;
  double? _cachedMaxWidth;

  /// 清除文本选择状态
  /// 使用反射调用私有方法，因为 SelectableTextState 不是公开类型
  void clearSelection() {
    final state = _selectableKey.currentState;
    if (state != null) {
      try {
        // 使用 dynamic 类型绕过静态类型检查
        final dynamicState = state as dynamic;
        dynamicState.clearSelection();
      } catch (e) {
        // 如果方法不存在或调用失败，尝试使用其他方式清除选择
        // 某些 Flutter 版本可能使用不同的内部实现
      }
    }
  }

  /// 获取或创建缓存的 TextPainter
  TextPainter _getTextPainter(double maxWidth) {
    // 如果文本、样式或宽度变化，重新创建 TextPainter
    if (_cachedTextPainter == null ||
        _cachedText != widget.text ||
        _cachedStyle != widget.style ||
        _cachedMaxWidth != maxWidth) {
      _cachedTextPainter?.dispose();
      _cachedTextPainter = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
      )..layout(maxWidth: maxWidth);
      _cachedText = widget.text;
      _cachedStyle = widget.style;
      _cachedMaxWidth = maxWidth;
    }
    return _cachedTextPainter!;
  }

  @override
  void dispose() {
    _cachedTextPainter?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SelectableText.rich(
      key: _selectableKey,
      TextSpan(children: widget.spans, style: widget.style),
      onSelectionChanged: (selection, cause) {
        if (selection.isValid && !selection.isCollapsed) {
          // 用户选择了文本
          final textLength = widget.text.length;
          // 确保偏移量在有效范围内
          final startOffset = selection.start.clamp(0, textLength);
          final endOffset = selection.end.clamp(0, textLength);

          if (startOffset < endOffset && textLength > 0) {
            // 获取选中的原始文本
            final selectedText = widget.text.substring(startOffset, endOffset);

            if (selectedText.isNotEmpty) {
              // 计算在章节中的实际偏移位置
              final chapterStartOffset = widget.textStartOffset + startOffset;
              final chapterEndOffset = widget.textStartOffset + endOffset;

              // 计算选中文本的实际位置
              final position = _calculateSelectionPosition(selection);
              widget.onTextSelected(
                selectedText,
                position,
                chapterStartOffset,
                chapterEndOffset,
              );
            }
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
    // 验证 selection 是否有效
    if (!selection.isValid || widget.text.isEmpty) {
      return _calculateCenterPosition();
    }

    final RenderBox? renderBox =
        _selectableKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return _calculateCenterPosition();
    }

    // 使用缓存的 TextPainter
    final textPainter = _getTextPainter(renderBox.size.width);

    // 确保 offset 在有效范围内
    final textLength = widget.text.length;
    final startOffset = selection.start.clamp(0, textLength);
    final endOffset = selection.end.clamp(0, textLength);

    // 获取选中文本的坐标（改进边界处理）
    List<TextBox> startRect;
    if (startOffset < textLength) {
      // 只在有效范围内访问 startOffset + 1
      startRect = textPainter.getBoxesForSelection(
        TextSelection(
          baseOffset: startOffset,
          extentOffset: (startOffset + 1).clamp(0, textLength),
        ),
      );
    } else {
      startRect = [];
    }

    List<TextBox> endRect;
    if (endOffset > 0) {
      // 只在有效范围内访问 endOffset - 1
      endRect = textPainter.getBoxesForSelection(
        TextSelection(
          baseOffset: (endOffset - 1).clamp(0, textLength),
          extentOffset: endOffset,
        ),
      );
    } else {
      endRect = [];
    }

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
