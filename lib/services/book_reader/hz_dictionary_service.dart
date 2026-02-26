import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../models/book_reader/dictionary_entry.dart';

/// 单词类型枚举
enum WordType {
  chineseChar, // 汉字单字
  chineseWord, // 汉字词语
  english, // 英文单词
}

/// HzDictionary API 服务
/// 支持中文字词查词、单字查词、英文单词查询
/// 使用说明：需要在 https://www.apihz.cn 注册获取 id 和 key
class HzDictionaryService {
  // API ID 和 Key（需要在 apihz.cn 注册获取）
  final String apiId;
  final String apiKey;

  static const String _baseUrl = 'https://cn.apihz.cn/api/zici';

  /// API 端点
  static const String _wordEndpoint = '$_baseUrl/chaciyu.php'; // 汉字词语
  static const String _charEndpoint = '$_baseUrl/chazd.php'; // 汉字单字
  static const String _englishEndpoint = '$_baseUrl/danci.php'; // 英文单词

  HzDictionaryService({required this.apiId, required this.apiKey});

  /// 查找单词
  Future<DictionaryEntry?> lookup(String word) async {
    try {
      print('HzDictionaryService 查询: $word'); // 调试
      // 判断单词类型
      final wordType = _detectWordType(word);
      print('检测到的类型: $wordType'); // 调试

      Map<String, dynamic> result;
      switch (wordType) {
        case WordType.chineseChar:
          result = await _lookupChineseChar(word);
          break;
        case WordType.chineseWord:
          result = await _lookupChineseWord(word);
          break;
        case WordType.english:
          result = await _lookupEnglish(word);
          break;
      }

      print('API 返回结果: $result'); // 调试

      // 转换为 DictionaryEntry
      final definition = _formatDefinition(result, wordType);
      print('格式化后的解释: $definition'); // 调试

      // 提取图片 URL
      String? imageUrl;
      final data = result['data'] as Map<String, dynamic>?;
      if (data != null && wordType == WordType.chineseChar) {
        imageUrl = data['smallimage']?.toString() ?? data['image']?.toString();
      }

      return DictionaryEntry(
        word: word,
        definition: definition,
        createdAt: DateTime.now(),
        imageUrl: imageUrl,
      );
    } catch (e) {
      print('HzDictionaryService 异常: $e'); // 调试
      return null; // 查询失败返回 null，由调用方处理
    }
  }

  /// 检测单词类型
  WordType _detectWordType(String word) {
    // 检查是否全为英文字母
    if (RegExp(r'^[a-zA-Z]+$').hasMatch(word)) {
      return WordType.english;
    }

    // 检查是否包含中文字符
    if (RegExp(r'[\u4e00-\u9fa5]').hasMatch(word)) {
      // 单个汉字 vs 词语
      return word.length == 1 && RegExp(r'^[\u4e00-\u9fa5]$').hasMatch(word)
          ? WordType.chineseChar
          : WordType.chineseWord;
    }

    // 默认视为词语
    return WordType.chineseWord;
  }

