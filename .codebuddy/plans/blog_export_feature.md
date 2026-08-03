# 笔记保存为博客（Jekyll post）功能

## 目标
在笔记详情面板右上角增加「保存博客」按钮，点击弹窗，按 Jekyll post 规范导出 `.md` 文件到用户选择的目录，并记住常用配置。

## 交互与字段
弹窗 `blog_export_dialog.dart` 包含：
1. **输出目录**：`getDirectoryPath()` 选择，选后通过 `SPUtil` 记住（`PrefKeys.blogExportDir`），下次自动带出。
2. **文件名（自动）**：`YYYY-MM-DD-<slug>.md`，其中 `slug` 为英文，由「翻译笔记标题（中文→英文）」生成（复用有道词典接口）。
3. **副标题**：弹窗手填，写入 front matter `subtitle`。
4. **封面地址**：弹窗手填（新增需求），写入 front matter `cover`（同时兼容 `image` 字段语义）。
5. **分类 categories**：手填，历史记录记住（`PrefKeys.blogCategories`），可下拉选/可删除已记住项。
6. **标签 tags**：手填，历史记录记住（`PrefKeys.blogTags`），可下拉选/可删除已记住项。
7. 预览区展示生成的 front matter + 正文（正文开头写入笔记原内容）。

## Jekyll front matter 规范
```yaml
---
layout: post
title: "<原笔记标题>"
date: 2026-08-03 12:00:00 +0800
subtitle: "<手填副标题>"
cover: "<手填封面地址>"
categories: [cat1, cat2]
tags: [tag1, tag2]
---
<空行>
<笔记正文内容>
```

## 实现步骤
1. `lib/utils/const.dart` 的 `PrefKeys` 新增：
   - `blogExportDir`
   - `blogCategories`
   - `blogTags`
   （封面地址无需持久化记忆，按需求仅手填）
2. `lib/services/book_reader/youdao_dictionary_service.dart`：
   - 将 `appId`/`appKey` 提取为可复用常量（避免与 `book_reader_page.dart:244` 硬编码重复），供博客弹窗复用翻译。
3. `lib/views/blog_export_dialog.dart`（新建）：
   - 翻译生成 slug（失败则回退为标题拼音/时间戳）。
   - 目录选择 + 记忆。
   - 副标题、封面地址输入框。
   - 分类/标签：手填 + 历史下拉 + 删除历史。
   - 组装 front matter 与正文，`File.writeAsString` 写出。
4. `lib/views/note_desktop.dart`：
   - 在右上角按钮区（约 2587 行 `保存` 按钮附近）新增「保存博客」`IconButton`，打开 `BlogExportDialog(note: widget.note)`。
5. `pubspec.yaml` 确认已依赖 `file_picker`、`shared_preferences`、`http`、`uuid`、`crypto`（书籍模块已用，复用即可）。

## 复用点
- 翻译：`YoudaoDictionaryService.lookup(title, from:'zh-CHS', to:'en')` → `translation`。
- 持久化：`SPUtil`（已封装 set/get/remove，支持 String 与 List<String>）。
- 目录选择：`file_picker` 的 `getDirectoryPath()`（note_desktop 已 import）。

## 注意
- 所有修改基于现有代码，不改动既有笔记读写逻辑。
- 翻译接口若失败，slug 回退方案保证导出不阻塞。
