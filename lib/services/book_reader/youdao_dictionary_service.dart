import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'dart:typed_data';

/// 有道词典 API 服务
/// 参考：https://ai.youdao.com/DOCS2022/assets/jsapi/zh-CN/apidoc.html
class YoudaoDictionaryService {
  // 需要配置的应用 ID 和密钥
  final String appId;
  final String appKey;

  // API 地址
  static const String _apiUrl = 'https://openapi.youdao.com/api';

  YoudaoDictionaryService({required this.appId, required this.appKey});

  /// 查询词典
  Future<DictionaryResult?> lookup(String word, {String from = 'en', String to = 'zh-CHS'}) async {
    final salt = const Uuid().v4().toString();
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final truncatedQuery = _truncateQuery(word);
    final sign = _generateSign(word, salt, timestamp.toString());

    final url = Uri.parse(_apiUrl).replace(
      queryParameters: {
        'q': word,
        'from': from,
        'to': to,
        'appKey': appId,
        'salt': salt,
        'sign': sign,
        'signType': 'v3',
        'curtime': '$timestamp',
      },
    );

    try {
      final response = await http.get(url);
      final responseBody = utf8.decode(response.bodyBytes);

      if (response.statusCode == 200) {
        final data = jsonDecode(responseBody);

        if (data['errorCode'] == 0 || data['errorCode'] == '0') {
          return DictionaryResult.fromJson(data);
        } else {
          print('有道词典API错误 [${data['errorCode']}]: ${responseBody}');
          return null;
        }
      }
    } catch (e) {
      print('有道词典API异常: $e');
      return null;
    }

    return null;
  }

  /// 生成 API 签名
  /// v3 签名算法：SHA256(appId + truncate(query) + salt + curtime + appKey)
  String _generateSign(String query, String salt, String curtime) {
    // v3 签名需要使用截断后的查询词
    final truncatedQuery = _truncateQuery(query);
    final input = appId + truncatedQuery + salt + curtime + appKey;
    final bytes = utf8.encode(input);
    final hash = sha256.convert(bytes);
    return hash.toString();
  }

  /// 截断查询字符串（有道 API 要求）
  /// 如果 query 长度 > 20：前 10 位 + 长度 + 后 10 位
  /// 否则：直接使用 query
  String _truncateQuery(String query) {
    if (query.length > 20) {
      return query.substring(0, 10) +
          query.length.toString() +
          query.substring(query.length - 10);
    }
    return query;
  }
}

/// 词典查询结果
class DictionaryResult {
  final String? query;
  final String? errorCode;
  final String? errorMsg;
  final BasicInfo? basic;
  final List<WebTranslation>? web;
  final String? translation;
  final List<String>? translations;

  DictionaryResult({
    this.query,
    this.errorCode,
    this.errorMsg,
    this.basic,
    this.web,
    this.translation,
    this.translations,
  });

  factory DictionaryResult.fromJson(Map<String, dynamic> json) {
    // translation 可能是字符串或数组
    String? translation;
    List<String>? translations;
    if (json['translation'] != null) {
      if (json['translation'] is List) {
        translations = (json['translation'] as List)
            .map((e) => e.toString())
            .toList();
        translation = translations.isNotEmpty ? translations.join(', ') : null;
      } else {
        translation = json['translation'] as String?;
      }
    }

    return DictionaryResult(
      query: json['query'] as String?,
      errorCode: json['errorCode']?.toString(),
      errorMsg: json['errorMsg'] as String?,
      basic: json['basic'] != null ? BasicInfo.fromJson(json['basic']) : null,
      web: (json['web'] as List?)
          ?.map((w) => WebTranslation.fromJson(w as Map<String, dynamic>))
          .toList(),
      translation: translation,
      translations: translations,
    );
  }

  /// 是否成功
  bool get isSuccess => errorCode == '0' || errorCode == null;
}

/// 基本释义信息
class BasicInfo {
  final String? phonetic;
  final List<String>? explains;
  final List<String>? ukPhonetic;
  final List<String>? usPhonetic;
  final List<String>? wfs;

  BasicInfo({
    this.phonetic,
    this.explains,
    this.ukPhonetic,
    this.usPhonetic,
    this.wfs,
  });

  factory BasicInfo.fromJson(Map<String, dynamic>? json) {
    if (json == null) return BasicInfo();

    // 调试输出
    print('BasicInfo JSON keys: ${json!.keys.toList()}');
    print('phonetic: ${json!['phonetic']}');
    print('uk-phonetic: ${json!['uk-phonetic']} (${json!['uk-phonetic'].runtimeType})');
    print('us-phonetic: ${json!['us-phonetic']} (${json!['us-phonetic'].runtimeType})');

    return BasicInfo(
      phonetic: json!['phonetic'] as String?,
      explains: (json!['explains'] as List?)?.map((e) => e.toString()).toList(),
      ukPhonetic: json!['uk-phonetic'] != null
          ? [json!['uk-phonetic'].toString()]
          : null,
      usPhonetic: json!['us-phonetic'] != null
          ? [json!['us-phonetic'].toString()]
          : null,
      wfs: (json!['wfs'] as List?)?.map((e) => e.toString()).toList(),
    );
  }

  /// 获取美式音标
  String? get usPhoneticStr =>
      usPhonetic?.isNotEmpty == true ? usPhonetic!.first : null;

  /// 获取英式音标
  String? get ukPhoneticStr =>
      ukPhonetic?.isNotEmpty == true ? ukPhonetic!.first : null;

  /// 获取音标显示字符串
  String get phoneticDisplay {
    if (phonetic?.isNotEmpty == true) return '[$phonetic]';
    if (usPhoneticStr != null && ukPhoneticStr != null) {
      return '[$usPhoneticStr, $ukPhoneticStr]';
    }
    if (usPhoneticStr != null) return '[$usPhoneticStr]';
    if (ukPhoneticStr != null) return '[$ukPhoneticStr]';
    return '';
  }
}

/// 网络释义
class WebTranslation {
  final String key;
  final List<String> value;

  WebTranslation({required this.key, required this.value});

  factory WebTranslation.fromJson(Map<String, dynamic> json) {
    return WebTranslation(
      key: json['key'] as String,
      value: (json['value'] as List).map((v) => v.toString()).toList(),
    );
  }
}
