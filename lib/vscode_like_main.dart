import 'package:flutter/material.dart';

void main() {
  runApp(VSCodeLikeEditorApp());
}

class VSCodeLikeEditorApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VSCode-like Editor',
      theme: ThemeData(primarySwatch: Colors.blue, brightness: Brightness.dark),
      home: VSCodeLayout(),
    );
  }
}

class VSCodeLayout extends StatefulWidget {
  @override
  _VSCodeLayoutState createState() => _VSCodeLayoutState();
}

class _VSCodeLayoutState extends State<VSCodeLayout> {
  double _sidebarWidth = 200.0;
  bool _sidebarVisible = true;
  int _selectedActivity = 0;
  String _currentFile = 'main.dart';

  // 模拟文件结构
  final List<FileItem> _fileStructure = [
    FileItem('lib', true, [
      FileItem('main.dart', false),
      FileItem('home_page.dart', false),
    ]),
    FileItem('pubspec.yaml', false),
    FileItem('README.md', false),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // 活动栏（左侧图标栏）[6](@ref)
          _buildActivityBar(),

          // 侧边栏分隔条（可拖拽调整宽度）
          if (_sidebarVisible) ...[
            // 侧边栏主区域[1,2](@ref)
            Container(
              width: _sidebarWidth,
              color: Colors.grey[850],
              child: _buildSidebar(),
            ),

            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    _sidebarWidth += details.delta.dx;
                    _sidebarWidth = _sidebarWidth.clamp(150.0, 400.0);
                  });
                },
                child: Container(width: 4, color: Colors.grey[800]),
              ),
            ),
          ],

          // 主编辑区域（使用Expanded填充剩余空间）[1](@ref)
          Expanded(
            child: Container(
              color: Colors.grey[850],
              child: Column(
                children: [
                  // 编辑器标签栏
                  Container(
                    height: 40,
                    color: Colors.grey[900],
                    child: Row(
                      children: [
                        Container(
                          width: 120,
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: Colors.blue, width: 2),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              _currentFile,
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 代码编辑器区域
                  Expanded(
                    child: Container(
                      padding: EdgeInsets.only(
                        left: 8.0,
                        top: 16,
                        right: 16,
                        bottom: 16,
                      ),
                      child: DefaultTextStyle.merge(
                        style: TextStyle(
                          fontFamily: 'Monospace',
                          fontSize: 14,
                          color: Colors.white70,
                        ),
                        child: SingleChildScrollView(
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: 'import ',
                                    style: TextStyle(
                                      color: Colors.purpleAccent,
                                    ),
                                  ),
                                  TextSpan(
                                    text: "'package:flutter/material.dart'",
                                    style: TextStyle(color: Colors.greenAccent),
                                  ),
                                  TextSpan(text: ';\n\n'),
                                  TextSpan(
                                    text: 'void ',
                                    style: TextStyle(
                                      color: Colors.purpleAccent,
                                    ),
                                  ),
                                  TextSpan(
                                    text: 'main',
                                    style: TextStyle(color: Colors.blueAccent),
                                  ),
                                  TextSpan(text: '() {\n  '),
                                  TextSpan(
                                    text: 'runApp',
                                    style: TextStyle(color: Colors.blueAccent),
                                  ),
                                  TextSpan(text: '(MyApp());\n}'),
                                ],
                              ),
                              // 确保文本左对齐
                              textAlign: TextAlign.left,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 构建活动栏[6](@ref)
  Widget _buildActivityBar() {
    return Container(
      width: 50,
      color: Colors.grey[900],
      child: Column(
        children: [
          _buildActivityIcon(Icons.explore, 0, '资源管理器'),
          _buildActivityIcon(Icons.search, 1, '搜索'),
          _buildActivityIcon(Icons.source, 2, '源代码管理'),
          _buildActivityIcon(Icons.bug_report, 3, '调试'),
          _buildActivityIcon(Icons.extension, 4, '扩展'),
          Spacer(),
          _buildActivityIcon(
            _sidebarVisible ? Icons.chevron_left : Icons.chevron_right,
            5,
            _sidebarVisible ? '隐藏侧边栏' : '显示侧边栏',
          ),
        ],
      ),
    );
  }

  // 构建活动栏图标
  Widget _buildActivityIcon(IconData icon, int index, String tooltip) {
    return Container(
      width: 50,
      height: 50,
      child: IconButton(
        icon: Icon(
          icon,
          color: _selectedActivity == index ? Colors.white : Colors.white54,
        ),
        onPressed: () {
          setState(() {
            if (index == 5) {
              _sidebarVisible = !_sidebarVisible;
            } else {
              _selectedActivity = index;
            }
          });
        },
      ),
    );
  }

  // 构建侧边栏内容[6](@ref)
  Widget _buildSidebar() {
    switch (_selectedActivity) {
      case 0: // 资源管理器
        return _buildExplorer();
      case 1: // 搜索
        return _buildSearch();
      case 2: // 源代码管理
        return _buildSourceControl();
      case 3: // 调试
        return _buildDebug();
      case 4: // 扩展
        return _buildExtensions();
      default:
        return _buildExplorer();
    }
  }

  // 构建资源管理器[6](@ref)
  Widget _buildExplorer() {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.all(8.0),
          child: Text(
            '资源管理器',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _fileStructure.length,
            itemBuilder: (context, index) {
              return _buildFileItem(_fileStructure[index]);
            },
          ),
        ),
      ],
    );
  }

  // 构建文件/文件夹项[6](@ref)
  Widget _buildFileItem(FileItem item) {
    if (item.isFolder) {
      return ExpansionTile(
        leading: Icon(Icons.folder, color: Colors.blueAccent),
        title: Text(item.name, style: TextStyle(color: Colors.white70)),
        children: item.children!.map((child) => _buildFileItem(child)).toList(),
      );
    } else {
      return ListTile(
        leading: Icon(Icons.description, color: Colors.grey),
        title: Text(item.name, style: TextStyle(color: Colors.white70)),
        onTap: () {
          setState(() {
            _currentFile = item.name;
          });
        },
      );
    }
  }

  // 构建搜索面板
  Widget _buildSearch() {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.all(8.0),
          child: TextField(
            decoration: InputDecoration(
              hintText: '搜索',
              hintStyle: TextStyle(color: Colors.white54),
              prefixIcon: Icon(Icons.search, color: Colors.white54),
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }

  // 构建源代码管理面板
  Widget _buildSourceControl() {
    return Center(
      child: Text('源代码管理面板', style: TextStyle(color: Colors.white70)),
    );
  }

  // 构建调试面板
  Widget _buildDebug() {
    return Center(
      child: Text('调试面板', style: TextStyle(color: Colors.white70)),
    );
  }

  // 构建扩展面板
  Widget _buildExtensions() {
    return Center(
      child: Text('扩展面板', style: TextStyle(color: Colors.white70)),
    );
  }
}

// 文件项数据模型
class FileItem {
  final String name;
  final bool isFolder;
  final List<FileItem>? children;

  FileItem(this.name, this.isFolder, [this.children]);
}
