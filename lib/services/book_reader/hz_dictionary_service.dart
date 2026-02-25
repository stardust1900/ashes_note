import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../models/book_reader/dictionary_entry.dart';

/// HzDictionary API 服务
/// 支持中文字词查词、单字查词、英文单词查询
/// 使用说明：需要在 https://www.apihz.cn 注册获取 id 和 key
class HzDictionaryService {
  // API ID 和 Key（需要在 apihz.cn 注册获取）
  final String apiId;
  final String apiKey;

  static const String _baseUrl = 'https://cn.apihz.cn/api/zici';

  /// API 端点
  static const String _wordEndpoint = '$_baseUrl/chaciyu.php';  // 汉字词语
  static const String _charEndpoint = '$_baseUrl/chazd.php';    // 汉字单字
  static const String _englishEndpoint = '$_baseUrl/danci.php';  // 英文单词

  HzDictionaryService({
    required this.apiId,
    required this.apiKey,
  });

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

      return DictionaryEntry(
        word: word,
        definition: definition,
        createdAt: DateTime.now(),
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
    final url = Uri.parse('$_charEndpoint').replace(
      queryParameters: {
        'word': char,
        'id': apiId,
        'key': apiKey,
      },
    );
    final response = await http.get(url).timeout(
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
    return {
      'type': 'char',
      'data': data,
    };
  }

  /// 查询汉字词语
  Future<Map<String, dynamic>> _lookupChineseWord(String word) async {
    final url = Uri.parse('$_wordEndpoint').replace(
      queryParameters: {
        'words': word,
        'id': apiId,
        'key': apiKey,
      },
    );
    final response = await http.get(url).timeout(
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
    return {
      'type': 'word',
      'data': data,
    };
  }

  /// 查询英文单词
  Future<Map<String, dynamic>> _lookupEnglish(String word) async {
    final url = Uri.parse('$_englishEndpoint').replace(
      queryParameters: {
        'word': word,
        'id': apiId,
        'key': apiKey,
      },
    );
    print('英文查询 URL: $url'); // 调试
    final response = await http.get(url).timeout(
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
    return {
      'type': 'english',
      'data': data,
    };
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
        if (data['word'] != null) buffer.writeln('汉字: ${data['word']}');
        if (data['pinyin'] != null) buffer.writeln('拼音: ${data['pinyin']}');
        if (data['bushou'] != null) buffer.writeln('部首: ${data['bushou']}');
        if (data['bihua'] != null) buffer.writeln('笔画: ${data['bihua']}');
        if (data['wubi'] != null) buffer.writeln('五笔: ${data['wubi']}');
        // jieshi 字段包含详细解释
        if (data['jieshi'] != null && data['jieshi'].toString().length < 500) {
          buffer.writeln('解释:');
          buffer.writeln(data['jieshi']);
        } else if (data['jianjie'] != null) {
          buffer.writeln('简介:');
          buffer.writeln(data['jianjie']);
        }
        break;

      case WordType.chineseWord:
        // 词语信息 - API 返回的扁平结构
        if (data['words'] != null) buffer.writeln('词语: ${data['words']}');
        // content 字段包含拼音和解释（格式：拼音\n解释）
        if (data['content'] != null) {
          final content = data['content'].toString();
          // 替换 HTML 标签为换行
          final cleanContent = content.replaceAll('<br>', '\n').replaceAll('</br>', '\n');
          final parts = cleanContent.split('\n');
          if (parts.isNotEmpty && parts[0].isNotEmpty) {
            buffer.writeln('拼音: ${parts[0]}');
          }
          if (parts.length > 1) {
            buffer.writeln('解释:');
            // 合并剩余的文本作为解释
            final explanation = parts.skip(1).join('\n').trim();
            if (explanation.isNotEmpty) {
              buffer.writeln(explanation);
            }
          }
        }
        // 其他可能的字段
        if (data['zcpy'] != null && data['zcpy'].toString().isNotEmpty) {
          buffer.writeln('组词拼音: ${data['zcpy']}');
        }
        if (data['cx'] != null && data['cx'].toString().isNotEmpty) {
          buffer.writeln('词性: ${data['cx']}');
        }
        break;

      case WordType.english:
        // 英文信息 - API 返回的扁平结构
        if (data['word'] != null) buffer.writeln('单词: ${data['word']}');
        if (data['british'] != null) buffer.writeln('英式音标: ${data['british']}');
        if (data['american'] != null) buffer.writeln('美式音标: ${data['american']}');
        // jbjs 字段是基本释义，wlsy 是网络释义
        if (data['jbjs'] != null) {
          buffer.writeln('基本释义:');
          buffer.writeln(data['jbjs']);
        }
        if (data['wlsy'] != null) {
          buffer.writeln('网络释义:');
          buffer.writeln(data['wlsy']);
        }
        if (data['lz'] != null && data['lz'].toString().isNotEmpty) {
          buffer.writeln('例句:');
          buffer.writeln(data['lz']);
        }
        break;
    }

    return buffer.toString().trim();
  }

  /// 格式化多行文本
  String _formatMultiline(dynamic text) {
    if (text == null) return '';
    String str = text.toString();
    // 将常见的分隔符转换为换行
    return str
        .replaceAll('；', '\n')
        .replaceAll('。', '\n')
        .replaceAll(';', '\n')
        .replaceAll('.', '\n')
        .trim();
  }
}

/// 单词类型枚举
enum WordType {
  chineseChar,  // 汉字单字
  chineseWord,  // 汉字词语
  english,      // 英文单词
}
