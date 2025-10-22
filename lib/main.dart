import 'package:ashes_note/utils/prefs_util.dart';
import 'package:ashes_note/views/note_view.dart';
import 'package:ashes_note/views/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:sidebarx/sidebarx.dart';
import 'ashes_theme.dart';

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
      title: '灰烬笔记1',
      debugShowCheckedModeBanner: false,
      theme: ashesNoteMinimalTheme,
      home: Builder(
        builder: (context) {
          //从本地存储中读取工作目录，判断工作目录是否设置
          String? workingDirectory = SPUtil.get<String>('workingDirectory', '');
          print('工作目录: $workingDirectory');
          if (workingDirectory.isEmpty) {
            //如果没有设置工作目录，弹出对话框提示用户设置
            Future.microtask(() {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('设置工作目录'),
                  content: Text('请先设置工作目录以保存和管理您的笔记。'),
                  actions: [
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        //打开设置页面
                        _controller.selectIndex(2); //假设设置页面的索引是2
                      },
                      child: Text('去设置'),
                    ),
                  ],
                ),
              );
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
      theme: ashesSidebarTheme,
      extendedTheme: ashesSidebarExtendedTheme,
      footerDivider: Divider(color: Theme.of(context).dividerColor),
      headerBuilder: (context, extended) => SizedBox(
        height: 100,
        child: Center(
          child: Text('灰烬笔记', style: ashesSidebarTheme.selectedTextStyle),
        ),
      ),
      items: [
        SidebarXItem(
          icon: Icons.home,
          label: '首页',
          onTap: () {
            // Handle the tap event here
            print('Home tapped');
          },
        ),
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
    final theme = ashesNoteMinimalTheme;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        if (controller.selectedIndex == 0) {
          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text('首页内容', style: theme.textTheme.headlineMedium),
          );
        } else if (controller.selectedIndex == 1) {
          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: NoteView(),
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

  //return Center(child: Text('Selected Index: ${controller.selectedIndex}'));
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}
