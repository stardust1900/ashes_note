//设置页面 显示工作目录，可以修改，有保存按钮
import 'package:ashes_note/utils/file_util.dart';
import 'package:ashes_note/utils/gitee_service.dart';
import 'package:flutter/material.dart';
import 'package:ashes_note/utils/prefs_util.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  String? _workingDirectory;

  String _gitPlatform = 'gitee';
  String? _giteeToken;
  String? _giteeRemoteUrl;

  String? _githubToken;
  String? _githubRemoteUrl;

  String? _token;
  String? _remoteUrl;

  bool _isObscure = true;

  // TextEditingController? _workingDirectoryController;
  TextEditingController? _tokenController;
  TextEditingController? _remoteUrlController;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _tokenController = TextEditingController(text: _token);
    _remoteUrlController = TextEditingController(text: _remoteUrl);
  }

  @override
  void dispose() {
    _tokenController?.dispose();
    _remoteUrlController?.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    setState(() {
      _workingDirectory = SPUtil.get<String>('workingDirectory', '');
      _gitPlatform = SPUtil.get<String>('gitPlatform', 'gitee');
      _giteeToken = SPUtil.get<String>('giteeToken', '');
      _giteeRemoteUrl = SPUtil.get<String>('giteeRemoteUrl', '');
      _githubToken = SPUtil.get<String>('githubToken', '');
      _githubRemoteUrl = SPUtil.get<String>('githubRemoteUrl', '');
      if (_gitPlatform == 'gitee') {
        _token = _giteeToken;
        _remoteUrl = _giteeRemoteUrl;
      } else {
        _token = _githubToken;
        _remoteUrl = _githubRemoteUrl;
      }
    });
  }

  Future<void> _saveSettings() async {
    print('_saveSettings _workingDirectory: $_workingDirectory');
    if (_workingDirectory != '') {
      await SPUtil.set<String>('workingDirectory', _workingDirectory!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('设置', style: Theme.of(context).textTheme.headlineMedium),
        backgroundColor: Theme.of(context).canvasColor,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildWorkingDirectorySection(),
            const SizedBox(height: 24),
            _buildGitConfigSection(),
            const SizedBox(height: 24),
            // _buildActionButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkingDirectorySection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('工作目录设置', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: '工作目录路径',
                      border: OutlineInputBorder(),
                    ),
                    controller: TextEditingController(text: _workingDirectory),
                    onChanged: (value) {
                      setState(() {
                        _workingDirectory = value;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.folder_open),
                  color: Colors.blue,
                  onPressed: () async {
                    // String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
                    // if (selectedDirectory != null) {
                    //   setState(() {
                    //     _workingDirectory = selectedDirectory;
                    //   });
                    // }
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '用于存储笔记数据和Git仓库的目录',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              onPressed: () {
                _saveSettings();
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('设置已保存')));
              },
              child: Text('保存设置'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGitConfigSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Git 配置', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              dropdownColor: Colors.grey[300],
              decoration: const InputDecoration(
                labelText: 'Git平台',
                border: OutlineInputBorder(),
              ),
              initialValue: _gitPlatform,
              items: [
                DropdownMenuItem(value: 'github', child: Text('GitHub')),
                DropdownMenuItem(value: 'gitee', child: Text('Gitee')),
              ],
              onChanged: (value) {
                setState(() {
                  _gitPlatform = value!;
                  if (_gitPlatform == 'gitee') {
                    print('切换到Gitee $_giteeRemoteUrl');
                    _token = _giteeToken;
                    _remoteUrl = _giteeRemoteUrl;
                    _tokenController?.text = _token!;
                    _remoteUrlController?.text = _remoteUrl!;
                  } else {
                    print('切换到GitHub $_githubRemoteUrl');
                    _token = _githubToken;
                    _remoteUrl = _githubRemoteUrl;
                    _tokenController?.text = _token!;
                    _remoteUrlController?.text = _remoteUrl!;
                  }
                });
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _tokenController,
              decoration: InputDecoration(
                labelText: 'Personal Token',
                border: OutlineInputBorder(),
                hintText: '输入您的Git Personal Token',
                suffixIcon: IconButton(
                  icon: Icon(
                    _isObscure ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () {
                    setState(() {
                      _isObscure = !_isObscure;
                    });
                  },
                ),
              ),
              obscureText: _isObscure,
              onChanged: (value) {
                setState(() {
                  _token = value;
                });
              },
            ),
            const SizedBox(height: 8),
            Text(
              'Token需要repo权限，请妥善保管',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _remoteUrlController,
              decoration: InputDecoration(
                labelText: '远程仓库地址',
                border: const OutlineInputBorder(),
                hintText: _gitPlatform == 'github'
                    ? 'https://github.com/用户名/仓库名.git'
                    : 'https://gitee.com/用户名/仓库名.git',
              ),
              onChanged: (value) {
                setState(() {
                  _remoteUrl = value;
                });
              },
            ),
            const SizedBox(height: 8),
            Text(
              _gitPlatform == 'github'
                  ? 'GitHub仓库SSH或HTTPS地址'
                  : 'Gitee仓库SSH或HTTPS地址',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              onPressed: () async {
                if (_remoteUrl == null || _token == null) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('请填写完整的Git配置')));
                  return;
                }

                String owner = _remoteUrl!
                    .split('/')
                    .reversed
                    .toList()[1]; // 获取倒数第二部分作为owner
                String repo = _remoteUrl!
                    .split('/')
                    .reversed
                    .toList()[0]; // 获取最后一部分作为repo
                if (repo.endsWith('.git')) {
                  repo = repo.substring(0, repo.length - 4);
                }

                print('Owner: $owner, Repo: $repo');
                if (_gitPlatform == 'gitee') {
                  GiteeService(accessToken: _token)
                      .getRepoInfo(owner, repo)
                      .then((repoInfo) {
                        print('Repo Info: $repoInfo');
                        SPUtil.set<String>('gitPlatform', _gitPlatform);
                        SPUtil.set<String>('giteeToken', _token!);
                        SPUtil.set<String>('giteeRemoteUrl', _remoteUrl!);
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('设置已保存')));
                      })
                      .catchError((error) {
                        print('Error fetching repo info: $error');
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('获取仓库信息失败: $error')),
                        );
                      });
                } else if (_gitPlatform == 'github') {
                  // GitHubService(accessToken: _token)
                  //     .getRepoInfo(owner, repo)
                  //     .then((repoInfo) {
                  //       print('Repo Info: $repoInfo');
                  //       SPUtil.set<String>('gitPlatform', _gitPlatform);
                  //       SPUtil.set<String>('githubToken', _token!);
                  //       SPUtil.set<String>('githubRemoteUrl', _remoteUrl!);
                  //       ScaffoldMessenger.of(
                  //         context,
                  //       ).showSnackBar(const SnackBar(content: Text('设置已保存')));
                  //     })
                  //     .catchError((error) {
                  //       print('Error fetching repo info: $error');
                  //       ScaffoldMessenger.of(context).showSnackBar(
                  //         SnackBar(content: Text('获取仓库信息失败: $error')),
                  //       );
                  //     });
                }

                // ScaffoldMessenger.of(
                //   context,
                // ).showSnackBar(SnackBar(content: Text('设置已保存')));
              },
              child: Text('保存配置'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton(
            onPressed: _saveSettings,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: const Text('保存设置'),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: ElevatedButton(
            //onPressed: _initializeAndSyncRepository,
            onPressed: () {},
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: const Text('初始化并同步仓库'),
          ),
        ),
      ],
    );
  }

  Widget _build(BuildContext context) {
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
                onPressed: () {
                  // 使用 file_picker 选择目录：
                  // 在 pubspec.yaml 添加依赖: file_picker
                  // 并在文件顶部添加: import 'package:file_picker/file_picker.dart';
                  // final String? selected = await FilePicker.platform.getDirectoryPath();
                  // if (selected != null) {
                  //   setState(() {
                  //     _workingDirectory = selected;
                  //   });
                  // }
                  // final fileUtil = FileUtil();

                  // fileUtil.resetDirectoryHandle();
                  FileUtil().getApplicationDocumentsPath().then((rootPath) {
                    print('rootPath: $rootPath');
                    setState(() {
                      _workingDirectory = rootPath;
                    });
                    _saveSettings();
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
}
