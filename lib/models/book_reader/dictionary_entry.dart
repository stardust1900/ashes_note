/// 字典条目模型
class DictionaryEntry {
  final String word;
  final String definition;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String? bookTitle;
  final String? chapterTitle;
  final int? chapterIndex;
  final int? pageIndex;
  final String? imageUrl; // 图片 URL

  DictionaryEntry({
    required this.word,
    required this.definition,
    required this.createdAt,
    this.updatedAt,
    this.bookTitle,
    this.chapterTitle,
    this.chapterIndex,
    this.pageIndex,
    this.imageUrl,
  });

  Map<String, dynamic> toJson() {
    return {
      'word': word,
      'definition': definition,
      'createdAt': createdAt.toIso8601String(),
      if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
      if (bookTitle != null) 'bookTitle': bookTitle,
      if (chapterTitle != null) 'chapterTitle': chapterTitle,
      if (chapterIndex != null) 'chapterIndex': chapterIndex,
      if (pageIndex != null) 'pageIndex': pageIndex,
      if (imageUrl != null) 'imageUrl': imageUrl,
    };
  }

  factory DictionaryEntry.fromJson(Map<String, dynamic> json) {
    return DictionaryEntry(
      word: json['word'] as String,
      definition: json['definition'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: json['updatedAt'] != null 
          ? DateTime.parse(json['updatedAt'] as String) 
          : null,
      bookTitle: json['bookTitle'] as String?,
      chapterTitle: json['chapterTitle'] as String?,
      chapterIndex: json['chapterIndex'] as int?,
      pageIndex: json['pageIndex'] as int?,
      imageUrl: json['imageUrl'] as String?,
    );
  }

  DictionaryEntry copyWith({
    String? word,
    String? definition,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? bookTitle,
    String? chapterTitle,
    int? chapterIndex,
    int? pageIndex,
    String? imageUrl,
  }) {
    return DictionaryEntry(
      word: word ?? this.word,
      definition: definition ?? this.definition,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      bookTitle: bookTitle ?? this.bookTitle,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      pageIndex: pageIndex ?? this.pageIndex,
      imageUrl: imageUrl ?? this.imageUrl,
    );
  }
}
