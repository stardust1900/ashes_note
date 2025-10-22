// Web 平台实现：使用 dart:html + dart:js_util 调用 File System Access API
// 兼容 Dart SDK 3.9.x；若未来升级到支持完整 dart:js_interop，可再迁移。
import 'dart:async';
import 'dart:html' as html;
import 'dart:js_util' as js_util;

/// Normalize path separators and trim leading '/'
List<String> _segments(String path) {
  var np = path.replaceAll('\\', '/');
  if (np.startsWith('/')) np = np.substring(1);
  if (np.isEmpty) return <String>[];
  return np.split('/');
}

dynamic _webRootHandle; // FileSystemDirectoryHandle (kept as dynamic)

Future<dynamic> _ensureWebRoot() async {
  if (_webRootHandle != null) return _webRootHandle;
  final supports = js_util.getProperty(html.window, 'showDirectoryPicker');
  if (supports == null) {
    throw Exception('File System Access API not supported in this browser.');
  }
  final promise = js_util.callMethod(
    html.window,
    'showDirectoryPicker',
    <Object>[],
  );
  final result = await js_util.promiseToFuture(promise);
  _webRootHandle = result;
  return _webRootHandle;
}

Future<dynamic> _webGetDirectoryHandle(
  dynamic startHandle,
  List<String> segments, {
  bool create = false,
}) async {
  var handle = startHandle;
  for (var seg in segments) {
    final args = <Object>[
      seg,
      js_util.jsify({'create': create}),
    ];
    final fn = js_util.getProperty(handle, 'getDirectoryHandle');
    final callResult = js_util.callMethod(fn, 'call', <Object>[
      handle,
      ...args,
    ]);
    handle = await js_util.promiseToFuture(callResult);
  }
  return handle;
}

Future<Map<String, dynamic>> _webResolveParentHandle(
  String path, {
  bool createDirs = false,
}) async {
  final segs = _segments(path);
  if (segs.isEmpty) {
    final root = await _ensureWebRoot();
    return {'parent': root, 'name': ''};
  }
  final name = segs.removeLast();
  final root = await _ensureWebRoot();
  final parent = await _webGetDirectoryHandle(root, segs, create: createDirs);
  return {'parent': parent, 'name': name};
}

/// 保存文件（覆盖）
Future<void> saveFile(String path, String content) async {
  final resolved = await _webResolveParentHandle(path, createDirs: true);
  final parent = resolved['parent'];
  final name = resolved['name'];

  final getFileHandleFn = js_util.getProperty(parent, 'getFileHandle');
  final fileHandlePromise = js_util.callMethod(
    getFileHandleFn,
    'call',
    <Object>[
      parent,
      name,
      js_util.jsify({'create': true}),
    ],
  );
  final fileHandle = await js_util.promiseToFuture(fileHandlePromise);

  final createWritableFn = js_util.getProperty(fileHandle, 'createWritable');
  final writable = await js_util.promiseToFuture(
    js_util.callMethod(createWritableFn, 'call', <Object>[fileHandle]),
  );

  final writeFn = js_util.getProperty(writable, 'write');
  await js_util.promiseToFuture(
    js_util.callMethod(writeFn, 'call', <Object>[writable, content]),
  );

  final closeFn = js_util.getProperty(writable, 'close');
  await js_util.promiseToFuture(
    js_util.callMethod(closeFn, 'call', <Object>[writable]),
  );
}

/// 读取文件内容，文件不存在抛异常
Future<String> readFile(String path) async {
  final resolved = await _webResolveParentHandle(path, createDirs: false);
  final parent = resolved['parent'];
  final name = resolved['name'];

  final getFileHandleFn = js_util.getProperty(parent, 'getFileHandle');
  final fileHandle = await js_util.promiseToFuture(
    js_util.callMethod(getFileHandleFn, 'call', <Object>[parent, name]),
  );

  final getFileFn = js_util.getProperty(fileHandle, 'getFile');
  final file = await js_util.promiseToFuture(
    js_util.callMethod(getFileFn, 'call', <Object>[fileHandle]),
  );

  final textFn = js_util.getProperty(file, 'text');
  final text = await js_util.promiseToFuture(
    js_util.callMethod(textFn, 'call', <Object>[file]),
  );
  return text as String;
}

/// 删除文件（如果存在）
Future<void> deleteFile(String path) async {
  final resolved = await _webResolveParentHandle(path, createDirs: false);
  final parent = resolved['parent'];
  final name = resolved['name'];
  try {
    final removeFn = js_util.getProperty(parent, 'removeEntry');
    await js_util.promiseToFuture(
      js_util.callMethod(removeFn, 'call', <Object>[parent, name]),
    );
  } catch (e) {
    // ignore not found or permission errors
  }
}

/// 创建目录（递归）
Future<void> createDirectory(String path) async {
  final segs = _segments(path);
  if (segs.isEmpty) return;
  final root = await _ensureWebRoot();
  await _webGetDirectoryHandle(root, segs, create: true);
}

/// 删除目录（递归）
Future<void> deleteDirectory(String path) async {
  final segs = _segments(path);
  if (segs.isEmpty) throw Exception('Refusing to delete root directory');
  final name = segs.removeLast();
  final root = await _ensureWebRoot();
  final parent = await _webGetDirectoryHandle(root, segs, create: false);
  try {
    final removeFn = js_util.getProperty(parent, 'removeEntry');
    await js_util.promiseToFuture(
      js_util.callMethod(removeFn, 'call', <Object>[
        parent,
        name,
        js_util.jsify({'recursive': true}),
      ]),
    );
  } catch (e) {
    // ignore
  }
}

/// 列出目录下的文件名（不递归）
Future<List<String>> listFiles(String path) async {
  final segs = _segments(path);
  final root = await _ensureWebRoot();
  final dirHandle = await _webGetDirectoryHandle(root, segs, create: false);

  final entriesFn = js_util.getProperty(dirHandle, 'entries');
  final iterator = await js_util.promiseToFuture(
    js_util.callMethod(entriesFn, 'call', <Object>[dirHandle]),
  );

  final results = <String>[];
  while (true) {
    final nextFn = js_util.getProperty(iterator, 'next');
    final next = await js_util.promiseToFuture(
      js_util.callMethod(nextFn, 'call', <Object>[iterator]),
    );
    final done = js_util.getProperty(next, 'done') as bool;
    if (done) break;
    final value = js_util.getProperty(next, 'value');
    final name = js_util.getProperty(value, '0') as String;
    final handle = js_util.getProperty(value, '1');
    final kind = js_util.getProperty(handle, 'kind') as String?;
    if (kind == 'file') {
      final joined = segs.isEmpty ? name : '${segs.join('/')}/$name';
      results.add(joined);
    }
  }
  return results;
}