  /// 查询汉字单字
  Future<Map<String, dynamic>> _lookupChineseChar(String char) async {
    final url = Uri.parse(
      '$_charEndpoint',
    ).replace(queryParameters: {'word': char, 'id': apiId, 'key': apiKey});
    final response = await http
        .get(url)
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            throw Exception('请求超时');
          },
        );

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body);

    if (data['code'] != 200) {
      throw Exception(data['msg'] ?? '查询失败');
    }

    // API 直接返回扁平结构
    return {'type': 'char', 'data': data};
  }

  /// 查询汉字词语
  Future<Map<String, dynamic>> _lookupChineseWord(String word) async {
    final url = Uri.parse(
      '$_wordEndpoint',
    ).replace(queryParameters: {'words': word, 'id': apiId, 'key': apiKey});
    final response = await http
        .get(url)
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            throw Exception('请求超时');
          },
        );

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body);

    if (data['code'] != 200) {
      throw Exception(data['msg'] ?? '查询失败');
    }

    // API 直接返回扁平结构，不是嵌套的 data 对象
    return {'type': 'word', 'data': data};
  }

  /// 查询英文单词
  Future<Map<String, dynamic>> _lookupEnglish(String word) async {
    final url = Uri.parse(
      '$_englishEndpoint',
    ).replace(queryParameters: {'word': word, 'id': apiId, 'key': apiKey});
    print('英文查询 URL: $url'); // 调试
    final response = await http
        .get(url)
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            throw Exception('请求超时');
          },
        );

    print('英文查询响应状态码: ${response.statusCode}'); // 调试
    print('英文查询响应体: ${response.body}'); // 调试

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body);

    if (data['code'] != 200) {
      throw Exception(data['msg'] ?? '查询失败');
    }

    // API 直接返回扁平结构
    return {'type': 'english', 'data': data};
  }

  /// 格式化定义为展示文本
  String _formatDefinition(Map<String, dynamic> result, WordType type) {
    final data = result['data'] as Map<String, dynamic>?;
    if (data == null || data.isEmpty) {
      return '未找到解释';
    }

    final buffer = StringBuffer();

    switch (type) {
      case WordType.chineseChar:
        // 单字信息 - API 返回的扁平结构
        if (data['word'] != null) {
          buffer.writeln('${data['word']}');
          buffer.writeln();
        }
        if (data['pinyin'] != null || data['yindiao'] != null) {
          final pinyin =
              data['yindiao']?.toString() ?? data['pinyin']?.toString() ?? '';
          buffer.writeln('拼音: ${_formatPinyin(pinyin)}');
          buffer.writeln();
        }
        // 基本信息
        final basicInfo = <String>[];
        if (data['bushou'] != null) {
          basicInfo.add('部首: ${data['bushou']}');
        }
        if (data['bihua'] != null) {
          basicInfo.add('笔画: ${data['bihua']}');
        }
        if (data['wubi'] != null) {
          basicInfo.add('五笔: ${data['wubi']}');
        }
        if (data['wuxing'] != null) {
          basicInfo.add('五行: ${data['wuxing']}');
        }
        if (data['jg'] != null) {
          basicInfo.add('结构: ${data['jg']}');
        }
        if (basicInfo.isNotEmpty) {
          buffer.writeln(basicInfo.join('  ')); // 使用两个空格分隔
          buffer.writeln();
        }
        // jieshi 字段包含详细解释
        if (data['jieshi'] != null) {
          buffer.writeln('详细解释:');
          buffer.writeln();
          buffer.writeln(_formatJieshi(data['jieshi'].toString()));
        } else if (data['jianjie'] != null) {
          buffer.writeln('简介:');
          buffer.writeln();
          final jianjie = data['jianjie'].toString();
          // 清理简介中的格式问题
          final cleanJianjie = _cleanText(jianjie);
          final parts = cleanJianjie.split('，'); // 按中文逗号分隔
          for (var part in parts) {
            if (part.trim().isNotEmpty) {
              buffer.writeln(part.trim());
            }
          }
        }
        break;

      case WordType.chineseWord:
        // 词语信息 - API 返回的扁平结构
        if (data['words'] != null) {
          buffer.writeln('${data['words']}');
          buffer.writeln();
        }
        // zcpy 字段包含拼音
        if (data['zcpy'] != null && data['zcpy'].toString().isNotEmpty) {
          buffer.writeln('拼音: ${_formatPinyin(data['zcpy'].toString())}');
          buffer.writeln();
        }
        // cx 字段包含词性
        if (data['cx'] != null && data['cx'].toString().isNotEmpty) {
          buffer.writeln('词性: ${data['cx']}');
          buffer.writeln();
        }
        // content 字段包含解释内容
        if (data['content'] != null) {
          buffer.writeln('解释:');
          buffer.writeln();
          final content = data['content'].toString();
          // 清理 HTML 标签
          final cleanContent = content
              .replaceAll('<br>', '\n')
              .replaceAll('</br>', '\n')
              .replaceAll('<br/>', '\n');
          // 按序号分割解释内容,但保留序号
          final expParts = cleanContent.split(RegExp(r'(?=[①②③④⑤⑥⑦⑧⑨⑩])'));
          for (var part in expParts) {
            if (part.trim().isNotEmpty) {
              buffer.writeln(part.trim());
            }
          }
        }
        break;

      case WordType.english:
        // 英文信息 - API 返回的扁平结构
        if (data['word'] != null) {
          buffer.writeln('${data['word']}');
          buffer.writeln();
        }
        if (data['british'] != null) {
          buffer.writeln('英式音标: ${data['british']}');
        }
        if (data['american'] != null) {
          buffer.writeln('美式音标: ${data['american']}');
        }
        buffer.writeln();
        // jbjs 字段是基本释义，wlsy 是网络释义
        if (data['jbjs'] != null) {
          buffer.writeln('基本释义:');
          buffer.writeln();
          final jbjs = data['jbjs'].toString();
          final parts = jbjs.split('；'); // 按中文分号分隔
          for (var part in parts) {
            if (part.trim().isNotEmpty) {
              buffer.writeln('  ${part.trim()}'); // 缩进显示
            }
          }
        }
        if (data['wlsy'] != null) {
          buffer.writeln();
          buffer.writeln('网络释义:');
          buffer.writeln();
          buffer.writeln(data['wlsy']);
        }
        if (data['lz'] != null && data['lz'].toString().isNotEmpty) {
          buffer.writeln();
          buffer.writeln('例句:');
          buffer.writeln();
          buffer.writeln(data['lz']);
        }
        break;
    }

    return buffer.toString().trim();
  }

  /// 清理文本中的格式问题
  String _cleanText(String text) {
    // 移除 Unicode 转义序列
    var cleaned = text.replaceAll(RegExp(r'\\u[0-9a-fA-F]{4}'), '');
    // 移除多余的分隔符
    cleaned = cleaned.replaceAll(RegExp(r',,'), ',');
    // 移除首尾多余的分隔符和空格
    cleaned = cleaned.trim().replaceAll(RegExp(r'^,|,$'), '').trim();
    return cleaned;
  }

  /// 格式化详细解释
  String _formatJieshi(String jieshi) {
    // 清理格式
    var cleaned = jieshi.replaceAll(
      RegExp(r'\{|\}|"|type|data|:|word|code|200'),
      '',
    );
    // 移除逗号分隔的多余空格
    cleaned = cleaned.replaceAll(RegExp(r',\s*'), '，');
    // 移除中英文混合的分隔符
    cleaned = cleaned.replaceAll(',,', '，');
    // 移除连续的逗号
    cleaned = cleaned.replaceAll(RegExp(r',{2,}'), '，');
    // 清理 Unicode 转义
    cleaned = _cleanText(cleaned);
    return cleaned;
  }

  /// 格式化拼音显示
  /// 处理类似 "luè" 这样的拼音，将数字声调转换为带声调符号
  String _formatPinyin(String pinyin) {
    if (pinyin.isEmpty) return pinyin;

    // 替换常见的声调数字为带声调符号的字母
    final toneMap = {
      'a1': 'ā',
      'a2': 'á',
      'a3': 'ǎ',
      'a4': 'à',
      'a5': 'a',
      'e1': 'ē',
      'e2': 'é',
      'e3': 'ě',
      'e4': 'è',
      'e5': 'e',
      'i1': 'ī',
      'i2': 'í',
      'i3': 'ǐ',
      'i4': 'ì',
      'i5': 'i',
      'o1': 'ō',
      'o2': 'ó',
      'o3': 'ǒ',
      'o4': 'ò',
      'o5': 'o',
      'u1': 'ū',
      'u2': 'ú',
      'u3': 'ǔ',
      'u4': 'ù',
      'u5': 'u',
      'v1': 'ǖ',
      'v2': 'ǘ',
      'v3': 'ǚ',
      'v4': 'ǜ',
      'v5': 'ü',
      'A1': 'Ā',
      'A2': 'Á',
      'A3': 'Ǎ',
      'A4': 'À',
      'A5': 'A',
      'E1': 'Ē',
      'E2': 'É',
      'E3': 'Ě',
      'E4': 'È',
      'E5': 'E',
      'I1': 'Ī',
      'I2': 'Í',
      'I3': 'Ǐ',
      'I4': 'Ì',
      'I5': 'I',
      'O1': 'Ō',
      'O2': 'Ó',
      'O3': 'Ǒ',
      'O4': 'Ò',
      'O5': 'O',
      'U1': 'Ū',
      'U2': 'Ú',
      'U3': 'Ǔ',
      'U4': 'Ù',
      'U5': 'U',
    };

    String result = pinyin;

    // 遍历映射表进行替换
    for (final entry in toneMap.entries) {
      result = result.replaceAll(entry.key, entry.value);
    }

    return result;
  }
}
