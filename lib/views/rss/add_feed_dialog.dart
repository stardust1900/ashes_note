import 'package:ashes_note/models/rss/rss_models.dart';
import 'package:ashes_note/services/rss/rss_service.dart';
import 'package:flutter/material.dart';

/// 添加 / 编辑订阅源对话框
class AddFeedDialog extends StatefulWidget {
  final RssFeed? feed; // 非空为编辑模式
  const AddFeedDialog({super.key, this.feed});

  @override
  State<AddFeedDialog> createState() => _AddFeedDialogState();
}

class _AddFeedDialogState extends State<AddFeedDialog> {
  late final TextEditingController _urlController;
  late final TextEditingController _titleController;
  late final TextEditingController _categoryController;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final f = widget.feed;
    _urlController = TextEditingController(text: f?.url ?? '');
    _titleController = TextEditingController(text: f?.title ?? '');
    _categoryController = TextEditingController(text: f?.category ?? '');
  }

  @override
  void dispose() {
    _urlController.dispose();
    _titleController.dispose();
    _categoryController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '请输入订阅源地址');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    final result = await RssService.fetchFeed(url);

    if (!mounted) return;

    if (widget.feed != null) {
      // 编辑模式：更新现有订阅源
      final f = widget.feed!;
      f.url = url;
      if (_titleController.text.trim().isNotEmpty) {
        f.title = _titleController.text.trim();
      } else if (result.ok && result.title != null) {
        f.title = result.title!;
      }
      f.category = _categoryController.text.trim().isEmpty
          ? null
          : _categoryController.text.trim();
      if (result.ok) {
        f.description = result.description ?? f.description;
        f.siteUrl = result.siteUrl ?? f.siteUrl;
        f.faviconUrl = result.faviconUrl;
        f.etag = result.etag;
        f.lastModified = result.lastModified;
        f.lastUpdated = result.lastUpdated;
        f.fetchError = null;
      } else {
        f.fetchError = result.error;
      }
      setState(() => _loading = false);
      if (!mounted) return;
      Navigator.pop(context, f);
      return;
    }

    // 添加模式
    final title = _titleController.text.trim().isNotEmpty
        ? _titleController.text.trim()
        : (result.ok && result.title != null ? result.title! : url);
    final category = _categoryController.text.trim().isEmpty
        ? null
        : _categoryController.text.trim();

    final feed = RssFeed(
      title: title,
      url: url,
      category: category,
      description: result.ok ? result.description : null,
      siteUrl: result.ok ? result.siteUrl : null,
      faviconUrl: result.ok ? result.faviconUrl : null,
      etag: result.ok ? result.etag : null,
      lastModified: result.ok ? result.lastModified : null,
      lastUpdated: result.ok ? result.lastUpdated : null,
      fetchError: result.ok ? null : result.error,
      articles: result.ok ? result.articles : [],
    );

    setState(() => _loading = false);
    if (!mounted) return;
    Navigator.pop(context, feed);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.feed != null;
    return AlertDialog(
      title: Text(isEdit ? '编辑订阅源' : '添加订阅源'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: '订阅源地址 (URL)',
                hintText: 'https://example.com/feed.xml',
              ),
              keyboardType: TextInputType.url,
              enabled: !_loading,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: '名称（可选，留空自动获取）',
              ),
              enabled: !_loading,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _categoryController,
              decoration: const InputDecoration(
                labelText: '分组（可选）',
              ),
              enabled: !_loading,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ],
            if (_loading) ...[
              const SizedBox(height: 16),
              const Row(
                children: [
                  SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('正在获取订阅源…'),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: _loading ? null : _save,
          child: Text(isEdit ? '保存' : '添加'),
        ),
      ],
    );
  }
}
