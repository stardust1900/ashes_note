import 'dart:io';

import 'package:ashes_note/models/rss/rss_models.dart';
import 'package:ashes_note/services/rss/opml_service.dart';
import 'package:ashes_note/services/rss/rss_storage_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// OPML 导入/导出对话框
class OpmlDialog extends StatefulWidget {
  final List<RssFeed> feeds;
  const OpmlDialog({super.key, required this.feeds});

  @override
  State<OpmlDialog> createState() => _OpmlDialogState();
}

class _OpmlDialogState extends State<OpmlDialog> {
  bool _busy = false;
  String? _message;
  bool _changed = false;

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['opml', 'xml'],
      );
      if (result == null || result.files.isEmpty) {
        setState(() {
          _busy = false;
          _message = '未选择文件';
        });
        return;
      }
      final path = result.files.first.path;
      if (path == null) {
        setState(() {
          _busy = false;
          _message = '无法读取文件';
        });
        return;
      }
      final content = await File(path).readAsString();
      final parsed = OpmlService.parse(content);
      if (parsed.isEmpty) {
        setState(() {
          _busy = false;
          _message = '未从文件中解析到订阅源';
        });
        return;
      }
      final existingUrls =
          widget.feeds.map((f) => f.url.toLowerCase()).toSet();
      final added = <RssFeed>[];
      for (final opml in parsed) {
        if (existingUrls.contains(opml.url.toLowerCase())) continue;
        added.add(RssFeed(
          title: opml.title,
          url: opml.url,
          category: opml.category,
        ));
        existingUrls.add(opml.url.toLowerCase());
      }
      widget.feeds.addAll(added);
      await RssStorageService().saveFeeds(widget.feeds);
      _changed = true;
      setState(() {
        _busy = false;
        _message = '成功导入 ${added.length} 个订阅源（共 ${parsed.length} 个）';
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _message = '导入失败：$e';
      });
    }
  }

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final dir = await RssStorageService().ensureOpmlDir();
      if (dir == null) {
        setState(() {
          _busy = false;
          _message = '未设置工作目录，无法导出';
        });
        return;
      }
      final opml = OpmlService.build(widget.feeds);
      final file = File(p.join(dir, 'subscriptions.opml'));
      await file.writeAsString(opml, flush: true);
      _changed = true;
      setState(() {
        _busy = false;
        _message = '已导出到：${file.path}';
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _message = '导出失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('OPML 导入 / 导出'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('批量迁移订阅源：从其他阅读器导出 OPML 后导入，或将当前订阅源导出备份。'),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _import,
                    icon: const Icon(Icons.file_download),
                    label: const Text('导入'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _export,
                    icon: const Icon(Icons.file_upload),
                    label: const Text('导出'),
                  ),
                ),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: 16),
              const Row(
                children: [
                  SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('处理中…'),
                ],
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 16),
              Text(
                _message!,
                style: TextStyle(
                  fontSize: 13,
                  color: _message!.startsWith('成功') || _message!.startsWith('已导出')
                      ? Colors.green
                      : Colors.red,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _changed),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
