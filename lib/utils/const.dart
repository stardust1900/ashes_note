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
  static const String scrollPosPrefix = 'scroll_pos_';
  static const String volumeKeyPageTurn = 'volumeKeyPageTurn';
  static const String unsyncedNoteIds = 'unsyncedNoteIds';
  static const String noteSortMode = 'noteSortMode';
  static const String bookViewMode = 'bookViewMode'; // grid / list
  static const String bookGridSize = 'bookGridSize'; // small / medium / large
  static const String bookSortMode = 'bookSortMode'; // name / imported
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

  /// 标题上下 padding（与渲染时的 EdgeInsets.only(top: 24, bottom: 12) 一致）
  static const double headerPaddingTop = 24;
  static const double headerPaddingBottom = 12;
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
}
