import 'package:shared_preferences/shared_preferences.dart';

class SPUtil {
  static late SharedPreferences _prefs;

  // 初始化（在应用启动时调用，如 main 函数或首个页面的 initState 中）
  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // 封装Set方法：支持常见类型，避免重复获取实例
  static Future<bool> set<T>(String key, T value) {
    if (value is int) {
      return _prefs.setInt(key, value);
    } else if (value is String) {
      return _prefs.setString(key, value);
    } else if (value is bool) {
      return _prefs.setBool(key, value);
    } else if (value is double) {
      return _prefs.setDouble(key, value);
    } else if (value is List<String>) {
      return _prefs.setStringList(key, value);
    }
    throw Exception('Type not supported');
  }

  // 封装Get方法：提供默认值，增强类型安全性
  static T get<T>(String key, T defaultValue) {
    dynamic value;
    if (T == int) {
      value = _prefs.getInt(key);
    } else if (T == String) {
      value = _prefs.getString(key);
    } else if (T == bool) {
      value = _prefs.getBool(key);
    } else if (T == double) {
      value = _prefs.getDouble(key);
    } else if (T == List<String>) {
      value = _prefs.getStringList(key);
    }
    return value ?? defaultValue;
  }

  // 封装删除和清空
  static Future<bool> remove(String key) => _prefs.remove(key);
  static Future<bool> clear() => _prefs.clear();
}
