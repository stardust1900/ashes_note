import 'package:ashes_note/ashes_theme.dart';
import 'package:ashes_note/utils/file_util.dart';
import 'package:ashes_note/utils/prefs_util.dart';
// import 'package:ashes_note/views/editor_view.dart';
// import 'package:ashes_note/views/flyme_note_view.dart';
// import 'package:ashes_note/views/note_view.dart';
import 'package:ashes_note/views/v1.dart';
import 'package:ashes_note/views/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:sidebarx/sidebarx.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SPUtil.init();
  runApp(AshesNoteApp());
}

class AshesNoteApp extends StatelessWidget {
  AshesNoteApp({super.key});

  final _controller = SidebarXController(selectedIndex: 0, extended: true);
  final _key = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '草灰笔记',
      debugShowCheckedModeBanner: false,
      theme: darkTheme.mainTheme,
      home: Builder(
        builder: (context) {
          //从本地存储中读取工作目录，判断工作目录是否设置
          String? workingDirectory = SPUtil.get<String>('workingDirectory', '');
          print('工作目录: $workingDirectory');
          print('FileUtil handle: ${FileUtil().isHandleGot()}');
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
                          _controller.selectIndex(1);
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
            // Handle the tap event here
            print('Notes tapped');
          },
        ),
        SidebarXItem(
          icon: Icons.settings,
          label: '设置',
          onTap: () {
            // Handle the tap event here
            print('Settings tapped');
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
            // child: NoteView(),
            // child: EditorView(),
            child: NotebookHomePage(),
          );
        } else if (controller.selectedIndex == 1) {
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
