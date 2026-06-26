import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:ashes_note/services/book_web_transfer_service.dart';

/// 网页传书弹窗
/// 显示访问地址和二维码，提醒用户连接 WiFi
class BookWebTransferDialog extends StatefulWidget {
  const BookWebTransferDialog({super.key});

  @override
  State<BookWebTransferDialog> createState() => _BookWebTransferDialogState();
}

class _BookWebTransferDialogState extends State<BookWebTransferDialog> {
  final _service = BookWebTransferService();
  String? _accessUrl;
  bool _starting = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  Future<void> _startServer() async {
    try {
      final url = await _service.start();
      if (mounted) {
        setState(() {
          _accessUrl = url;
          _starting = false;
          _error = url == null ? '无法获取局域网 IP 地址，请检查网络连接' : null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = '启动服务失败：$e';
        });
      }
    }
  }

  Future<void> _stopServer() async {
    await _service.stop();
  }

  @override
  void dispose() {
    _stopServer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.cloud_upload_outlined, size: 24),
          const SizedBox(width: 8),
          const Text('网页传书'),
          const Spacer(),
          if (_service.isRunning)
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
              ),
            ),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: _starting
            ? const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              )
            : _error != null
                ? _buildError()
                : _buildContent(),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await _stopServer();
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildError() => SizedBox(
        height: 120,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.orange),
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
            ],
          ),
        ),
      );

  Widget _buildContent() => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // WiFi 提醒
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.wifi, color: Colors.orange.shade700, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '请确保手机和电脑连接同一 WiFi',
                    style: TextStyle(fontSize: 13, color: Colors.orange.shade800),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // 二维码
          if (_accessUrl != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: QrImageView(
                data: _accessUrl!,
                size: 180,
                backgroundColor: Colors.white,
              ),
            ),
          const SizedBox(height: 16),

          // 访问地址
          if (_accessUrl != null) ...[
            const Text('访问地址', style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            GestureDetector(
              onTap: () => _copyUrl(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: SelectableText(
                        _accessUrl!,
                        style: const TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                          color: Colors.black87,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.copy, size: 14, color: Colors.grey),
                  ],
                ),
              ),
            ),
          ],

          const SizedBox(height: 16),

          // 使用说明
          const Text(
            '用手机扫描二维码，或访问上方地址\n即可在网页中选择 EPUB 文件上传',
            style: TextStyle(fontSize: 12, color: Colors.grey),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 12),

          // 不要关闭窗口提醒
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber, color: Colors.red.shade700, size: 16),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '传输过程中请不要关闭此窗口',
                    style: TextStyle(fontSize: 12, color: Colors.red),
                  ),
                ),
              ],
            ),
          ),
        ],
      );

  void _copyUrl(BuildContext context) {
    if (_accessUrl == null) return;
    Clipboard.setData(ClipboardData(text: _accessUrl!));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制访问地址'), duration: Duration(seconds: 1)),
    );
  }
}
