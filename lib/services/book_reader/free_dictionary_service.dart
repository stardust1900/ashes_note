import 'dart:convert';
import 'package:http/http.dart' as http;

/// Free Dictionary API 服务（免费英文词典）
/// 参考：https://freedictionaryapi.com/
class FreeDictionaryService {
  // API 地址
  static const String _apiUrl = 'https://freedictionaryapi.com/api/v1/entries';

  FreeDictionaryService();

  /// 查询英文词典
  Future<DictionaryResult?> lookup(String word, {String from = 'en', String to = 'en'}) async {
    // Free Dictionary API 支持多种语言，语言代码使用 ISO 639-1
    // API 路径: /api/v1/entries/{language}/{word}
    // 需要翻译时添加 translations=true 参数
    // 将单词转为小写以避免大小写敏感问题
    final lowerWord = word.toLowerCase();
    final needTranslations = to != from;
    final url = Uri.parse('$_apiUrl/$from/$lowerWord').replace(
      queryParameters: needTranslations ? {'translations': 'true'} : {},
    );

    print('lookup: word=$word, from=$from, to=$to, needTranslations=$needTranslations');
    print('URL: $url');

    try {
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        print('响应报文: ${jsonEncode(data)}');
        final result = DictionaryResult.fromJson(data, targetLanguage: to);

        // 如果需要翻译但没有翻译结果，尝试查询单数形式
        if (needTranslations && (result.translation == null || result.translation!.isEmpty)) {
          print('当前单词没有翻译结果，尝试查询单数形式');
          final singularWord = _tryGetSingular(lowerWord);
          if (singularWord != lowerWord) {
            print('尝试查询单数形式: $singularWord');
            final singularUrl = Uri.parse('$_apiUrl/$from/$singularWord').replace(
              queryParameters: {'translations': 'true'},
            );
            final singularResponse = await http.get(singularUrl);
            if (singularResponse.statusCode == 200) {
              final singularData = jsonDecode(utf8.decode(singularResponse.bodyBytes));
              print('单数形式响应报文: ${jsonEncode(singularData)}');
              final singularResult = DictionaryResult.fromJson(singularData, targetLanguage: to);

              // 如果单数形式有翻译，返回合并的结果
              if (singularResult.translation != null && singularResult.translation!.isNotEmpty) {
                print('单数形式找到翻译: ${singularResult.translation}');
                return DictionaryResult(
                  word: word, // 保留原词
                  phonetic: result.phonetic ?? singularResult.phonetic,
                  phonetics: result.phonetics ?? singularResult.phonetics,
                  meanings: result.meanings,
                  translation: singularResult.translation,
                  web: result.web, // 保留原词的释义（如果有的话）
                  formInfo: result.formInfo ?? singularResult.formInfo, // 保留变形信息
                );
              }
            }
          }
        }

        return result;
      } else if (response.statusCode == 404) {
        print('Free Dictionary API: 未找到单词 $word');
        return null;
      } else if (response.statusCode == 429) {
        print('Free Dictionary API: 请求超限 (每小时1000次限制)');
        return null;
      }
    } catch (e) {
      print('Free Dictionary API 异常: $e');
      return null;
    }

    return null;
  }

  /// 尝试获取单词的单数形式
  /// 对于像 lectures 这样的单词，需要去掉末尾的 s
  String _tryGetSingular(String word) {
    // 如果单词很短（少于3个字符），不转换
    if (word.length < 3) return word;

    // 检查是否是复数形式
    // 1. -ies → y (如 cities → city)
    if (word.endsWith('ies')) {
      return word.substring(0, word.length - 3) + 'y';
    }

    // 2. -es → 去掉 es (如 boxes → box, buses → bus)
    // 但要注意不是所有 -es 结尾的都是复数（如 yes, his, 等）
    // 这里只处理常见的复数后缀
    if (word.endsWith('xes') || word.endsWith('ches') || word.endsWith('shes') || word.endsWith('ses')) {
      return word.substring(0, word.length - 2);
    }

    // 3. -s → 去掉 s (如 lectures → lecture, books → book)
    // 但要排除一些不是复数的常见词
    final commonNonPluralWords = {'yes', 'his', 'is', 'as', 'us', 'bus', 'this', 'that'};
    if (word.endsWith('s') && !commonNonPluralWords.contains(word)) {
      return word.substring(0, word.length - 1);
    }

    return word;
  }
}

