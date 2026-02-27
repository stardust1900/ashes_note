import 'package:flutter/material.dart';
import 'package:sidebarx/sidebarx.dart';
import 'package:ashes_note/utils/prefs_util.dart';
import 'package:ashes_note/utils/const.dart';

// 主题与侧边栏风格（极简、层次清晰）
final ThemeData ashesNoteMinimalTheme = ThemeData(
  brightness: Brightness.light,
  primaryColor: const Color(0xFF685BFF),
  canvasColor: Colors.white,
  scaffoldBackgroundColor: const Color(0xFFF6F7FB),
  colorScheme: const ColorScheme.light(
    primary: Color(0xFF685BFF),
    secondary: Color(0xFF5F5FA7),
    surface: Colors.white,
    onPrimary: Colors.white,
    onSecondary: Colors.white,
    onSurface: Colors.black87,
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.white,
    elevation: 0,
    iconTheme: IconThemeData(color: Colors.black54),
    titleTextStyle: TextStyle(
      color: Colors.black87,
      fontSize: 18,
      fontWeight: FontWeight.w600,
    ),
  ),
  textTheme: const TextTheme(
    bodyMedium: TextStyle(color: Colors.black87, fontSize: 14),
    titleMedium: TextStyle(
      color: Colors.black87,
      fontSize: 16,
      fontWeight: FontWeight.w600,
    ),
    headlineSmall: TextStyle(
      color: Colors.black87,
      fontSize: 20,
      fontWeight: FontWeight.w700,
    ),
  ),
  dividerColor: const Color(0xFFE9E9F0),
  cardTheme: const CardThemeData(
    color: Colors.white,
    elevation: 2,
    margin: EdgeInsets.symmetric(vertical: 6, horizontal: 8),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(10)),
    ),
  ),
  iconTheme: const IconThemeData(color: Colors.black54),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: Color(0xFF685BFF),
    elevation: 4,
  ),
);

// SidebarX 极简风格
final SidebarXTheme ashesSidebarMinimalTheme = SidebarXTheme(
  width: 72,
  decoration: const BoxDecoration(
    color: Colors.white,
    border: Border(right: BorderSide(color: Color(0xFFECECF2), width: 1)),
  ),
  selectedIconTheme: const IconThemeData(color: Color(0xFF685BFF), size: 22),
  textStyle: const TextStyle(
    color: Colors.black54,
    fontWeight: FontWeight.w700,
  ),
  iconTheme: const IconThemeData(color: Colors.black38, size: 20),
  hoverColor: const Color(0xFFF2F4FF),
  hoverIconTheme: const IconThemeData(color: Color(0xFF3B3B8E)),
  hoverTextStyle: const TextStyle(color: Color(0xFF3B3B8E)),
  selectedItemDecoration: BoxDecoration(
    color: const Color(0xFFF2F4FF),
    borderRadius: BorderRadius.circular(10),
  ),
);

final SidebarXTheme ashesSidebarExtendedMinimalTheme = ashesSidebarMinimalTheme
    .copyWith(width: 200);

// 暗黑主题
final ThemeData ashesDarkTheme = ThemeData(
  brightness: Brightness.dark,
  primaryColor: Colors.blue,
  canvasColor: Color.fromARGB(255, 48, 48, 48),
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
    labelSmall: TextStyle(
      color: Colors.white,
      fontSize: 18,
      fontWeight: FontWeight.w600,
    ),
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
);

final SidebarXTheme ashesSidebarDarkTheme = SidebarXTheme(
  margin: const EdgeInsets.all(10),
  decoration: BoxDecoration(
    color: Color.fromARGB(255, 48, 48, 48),
    borderRadius: BorderRadius.circular(20),
  ),
  hoverColor: Color(0xFF464667),
  textStyle: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
  selectedTextStyle: const TextStyle(color: Colors.white),
  hoverTextStyle: const TextStyle(
    color: Colors.white,
    fontWeight: FontWeight.w500,
  ),
  itemTextPadding: const EdgeInsets.only(left: 30),
  selectedItemTextPadding: const EdgeInsets.only(left: 30),
  itemDecoration: BoxDecoration(
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: Color.fromARGB(255, 48, 48, 48)),
  ),
  selectedItemDecoration: BoxDecoration(
    borderRadius: BorderRadius.circular(10),
    border: Border.all(color: Color(0xFF5F5FA7).withValues(alpha: 0.6)),
    gradient: const LinearGradient(
      colors: [Color(0xFF3E3E61), Color.fromARGB(255, 48, 48, 48)],
    ),
    boxShadow: [
      BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 30),
    ],
  ),
  iconTheme: IconThemeData(
    color: Colors.white.withValues(alpha: 0.7),
    size: 20,
  ),
  selectedIconTheme: const IconThemeData(color: Colors.white, size: 20),
);

