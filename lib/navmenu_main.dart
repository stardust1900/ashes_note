import 'package:flutter/material.dart';

void main() {
  runApp(const NavMenuApp());
}

/// 导航菜单项数据模型
class NavMenuItem {
  final String id;
  final String label;
  final IconData? icon;
  final String? route;
  final List<NavMenuItem> children;
  bool isExpanded;
  bool isSelected;

  NavMenuItem({
    required this.id,
    required this.label,
    this.icon,
    this.route,
    this.children = const [],
    this.isExpanded = false,
    this.isSelected = false,
  });

  // 判断是否为叶子节点（没有子节点）
  bool get isLeaf => children.isEmpty;

  NavMenuItem copyWith({
    String? id,
    String? label,
    IconData? icon,
    String? route,
    List<NavMenuItem>? children,
    bool? isExpanded,
    bool? isSelected,
  }) {
    return NavMenuItem(
      id: id ?? this.id,
      label: label ?? this.label,
      icon: icon ?? this.icon,
      route: route ?? this.route,
      children: children ?? this.children,
      isExpanded: isExpanded ?? this.isExpanded,
      isSelected: isSelected ?? this.isSelected,
    );
  }
}

/// 主应用入口
class NavMenuApp extends StatelessWidget {
  const NavMenuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter NavMenu 示例',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const MainLayout(),
    );
  }
}

/// 主布局框架
class MainLayout extends StatefulWidget {
  const MainLayout({super.key});

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  // 当前选中的菜单项路由
  String _currentRoute = '/dashboard';
  String _currentPageTitle = '仪表盘';

  // 模拟菜单数据
  final List<NavMenuItem> _menuData = [
    NavMenuItem(
      id: 'dashboard',
      label: '仪表盘',
      icon: Icons.dashboard,
      route: '/dashboard',
    ),
    NavMenuItem(
      id: 'content',
      label: '内容管理',
      icon: Icons.library_books,
      children: [
        NavMenuItem(
          id: 'articles',
          label: '文章管理',
          icon: Icons.article,
          children: [
            NavMenuItem(
              id: 'published',
              label: '已发布',
              route: '/content/articles/published',
            ),
            NavMenuItem(
              id: 'drafts',
              label: '草稿箱',
              route: '/content/articles/drafts',
            ),
          ],
        ),
        NavMenuItem(
          id: 'media',
          label: '媒体库',
          icon: Icons.photo_library,
          route: '/content/media',
        ),
        NavMenuItem(
          id: 'comments',
          label: '评论管理',
          icon: Icons.comment,
          route: '/content/comments',
        ),
      ],
    ),
    NavMenuItem(
      id: 'user',
      label: '用户管理',
      icon: Icons.people,
      children: [
        NavMenuItem(
          id: 'admins',
          label: '管理员',
          icon: Icons.admin_panel_settings,
          route: '/user/admins',
        ),
        NavMenuItem(
          id: 'members',
          label: '会员列表',
          icon: Icons.person,
          route: '/user/members',
        ),
        NavMenuItem(
          id: 'roles',
          label: '角色权限',
          icon: Icons.lock,
          route: '/user/roles',
        ),
      ],
    ),
    NavMenuItem(
      id: 'system',
      label: '系统设置',
      icon: Icons.settings,
      children: [
        NavMenuItem(
          id: 'general',
          label: '通用设置',
          icon: Icons.settings_applications,
          route: '/system/general',
        ),
        NavMenuItem(
          id: 'security',
          label: '安全设置',
          icon: Icons.security,
          route: '/system/security',
        ),
        NavMenuItem(
          id: 'backup',
          label: '数据备份',
          icon: Icons.backup,
          route: '/system/backup',
        ),
      ],
    ),
  ];

  // 处理菜单项选中
  void _onMenuSelected(String route, String label) {
    setState(() {
      _currentRoute = route;
      _currentPageTitle = label;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentPageTitle),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(icon: const Icon(Icons.search), onPressed: () {}),
          IconButton(icon: const Icon(Icons.settings), onPressed: () {}),
        ],
      ),
      body: const Row(
        children: [
          // 侧边导航菜单
          SizedBox(width: 280, child: NavigationMenu()),
          // 右侧内容区域
          Expanded(child: ContentArea()),
        ],
      ),
    );
  }
}

/// 导航菜单组件
class NavigationMenu extends StatefulWidget {
  const NavigationMenu({super.key});

  @override
  State<NavigationMenu> createState() => _NavigationMenuState();
}

