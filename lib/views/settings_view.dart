//设置页面 显示工作目录，可以修改，有保存按钮
import 'package:ashes_note/utils/file_util.dart';
import 'package:flutter/material.dart';
import 'package:ashes_note/utils/prefs_util.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  String? _workingDirectory;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    String? workingDirectory = SPUtil.get<String>('workingDirectory', '');
    setState(() {
      _workingDirectory = workingDirectory;
    });
  }

  Future<void> _saveSettings() async {
    if (_workingDirectory != '') {
      await SPUtil.set<String>('workingDirectory', _workingDirectory!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = TextEditingController(text: _workingDirectory);
    return Container(
      padding: const EdgeInsets.fromLTRB(64, 64, 64, 0),
      // color: Colors.grey[80],
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    labelText: '工作目录',
                    // helperStyle: Theme.of(context).textTheme.headlineSmall,
                    labelStyle: Theme.of(context).textTheme.labelMedium,
                  ),
                  controller: controller,
                  onChanged: (value) {
                    setState(() {
                      _workingDirectory = value;
                    });
                  },
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              IconButton(
                icon: Icon(Icons.folder_open),
                // color: Colors.white,
                onPressed: () async {
                  // 使用 file_picker 选择目录：
                  // 在 pubspec.yaml 添加依赖: file_picker
                  // 并在文件顶部添加: import 'package:file_picker/file_picker.dart';
                  // final String? selected = await FilePicker.platform.getDirectoryPath();
                  // if (selected != null) {
                  //   setState(() {
                  //     _workingDirectory = selected;
                  //   });
                  // }
                  final fileUtil = FileUtil();
                  fileUtil.resetDirectoryHandle();
                  final rootPath = await fileUtil.getApplicationDocumentsPath();

                  print('rootPath: $rootPath');
                  setState(() {
                    _workingDirectory = rootPath;
                  });

                  // final files = await fileUtil.listFiles("");
                  // print('files: $files');
                },
              ),
            ],
          ),
          SizedBox(height: 16),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
            onPressed: () {
              _saveSettings();
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('设置已保存')));
            },
            child: Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _build(BuildContext context) {
    final controller = TextEditingController(text: _workingDirectory);
    return Scaffold(
      appBar: AppBar(title: Text('设置')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(labelText: '工作目录'),
                    controller: controller,
                    onChanged: (value) {
                      setState(() {
                        _workingDirectory = value;
                      });
                    },
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.folder_open),
                  onPressed: () async {
                    // 使用 file_picker 选择目录：
                    // 在 pubspec.yaml 添加依赖: file_picker
                    // 并在文件顶部添加: import 'package:file_picker/file_picker.dart';
                    // final String? selected = await FilePicker.platform.getDirectoryPath();
                    // if (selected != null) {
                    //   setState(() {
                    //     _workingDirectory = selected;
                    //   });
                    // }
                    final fileUtil = FileUtil();
                    fileUtil.resetDirectoryHandle();
                    final rootPath = await fileUtil
                        .getApplicationDocumentsPath();

                    print('rootPath: $rootPath');
                    setState(() {
                      _workingDirectory = rootPath;
                    });

                    // final files = await fileUtil.listFiles("");
                    // print('files: $files');
                  },
                ),
              ],
            ),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                _saveSettings();
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('设置已保存')));
              },
              child: Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}