final SidebarXTheme ashesSidebarExtendedDarkTheme = ashesSidebarDarkTheme
    .copyWith(width: 200);

// ===== 墨水屏主题 =====
/// 墨水屏优化主题
/// 针对墨水屏设备的特殊优化：
/// 1. 纯黑白高对比度
/// 2. 禁用动画和过渡效果
/// 3. 更大字体和图标
/// 4. 禁用渐变和阴影
final ThemeData ashesInkModeTheme = ThemeData(
  brightness: Brightness.light,
  primaryColor: Colors.black,
  canvasColor: Colors.white,
  scaffoldBackgroundColor: Colors.white,
  colorScheme: const ColorScheme.light(
    primary: Colors.black,
    secondary: Colors.black87,
    surface: Colors.white,
    onPrimary: Colors.white,
    onSecondary: Colors.white,
    onSurface: Colors.black87,
  ),
  // 文字样式 - 增大字号和对比度
  textTheme: const TextTheme(
    displayLarge: TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.bold,
      color: Colors.black,
      letterSpacing: 0.5,
    ),
    displayMedium: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.bold,
      color: Colors.black,
    ),
    displaySmall: TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.bold,
      color: Colors.black,
    ),
    headlineLarge: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.bold,
      color: Colors.black,
    ),
    headlineMedium: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.bold,
      color: Colors.black,
    ),
    headlineSmall: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      color: Colors.black,
    ),
    titleLarge: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      color: Colors.black,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: Colors.black,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: Colors.black,
    ),
    bodyLarge: TextStyle(
      fontSize: 18,
      color: Colors.black,
      height: 1.6,
    ),
    bodyMedium: TextStyle(
      fontSize: 16,
      color: Colors.black,
      height: 1.5,
    ),
    bodySmall: TextStyle(
      fontSize: 14,
      color: Colors.black87,
      height: 1.4,
    ),
    labelLarge: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      color: Colors.black,
    ),
    labelMedium: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: Colors.black,
    ),
    labelSmall: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: Colors.black87,
    ),
  ),
  // 禁用所有动画
  pageTransitionsTheme: const PageTransitionsTheme(
    builders: {
      TargetPlatform.android: NoAnimationPageTransitionsBuilder(),
      TargetPlatform.iOS: NoAnimationPageTransitionsBuilder(),
      TargetPlatform.linux: NoAnimationPageTransitionsBuilder(),
      TargetPlatform.macOS: NoAnimationPageTransitionsBuilder(),
      TargetPlatform.windows: NoAnimationPageTransitionsBuilder(),
    },
  ),
  // 按钮样式 - 更大更清晰
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      minimumSize: const Size(120, 50),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      textStyle: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      elevation: 0, // 禁用阴影
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Colors.black, width: 2),
      ),
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(
      foregroundColor: Colors.black,
      minimumSize: const Size(100, 50),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      textStyle: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: Colors.black,
      minimumSize: const Size(100, 50),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      side: const BorderSide(color: Colors.black, width: 2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    ),
  ),
  // Card 样式
  cardTheme: CardThemeData(
    color: Colors.white,
    elevation: 0, // 禁用阴影
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: const BorderSide(color: Colors.black87, width: 1),
    ),
    margin: const EdgeInsets.all(8),
  ),
  // AppBar 样式
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.white,
    foregroundColor: Colors.black,
    elevation: 0,
    centerTitle: true,
    titleTextStyle: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.bold,
      color: Colors.black,
    ),
    iconTheme: IconThemeData(
      color: Colors.black,
      size: 28,
    ),
    actionsIconTheme: IconThemeData(
      color: Colors.black,
      size: 28,
    ),
  ),
  // 图标主题 - 更大的图标
  iconTheme: const IconThemeData(
    color: Colors.black,
    size: 28,
  ),
  // 输入框样式
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.grey[100],
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Colors.black87, width: 1),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Colors.black87, width: 1),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Colors.black, width: 2),
    ),
    labelStyle: const TextStyle(
      fontSize: 16,
      color: Colors.black,
    ),
    hintStyle: const TextStyle(
      fontSize: 16,
      color: Colors.black54,
    ),
  ),
  // 对话框样式
  dialogTheme: DialogThemeData(
    backgroundColor: Colors.white,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: Colors.black87, width: 1),
    ),
    titleTextStyle: const TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.bold,
      color: Colors.black,
    ),
    contentTextStyle: const TextStyle(
      fontSize: 16,
      color: Colors.black,
      height: 1.5,
    ),
  ),
  // 分割线
  dividerTheme: const DividerThemeData(
    color: Colors.black87,
    thickness: 1,
    space: 1,
  ),
  // Switch 样式
  switchTheme: SwitchThemeData(
    thumbColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return Colors.black;
      }
      return Colors.white;
    }),
    trackColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return Colors.black87;
      }
      return Colors.black26;
    }),
  ),
  // Checkbox 样式
  checkboxTheme: CheckboxThemeData(
    fillColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return Colors.black;
      }
      return Colors.transparent;
    }),
    checkColor: const WidgetStatePropertyAll(Colors.white),
    side: const BorderSide(color: Colors.black, width: 2),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(4),
    ),
  ),
  // Snackbar 样式
  snackBarTheme: SnackBarThemeData(
    backgroundColor: Colors.black87,
    contentTextStyle: const TextStyle(
      fontSize: 16,
      color: Colors.white,
    ),
    behavior: SnackBarBehavior.floating,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
    ),
  ),
  // ListTile 样式
  listTileTheme: const ListTileThemeData(
    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    minLeadingWidth: 32,
    iconColor: Colors.black,
    textColor: Colors.black,
    tileColor: Colors.transparent,
    selectedTileColor: Colors.black12,
    titleTextStyle: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      color: Colors.black,
    ),
    subtitleTextStyle: TextStyle(
      fontSize: 14,
      color: Colors.black87,
    ),
  ),
);

