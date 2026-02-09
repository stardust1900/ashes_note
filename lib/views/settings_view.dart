//设置页面 显示工作目录，可以修改，有保存按钮
import 'dart:io';
import 'package:ashes_note/utils/const.dart';
import 'package:ashes_note/utils/file_util.dart';
import 'package:ashes_note/utils/git_service.dart';
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
  late final TextEditingController _tokenController;
  late final TextEditingController _remoteUrlController;
  late final TextEditingController _workingDirectoryController;

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    print('initState');
    _workingDirectory = SPUtil.get<String>(PrefKeys.workingDirectory, '');
    _gitPlatform = SPUtil.get<String>(PrefKeys.gitPlatform, GitPlatforms.gitee);
    _giteeToken = SPUtil.get<String>(PrefKeys.giteeToken, '');
    _giteeRemoteUrl = SPUtil.get<String>(PrefKeys.giteeRemoteUrl, '');
    _githubToken = SPUtil.get<String>(PrefKeys.githubToken, '');
    _githubRemoteUrl = SPUtil.get<String>(PrefKeys.githubRemoteUrl, '');

    setState(() {
      if (_gitPlatform == GitPlatforms.gitee) {
        _token = _giteeToken;
        _remoteUrl = _giteeRemoteUrl;
      } else {
        _token = _githubToken;
        _remoteUrl = _githubRemoteUrl;
      }

      _tokenController = TextEditingController(text: _token!);
      _remoteUrlController = TextEditingController(text: _remoteUrl!);
      _workingDirectoryController = TextEditingController(
        text: _workingDirectory!,
      );
    });
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _remoteUrlController.dispose();
    _workingDirectoryController.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() async {
    if (_workingDirectory != '') {
      await SPUtil.set<String>(PrefKeys.workingDirectory, _workingDirectory!);
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
                      // border: OutlineInputBorder(),
                    ),
                    controller: _workingDirectoryController,
                    readOnly: true,
                    onChanged: (value) {
                      setState(() {
                        // _workingDirectory = value;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.folder_open),
                  color: Colors.blue,
                  onPressed: () {
                    // print('on press workingDirectory: $_workingDirectory');
                    final messageState = ScaffoldMessenger.of(context);
                    final themeData = Theme.of(context);
                    FileUtil().getApplicationDocumentsPath().then((rootPath) {
                      // print('rootPath: $rootPath');
                      setState(() {
                        _workingDirectory = rootPath;
                        _workingDirectoryController.text = rootPath!;
                      });
                      if (themeData.platform == TargetPlatform.android ||
                          themeData.platform == TargetPlatform.iOS) {
                        messageState.showSnackBar(
                          SnackBar(content: Text('android ios无法选择目录，直接保存即可')),
                        );
                      }
                      _saveSettings();
                    });
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
      // color: Theme.of(context).canvasColor,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Git 配置', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              dropdownColor: Theme.of(context).canvasColor,
              decoration: const InputDecoration(
                labelText: 'Git平台',
                // border: OutlineInputBorder(),
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
                    _tokenController.text = _token!;
                    _remoteUrlController.text = _remoteUrl!;
                  } else {
                    print('切换到GitHub $_githubRemoteUrl');
                    _token = _githubToken;
                    _remoteUrl = _githubRemoteUrl;
                    _tokenController.text = _token!;
                    _remoteUrlController.text = _remoteUrl!;
                  }
                });
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _tokenController,
              decoration: InputDecoration(
                labelText: 'Personal Token',
                // border: OutlineInputBorder(),
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
            Row(
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                  onPressed: () async {
                    ScaffoldMessengerState messengerState =
                        ScaffoldMessenger.of(context);
                    if (_remoteUrl == null || _token == null) {
                      messengerState.showSnackBar(
                        const SnackBar(content: Text('请填写完整的Git配置')),
                      );
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

                    GitFactory.getGitService(_gitPlatform, _token!)
                        .getRepoInfo(owner, repo)
                        .then((repoInfo) {
                          print('Repo Info: $repoInfo');
                          SPUtil.set<String>(
                            PrefKeys.gitPlatform,
                            _gitPlatform,
                          );
                          if (_gitPlatform == GitPlatforms.github) {
                            SPUtil.set<String>(PrefKeys.githubToken, _token!);
                            SPUtil.set<String>(
                              PrefKeys.githubRemoteUrl,
                              _remoteUrl!,
                            );
                          } else if (_gitPlatform == GitPlatforms.gitee) {
                            SPUtil.set<String>(PrefKeys.giteeToken, _token!);
                            SPUtil.set<String>(
                              PrefKeys.giteeRemoteUrl,
                              _remoteUrl!,
                            );
                          }
                          messengerState.showSnackBar(
                            const SnackBar(content: Text('配置已保存')),
                          );
                        })
                        .catchError((error) {
                          print('Error fetching repo info: $error');
                          messengerState.showSnackBar(
                            SnackBar(content: Text('获取仓库信息失败: $error')),
                          );
                        });
                  },
                  child: Text('保存配置'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  icon: _isLoading
                      ? Icon(Icons.downloading)
                      : Icon(Icons.cloud_download_outlined),
                  label: Text('初始化仓库'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isLoading ? Colors.grey : Colors.orange,
                  ),
                  onPressed: () {
                    if (_remoteUrl == null ||
                        _token == null ||
                        _workingDirectory == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请填写完整的Git配置和工作目录')),
                      );
                      return;
                    }
                    if (_isLoading) {
                      return;
                    }
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text('初始化仓库'),
                        content: Text('该操作会删除未保存的本地文件，确定要初始化仓库吗？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: Text('取消'),
                          ),
                          TextButton(
                            onPressed: () {
                              _initRepo();
                              Navigator.pop(context);
                            },
                            child: Text(
                              '初始化',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _initRepo() {
    GitService git = GitFactory.getGitService(_gitPlatform, _token!);
    var (owner, repo) = git.getOwnerRepoFromUrl(_remoteUrl!);
    print('开始同步仓库 $owner/$repo');
    print('工作目录: $_workingDirectory');
    print('notes 目录: $_workingDirectory/notes');
    setState(() {
      _isLoading = true;
    });
    ScaffoldMessengerState messengerState = ScaffoldMessenger.of(context);

    // notes 目录作为 Git 仓库根目录
    final notesDirectory = '$_workingDirectory/notes';

    FileUtil()
        .deleteDirectory(notesDirectory, '*')
        .then((_) {
          print('删除目录完成，开始 Git pull: $notesDirectory');
          git
              .pull(owner, repo, notesDirectory)
              .then((_) {
                // 打印 notes 目录下的文件
                final notesDir = Directory(notesDirectory);
                if (notesDir.existsSync()) {
                  notesDir.list().listen((entity) {
                    print('Git pull 完成, notes 目录内容: ${entity.path}');
                  }, onDone: () {
                    print('Git pull 完成, notes 目录列出完毕');
                  });
                } else {
                  print('Git pull 完成,但 notes 目录不存在');
                }
                messengerState.showSnackBar(
                  const SnackBar(content: Text('仓库初始化完成')),
                );
                setState(() {
                  _isLoading = false;
                });
              })
              .catchError((error) {
                print('Error pulling repo: $error');
                messengerState.showSnackBar(
                  SnackBar(content: Text('仓库初始化失败: $error')),
                );
                setState(() {
                  _isLoading = false;
                });
              });
          SPUtil.set(PrefKeys.lastPullTime, DateTime.now().toIso8601String());
        })
        .catchError((error) {
          print('Error deleting directory: $error');
          messengerState.showSnackBar(
            SnackBar(content: Text('删除文件失败: $error')),
          );
          setState(() {
            _isLoading = false;
          });
        });
  }
}
