/// 单篇笔记的标签编辑条：展示、新增、移除标签。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:ashes_note/models/notes/note_index_models.dart';
import 'package:ashes_note/services/notes/notes_index_service.dart';

/// 按标签名稳定地生成一个默认颜色，保证同一标签在各处颜色一致。
Color defaultTagColor(String tag, ThemeData theme) {
  const palette = <int>[
    0xFF4C8DF6,
    0xFF27AE60,
    0xFFE67E22,
    0xFF8E44AD,
    0xFF16A085,
    0xFFD35400,
    0xFF2980B9,
    0xFFC0392B,
  ];
  var hash = 0;
  for (final unit in tag.toLowerCase().codeUnits) {
    hash = (hash * 31 + unit) & 0x7FFFFFFF;
  }
  return Color(palette[hash % palette.length]);
}

/// 取标签的最终显示色：优先用户自定义，其次按名称哈希。
Color resolveTagColor(String tag, ThemeData theme) {
  final custom = NotesIndexService().tagColorOf(tag);
  return custom != null ? Color(custom) : defaultTagColor(tag, theme);
}

class TagEditorBar extends StatefulWidget {
  /// 当前笔记 id。
  final String noteId;

  /// 是否允许编辑（只读场景传 false）。
  final bool editable;

  /// 紧凑模式，用于空间受限的移动端标题区。
  final bool dense;

  /// 点击标签时回调（通常用于跳转到按标签筛选）。
  final void Function(String tag)? onTagTap;

  const TagEditorBar({
    super.key,
    required this.noteId,
    this.editable = true,
    this.dense = false,
    this.onTagTap,
  });

  @override
  State<TagEditorBar> createState() => _TagEditorBarState();
}

class _TagEditorBarState extends State<TagEditorBar> {
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  bool _adding = false;

  @override
  void didUpdateWidget(covariant TagEditorBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换笔记时退出输入态，避免把标签加到错误的笔记上。
    if (oldWidget.noteId != widget.noteId && _adding) {
      _cancelAdding();
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _cancelAdding() {
    _inputController.clear();
    if (mounted) {
      setState(() => _adding = false);
    } else {
      _adding = false;
    }
  }

  Future<void> _commitTag(String raw) async {
    final tag = normalizeTagName(raw);
    if (tag.isEmpty) {
      _cancelAdding();
      return;
    }
    await NotesIndexService().addTag(widget.noteId, tag);
    _inputController.clear();
    // 连续添加：保持输入态并重新聚焦。
    if (mounted) _inputFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = NotesIndexService();

    return ListenableBuilder(
      listenable: index,
      builder: (context, _) {
        final tags = index.tagsOf(widget.noteId);

        if (tags.isEmpty && !widget.editable) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: widget.dense ? 12 : 16,
            vertical: widget.dense ? 4 : 6,
          ),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ...tags.map((t) => _buildChip(theme, t)),
              if (widget.editable)
                _adding ? _buildInput(theme, index) : _buildAddButton(theme),
            ],
          ),
        );
      },
    );
  }

  Widget _buildChip(ThemeData theme, String tag) {
    final color = resolveTagColor(tag, theme);
    final height = widget.dense ? 24.0 : 28.0;

    return Material(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(height / 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(height / 2),
        onTap: widget.onTagTap == null ? null : () => widget.onTagTap!(tag),
        child: Container(
          height: height,
          padding: EdgeInsets.only(left: 10, right: widget.editable ? 4 : 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tag,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (widget.editable) ...[
                const SizedBox(width: 2),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () =>
                      NotesIndexService().removeTag(widget.noteId, tag),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 12, color: color),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAddButton(ThemeData theme) {
    final height = widget.dense ? 24.0 : 28.0;

    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(height / 2),
        side: BorderSide(color: theme.dividerColor),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(height / 2),
        onTap: () {
          setState(() => _adding = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _inputFocus.requestFocus();
          });
        },
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 13, color: theme.hintColor),
              const SizedBox(width: 3),
              Text(
                '标签',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInput(ThemeData theme, NotesIndexService index) {
    final height = widget.dense ? 24.0 : 28.0;
    final existing = index.tagsOf(widget.noteId).map((e) => e.toLowerCase()).toSet();

    return SizedBox(
      height: height,
      width: 150,
      child: RawAutocomplete<String>(
        textEditingController: _inputController,
        focusNode: _inputFocus,
        optionsBuilder: (value) {
          final q = value.text.trim().toLowerCase();
          return index
              .allTagsWithCount()
              .map((e) => e.name)
              // 已有的标签不再作为候选。
              .where((name) => !existing.contains(name.toLowerCase()))
              .where((name) => q.isEmpty || name.toLowerCase().contains(q))
              .take(8);
        },
        onSelected: _commitTag,
        fieldViewBuilder: (context, controller, focusNode, onSubmit) {
          return Focus(
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                _cancelAdding();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              style: theme.textTheme.labelSmall,
              decoration: InputDecoration(
                isDense: true,
                hintText: '标签名',
                hintStyle: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor,
                  fontSize: 11,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(height / 2),
                ),
              ),
              onSubmitted: _commitTag,
              onTapOutside: (_) {
                if (controller.text.trim().isEmpty) _cancelAdding();
              },
            ),
          );
        },
        optionsViewBuilder: (context, onSelected, options) {
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200, maxWidth: 180),
                child: ListView(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  children: options
                      .map(
                        (o) => ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          leading: Icon(
                            Icons.local_offer_outlined,
                            size: 14,
                            color: resolveTagColor(o, theme),
                          ),
                          title: Text(o, style: theme.textTheme.bodySmall),
                          onTap: () => onSelected(o),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 只读的标签展示行，用于笔记列表项。
class TagChipsRow extends StatelessWidget {
  final List<String> tags;
  final int maxVisible;

  const TagChipsRow({super.key, required this.tags, this.maxVisible = 3});

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final visible = tags.take(maxVisible).toList();
    final overflow = tags.length - visible.length;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          ...visible.map((t) {
            final color = resolveTagColor(t, theme);
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                t,
                style: theme.textTheme.labelSmall?.copyWith(color: color),
              ),
            );
          }),
          if (overflow > 0)
            Text(
              '+$overflow',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
        ],
      ),
    );
  }
}