/// 词典查询结果
class DictionaryResult {
  final String? word;
  final String? phonetic;
  final String? audio;
  final List<String>? phonetics;
  final List<Meaning>? meanings;
  final String? translation;
  final List<WebTranslation>? web;
  final String? formInfo; // 变形信息（复数、过去式等）

  DictionaryResult({
    this.word,
    this.phonetic,
    this.audio,
    this.phonetics,
    this.meanings,
    this.translation,
    this.web,
    this.formInfo,
  });

  factory DictionaryResult.fromJson(Map<String, dynamic> json, {String? targetLanguage}) {
    // 解析发音信息
    String? phonetic;
    String? audio;
    List<String>? phonetics;
    String? translation;
    String? formInfo; // 变形信息（复数、过去式等）
    final webTranslations = <WebTranslation>[];
    final targetTranslations = <String>[];

    print('fromJson: targetLanguage=$targetLanguage');

    // 从 entries 中获取发音和释义
    if (json['entries'] != null && json['entries'] is List && json['entries'].isNotEmpty) {
      final entries = json['entries'] as List;
      print('找到 ${entries.length} 个 entries');

      // 遍历所有 entries
      for (final entry in entries) {
        final entryMap = entry as Map<String, dynamic>;

        // 解析 pronunciations（从第一个 entry 获取）
        if (phonetic == null && entryMap['pronunciations'] != null && entryMap['pronunciations'] is List) {
          final pronunciations = entryMap['pronunciations'] as List;
          final phoneticList = <String>[];

          for (final p in pronunciations) {
            final pMap = p as Map<String, dynamic>;
            if (pMap['text'] != null) {
              phoneticList.add(pMap['text'] as String);
            }
          }

          if (phoneticList.isNotEmpty) {
            phonetics = phoneticList;
            phonetic = phoneticList.first;
          }
        }

        // 解析 senses 中的翻译和定义
        if (entryMap['senses'] != null && entryMap['senses'] is List) {
          final senses = entryMap['senses'] as List;
          final partOfSpeech = entryMap['partOfSpeech'] as String? ?? '';
          print('找到 ${senses.length} 个 senses, 词性: $partOfSpeech');

          for (final s in senses) {
            final sMap = s as Map<String, dynamic>;
            final definition = sMap['definition'] as String?;
            final examples = sMap['examples'] as List?;
            final tags = sMap['tags'] as List?;

            // 检测变形（复数、过去式等）
            if (formInfo == null && tags != null && tags.isNotEmpty) {
              final tagList = tags.map((e) => e.toString()).toList();
              print('  tags: $tagList');
              // 查找变形标签：form of, plural, past, participle 等
              final formTags = tagList.where((tag) =>
                tag.contains('form of') ||
                tag == 'plural' ||
                tag == 'past' ||
                tag == 'participle' ||
                tag == 'present' ||
                tag == 'singular'
              ).toList();

              print('  formTags: $formTags');
              if (formTags.isNotEmpty) {
                // 从定义中提取原型
                final baseWord = _extractBaseWord(definition);
                print('  baseWord: $baseWord');
                if (baseWord != null) {
                  final formType = _getFormType(tagList);
                  print('  formType: $formType');
                  formInfo = '这是 $formType 形式，原型：$baseWord';
                  print('  formInfo: $formInfo');
                }
              }
            }

            if (definition != null && !definition.contains('plural of') && !definition.contains('form of')) {
              webTranslations.add(WebTranslation(
                key: partOfSpeech,
                value: [definition],
              ));

              // 如果有例句，添加为单独的条目
              if (examples != null && examples.isNotEmpty) {
                final exampleTexts = examples.map((e) => e.toString()).toList();
                webTranslations.add(WebTranslation(
                  key: '例句',
                  value: exampleTexts,
                ));
              }
            }

            // 解析翻译（如果需要翻译到特定语言）
            if (targetLanguage != null && sMap['translations'] != null) {
              final translations = sMap['translations'] as List;
              print('  sense 有 ${translations.length} 个翻译');
              for (final t in translations) {
                if (t is Map<String, dynamic>) {
                  final tMap = t;
                  final lang = tMap['language'] as Map<String, dynamic>?;
                  final langCode = lang?['code'] as String?;
                  final translatedWord = tMap['word'] as String?;

                  print('    翻译: langCode=$langCode, word=$translatedWord, 目标=$targetLanguage');

                  // 匹配目标语言代码
                  if (langCode != null && langCode == targetLanguage && translatedWord != null) {
                    if (!targetTranslations.contains(translatedWord)) {
                      targetTranslations.add(translatedWord);
                      print('      添加翻译: $translatedWord');
                    }
                  }
                }
              }
            }
          }
        }
      }

      // 合并翻译结果
      if (targetTranslations.isNotEmpty) {
        translation = targetTranslations.join('; ');
        print('最终翻译: $translation');
      } else {
        print('未找到任何翻译');
      }

      return DictionaryResult(
        word: json['word'] as String?,
        phonetic: phonetic,
        phonetics: phonetics,
        meanings: [],
        translation: translation,
        web: webTranslations,
        formInfo: formInfo,
      );
    }

    print('没有找到 entries');
    return DictionaryResult(
      word: json['word'] as String?,
      phonetic: phonetic,
      audio: audio,
      phonetics: phonetics,
      meanings: [],
      translation: translation,
      web: webTranslations,
      formInfo: formInfo,
    );
  }

