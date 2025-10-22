import 'package:ashes_note/utils/file_util.dart';
import 'package:flutter/material.dart';

class NoteView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth > 600) {
          // Tablet/Desktop layout
          return Row(
            children: [
              NavigationPanel(),
              Expanded(child: ContentArea()),
            ],
          );
        } else {
          // Mobile layout
          return ContentArea();
        }
      },
    );
  }
}

class NavigationPanel extends StatefulWidget {
  const NavigationPanel({super.key});
  @override
  State<StatefulWidget> createState() {
    return NavigationPanelState();
  }
}

class NavigationPanelState extends State<NavigationPanel> {
  final TextEditingController _textEditingController = TextEditingController();
  final FileUtil fileUtil = FileUtil();
  String _notebookName = "";
  List<String> _notebookList = [];
  Map<String, List<String>> _notebookMap = {};
  @override
  void initState() {
    super.initState();
    _loadNotebookList();
  }

  Future<void> _loadNotebookList() async {
    final List<String> list = await fileUtil.listFiles('');
    setState(() {
      _notebookList = list;
    });
    for (var notebook in _notebookList) {
      final List<String> list = await fileUtil.listFiles(notebook);
      setState(() {
        _notebookMap[notebook] = list;
      });
    }
  }

  // 弹出对话框的方法
  Future<void> _showNotebookNameDialog() async {
    // 重置控制器内容
    _textEditingController.clear();

    // 使用 showDialog 显示对话框
    final String? result = await showDialog<String>(
      context: context,
      barrierDismissible: false, // 点击对话框外部不可关闭
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('输入笔记本名称'), // 对话框标题
          content: Column(
            mainAxisSize: MainAxisSize.min, // 内容高度根据子组件决定
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Text('请输入您的笔记本名称:'),
              SizedBox(height: 10), // 添加间距
              TextField(
                controller: _textEditingController, // 使用控制器管理输入
                decoration: InputDecoration(
                  //hintText: '例如：我的办公笔记本', // 提示文本
                  border: OutlineInputBorder(),
                  labelText: '笔记本名称', // 标签文本
                ),
                autofocus: true, // 自动获取焦点
                onChanged: (value) {
                  // 可以在此处实时处理输入变化
                },
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              child: Text('取消'),
              onPressed: () {
                Navigator.of(context).pop(); // 关闭对话框，返回 null
              },
            ),
            TextButton(
              child: Text('确定'),
              onPressed: () {
                String inputText = _textEditingController.text.trim();
                if (inputText.isNotEmpty) {
                  Navigator.of(context).pop(inputText); // 返回用户输入
                } else {
                  // 可选：输入为空时的提示
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('请输入笔记本名称')));
                }
              },
            ),
          ],
        );
      },
    );

    // print("result: $result");
    // 处理对话框返回的结果
    if (result != null && result.isNotEmpty) {
      setState(() {
        _notebookName = result; // 更新状态
      });

      // 这里可以添加其他处理逻辑，比如保存到本地等
      print('用户输入的笔记本名称: $result');

      fileUtil.createDirectory(result);
    }
  }

  // 添加笔记 弹出对话框
  Future<void> _showNoteDialog(String noteBook) async {
    // 重置控制器内容
    _textEditingController.clear();

    // 使用 showDialog 显示对话框
    final String? result = await showDialog<String>(
      context: context,
      barrierDismissible: false, // 点击对话框外部不可关闭
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('输入笔记名称'), // 对话框标题
          content: Column(
            mainAxisSize: MainAxisSize.min, // 内容高度根据子组件决定
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Text('请输入您的笔记名称:'),
              SizedBox(height: 10), // 添加间距
              TextField(
                controller: _textEditingController, // 使用控制器管理输入
                decoration: InputDecoration(
                  //hintText: '例如：我的办公笔记本', // 提示文本
                  border: OutlineInputBorder(),
                  labelText: '笔记名称', // 标签文本
                ),
                autofocus: true, // 自动获取焦点
                onChanged: (value) {
                  // 可以在此处实时处理输入变化
                },
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              child: Text('取消'),
              onPressed: () {
                Navigator.of(context).pop(); // 关闭对话框，返回 null
              },
            ),
            TextButton(
              child: Text('确定'),
              onPressed: () {
                String inputText = _textEditingController.text.trim();
                if (inputText.isNotEmpty) {
                  Navigator.of(context).pop(inputText); // 返回用户输入
                } else {
                  // 可选：输入为空时的提示
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('请输入笔记名称')));
                }
              },
            ),
          ],
        );
      },
    );

    // print("result: $result");
    // 处理对话框返回的结果
    if (result != null && result.isNotEmpty) {
      fileUtil.saveFile(noteBook, result, "").then((value) {
        setState(() {
          _notebookMap[noteBook]?.add(result);
        });
      });
      // 这里可以添加其他处理逻辑，比如保存到本地等
      print('用户输入的笔记名称: $result');
    }
  }

  @override
  Widget build(BuildContext context) {
    //fileUtil.listFiles('').then((value) => _notebookList = value);
    return Column(
      children: [
        Expanded(
          child: Container(
            width: 250,
            color: Colors.grey[200],
            child: ListView(
              children: [
                ..._notebookList.map(
                  (notebook) => ExpansionTile(
                    title: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(notebook),
                        IconButton(
                          icon: Icon(Icons.add),
                          onPressed: () => _showNoteDialog(notebook),
                        ),
                      ],
                    ),
                    children: [
                      ..._notebookMap[notebook]?.map(
                            (note) => ListTile(title: Text(note), onTap: () {}),
                          ) ??
                          [],
                      //ListTile(title: Text('Sub-item 1'), onTap: () {}),
                      //ListTile(title: Text('Sub-item 2'), onTap: () {}),
                    ],
                  ),
                ),

                // ExpansionTile(
                //   title: Row(
                //     mainAxisAlignment: MainAxisAlignment.spaceBetween,
                //     children: [
                //       Text('Category 1'),
                //       IconButton(
                //         icon: Icon(Icons.add),
                //         onPressed: () {
                //           // Add new notebook logic for Category 1
                //         },
                //       ),
                //     ],
                //   ),
                //   children: [
                //     ListTile(title: Text('Sub-item 1'), onTap: () {}),
                //     ListTile(title: Text('Sub-item 2'), onTap: () {}),
                //   ],
                // ),
              ],
            ),
          ),
        ),
        Container(
          width: 250,
          color: Colors.grey[300],
          child: TextButton.icon(
            icon: Icon(Icons.add),
            label: Text('新建笔记本'),
            onPressed: _showNotebookNameDialog,
          ),
        ),
      ],
    );
  }
}

class ContentArea extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(child: Text('Select an item from the navigation panel'));
  }
}