// SidebarX 墨水屏风格
final SidebarXTheme ashesSidebarInkModeTheme = SidebarXTheme(
  width: 72,
  decoration: const BoxDecoration(
    color: Colors.white,
    border: Border(right: BorderSide(color: Colors.black87, width: 1)),
  ),
  selectedIconTheme: const IconThemeData(color: Colors.black, size: 22),
  textStyle: const TextStyle(
    color: Colors.black87,
    fontWeight: FontWeight.w700,
  ),
  iconTheme: const IconThemeData(color: Colors.black38, size: 20),
  hoverColor: const Color(0xFFEEEEEE),
  hoverIconTheme: const IconThemeData(color: Colors.black),
  hoverTextStyle: const TextStyle(color: Colors.black),
  selectedItemDecoration: BoxDecoration(
    color: const Color(0xFFE8E8E8),
    borderRadius: BorderRadius.circular(10),
  ),
);

/// 墨水屏 SidebarX 扩展风格
final SidebarXTheme ashesSidebarExtendedInkModeTheme = ashesSidebarInkModeTheme
    .copyWith(width: 200);

/// 无动画页面转换构建器
class NoAnimationPageTransitionsBuilder extends PageTransitionsBuilder {
  const NoAnimationPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 直接返回 child，没有任何动画
    return child;
  }
}

class AshesTheme {
  final ThemeData _mainTheme;
  final SidebarXTheme _sidebarTheme;
  final SidebarXTheme _sidebarExtendedTheme;

  AshesTheme(this._mainTheme, this._sidebarTheme, this._sidebarExtendedTheme);

  ThemeData get mainTheme => _mainTheme;
  SidebarXTheme get sidebarTheme => _sidebarTheme;
  SidebarXTheme get sidebarExtendedTheme => _sidebarExtendedTheme;
}

final AshesTheme lightTheme = AshesTheme(
  ashesNoteMinimalTheme,
  ashesSidebarMinimalTheme,
  ashesSidebarExtendedMinimalTheme,
);

final AshesTheme darkTheme = AshesTheme(
  ashesDarkTheme,
  ashesSidebarDarkTheme,
  ashesSidebarExtendedDarkTheme,
);

final AshesTheme inkModeTheme = AshesTheme(
  ashesInkModeTheme,
  ashesSidebarInkModeTheme,
  ashesSidebarExtendedInkModeTheme,
);

// 主题管理器
class ThemeManager {
  static AshesTheme getCurrentTheme() {
    final themeMode = SPUtil.get<String>(PrefKeys.themeMode, ThemeModes.minimal);
    switch (themeMode) {
      case ThemeModes.dark:
        return darkTheme;
      case ThemeModes.inkMode:
        return inkModeTheme;
      case ThemeModes.minimal:
      default:
        return lightTheme;
    }
  }

  static void setTheme(String themeMode) {
    SPUtil.set<String>(PrefKeys.themeMode, themeMode);
  }

  static bool isDarkMode() {
    final mode = SPUtil.get<String>(PrefKeys.themeMode, ThemeModes.minimal);
    return mode == ThemeModes.dark || mode == ThemeModes.inkMode;
  }

  static bool isInkMode() {
    return SPUtil.get<String>(PrefKeys.themeMode, ThemeModes.minimal) == ThemeModes.inkMode;
  }
}