  /// 从定义中提取原型单词
  static String? _extractBaseWord(String? definition) {
    if (definition == null) return null;

    // 匹配 "plural of lecture" 或 "third-person singular of lecture" 等格式
    final regex = RegExp(r'(?:plural|form of|singular|past|present|participle)\s+(?:of\s+)?([a-zA-Z]+)');
    final match = regex.firstMatch(definition);
    if (match != null && match.groupCount >= 1) {
      return match.group(1);
    }
    return null;
  }

  /// 获取变形类型描述
  static String _getFormType(List<String> tags) {
    if (tags.contains('plural')) return '复数';
    if (tags.contains('past')) return '过去式';
    if (tags.contains('participle')) return '分词';
    if (tags.contains('present') && tags.contains('singular')) return '第三人称单数';
    if (tags.contains('singular')) return '单数';
    return '变形';
  }

  /// 是否成功
  bool get isSuccess => word != null && word!.isNotEmpty;

  /// 获取基本释义
  List<String> get explains {
    if (web == null || web!.isEmpty) return [];
    return web!
        .where((w) => w.key != '例句')
        .expand((w) => w.value)
        .toList();
  }
}

/// 词性和释义（保留用于兼容，Free Dictionary API 使用 WebTranslation）
class Meaning {
  final String? partOfSpeech;
  final List<Definition>? definitions;

  Meaning({
    this.partOfSpeech,
    this.definitions,
  });

  factory Meaning.fromJson(Map<String, dynamic> json) {
    final List<Definition> defs = [];
    if (json['definitions'] != null) {
      for (final d in json['definitions'] as List) {
        defs.add(Definition.fromJson(d as Map<String, dynamic>));
      }
    }

    return Meaning(
      partOfSpeech: json['partOfSpeech'] as String?,
      definitions: defs,
    );
  }
}

/// 定义
class Definition {
  final String? definition;
  final String? example;

  Definition({
    this.definition,
    this.example,
  });

  factory Definition.fromJson(Map<String, dynamic> json) {
    return Definition(
      definition: json['definition'] as String?,
      example: json['example'] as String?,
    );
  }
}

/// 网络释义（用于兼容有道词典格式）
class WebTranslation {
  final String key;
  final List<String> value;

  WebTranslation({required this.key, required this.value});
}
