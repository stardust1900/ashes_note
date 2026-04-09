import 'package:flutter/material.dart';
import 'package:yaml/yaml.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:url_launcher/url_launcher.dart';

/// 关于页面
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String? _version;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final yamlString = await rootBundle.loadString('pubspec.yaml');
      final yaml = loadYaml(yamlString);
      if (mounted) {
        setState(() {
          final versionString = yaml['version'] as String?;
          _version = versionString?.split('+').first;
        });
      }
    } catch (e) {
      // 如果读取失败,使用默认版本
      if (mounted) {
        setState(() {
          _version = '1.0.0';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final currentYear = DateTime.now().year;

    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 应用图标
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.grey[800] : Colors.grey[200],
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.menu_book,
                      size: 80,
                      color: Colors.blue,
                    ),
                  ),
                  const SizedBox(height: 24),
                  // 应用名称
                  Text(
                    '草灰笔记',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 版本号
                  Text(
                    '版本 ${_version ?? '加载中...'}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isDark ? Colors.grey[400] : Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 32),
                  // 应用描述
                  _buildSectionCard(
                    theme,
                    icon: Icons.info_outline,
                    title: '应用简介',
                    content: '''草灰笔记是一款跨平台的笔记管理应用，支持 Markdown 编辑和 EPUB 电子书阅读。
这是一个开源项目，你可以在 GitHub/Gitee 上找到源码。
gitee：https://gitee.com/wangyidao/ashes_note
github: https://github.com/stardust1900/ashes_note

如果你对这个应用有什么问题或者建议，请联系我 :)
email: stardust1900@hotmail.com
微博: @王一舠
微信公众号: 魔域桃源
                    ''',
                  ),
                  const SizedBox(height: 32),
                  // 底部信息
                  Column(
                    children: [
                      Text(
                        '使用 Flutter 构建',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isDark ? Colors.grey[500] : Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '© $currentYear ',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isDark
                                  ? Colors.grey[500]
                                  : Colors.grey[600],
                            ),
                          ),
                          GestureDetector(
                            onTap: () async {
                              final uri = Uri.parse('https://wangxuan.me');
                              if (await canLaunchUrl(uri)) {
                                await launchUrl(uri);
                              }
                            },
                            child: Text(
                              'wangxuan.me',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.primaryColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionCard(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String content,
  }) {
    final isDark = theme.brightness == Brightness.dark;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.primaryColor, size: 24),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SelectionArea(
              child: Text(
                content,
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.6,
                  color: isDark ? Colors.grey[300] : Colors.grey[800],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
