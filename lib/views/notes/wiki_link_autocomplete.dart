/// `[[` 双链输入自动补全：候选计算逻辑 + 两端 UI 呈现。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:ashes_note/models/notes/note_index_models.dart';
import 'package:ashes_note/services/notes/notes_index_service.dart';
import 'package:ashes_note/services/notes/wiki_link_parser.dart' as wiki;
import 'package:ashes_note/utils/const.dart';

/// 补全状态机：只负责「算候选」与「算插入结果」，不关心 UI。
class WikiAutocompleteController extends ChangeNotifier {
  final String? currentNotebook;

  Timer? _debounce;
  wiki.AutocompleteContext? _context;
  List<NoteRef> _candidates = const [];
  int _selectedIndex = 0;

  WikiAutocompleteController({this.currentNotebook});

  /// 当前是否应展示候选浮层。
  bool get isActive => _context != null && _candidates.isNotEmpty;

  List<NoteRef> get candidates => _candidates;
  int get selectedIndex => _selectedIndex;
  wiki.AutocompleteContext? get context => _context;

  /// 当前高亮的候选。
  NoteRef? get selected =>
      isActive && _selectedIndex < _candidates.length
      ? _candidates[_selectedIndex]
      : null;

  /// 文本或光标变化时调用，带防抖。
  void onTextChanged(String text, int caret) {
    _debounce?.cancel();
    _debounce = Timer(NoteIndexConstants.autocompleteDebounce, () {
      _recompute(text, caret);
    });
  }

  /// 立即重算，不走防抖（用于按键导航后同步状态）。
  void recomputeNow(String text, int caret) {
    _debounce?.cancel();
    _recompute(text, caret);
  }

  void _recompute(String text, int caret) {
    final ctx = wiki.detectAutocomplete(text, caret);
    if (ctx == null) {
      _clear();
      return;
    }

    final results = NotesIndexService().searchTitles(
      ctx.prefix,
      currentNotebook: currentNotebook,
    );

    if (results.isEmpty) {
      _clear();
      return;
    }

    _context = ctx;
    _candidates = results;
    // 前缀变化后重置高亮项，避免停留在越界索引。
    if (_selectedIndex >= results.length) _selectedIndex = 0;
    notifyListeners();
  }

  void _clear() {
    if (_context == null && _candidates.isEmpty) return;
    _context = null;
    _candidates = const [];
    _selectedIndex = 0;
    notifyListeners();
  }

  /// 主动关闭候选（Esc 或失焦）。
  void dismiss() {
    _debounce?.cancel();
    _clear();
  }

  void moveSelection(int delta) {
    if (!isActive) return;
    final len = _candidates.length;
    _selectedIndex = (_selectedIndex + delta + len) % len;
    notifyListeners();
  }

  void selectAt(int index) {
    if (index < 0 || index >= _candidates.length) return;
    _selectedIndex = index;
    notifyListeners();
  }

  /// 用当前高亮候选生成插入结果；无候选时返回 null。
  wiki.AutocompleteResult? buildResult(String text, {NoteRef? ref}) {
    final ctx = _context;
    final target = ref ?? selected;
    if (ctx == null || target == null) return null;
    return wiki.applyAutocomplete(text, ctx, target);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

/// 桌面端候选栏：置于编辑器顶部，风格对齐查找面板。
class WikiAutocompleteBar extends StatelessWidget implements PreferredSizeWidget {
  final WikiAutocompleteController controller;

  /// 选中某个候选时回调。
  final void Function(NoteRef ref) onPick;

  final VoidCallback onDismiss;

  const WikiAutocompleteBar({
    super.key,
    required this.controller,
    required this.onPick,
    required this.onDismiss,
  });

  @override
  Size get preferredSize => const Size.fromHeight(40);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.isActive) return const SizedBox.shrink();

        return Container(
          height: 40,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: [
              const SizedBox(width: 10),
              Icon(Icons.link, size: 14, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: controller.candidates.length,
                  itemBuilder: (context, i) {
                    final ref = controller.candidates[i];
                    final active = i == controller.selectedIndex;
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 3,
                        vertical: 6,
                      ),
                      child: Material(
                        color: active
                            ? theme.colorScheme.primary
                            : theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(4),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () => onPick(ref),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  ref.displayTitle,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: active
                                        ? theme.colorScheme.onPrimary
                                        : null,
                                    fontWeight: active
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                                if (ref.notebookName.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    ref.notebookName,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: active
                                          ? theme.colorScheme.onPrimary
                                                .withValues(alpha: 0.7)
                                          : theme.hintColor,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Text(
                '↑↓ 选择 · Enter 插入 · Esc 关闭',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 14),
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 移动端候选条：置于输入区上方（键盘之上）。
class WikiAutocompleteStrip extends StatelessWidget {
  final WikiAutocompleteController controller;
  final void Function(NoteRef ref) onPick;

  const WikiAutocompleteStrip({
    super.key,
    required this.controller,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.isActive) return const SizedBox.shrink();

        return Container(
          height: 44,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            border: Border(top: BorderSide(color: theme.dividerColor)),
          ),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            itemCount: controller.candidates.length,
            itemBuilder: (context, i) {
              final ref = controller.candidates[i];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: ActionChip(
                  avatar: Icon(
                    Icons.link,
                    size: 13,
                    color: theme.colorScheme.primary,
                  ),
                  label: Text(
                    ref.displayTitle,
                    style: theme.textTheme.labelMedium,
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onPick(ref),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// 供桌面编辑器包裹使用的键盘快捷键映射。
///
/// 把上下键、回车、Esc 交给补全控制器处理；补全未激活时不拦截。
Map<ShortcutActivator, VoidCallback> buildAutocompleteShortcuts({
  required WikiAutocompleteController controller,
  required VoidCallback onAccept,
}) {
  return {
    const SingleActivator(LogicalKeyboardKey.arrowDown): () {
      if (controller.isActive) controller.moveSelection(1);
    },
    const SingleActivator(LogicalKeyboardKey.arrowUp): () {
      if (controller.isActive) controller.moveSelection(-1);
    },
    const SingleActivator(LogicalKeyboardKey.enter): () {
      if (controller.isActive) onAccept();
    },
    const SingleActivator(LogicalKeyboardKey.escape): () {
      if (controller.isActive) controller.dismiss();
    },
  };
}
