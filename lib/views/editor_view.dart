import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

// 文件项数据模型
class FileItem {
  final String name;
  final bool isFolder;
  final List<FileItem>? children;

  FileItem(this.name, this.isFolder, [this.children]);
}

class EditorView extends StatefulWidget {
  const EditorView({super.key});

  @override
  State<StatefulWidget> createState() {
    return EditorViewState();
  }
}

class EditorViewState extends State<EditorView> {
  double _sidebarWidth = 200.0;
  // 文本编辑控制器
  final TextEditingController _textController = TextEditingController();
  // 模拟文件结构
  final List<FileItem> _fileStructure = [
    FileItem('lib', true, [
      FileItem('main.dart', false),
      FileItem('home_page.dart', false),
    ]),
    FileItem('pubspec.yaml', false),
    FileItem('README.md', false),
  ];
  String _currentFile = 'main.dart';
  bool _isEditing = true; // 切换编辑/预览模式
  // 文件内容映射
  final Map<String, String> _fileContents = {};
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
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
                      Spacer(),
                      Row(
                        children: [
                          IconButton(
                            icon: Icon(
                              Icons.edit,
                              size: 16,
                              color: _isEditing ? Colors.blue : Colors.white54,
                            ),
                            onPressed: () {
                              setState(() {
                                _isEditing = true;
                              });
                            },
                            tooltip: '编辑',
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.preview,
                              size: 16,
                              color: !_isEditing ? Colors.blue : Colors.white54,
                            ),
                            onPressed: () {
                              setState(() {
                                _isEditing = false;
                              });
                            },
                            tooltip: '预览',
                          ),
                        ],
                      ),
                      SizedBox(width: 16),
                    ],
                  ),
                ),

                // 代码编辑器区域
                Expanded(child: _isEditing ? _buildEditor() : _buildPreview()),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // 构建Markdown编辑器
  Widget _buildEditor() {
    return Container(
      padding: EdgeInsets.only(left: 16, top: 8, right: 16, bottom: 8),
      child: TextField(
        controller: _textController,
        maxLines: null, // 允许多行
        expands: true, // 填充可用空间
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: '开始输入Markdown内容...',
          hintStyle: TextStyle(color: Colors.white30),
        ),
        style: TextStyle(
          fontFamily: 'Monospace',
          fontSize: 14,
          color: Colors.white70,
        ),
        onChanged: (text) {
          // 实时更新文件内容
          setState(() {
            _fileContents[_currentFile] = text;
          });
        },
      ),
    );
  }

  // 构建Markdown预览
  Widget _buildPreview() {
    return SelectionArea(
      child: Container(
        padding: EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Markdown(
            data: _fileContents[_currentFile] ?? '',
            selectable: false,
            styleSheet: MarkdownStyleSheet(
              p: TextStyle(fontSize: 14, color: Colors.white70),
              h1: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              h2: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              h3: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              code: TextStyle(
                backgroundColor: Colors.grey[800],
                color: Colors.orange,
                fontFamily: 'Monospace',
              ),
              codeblockPadding: EdgeInsets.all(8),
              codeblockDecoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            shrinkWrap: true,
          ),
        ),
      ),
    );
  }

  Widget _buildSidebar() {
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
}
