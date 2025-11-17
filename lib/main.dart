import 'package:ashes_note/utils/prefs_util.dart';
// import 'package:ashes_note/views/editor_view.dart';
import 'package:ashes_note/views/flyme_note_view.dart';
// import 'package:ashes_note/views/note_view.dart';
import 'package:ashes_note/views/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:sidebarx/sidebarx.dart';
// import 'ashes_theme.dart';

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
      theme: ThemeData(
        primaryColor: Colors.blue,
        canvasColor: canvasColor,
        scaffoldBackgroundColor: Colors.grey[800],
        textTheme: const TextTheme(
          headlineMedium: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
          headlineSmall: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
          labelMedium: TextStyle(color: Colors.white, fontSize: 30),
          bodyMedium: TextStyle(color: Colors.white, fontSize: 15),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.grey[800],
          titleTextStyle: const TextStyle(color: Colors.white),
          contentTextStyle: const TextStyle(color: Colors.white),
        ),
        buttonTheme: const ButtonThemeData(
          buttonColor: Colors.blue,
          textTheme: ButtonTextTheme.primary,
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: Colors.blue),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(foregroundColor: Colors.white),
        ),
      ),
      home: Builder(
        builder: (context) {
          //从本地存储中读取工作目录，判断工作目录是否设置
          String? workingDirectory = SPUtil.get<String>('workingDirectory', '');
          print('工作目录: $workingDirectory');
          //web环境不能只判断缓存
          if (workingDirectory.isEmpty) {
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
                    title: Text('灰烬笔记'),
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
      theme: SidebarXTheme(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: canvasColor,
          borderRadius: BorderRadius.circular(20),
        ),
        hoverColor: scaffoldBackgroundColor,
        textStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
        selectedTextStyle: const TextStyle(color: Colors.white),
        hoverTextStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ),
        itemTextPadding: const EdgeInsets.only(left: 30),
        selectedItemTextPadding: const EdgeInsets.only(left: 30),
        itemDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: canvasColor),
        ),
        selectedItemDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: actionColor.withOpacity(0.37)),
          gradient: const LinearGradient(
            colors: [accentCanvasColor, canvasColor],
          ),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.28), blurRadius: 30),
          ],
        ),
        iconTheme: IconThemeData(
          color: Colors.white.withOpacity(0.7),
          size: 20,
        ),
        selectedIconTheme: const IconThemeData(color: Colors.white, size: 20),
      ),
      extendedTheme: const SidebarXTheme(
        width: 200,
        decoration: BoxDecoration(color: canvasColor),
      ),
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

const primaryColor = Color(0xFF685BFF);
// const canvasColor = Color(0xFF2E2E48);
const canvasColor = Color.fromARGB(255, 48, 48, 48);
const scaffoldBackgroundColor = Color(0xFF464667);
const accentCanvasColor = Color(0xFF3E3E61);
const white = Colors.white;
final actionColor = const Color(0xFF5F5FA7).withOpacity(0.6);
final divider = Divider(color: white.withOpacity(0.3), height: 1);
