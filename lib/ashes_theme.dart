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
  textTheme: const TextTheme(
    bodyMedium: TextStyle(color: Colors.black, fontSize: 16),
    headlineMedium: TextStyle(
      color: Colors.black,
      fontSize: 28,
      fontWeight: FontWeight.bold,
    ),
  ),
  dividerColor: Colors.grey[300],
  iconTheme: const IconThemeData(color: Colors.black),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: Colors.black,
    foregroundColor: Colors.white,
    elevation: 0,
  ),
  cardTheme: const CardThemeData(
    color: Colors.white,
    elevation: 0,
    margin: EdgeInsets.all(8),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(8)),
    ),
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