class _NavigationMenuState extends State<NavigationMenu> {
  // 菜单数据
  final List<NavMenuItem> _menuItems = [
    NavMenuItem(
      id: 'dashboard',
      label: '仪表盘',
      icon: Icons.dashboard,
      route: '/dashboard',
      isSelected: true,
    ),
    NavMenuItem(
      id: 'content',
      label: '内容管理',
      icon: Icons.library_books,
      children: [
        NavMenuItem(
          id: 'articles',
          label: '文章管理',
          icon: Icons.article,
          children: [
            NavMenuItem(
              id: 'published',
              label: '已发布',
              route: '/content/articles/published',
            ),
            NavMenuItem(
              id: 'drafts',
              label: '草稿箱',
              route: '/content/articles/drafts',
            ),
          ],
        ),
        NavMenuItem(
          id: 'media',
          label: '媒体库',
          icon: Icons.photo_library,
          route: '/content/media',
        ),
      ],
      isExpanded: true,
    ),
    NavMenuItem(
      id: 'user',
      label: '用户管理',
      icon: Icons.people,
      children: [
        NavMenuItem(id: 'admins', label: '管理员', route: '/user/admins'),
        NavMenuItem(id: 'members', label: '会员列表', route: '/user/members'),
      ],
    ),
  ];

  // 切换菜单展开/折叠状态
  void _toggleExpansion(NavMenuItem item) {
    setState(() {
      _updateItemInList(
        _menuItems,
        item.copyWith(isExpanded: !item.isExpanded),
      );
    });
  }

  // 选中菜单项
  void _selectItem(NavMenuItem item) {
    setState(() {
      // 先取消所有选中状态
      _deselectAllItems(_menuItems);
      // 设置当前项为选中状态
      _updateItemInList(_menuItems, item.copyWith(isSelected: true));
    });
  }

  // 递归取消所有菜单项的选中状态
  void _deselectAllItems(List<NavMenuItem> items) {
    for (var item in items) {
      _updateItemInList(items, item.copyWith(isSelected: false));
      if (item.children.isNotEmpty) {
        _deselectAllItems(item.children);
      }
    }
  }

  // 在列表中更新菜单项
  void _updateItemInList(List<NavMenuItem> items, NavMenuItem updatedItem) {
    for (int i = 0; i < items.length; i++) {
      if (items[i].id == updatedItem.id) {
        items[i] = updatedItem;
        return;
      }
      if (items[i].children.isNotEmpty) {
        _updateItemInList(items[i].children, updatedItem);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey[50],
      child: Column(
        children: [
          // 菜单头部
          Container(
            height: 120,
            width: double.infinity,
            color: Colors.blue[700],
            child: const Padding(
              padding: EdgeInsets.only(left: 20, bottom: 20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: Colors.white,
                    child: Icon(Icons.person, color: Colors.blue),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '管理后台',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 菜单列表
          Expanded(child: ListView(children: _buildMenuItems(_menuItems))),
        ],
      ),
    );
  }

  // 构建菜单项列表
  List<Widget> _buildMenuItems(List<NavMenuItem> items) {
    return items.map((item) => _buildMenuItem(item)).toList();
  }

  // 构建单个菜单项
  Widget _buildMenuItem(NavMenuItem item) {
    final theme = Theme.of(context);
    final isSelected = item.isSelected;
    final hasChildren = item.children.isNotEmpty;

    return Column(
      children: [
        // 菜单项主体
        ListTile(
          leading: item.icon != null
              ? Icon(
                  item.icon,
                  size: 20,
                  color: isSelected
                      ? theme.colorScheme.primary
                      : Colors.grey[700],
                )
              : null,
          title: Text(
            item.label,
            style: TextStyle(
              color: isSelected ? theme.colorScheme.primary : Colors.grey[800],
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          trailing: hasChildren
              ? IconButton(
                  icon: Icon(
                    item.isExpanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 16,
                  ),
                  onPressed: () => _toggleExpansion(item),
                  splashRadius: 16,
                )
              : null,
          selected: isSelected,
          selectedTileColor: theme.colorScheme.primary.withOpacity(0.1),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          onTap: () {
            if (hasChildren) {
              _toggleExpansion(item);
            } else {
              _selectItem(item);
              // 在实际应用中，这里可以添加路由跳转逻辑
              print('导航到: ${item.route}');
            }
          },
        ),
        // 子菜单
        if (hasChildren && item.isExpanded)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Column(children: _buildMenuItems(item.children)),
          ),
      ],
    );
  }
}

/// 内容区域组件
class ContentArea extends StatelessWidget {
  const ContentArea({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 页面标题区域
          Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '仪表盘',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  '欢迎使用管理后台，在这里您可以查看系统概览和进行各项管理操作。',
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                ),
              ],
            ),
          ),
          // 内容卡片区域
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  // 统计卡片
                  Row(
                    children: [
                      Expanded(
                        child: _InfoCard(
                          title: '用户数量',
                          value: '1,234',
                          icon: Icons.people,
                          color: Colors.blue,
                        ),
                      ),
                      SizedBox(width: 16),
                      Expanded(
                        child: _InfoCard(
                          title: '文章数量',
                          value: '567',
                          icon: Icons.article,
                          color: Colors.green,
                        ),
                      ),
                      SizedBox(width: 16),
                      Expanded(
                        child: _InfoCard(
                          title: '评论数量',
                          value: '8,901',
                          icon: Icons.comment,
                          color: Colors.orange,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 24),
                  // 其他内容...
                  Placeholder(fallbackHeight: 400, color: Colors.white),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 信息统计卡片组件
class _InfoCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _InfoCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.grey,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Icon(icon, color: color, size: 20),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
