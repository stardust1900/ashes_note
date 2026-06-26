import 'dart:convert';
import 'dart:io';
import 'package:mime/mime.dart';
import 'package:ashes_note/utils/prefs_util.dart';

/// 网页传书服务
/// 启动本地 HTTP 服务，允许通过网页上传 EPUB 文件到书籍库
class BookWebTransferService {
  static final BookWebTransferService _instance = BookWebTransferService._internal();
  factory BookWebTransferService() => _instance;
  BookWebTransferService._internal();

  HttpServer? _server;
  String? _localIp;
  int _port = 8080;

  /// 获取访问地址
  String? get accessUrl {
    if (_localIp == null) return null;
    return 'http://$_localIp:$_port';
  }

  /// 获取本地 IP 地址
  Future<String?> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            final ip = addr.address;
            if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) {
              return ip;
            }
          }
        }
      }
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  /// 启动 HTTP 服务
  Future<String?> start() async {
    if (_server != null) return accessUrl;

    _localIp = await _getLocalIp();
    if (_localIp == null) return null;

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      _server!.listen(_handleRequest);
      return accessUrl;
    } catch (e) {
      try {
        _port = 8081;
        _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
        _server!.listen(_handleRequest);
        return accessUrl;
      } catch (e2) {
        return null;
      }
    }
  }

  /// 停止 HTTP 服务
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// 是否已运行
  bool get isRunning => _server != null;

  /// 处理 HTTP 请求
  void _handleRequest(HttpRequest request) async {
    request.response.headers.set('Access-Control-Allow-Origin', '*');
    request.response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    request.response.headers.set('Access-Control-Allow-Headers', 'Content-Type');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = 200;
      await request.response.close();
      return;
    }

    if (request.method == 'GET') {
      await _handleGet(request);
    } else if (request.method == 'POST' && request.uri.path == '/upload') {
      await _handleUpload(request);
    } else {
      request.response.statusCode = 404;
      await request.response.close();
    }
  }

  /// 处理 GET 请求 - 返回上传页面
  Future<void> _handleGet(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Content-Type', 'text/html; charset=utf-8');

    const html = '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>草灰笔记 - 网页传书</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 20px;
    }
    .container {
      background: white;
      border-radius: 16px;
      box-shadow: 0 20px 60px rgba(0,0,0,0.15);
      padding: 40px;
      max-width: 480px;
      width: 100%;
      text-align: center;
    }
    .icon { font-size: 64px; margin-bottom: 16px; }
    h1 { color: #333; font-size: 24px; margin-bottom: 8px; }
    p { color: #666; font-size: 14px; margin-bottom: 24px; line-height: 1.6; }
    .upload-area {
      border: 2px dashed #667eea;
      border-radius: 12px;
      padding: 40px 20px;
      cursor: pointer;
      transition: all 0.3s;
      background: #f8f9ff;
    }
    .upload-area:hover, .upload-area.dragover {
      border-color: #764ba2;
      background: #f0f2ff;
    }
    .upload-area .icon { font-size: 48px; }
    .upload-area p { margin: 12px 0 0; color: #667eea; font-weight: 500; }
    input[type="file"] { display: none; }
    .btn {
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      color: white;
      border: none;
      padding: 12px 32px;
      border-radius: 8px;
      font-size: 16px;
      cursor: pointer;
      margin-top: 20px;
      transition: opacity 0.3s;
    }
    .btn:hover { opacity: 0.9; }
    .btn:disabled { opacity: 0.5; cursor: not-allowed; }
    .progress { display: none; margin-top: 20px; }
    .progress-bar {
      height: 6px;
      background: #eee;
      border-radius: 3px;
      overflow: hidden;
    }
    .progress-bar-fill {
      height: 100%;
      background: linear-gradient(90deg, #667eea 0%, #764ba2 100%);
      transition: width 0.3s;
      width: 0%;
    }
    .progress-text { font-size: 13px; color: #666; margin-top: 8px; }
    .result { display: none; margin-top: 20px; padding: 12px; border-radius: 8px; font-size: 14px; }
    .result.success { background: #e8f5e9; color: #2e7d32; }
    .result.error { background: #ffebee; color: #c62828; }
    .file-list { margin-top: 16px; text-align: left; }
    .file-item {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 8px 12px;
      background: #f5f5f5;
      border-radius: 6px;
      margin-bottom: 8px;
      font-size: 13px;
    }
    .file-item .name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .file-item .status { margin-left: 8px; font-weight: 500; }
    .file-item .status.ok { color: #2e7d32; }
    .file-item .status.fail { color: #c62828; }
  </style>
</head>
<body>
  <div class="container">
    <div class="icon">📚</div>
    <h1>网页传书</h1>
    <p>选择 EPUB 文件上传到草灰笔记书籍库<br>支持多选，仅支持 .epub 格式</p>
    
    <div class="upload-area" id="uploadArea">
      <div class="icon">📁</div>
      <p>点击选择文件或拖拽文件到此处</p>
    </div>
    <input type="file" id="fileInput" accept=".epub" multiple>
    
    <div class="file-list" id="fileList"></div>
    
    <button class="btn" id="uploadBtn" style="display:none;">开始上传</button>
    
    <div class="progress" id="progress">
      <div class="progress-bar"><div class="progress-bar-fill" id="barFill"></div></div>
      <div class="progress-text" id="progressText">正在上传...</div>
    </div>
    
    <div class="result" id="result"></div>
  </div>

  <script>
    const uploadArea = document.getElementById('uploadArea');
    const fileInput = document.getElementById('fileInput');
    const uploadBtn = document.getElementById('uploadBtn');
    const fileList = document.getElementById('fileList');
    const progress = document.getElementById('progress');
    const barFill = document.getElementById('barFill');
    const progressText = document.getElementById('progressText');
    const result = document.getElementById('result');

    let selectedFiles = [];

    uploadArea.addEventListener('click', () => fileInput.click());

    fileInput.addEventListener('change', (e) => {
      handleFiles(Array.from(e.target.files));
    });

    uploadArea.addEventListener('dragover', (e) => {
      e.preventDefault();
      uploadArea.classList.add('dragover');
    });
    uploadArea.addEventListener('dragleave', () => {
      uploadArea.classList.remove('dragover');
    });
    uploadArea.addEventListener('drop', (e) => {
      e.preventDefault();
      uploadArea.classList.remove('dragover');
      handleFiles(Array.from(e.dataTransfer.files));
    });

    function handleFiles(files) {
      selectedFiles = files.filter(f => f.name.toLowerCase().endsWith('.epub'));
      if (selectedFiles.length === 0) {
        alert('请选择 EPUB 格式的文件');
        return;
      }
      renderFileList();
      uploadBtn.style.display = 'inline-block';
      result.style.display = 'none';
    }

    function renderFileList() {
      fileList.innerHTML = '';
      selectedFiles.forEach((f, i) => {
        const div = document.createElement('div');
        div.className = 'file-item';
        div.innerHTML = '<span class="name">' + f.name + ' (' + formatSize(f.size) + ')</span>' +
          '<span class="status" id="status_' + i + '">等待上传</span>';
        fileList.appendChild(div);
      });
    }

    function formatSize(bytes) {
      if (bytes < 1024) return bytes + ' B';
      if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
      return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
    }

    uploadBtn.addEventListener('click', async () => {
      uploadBtn.disabled = true;
      uploadBtn.style.display = 'none';
      progress.style.display = 'block';
      result.style.display = 'none';

      let success = 0, fail = 0;

      for (let i = 0; i < selectedFiles.length; i++) {
        const file = selectedFiles[i];
        progressText.textContent = '正在上传 (' + (i + 1) + '/' + selectedFiles.length + '): ' + file.name;
        barFill.style.width = ((i / selectedFiles.length) * 100) + '%';

        try {
          const formData = new FormData();
          formData.append('file', file);

          const resp = await fetch('/upload', {
            method: 'POST',
            body: formData,
          });

          if (resp.ok) {
            success++;
            document.getElementById('status_' + i).textContent = '成功';
            document.getElementById('status_' + i).className = 'status ok';
          } else {
            fail++;
            document.getElementById('status_' + i).textContent = '失败';
            document.getElementById('status_' + i).className = 'status fail';
          }
        } catch (e) {
          fail++;
          document.getElementById('status_' + i).textContent = '失败';
          document.getElementById('status_' + i).className = 'status fail';
        }
      }

      barFill.style.width = '100%';
      progressText.textContent = '上传完成';

      result.className = 'result ' + (fail === 0 ? 'success' : 'error');
      result.textContent = '上传完成：成功 ' + success + ' 个，失败 ' + fail + ' 个';
      result.style.display = 'block';

      setTimeout(() => {
        selectedFiles = [];
        fileList.innerHTML = '';
        progress.style.display = 'none';
        barFill.style.width = '0%';
        uploadBtn.style.display = 'none';
      }, 3000);
    });
  </script>
</body>
</html>
''';

    response.write(html);
    await response.close();
  }

  /// 处理文件上传
  Future<void> _handleUpload(HttpRequest request) async {
    final response = request.response;

    try {
      final workingDir = SPUtil.get<String>('workingDirectory', '');
      if (workingDir.isEmpty) {
        _sendJson(response, 500, {'success': false, 'error': 'Working directory not set'});
        return;
      }

      final booksDir = Directory('$workingDir/books');
      if (!await booksDir.exists()) await booksDir.create(recursive: true);

      final contentType = request.headers.contentType;
      if (contentType == null || !contentType.value.contains('multipart/form-data')) {
        _sendJson(response, 400, {'success': false, 'error': 'Invalid content type'});
        return;
      }

      final boundary = contentType.parameters['boundary'];
      if (boundary == null) {
        _sendJson(response, 400, {'success': false, 'error': 'Missing boundary'});
        return;
      }

      final transformer = MimeMultipartTransformer(boundary);
      final uploadedFiles = <String>[];

      await for (final part in request.cast<List<int>>().transform(transformer)) {
        final contentDisposition = part.headers['content-disposition'];
        if (contentDisposition == null) continue;

        final filename = _parseFilename(contentDisposition);
        if (filename == null || filename.isEmpty) continue;
        if (!filename.toLowerCase().endsWith('.epub')) continue;

        final destPath = '${booksDir.path}/$filename';
        final destFile = File(destPath);

        if (await destFile.exists()) {
          uploadedFiles.add('$filename (已存在)');
          continue;
        }

        final sink = destFile.openWrite();
        await part.pipe(sink);
        await sink.close();
        uploadedFiles.add(filename);
      }

      _sendJson(response, 200, {'success': true, 'files': uploadedFiles});
    } catch (e) {
      _sendJson(response, 500, {'success': false, 'error': e.toString()});
    }

    await response.close();
  }

  /// 发送 JSON 响应
  void _sendJson(HttpResponse response, int statusCode, Map<String, dynamic> data) {
    response.statusCode = statusCode;
    response.headers.set('Content-Type', 'application/json; charset=utf-8');
    response.write(jsonEncode(data));
  }

  /// 从 Content-Disposition 中解析文件名
  String? _parseFilename(String contentDisposition) {
    final regex1 = RegExp(r'filename="([^"]+)"');
    final match1 = regex1.firstMatch(contentDisposition);
    if (match1 != null) return match1.group(1);

    final regex2 = RegExp(r"filename\*=UTF-8''(.+)");
    final match2 = regex2.firstMatch(contentDisposition);
    if (match2 != null) return Uri.decodeComponent(match2.group(1)!);

    return null;
  }
}
