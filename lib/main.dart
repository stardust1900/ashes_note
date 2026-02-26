import 'package:ashes_note/ashes_theme.dart';
import 'package:ashes_note/l10n/app_localizations.dart';
import 'package:ashes_note/utils/file_util.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:ashes_note/views/flyme_note_view.dart';
import 'package:ashes_note/views/settings_view.dart';
import 'package:ashes_note/views/book_library_page.dart';
import 'package:flutter/material.dart';
import 'package:sidebarx/sidebarx.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SPUtil.init();
  runApp(AshesNoteApp());
}

class AshesNoteApp extends StatefulWidget {
  const AshesNoteApp({super.key});

  @override
  State<AshesNoteApp> createState() => _AshesNoteAppState();
}

class _AshesNoteAppState extends State<AshesNoteApp> {
  late SidebarXController _controller;
  final _key = GlobalKey<ScaffoldState>();
  static const String _lastSelectedMenuKey = 'last_selected_menu';

  @override
  void initState() {
    super.initState();
    // 从本地存储加载上次选择的菜单索引
    final lastSelectedIndex = SPUtil.get<int>(_lastSelectedMenuKey, 0);
    _controller = SidebarXController(
      selectedIndex: lastSelectedIndex,
      extended: true,
    );
    // 监听菜单选择变化并保存
    _controller.addListener(_onMenuChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onMenuChanged);
    super.dispose();
  }

  void _onMenuChanged() {
    // 保存当前选择的菜单索引
    SPUtil.set(_lastSelectedMenuKey, _controller.selectedIndex);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '草灰笔记',
      debugShowCheckedModeBanner: false,
      theme: darkTheme.mainTheme,
      localizationsDelegates: const [
        ...AppLocalizations.localizationsDelegates,
      ],
      home: Builder(
        builder: (context) {
          //从本地存储中读取工作目录，判断工作目录是否设置
          String? workingDirectory = SPUtil.get<String>('workingDirectory', '');
          //web环境不能只判断缓存
          if (workingDirectory.isEmpty || !FileUtil().isHandleGot()) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) {
                // 添加安全检查
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('设置工作目录'),
                    content: Text('请先设置工作目录以保存和管理您的笔记。'),
                    actions: [
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                          _controller.selectIndex(2);
                        },
                        child: Text('去设置'),
                      ),
                    ],
                  ),
                );
              }
            });
          }
          final isSmallScreen = MediaQuery.of(context).size.width < 600;
          return Scaffold(
            key: _key,
            appBar: isSmallScreen
                ? AppBar(
                    title: Text('草灰笔记'),
                    leading: IconButton(
                      onPressed: () {
                        _key.currentState?.openDrawer();
                      },
                      icon: const Icon(Icons.menu),
                    ),
                  )
                : null,
            drawer: AshesNoteSidebarX(controller: _controller),
            body: Row(
              children: [
                if (!isSmallScreen) AshesNoteSidebarX(controller: _controller),
                Expanded(
                  child: Center(
                    child: AshesNoteScreens(controller: _controller),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 侧边栏
class AshesNoteSidebarX extends StatelessWidget {
  final SidebarXController _controller;

  const AshesNoteSidebarX({super.key, required SidebarXController controller})
    : _controller = controller;

  @override
  Widget build(BuildContext context) {
    return SidebarX(
      controller: _controller,
      theme: darkTheme.sidebarTheme,
      extendedTheme: darkTheme.sidebarExtendedTheme,
      footerDivider: Divider(color: Theme.of(context).dividerColor),
      // headerBuilder: (context, extended) => SizedBox(
      //   height: 100,
      //   child: Center(
      //     child: Text('灰烬笔记', style: ashesSidebarTheme.selectedTextStyle),
      //   ),
      // ),
      items: [
        // SidebarXItem(
        //   icon: Icons.home,
        //   label: '首页',
        //   onTap: () {
        //     print('Home tapped');
        //   },
        // ),
        SidebarXItem(
          icon: Icons.note,
          label: '笔记',
          onTap: () {
            _controller.selectIndex(0);
          },
        ),
        SidebarXItem(
          icon: Icons.library_books,
          label: '书籍',
          onTap: () {
            _controller.selectIndex(1);
          },
        ),
        SidebarXItem(
          icon: Icons.settings,
          label: '设置',
          onTap: () {
            _controller.selectIndex(2);
          },
        ),
      ],
    );
  }
}

/// 主屏幕
class AshesNoteScreens extends StatelessWidget {
  final SidebarXController controller;

  const AshesNoteScreens({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        if (controller.selectedIndex == 0) {
          return Padding(
            padding: const EdgeInsets.all(8.0),
            child: NotebookHomePage(),
          );
        } else if (controller.selectedIndex == 1) {
          return Padding(
            padding: EdgeInsets.zero,
            child: const BookLibraryPage(),
          );
        } else if (controller.selectedIndex == 2) {
          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: SettingsView(),
          );
        } else {
          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(controller.selectedIndex.toString()),
          );
        }
      },
    );
  }
}
