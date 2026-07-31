# ashes_note（草灰笔记）

![logo](android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png)

一款基于Flutter开发的跨平台笔记应用，专注于提供简洁高效的笔记管理功能。  
同时还是一款epub阅读器，可以读书笔记以markdown格式直接导出到笔记管理中。
## 🌟 主要特性

### 📝 核心功能
- **无工具栏编辑体验** - 专注写作，减少干扰
- **本地存储与Git同步** - 支持Gitee同步，数据安全可靠
- **内容组织管理** - 标签分类、双向链接、关系图谱
- **文档解析阅读** - EPUB格式支持，内置阅读器

### 🔗 双向链接与标签

笔记之间可以用 `[[链接]]` 互相引用，构建可跳转、可回溯、可视化的知识网络：

- **双链语法**：`[[笔记本/标题]]` 精确定位目标笔记；省略笔记本时写 `[[标题]]` 会全局匹配（当前笔记本优先，重名时弹出候选框选择）；`[[目标|别名]]` 自定义显示文本。大小写不敏感，`.md` 后缀可省略。
- **预览与跳转**：在预览/分栏模式下 `[[…]]` 渲染为带图标的链接胶囊，点击即跳转。目标不存在时显示为「待创建」虚线样式，点击可在指定笔记本一键创建空笔记后跳转。代码块与行内代码中的 `[[` 不会被当作链接。
- **反向链接面板**：在笔记详情内可展开「被引用」区域，列出所有引用本篇的笔记（含来源上下文摘要），并同时展示本篇的「出链」与「未解析链接」，实现双向回溯。
- **输入自动补全**：输入 `[[` 后弹出笔记候选列表，支持模糊筛选、方向键与回车选择、Esc 取消，选中后自动补全为 `[[笔记本/标题]]`。
- **关系图谱**：以笔记为节点、链接为有向边可视化整张知识网络，支持缩放/拖拽画布、拖动节点、点击跳转、按笔记本或标签着色、隐藏孤立节点、「只看当前笔记邻域」等模式。
- **标签**：可对任意笔记打彩色标签，标签数据保存在独立的索引文件 `notes/.ashes/tags.json` 中，**不改动任何 `.md` 原文**；支持侧栏/抽屉按标签筛选聚合、标签重命名与改色。搜索框支持 `tag:标签名` 语法，可与其他关键字组合（如 `tag:读书 卡片`）。
- **同步一致性**：标签索引随 Git 同步一起上传，多设备按「按笔记条目、按更新时间取新」的方式合并，避免互相覆盖；笔记的新建、改名、删除后链接索引与标签索引自动跟随更新，不产生悬空数据。

### 🎨 多主题支持 ✨

支持三种精美主题模式：

#### 🌟 极简主题（默认）
- 清爽明亮的界面风格，蓝灰色调设计
- 适合日间阅读和办公场景
- 支持完整的个性化调节

#### 🌙 暗黑主题
- 护眼舒适的深色界面，减少蓝光辐射
- 适合夜间阅读和低光环境
- OLED屏幕更省电

#### ✒️ 墨水屏模式
- 纯黑白高对比度设计，专为电子墨水屏设备优化
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
git clone https://gitee.com/wangyidao/ashes_note.git
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
- **高亮笔记** - 文本高亮，支持导出笔记

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

### 核心模块
- **主题系统** - 统一管理极简、暗黑、墨水屏三种主题
- **阅读器引擎** - 支持EPUB格式解析与渲染
- **词典服务** - 集成多平台词典API
- **数据存储** - 本地文件管理与Git同步
- **国际化** - 多语言支持

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

🔗 开源项目列表

### 核心框架
- **[Flutter](https://github.com/flutter/flutter)** - Google 开发的跨平台 UI 框架
- **[Dart SDK](https://github.com/dart-lang/sdk)** - Dart 编程语言运行时

### UI 组件与图标
- **[sidebarx](https://github.com/FlaviaIT/sidebarx)** - 侧边栏导航组件
- **[cupertino_icons](https://pub.dev/packages/cupertino_icons)** - iOS 风格图标库
- **[flutter_markdown_plus](https://pub.dev/packages/flutter_markdown_plus)** - Markdown 渲染组件
- **[flutter_html](https://pub.dev/packages/flutter_html)** - HTML 渲染组件
- **[flutter_launcher_icons](https://pub.dev/packages/flutter_launcher_icons)** - 应用图标生成工具

### 编辑器与阅读
- **[super_editor](https://pub.dev/packages/super_editor)** - 富文本编辑器组件
- **[re_editor](https://pub.dev/packages/re_editor)** - 代码编辑器组件
- **[re_highlight](https://pub.dev/packages/re_highlight)** - 代码语法高亮
- **[epub_plus](https://pub.dev/packages/epub_plus)** - EPUB 电子书解析库

### 文件与数据存储
- **[file_picker](https://pub.dev/packages/file_picker)** - 文件选择器
- **[path_provider](https://pub.dev/packages/path_provider)** - 文件路径获取
- **[shared_preferences](https://pub.dev/packages/shared_preferences)** - 本地键值存储
- **[archive](https://pub.dev/packages/archive)** - 压缩/解压库
- **[image](https://pub.dev/packages/image)** - 图片处理库

### 网络与工具
- **[http](https://pub.dev/packages/http)** - HTTP 客户端库
- **[crypto](https://pub.dev/packages/crypto)** - 加密算法库
- **[uuid](https://pub.dev/packages/uuid)** - UUID 生成器
- **[logging](https://pub.dev/packages/logging)** - 日志工具
- **[intl](https://pub.dev/packages/intl)** - 国际化支持

### 其他工具
- **[path](https://pub.dev/packages/path)** - 文件路径操作工具
- **[html](https://pub.dev/packages/html)** - HTML 解析器
- **[overlord](https://pub.dev/packages/overlord)** - UI 动画过渡库
- **[follow_the_leader](https://pub.dev/packages/follow_the_leader)** - 跟随定位组件
- **[flutter_localization](https://pub.dev/packages/flutter_localization)** - Flutter 本地化工具

---
*Made with ❤️ using Flutter*