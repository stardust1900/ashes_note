import 'package:flutter/material.dart';
import 'package:sidebarx/sidebarx.dart';

// 极简风格主题
final ThemeData ashesNoteMinimalTheme = ThemeData(
  brightness: Brightness.light,
  primaryColor: Colors.white,
  scaffoldBackgroundColor: Colors.white,
  colorScheme: ColorScheme.light(
    primary: Colors.black,
    secondary: Colors.grey[800]!,
    surface: Colors.white,
    onPrimary: Colors.black,
    onSecondary: Colors.black,
    onSurface: Colors.black,
  ),

  // 应用栏主题
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.white,
    elevation: 0,
    iconTheme: IconThemeData(color: Colors.black),
    titleTextStyle: TextStyle(
      color: Colors.black,
      fontSize: 20,
      fontWeight: FontWeight.bold,
    ),
  ),

  // 文本主题 - 增强层次感
  textTheme: const TextTheme(
    bodyMedium: TextStyle(color: Colors.black, fontSize: 16),
    headlineMedium: TextStyle(
      color: Colors.black,
      fontSize: 28,
      fontWeight: FontWeight.bold,
    ),
    // 新增：专门用于笔记本标题
    titleLarge: TextStyle(
      color: Colors.black,
      fontSize: 18,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.3,
    ),
    // 新增：专门用于笔记标题
    bodyLarge: TextStyle(
      color: Colors.grey,
      fontSize: 15,
      fontWeight: FontWeight.normal,
      height: 1.4,
    ),
    // 建议新增：选中笔记的专用样式
    titleMedium: TextStyle(
      // 可以使用更高层级的样式
      color: Colors.black, // 深黑色，突出显示
      fontSize: 15,
      fontWeight: FontWeight.w600, // 中等加粗，增加视觉重量
      height: 1.4,
    ),
  ),

  // 分割线颜色
  dividerColor: Colors.grey[300],

  // 图标主题
  iconTheme: const IconThemeData(color: Colors.black),

  // 浮动操作按钮主题
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: Colors.black,
    foregroundColor: Colors.white,
    elevation: 0,
  ),

  // 卡片主题 - 为笔记本容器优化
  cardTheme: CardThemeData(
    color: Colors.white,
    elevation: 1,
    margin: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
    shape: RoundedRectangleBorder(
      side: BorderSide(color: Colors.grey[100]!, width: 1),
      borderRadius: BorderRadius.circular(8),
    ),
    shadowColor: Colors.black.withOpacity(0.1),
  ),

  // 列表瓦片主题 - 专门优化笔记项
  listTileTheme: ListTileThemeData(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    dense: true, // 紧凑布局
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
  ),
);

// SidebarX 极简风格
final SidebarXTheme ashesSidebarTheme = SidebarXTheme(
  decoration: BoxDecoration(color: Colors.grey[200]),
  selectedTextStyle: const TextStyle(
    color: Colors.black,
    fontWeight: FontWeight.bold,
  ),
  selectedIconTheme: const IconThemeData(color: Colors.black),
  textStyle: const TextStyle(color: Colors.grey),
  iconTheme: const IconThemeData(color: Colors.grey),
  hoverColor: Colors.grey[200],
  hoverTextStyle: const TextStyle(color: Colors.black),
  hoverIconTheme: const IconThemeData(color: Colors.black),
  selectedItemDecoration: BoxDecoration(
    color: Colors.grey[200],
    borderRadius: BorderRadius.circular(8),
  ),
);

final SidebarXTheme ashesSidebarExtendedTheme = SidebarXTheme(
  width: 200,
  decoration: BoxDecoration(color: Colors.grey[200]),
  selectedTextStyle: const TextStyle(
    color: Colors.black,
    fontWeight: FontWeight.bold,
  ),
  selectedIconTheme: const IconThemeData(color: Colors.black),
  textStyle: const TextStyle(color: Colors.grey),
  iconTheme: const IconThemeData(color: Colors.grey),
  hoverColor: Colors.grey[400],
  selectedItemDecoration: BoxDecoration(
    color: Colors.grey[200],
    borderRadius: BorderRadius.circular(8),
  ),
);
