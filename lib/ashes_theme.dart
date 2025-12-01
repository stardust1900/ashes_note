import 'package:flutter/material.dart';
import 'package:sidebarx/sidebarx.dart';

// 主题与侧边栏风格（极简、层次清晰）
final ThemeData ashesNoteMinimalTheme = ThemeData(
  brightness: Brightness.light,
  primaryColor: const Color(0xFF685BFF),
  canvasColor: Colors.white,
  scaffoldBackgroundColor: const Color(0xFFF6F7FB),
  colorScheme: const ColorScheme.light(
    primary: Color(0xFF685BFF),
    secondary: Color(0xFF5F5FA7),
    background: Color(0xFFF6F7FB),
    surface: Colors.white,
    onPrimary: Colors.white,
    onSecondary: Colors.white,
    onBackground: Colors.black87,
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
  // Removed showToggleButton as it is not defined in SidebarXTheme
);

final SidebarXTheme ashesSidebarExtendedMinimalTheme = ashesSidebarMinimalTheme
    .copyWith(width: 200);

final ThemeData ashesDarkTheme = ThemeData(
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
    border: Border.all(color: Color.fromARGB(255, 48, 48, 48)),
  ),
  selectedItemDecoration: BoxDecoration(
    borderRadius: BorderRadius.circular(10),
    border: Border.all(
      color: Color(0xFF5F5FA7).withOpacity(0.6).withOpacity(0.37),
    ),
    gradient: const LinearGradient(
      colors: [Color(0xFF3E3E61), Color.fromARGB(255, 48, 48, 48)],
    ),
    boxShadow: [
      BoxShadow(color: Colors.black.withOpacity(0.28), blurRadius: 30),
    ],
  ),
  iconTheme: IconThemeData(color: Colors.white.withOpacity(0.7), size: 20),
  selectedIconTheme: const IconThemeData(color: Colors.white, size: 20),
);
final SidebarXTheme ashesSidebarExtendedDarkTheme = ashesSidebarDarkTheme
    .copyWith(width: 200);

class AshesTheme {
  ThemeData _mainTheme;
  SidebarXTheme _sidebarTheme;
  SidebarXTheme _sidebarExtendedTheme;
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
