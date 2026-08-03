import 'dart:io';

import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:ashes_note/services/book_reader/youdao_dictionary_service.dart';
import 'package:ashes_note/utils/const.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// 将笔记保存为 Jekyll post（.md）的弹窗。
///
/// 功能：选择输出目录（记住）、自动生成 YYYY-MM-DD-slug 文件名、
/// 手填副标题与封面地址、手填分类/标签（记住历史、可下拉、可删除历史）。
class BlogExportDialog extends StatefulWidget {
  final Note note;

  const BlogExportDialog({super.key, required this.note});

  @override
  State<BlogExportDialog> createState() => _BlogExportDialogState();
}

class _BlogExportDialogState extends State<BlogExportDialog> {
  final _subtitleController = TextEditingController();
  final _coverController = TextEditingController();
  final _categoryController = TextEditingController();
  final _tagController = TextEditingController();

  String _exportDir = '';
  String _slug = '';
  bool _translating = false;
  String _fileName = '';

  List<String> _historyCategories = [];
  List<String> _historyTags = [];

  @override
  void initState() {
    super.initState();
    _exportDir = SPUtil.get(PrefKeys.blogExportDir, '');
    _historyCategories = SPUtil.get(PrefKeys.blogCategories, <String>[]);
    _historyTags = SPUtil.get(PrefKeys.blogTags, <String>[]);
    _generateSlug();
  }

  @override
  void dispose() {
    _subtitleController.dispose();
    _coverController.dispose();
    _categoryController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  /// 通过有道翻译生成英文 slug；失败则回退为时间戳。
  Future<void> _generateSlug() async {
    final title = widget.note.title.trim();
    if (title.isEmpty) {
      setState(() => _slug = DateTime.now().millisecondsSinceEpoch.toString());
      return;
    }
    setState(() => _translating = true);
    String slug = DateTime.now().millisecondsSinceEpoch.toString();
    try {
      final service = YoudaoDictionaryService(
        appId: YoudaoConstants.appId,
        appKey: YoudaoConstants.appKey,
      );
      final result = await service.lookup(
        title,
        from: 'zh-CHS',
        to: 'en',
      );
      final translated = result?.translation;
      if (translated != null && translated.trim().isNotEmpty) {
        slug = _slugify(translated.trim());
      }
    } catch (e) {
      // 翻译失败：保留时间戳回退值
    } finally {
      if (mounted) {
        setState(() {
          _slug = slug;
          _translating = false;
          _fileName = _composeFileName();
        });
      }
    }
  }

  /// 根据 slug 与当前日期拼出默认文件名（不含 .md 后缀，用户可编辑）。
  String _composeFileName() {
    final date = DateTime.now();
    final ymd =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    return _slug.isEmpty ? ymd : '$ymd-$_slug';
  }

  /// 将任意字符串转成小写连字符 slug（仅保留字母数字与连字符）。
  String _slugify(String input) {
    // 先去掉可能混入的扩展名/后缀（如 .md、.MD、.markdown）
    final cleaned = input
        .replaceAll(RegExp(r'\.(md|markdown|html?)$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bmd\b', caseSensitive: false), '');
    final normalized = cleaned.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '-',
    );
    return normalized.replaceAll(RegExp(r'^-+|-+$'), '').isEmpty
        ? DateTime.now().millisecondsSinceEpoch.toString()
        : normalized.replaceAll(RegExp(r'^-+|-+$'), '');
  }

  Future<void> _pickDir() async {
    final result = await FilePicker.platform.getDirectoryPath(
      initialDirectory: _exportDir,
    );
    if (result != null && result.isNotEmpty) {
      setState(() => _exportDir = result);
      await SPUtil.set(PrefKeys.blogExportDir, result);
    }
  }

  void _addHistoryCategory(String value) {
    final v = value.trim();
    if (v.isEmpty) return;
    if (!_historyCategories.contains(v)) {
      setState(() => _historyCategories.add(v));
      SPUtil.set(PrefKeys.blogCategories, _historyCategories);
    }
  }

  void _addHistoryTag(String value) {
    final v = value.trim();
    if (v.isEmpty) return;
    if (!_historyTags.contains(v)) {
      setState(() => _historyTags.add(v));
      SPUtil.set(PrefKeys.blogTags, _historyTags);
    }
  }

  void _removeHistoryCategory(String value) {
    setState(() => _historyCategories.remove(value));
    SPUtil.set(PrefKeys.blogCategories, _historyCategories);
  }

  void _removeHistoryTag(String value) {
    setState(() => _historyTags.remove(value));
    SPUtil.set(PrefKeys.blogTags, _historyTags);
  }

