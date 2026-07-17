class PrefKeys {
  static const String workingDirectory = 'workingDirectory';
  static const String gitPlatform = 'gitPlatform';
  static const String giteeToken = 'giteeToken';
  static const String giteeRemoteUrl = 'giteeRemoteUrl';
  static const String githubToken = 'githubToken';
  static const String githubRemoteUrl = 'githubRemoteUrl';
  static const String lastPullTime = 'lastPullTime';
  static const String selectedNotebook = 'selectedNotebook';
  static const String selectedNote = 'selectedNote';
  static const String themeMode = 'themeMode'; // 主题模式：minimal 或 dark
  static const String showLineNumbers = 'showLineNumbers';
  static const String autoWrap = 'autoWrap';
  static const String editorFontSize = 'editorFontSize'; // 编辑器正文字号
  static const String scrollPosPrefix = 'scroll_pos_';
  static const String volumeKeyPageTurn = 'volumeKeyPageTurn';
  static const String unsyncedNoteIds = 'unsyncedNoteIds';
  static const String noteSortMode = 'noteSortMode';
  static const String bookViewMode = 'bookViewMode'; // grid / list
  static const String bookGridSize = 'bookGridSize'; // small / medium / large
  static const String bookSortMode = 'bookSortMode'; // name / imported

  // ===== RSS 阅读器相关常量 =====
  static const String rssRefreshInterval =
      'rssRefreshInterval'; // 定时刷新间隔（分钟）
  static const String rssViewMode = 'rssViewMode'; // list / grid
  static const String rssLastSelectedFeedId =
      'rssLastSelectedFeedId'; // 上次选中的订阅源/分组 id
  static const String rssShowRead = 'rssShowRead'; // 是否在列表显示已读
  static const String rssStarredOnly = 'rssStarredOnly'; // 仅看收藏
}

class GitPlatforms {
  static const String gitee = 'gitee';
  static const String github = 'github';
}

class ThemeModes {
  static const String minimal = 'minimal';
  static const String dark = 'dark';
  static const String inkMode = 'inkMode';
}

/// 书籍阅读器相关常量
class BookReaderConstants {
  /// 文本行高 - 分页计算和渲染必须保持一致
  static const double lineHeight = 1.5;

  /// 标题行高
  static const double headerLineHeight = 1.2;

  /// 标题上下 padding（桌面端减小底部间距以减少空行）
  static const double headerPaddingTop = 16;
  static const double headerPaddingBottom = 4;
  static const double headerTotalPadding =
      headerPaddingTop + headerPaddingBottom;

  /// 获取标题字体大小（h1=32, h2=28, ..., h6=12）
  static double getHeaderFontSize(int level) {
    final clampedLevel = level.clamp(1, 6);
    return 32.0 - (clampedLevel - 1) * 4;
  }

  /// 计算标题实际占用高度（字体高度 + padding）
  static double getHeaderHeight(int level, double baseFontSize) {
    final headerFontSize = getHeaderFontSize(level);
    final headerTextHeight = headerFontSize * headerLineHeight;
    return headerTextHeight + headerTotalPadding;
  }

  /// 页面内容区垂直方向总预留高度
  /// - 顶部占位（kToolbarHeight）或 padding top（10）
  /// - 底部 padding（10）
  /// - 底部 SizedBox（20）
  /// 总计：120 像素
  static const double pageVerticalReserve = 120;

  /// _buildPageContent 内部的上下 padding（各 10）
  static const double contentPaddingVertical = 20;

  /// SelectableText 额外的内边距补偿（用于选择手柄区域）
  /// 小字体时 TextPainter 计算和实际渲染有差异，原因：
  /// 1. SelectableText 有选择手柄区域的内边距
  /// 2. TextPainter 和实际渲染的行高计算有微小差异
  /// 3. 字体 hinting 和 subpixel 渲染导致的差异
  /// 预留 20 像素作为保险（约 1-1.5 行）
  static const double selectableTextExtraPadding = 20;

  /// 桌面端阅读器最大内容宽度（dp）
  /// 超过此宽度时，内容区域居中显示，不再随窗口变宽
  /// Kindle 风格：保持舒适的阅读宽度，避免长行影响阅读体验
  static const double maxReaderContentWidth = 800.0;
}

/// RSS 阅读器相关常量
class RssConstants {
  /// 工作目录下存放 RSS 数据的子目录
  static const String rssDir = 'rss';

  /// 订阅源与文章缓存文件名
  static const String feedsFile = 'feeds.json';

  /// OPML 导入导出目录
  static const String opmlDir = 'opml';

  /// 单源最多缓存文章数（控制 feeds.json 体积）
  static const int maxArticlesPerFeed = 200;

  /// 默认定时刷新间隔（分钟）
  static const int defaultRefreshInterval = 30;

  /// 可选的刷新间隔档位（分钟），用于设置页下拉选择
  static const List<int> refreshIntervalOptions = [0, 15, 30, 60, 120, 360];

  /// 全文搜索输入防抖时长（毫秒）
  static const Duration searchDebounce = Duration(milliseconds: 300);

  /// 特殊分组 id：全部、未读、收藏
  static const String allFeedsId = '__all__';
  static const String unreadFeedsId = '__unread__';
  static const String starredFeedsId = '__starred__';
}
