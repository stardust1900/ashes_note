/// 支持 `[[双向链接]]` 的 Markdown 预览组件。
///
/// 渲染前把正文中的 `[[...]]` 重写为标准 Markdown 链接，
/// 再通过 `onTapLink` 拦截自定义 scheme 完成跳转。
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as fm;
import 'package:url_launcher/url_launcher.dart';

import 'package:ashes_note/logging.dart';
import 'package:ashes_note/services/notes/notes_index_service.dart';
import 'package:ashes_note/services/notes/wiki_link_parser.dart' as wiki;

class WikiMarkdownView extends StatelessWidget {
  /// Markdown 原文（含 `[[...]]`）。
  final String data;

  /// 当前笔记所属笔记本，用于同名链接的消歧。
  final String? currentNotebook;

  /// 点击双链时回调。
  final void Function(wiki.OpenNoteIntent intent)? onOpenNote;

  final ScrollController? controller;
  final String? imageDirectory;
  final bool selectable;
  final bool shrinkWrap;
  final EdgeInsets? padding;
  final fm.MarkdownStyleSheet? styleSheet;
  final ScrollPhysics? physics;

  /// 自定义图片构建器，用于本地/网络图片的差异化加载。
  final fm.MarkdownImageBuilder? imageBuilder;

  const WikiMarkdownView({
    super.key,
    required this.data,
    this.currentNotebook,
    this.onOpenNote,
    this.controller,
    this.imageDirectory,
    this.selectable = true,
    this.shrinkWrap = false,
    this.padding,
    this.styleSheet,
    this.physics,
    this.imageBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final index = NotesIndexService();

    // 订阅索引变更：新建/删除笔记后，链接的存在状态需要实时反映。
    return ListenableBuilder(
      listenable: index,
      builder: (context, _) {
        final rewritten = index.rewriteForPreview(
          data,
          currentNotebook: currentNotebook,
        );

        final sheet = styleSheet ?? fm.MarkdownStyleSheet.fromTheme(Theme.of(context));

        return fm.Markdown(
          data: rewritten,
          selectable: selectable,
          shrinkWrap: shrinkWrap,
          controller: controller,
          imageDirectory: imageDirectory,
          physics: physics,
          padding: padding ?? const EdgeInsets.all(16),
          styleSheet: sheet,
          imageBuilder: imageBuilder,
          onTapLink: (text, href, title) => _handleTap(context, href),
        );
      },
    );
  }

  void _handleTap(BuildContext context, String? href) {
    if (href == null || href.isEmpty) return;

    final intent = wiki.parseOpenUri(href);
    if (intent != null) {
      onOpenNote?.call(intent);
      return;
    }

    _launchExternal(context, href);
  }

  Future<void> _launchExternal(BuildContext context, String href) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final uri = Uri.parse(href);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw Exception('系统未能打开该链接');
      }
    } catch (e) {
      appLog.warning('打开外部链接失败：$e');
      messenger?.showSnackBar(
        SnackBar(content: Text('无法打开链接：$href')),
      );
    }
  }
}

/// 为 Markdown 样式表补上双链的视觉区分。
///
/// 由于 `flutter_markdown_plus` 的 `styleSheet.a` 对所有链接统一生效，
/// 这里把双链与普通链接统一成主色，靠「待创建」链接文本前的标记做区分。
fm.MarkdownStyleSheet applyWikiLinkStyle(
  fm.MarkdownStyleSheet base,
  ThemeData theme,
) {
  return base.copyWith(
    a: (base.a ?? theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: theme.colorScheme.primary.withValues(alpha: 0.4),
    ),
  );
}