  /// 组装 Jekyll front matter + 正文。
  String _buildContent() {
    final title = widget.note.title.trim();

    final categories = _categoryController.text
        .split(RegExp(r'[,\s]+'))
        .where((e) => e.trim().isNotEmpty)
        .toList();
    final tags = _tagController.text
        .split(RegExp(r'[,\s]+'))
        .where((e) => e.trim().isNotEmpty)
        .toList();

    final buffer = StringBuffer();
    buffer.writeln('---');
    buffer.writeln('layout: post');
    buffer.writeln('title: "${_escapeYaml(title)}"');
    final subtitle = _subtitleController.text.trim();
    if (subtitle.isNotEmpty) {
      buffer.writeln('subtitle: "${_escapeYaml(subtitle)}"');
    }
    final cover = _coverController.text.trim();
    if (cover.isNotEmpty) {
      buffer.writeln('cover: "$cover"');
    }
    buffer.writeln('categories: [${categories.join(', ')}]');
    buffer.writeln('tags: [${tags.join(', ')}]');
    buffer.writeln('---');
    buffer.writeln();
    buffer.write(widget.note.content);
    return buffer.toString();
  }

  /// 转义 YAML 双引号字符串内的引号。
  String _escapeYaml(String s) => s.replaceAll('"', '\\"');

  Future<void> _export() async {
    if (_exportDir.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先选择输出目录')));
      return;
    }
    if (_slug.isEmpty) {
      await _generateSlug();
    }
    final trimmedName = _fileName.trim();
    if (trimmedName.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('文件名不能为空')));
      return;
    }
    final file = File('$_exportDir/$trimmedName.md');
    try {
      await file.writeAsString(_buildContent());
      // 记住本次手填的分类/标签
      for (final c in _categoryController.text
          .split(RegExp(r'[,\s]+'))
          .where((e) => e.trim().isNotEmpty)) {
        _addHistoryCategory(c);
      }
      for (final t in _tagController.text
          .split(RegExp(r'[,\s]+'))
          .where((e) => e.trim().isNotEmpty)) {
        _addHistoryTag(t);
      }
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存: $trimmedName.md')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = _buildContent();
    return AlertDialog(
      title: const Text('保存为博客 (Jekyll post)'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 输出目录
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _exportDir.isEmpty ? '未选择目录' : _exportDir,
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: _pickDir,
                    child: const Text('选择目录'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 文件名（可编辑，不含 .md 后缀）
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        _translating ? '翻译生成中…' : _fileName,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.primaryColor,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '.md',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.primaryColor,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _translating ? null : _generateSlug,
                        child: const Text('重新生成'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    onChanged: (v) => _fileName = v,
                    controller: TextEditingController(text: _fileName)
                      ..selection = TextSelection.collapsed(
                        offset: _fileName.length,
                      ),
                    decoration: const InputDecoration(
                      labelText: '文件名 (不含后缀)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
              const Divider(),
              // 副标题
              TextField(
                controller: _subtitleController,
                decoration: const InputDecoration(
                  labelText: '副标题 (subtitle)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              // 封面地址
              TextField(
                controller: _coverController,
                decoration: const InputDecoration(
                  labelText: '封面地址 (cover)',
                  hintText: 'https://...',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              // 分类
              _CsvInput(
                label: '分类 (categories)',
                color: Colors.orange,
                controller: _categoryController,
                history: _historyCategories,
                onAddHistory: _addHistoryCategory,
                onRemoveHistory: _removeHistoryCategory,
              ),
              const SizedBox(height: 8),
              // 标签
              _CsvInput(
                label: '标签 (tags)',
                color: Colors.teal,
                controller: _tagController,
                history: _historyTags,
                onAddHistory: _addHistoryTag,
                onRemoveHistory: _removeHistoryTag,
              ),
              const Divider(),
              const Text('预览', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 200),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.dividerColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    content,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: _export,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 分类/标签输入组件：手填 + 历史记忆下拉 + 删除历史。
class _CsvInput extends StatelessWidget {
  final String label;
  final Color color;
  final TextEditingController controller;
  final List<String> history;
  final void Function(String) onAddHistory;
  final void Function(String) onRemoveHistory;

  const _CsvInput({
    required this.label,
    required this.color,
    required this.controller,
    required this.history,
    required this.onAddHistory,
    required this.onRemoveHistory,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: label,
            hintText: '多个用空格或逗号分隔',
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        if (history.isNotEmpty) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: history
                .map(
                  (item) => InputChip(
                    label: Text(
                      item,
                      style: TextStyle(
                        fontSize: 12,
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    backgroundColor: color.withValues(alpha: 0.15),
                    deleteIconColor: color,
                    onPressed: () {
                      final cur = controller.text.trim();
                      if (cur.isEmpty) {
                        controller.text = item;
                      } else if (!cur
                          .split(RegExp(r'[,\s]+'))
                          .contains(item)) {
                        controller.text = '$cur $item';
                      }
                      onAddHistory(item);
                    },
                    onDeleted: () => onRemoveHistory(item),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                )
                .toList(),
          ),
        ],
      ],
    );
  }
}
