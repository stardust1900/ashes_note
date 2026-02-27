# ashes_note（草灰笔记）

一款基于Flutter开发的跨平台笔记应用，专注于提供简洁高效的笔记管理功能。

## 🌟 主要特性

### 📝 核心功能
- **无工具栏编辑体验** - 专注写作，减少干扰
- **本地存储与Git同步** - 支持Gitee同步，数据安全可靠
- **内容组织管理** - 标签分类、双向链接（待完善）
- **文档解析阅读** - EPUB格式支持，内置阅读器

### 🎨 多主题支持 ✨
现在支持三种精美主题模式：

#### 🌟 极简主题（默认）
- 清爽明亮的界面风格
- 蓝灰色调设计
- 适合日间阅读和办公场景
- 支持完整的个性化调节

#### 🌙 暗黑主题
- 护眼舒适的深色界面
- 减少蓝光辐射保护视力
- 适合夜间阅读和低光环境
- OLED屏幕更省电

#### ✒️ 墨水屏模式
- 纯黑白高对比度设计
- 专为电子墨水屏设备优化
- 禁用动画和渐变效果
- 模拟真实纸质书阅读体验

### 🔍 其他功能
- **智能搜索** - 全文检索，快速定位内容
- **多语言支持** - 国际化本地化
- **跨平台兼容** - Android、iOS、Windows、macOS、Linux、Web
- **词典服务** - 集成有道、HZ、Free Dictionary
- **文件管理** - 完善的本地文件操作

## 🚀 快速开始

### 环境要求
- Flutter SDK 3.0+
- Dart 2.17+
- Android Studio / VS Code

### 安装步骤
```bash
# 克隆项目
git clone https://gitee.com/your_username/ashes_note.git
cd ashes_note

# 获取依赖
flutter pub get

# 运行应用
flutter run
```

### 构建发布
```bash
# Android APK
flutter build apk

# iOS IPA
flutter build ios

# Web
flutter build web

# Windows
flutter build windows
```

## 📖 使用指南

### 主题切换
1. 进入设置页面
2. 选择喜欢的主题模式
3. 主题即时生效，无需重启

### 阅读器特色
- **多主题适配** - 自动根据全局主题调整界面
- **字体调节** - 支持12px-24px字体大小调节
- **行间距控制** - 1.0-2.5倍行间距自定义
- **书签管理** - 彩色书签，时间排序
- **页面导航** - 目录跳转，快速定位

### 同步配置
1. 在设置中配置Git仓库
2. 选择Gitee或GitHub平台
3. 输入Access Token和远程仓库地址
4. 启用自动同步功能

## 🛠️ 技术架构

### 前端框架
- **Flutter** - 跨平台UI框架
- **Dart** - 编程语言
- **Material Design** - 设计规范

### 核心组件
```
lib/
├── ashes_theme.dart          # 主题管理系统
├── main.dart                 # 应用入口
├── views/                    # UI视图层
│   ├── book_reader_page.dart # 原始阅读器
│   ├── book_reader_page_themes.dart # 多主题阅读器 ✨
│   └── settings_view.dart    # 设置页面
├── models/                   # 数据模型
├── services/                 # 业务服务
└── utils/                    # 工具类
```

### 主题实现原理
```dart
// 主题管理器
class ThemeManager {
  static bool isDarkMode() { ... }
  static bool isInkMode() { ... }
  static AshesTheme getCurrentTheme() { ... }
}

// 多主题阅读器核心逻辑
class ThemedBookReaderPage extends StatefulWidget {
  @override
  Widget build(BuildContext context) {
    final isDarkMode = ThemeManager.isDarkMode();
    final isInkMode = ThemeManager.isInkMode();
    
    // 根据主题动态调整颜色和样式
    final backgroundColor = _getReaderBackgroundColor(isInkMode, isDarkMode);
    final textColor = _getReaderTextColor(isInkMode, isDarkMode);
    // ...
  }
}
```

## 📱 平台支持

| 平台 | 状态 | 特性支持 |
|------|------|----------|
| Android | ✅ 完整 | 所有功能 |
| iOS | ✅ 完整 | 所有功能 |
| Windows | ✅ 完整 | 所有功能 |
| macOS | ✅ 完整 | 所有功能 |
| Linux | ✅ 完整 | 所有功能 |
| Web | ✅ 基础 | 核心功能 |

## 🤝 贡献指南

欢迎提交Issue和Pull Request！

### 开发流程
1. Fork项目到个人仓库
2. 创建功能分支 `git checkout -b feature/your-feature`
3. 提交更改 `git commit -m 'Add some feature'`
4. 推送到分支 `git push origin feature/your-feature`
5. 创建Pull Request

### 代码规范
- 遵循Flutter官方代码风格
- 使用有意义的变量和函数命名
- 添加必要的注释和文档
- 通过所有测试用例

## 📄 许可证

本项目采用MIT许可证 - 查看[LICENSE](LICENSE)文件了解详情

## 🙏 致谢

感谢以下开源项目的支持：
- [Flutter](https://flutter.dev/)
- [epub_kitty](https://pub.dev/packages/epub_kitty)
- [sidebarx](https://pub.dev/packages/sidebarx)
- 所有贡献者和支持者

---
*Made with ❤️ using Flutter*