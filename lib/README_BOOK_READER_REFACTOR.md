# 阅读器模块重构说明

## 重构目标

1. **减少单文件代码量** - 将 `book_reader_page.dart` 中的实体类和服务抽取到独立文件
2. **支持多格式扩展** - 将 EPUB 解析独立出来，为以后支持 MOBI、PDF 等格式做准备

## 新的文件结构

```
lib/
├── models/book_reader/           # 数据模型层
│   ├── content_item.dart         # 内容项（文本、图片、封面）
│   ├── page_content.dart         # 页面内容
│   ├── bookmark.dart             # 书签模型
│   ├── highlight.dart            # 高亮和笔记模型
│   ├── reading_mode.dart         # 阅读模式枚举
│   └── book_reader_models.dart   # 模型导出文件
│
├── services/
│   ├── book_parser/              # 书籍解析服务
│   │   ├── book_parser.dart      # 解析器抽象接口
│   │   ├── epub_book_parser.dart # EPUB 解析器实现
│   │   ├── book_parser_factory.dart # 解析器工厂
│   │   └── book_parsers.dart     # 解析器导出文件
│   │
│   └── book_reader/              # 阅读器服务
│       ├── book_cache_service.dart   # 页面缓存服务
│       ├── book_storage_service.dart # 数据存储服务
│       └── book_reader_services.dart # 服务导出文件
│
└── views/book_reader/            # 阅读器视图（可选）
    └── book_reader_page_refactored.dart  # 重构后的示例
```

## 架构说明

### 1. 数据模型层 (models/book_reader/)

所有与阅读器相关的数据模型都抽取到这里：

- `ContentItem` - 抽象内容项
  - `TextContent` - 文本内容
  - `ImageContent` - 图片内容
  - `CoverContent` - 封面内容
- `PageContent` - 页面内容
- `Bookmark` - 书签
- `Highlight` - 高亮和笔记
- `ReadingMode` - 阅读模式枚举

### 2. 解析服务层 (services/book_parser/)

采用策略模式，支持多种书籍格式：

```dart
// 解析器接口
abstract class BookParser {
  Future<BookData> parse(String filePath);
  bool supportsFormat(String filePath);
}

// 使用工厂获取解析器
final parser = BookParserFactory.getParser(filePath);
final bookData = await parser.parse(filePath);
```

**扩展新格式的方法：**

1. 创建新的解析器类实现 `BookParser` 接口
2. 在 `BookParserFactory` 中注册

```dart
// 示例：添加 MOBI 支持
class MobiBookParser implements BookParser {
  @override
  bool supportsFormat(String filePath) => filePath.endsWith('.mobi');
  
  @override
  Future<BookData> parse(String filePath) async {
    // 实现 MOBI 解析
  }
}

// 在工厂中注册
BookParserFactory.registerParser(MobiBookParser());
```

### 3. 阅读器服务层 (services/book_reader/)

- `BookCacheService` - 管理页面布局缓存
- `BookStorageService` - 管理阅读进度、书签、高亮等数据的持久化

### 4. 视图层

重构后的阅读器页面更加简洁，依赖注入服务：

```dart
class _BookReaderPageState extends State<BookReaderPage> {
  final BookCacheService _cacheService = BookCacheService();
  final BookStorageService _storageService = BookStorageService();
  
  // ... 只需要关注 UI 逻辑
}
```

## 与原代码的对比

| 原代码 | 重构后 |
|--------|--------|
| `book_reader_page.dart` (4900+ 行) | 拆分为多个小文件 |
| 实体类定义在阅读器页面中 | 独立到 `models/book_reader/` |
| EPUB 解析逻辑在阅读器页面中 | 独立到 `services/book_parser/` |
| 缓存逻辑在阅读器页面中 | 独立到 `BookCacheService` |
| 存储逻辑在阅读器页面中 | 独立到 `BookStorageService` |
| 只支持 EPUB | 易于扩展支持其他格式 |

## 迁移建议

### 逐步迁移步骤：

1. **第一阶段** - 使用新的数据模型
   - 在 `book_reader_page.dart` 中导入新的模型
   - 逐步替换内嵌的类定义

2. **第二阶段** - 使用新的服务
   - 使用 `BookStorageService` 替代原存储逻辑
   - 使用 `BookCacheService` 替代原缓存逻辑

3. **第三阶段** - 使用新的解析器
   - 使用 `BookParserFactory` 获取解析器
   - 为未来支持其他格式做准备

4. **第四阶段** - 完全迁移
   - 删除旧的代码
   - 使用重构后的阅读器页面

## 注意事项

1. **数据兼容性** - 新的存储服务使用相同的 SharedPreferences 键，数据可以无缝迁移
2. **缓存兼容性** - 缓存文件格式保持不变
3. **测试** - 重构后需要全面测试阅读器的各项功能
