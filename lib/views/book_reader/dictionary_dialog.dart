import 'package:flutter/material.dart' hide Image;
import 'package:flutter/material.dart' as material show Image;
import '../../services/book_reader/youdao_dictionary_service.dart';
import '../../services/book_reader/free_dictionary_service.dart';
import '../../services/book_reader/hz_dictionary_service.dart';

/// 词典结果对话框
class DictionaryDialog {
  /// 语言代码映射（有道词典 -> Free Dictionary API）
  /// Free Dictionary API 使用 cmn 表示普通话（中文翻译）
  static const Map<String, String> _languageCodeMap = {
    'zh-CHS': 'cmn', // 简体中文 -> Chinese Mandarin
    'zh': 'cmn',
    'cmn': 'cmn',
    'en': 'en',
    'ja': 'ja',
    'ko': 'ko',
    'fr': 'fr',
    'de': 'de',
    'es': 'es',
  };

  /// 转换语言代码到 Free Dictionary API 格式
  static String convertToFreeDictionaryLanguageCode(String code) {
    return _languageCodeMap[code] ?? code;
  }

  /// 显示词典结果对话框
  static void show(
    BuildContext context, {
    required String word,
    dynamic result,
    String from = 'en',
    String to = 'zh-CHS',
    String dataSource = 'hz',
    required YoudaoDictionaryService youdaoService,
    required FreeDictionaryService freeDictionaryService,
    required HzDictionaryService hzService,
    required Future<void> Function(String language) saveDictionaryTargetLanguage,
  }) {
    // 检测所选文字是否为中文
    final isSourceChinese = word.contains(RegExp(r'[\u4e00-\u9fa5]'));
    final sourceLanguageText = isSourceChinese ? '中文' : '英文';

    // Free Dictionary 只支持英文
    final canUseFreeDictionary = !isSourceChinese;

    StateSetter? setState;
    String currentWord = word;
    dynamic currentResult = result;
    bool isLoading = false;
    String currentFrom = from;
    String currentTo = to;
    String currentDataSource = dataSource;

    void fetchDictionary(
      String dataSource,
      String newFrom,
      String newTo,
    ) async {
      if (!context.mounted) return;
      setState?.call(() {
        isLoading = true;
      });

      dynamic newResult;
      if (dataSource == 'hz') {
        // Hz Dictionary API
        newResult = await hzService.lookup(currentWord);
      } else if (dataSource == 'free') {
        // Free Dictionary API 需要转换语言代码
        final freeFrom = convertToFreeDictionaryLanguageCode(newFrom);
        final freeTo = convertToFreeDictionaryLanguageCode(newTo);
        newResult = await freeDictionaryService.lookup(
          currentWord,
          from: freeFrom,
          to: freeTo,
        );
      } else {
        newResult = await youdaoService.lookup(
          currentWord,
          from: newFrom,
          to: newTo,
        );
      }

      if (!context.mounted) return;
      setState?.call(() {
        currentResult = newResult;
        currentDataSource = dataSource;
        currentFrom = newFrom;
        currentTo = newTo;
        isLoading = false;
      });
    }

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setStateBuilder) {
          setState = setStateBuilder;

          // 根据结果类型解析数据
          String? phoneticOrPinyin;
          String? phoneticDisplay;
          List<String>? explains;
          List<dynamic>? webTranslations;
          String? translation;
          String? formInfo; // 变形信息
          String? hzDefinition; // Hz 词典的完整解释
          String? hzImageUrl; // Hz 词典的图片 URL

          if (currentDataSource == 'hz') {
            // Hz Dictionary 结果
            hzDefinition = currentResult?.definition;
            hzImageUrl = currentResult?.imageUrl;
          } else if (currentDataSource == 'free') {
            // Free Dictionary 结果
            phoneticOrPinyin = currentResult.phonetic ?? '';
            explains = currentResult.explains;
            webTranslations = currentResult.web?.cast<dynamic>();
            translation = currentResult.translation;
            formInfo = currentResult.formInfo;
            phoneticDisplay = phoneticOrPinyin?.isNotEmpty == true
                ? '[$phoneticOrPinyin]'
                : '';
          } else if (currentResult is YoudaoDictionaryResult) {
            // 有道词典结果
            final basic = currentResult.basic;
            phoneticOrPinyin = currentFrom == 'en'
                ? (basic?.phonetic ?? '')
                : (currentResult.basic?.phonetic ?? '');
            phoneticDisplay =
                currentFrom == 'en' && (phoneticOrPinyin?.isNotEmpty ?? false)
                ? '[$phoneticOrPinyin]'
                : (phoneticOrPinyin ?? '');
            explains = basic?.explains?.map((e) => '$e').toList();
            webTranslations = currentResult.web?.cast<dynamic>();
            translation = currentResult.translation ?? '';
          }

          final explainsText = explains?.join('; ') ?? '';
          final webTranslationsText =
              webTranslations
                  ?.map((w) => '${w.key}: ${(w.value as List).join('; ')}')
                  .join('\n') ??
              '';

          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.menu_book, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        currentWord,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        sourceLanguageText,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (phoneticDisplay?.isNotEmpty == true)
                  Text(
                    phoneticDisplay!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(fontSize: 14),
                  ),
              ],
            ),
            content: isLoading
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 词典源选择下拉框（不在滚动区域内）
                      DropdownButtonFormField<String>(
                        initialValue: currentDataSource,
                        decoration: const InputDecoration(
                          labelText: '词典源',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        items: [
                          const DropdownMenuItem(value: 'hz', child: Text('Hz 词典')),
                          const DropdownMenuItem(
                            value: 'youdao',
                            child: Text('有道词典'),
                          ),
                          if (canUseFreeDictionary)
                            const DropdownMenuItem(
                              value: 'free',
                              child: Text('Free Dictionary'),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null && value != currentDataSource) {
                            fetchDictionary(value, currentFrom, currentTo);
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                      // 内容区域（可滚动）
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 检查是否有结果
                              if ((currentDataSource == 'hz' &&
                                      hzDefinition == null) ||
                                  (currentDataSource != 'hz' &&
                                      explainsText.isEmpty &&
                                      translation?.isEmpty != false)) ...[
                                // 没有查到结果
                                Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      children: [
                                        Icon(
                                          Icons.search_off,
                                          size: 48,
                                          color: Theme.of(
                                            context,
                                          ).iconTheme.color,
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          '没有查到结果',
                                          style: TextStyle(
                                            fontSize: 16,
                                            color: Theme.of(
                                              context,
                                            ).textTheme.bodySmall?.color,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ] else ...[
                                // Hz 词典显示完整解释（使用 Markdown 渲染）
                                if (currentDataSource == 'hz' &&
                                    hzDefinition != null &&
                                    hzDefinition.isNotEmpty) ...[
                                  // 显示汉字图片
                                  if (hzImageUrl != null &&
                                      hzImageUrl.isNotEmpty) ...[
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: material.Image.network(
                                        hzImageUrl,
                                        width: 120,
                                        height: 120,
                                        fit: BoxFit.contain,
                                        errorBuilder:
                                            (context, error, stackTrace) {
                                          return Container(
                                            width: 120,
                                            height: 120,
                                            decoration: BoxDecoration(
                                              color: Theme.of(
                                                context,
                                              ).dividerColor,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Icon(
                                              Icons.image_not_supported,
                                              size: 40,
                                              color: Theme.of(
                                                context,
                                              ).iconTheme.color,
                                            ),
                                          );
                                        },
                                        loadingBuilder:
                                            (context, child, loadingProgress) {
                                          if (loadingProgress == null) {
                                            return child;
                                          }
                                          return Container(
                                            width: 120,
                                            height: 120,
                                            decoration: BoxDecoration(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.surface,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: const Center(
                                              child:
                                                  CircularProgressIndicator(),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                  // 显示详细解释
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: _parseMarkdown(hzDefinition),
                                    ),
                                  ),
                                ] else ...[
                                  // 翻译方向切换按钮
                                  if (currentDataSource == 'youdao') ...[
                                    // 有道词典支持中文
                                    Wrap(
                                      spacing: 8,
                                      children: [
                                        if (isSourceChinese) ...[
                                          ChoiceChip(
                                            label: const Text('中→英'),
                                            selected: currentTo == 'en',
                                            onSelected: (selected) {
                                              if (selected) {
                                                fetchDictionary(
                                                  'youdao',
                                                  'zh-CHS',
                                                  'en',
                                                );
                                              }
                                            },
                                          ),
                                          ChoiceChip(
                                            label: const Text('中→中'),
                                            selected: currentTo == 'zh-CHS',
                                            onSelected: (selected) {
                                              if (selected) {
                                                fetchDictionary(
                                                  'youdao',
                                                  'zh-CHS',
                                                  'zh-CHS',
                                                );
                                              }
                                            },
                                          ),
                                        ] else ...[
                                          ChoiceChip(
                                            label: const Text('英→中'),
                                            selected: currentTo == 'zh-CHS',
                                            onSelected: (selected) {
                                              if (selected) {
                                                saveDictionaryTargetLanguage(
                                                  'zh-CHS',
                                                );
                                                fetchDictionary(
                                                  'youdao',
                                                  'en',
                                                  'zh-CHS',
                                                );
                                              }
                                            },
                                          ),
                                          ChoiceChip(
                                            label: const Text('英→英'),
                                            selected: currentTo == 'en',
                                            onSelected: (selected) {
                                              if (selected) {
                                                saveDictionaryTargetLanguage(
                                                  'en',
                                                );
                                                fetchDictionary(
                                                  'youdao',
                                                  'en',
                                                  'en',
                                                );
                                              }
                                            },
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                  ] else if (currentDataSource == 'free') ...[
                                    // Free Dictionary 支持英文翻译方向
                                    Wrap(
                                      spacing: 8,
                                      children: [
                                        ChoiceChip(
                                          label: const Text('英→中'),
                                          selected: currentTo == 'zh-CHS',
                                          onSelected: (selected) {
                                            if (selected) {
                                              saveDictionaryTargetLanguage(
                                                'zh-CHS',
                                              );
                                              fetchDictionary(
                                                'free',
                                                'en',
                                                'zh-CHS',
                                              );
                                            }
                                          },
                                        ),
                                        ChoiceChip(
                                          label: const Text('英→英'),
                                          selected: currentTo == 'en',
                                          onSelected: (selected) {
                                            if (selected) {
                                              saveDictionaryTargetLanguage(
                                                'en',
                                              );
                                              fetchDictionary(
                                                'free',
                                                'en',
                                                'en',
                                              );
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                  if (formInfo?.isNotEmpty == true) ...[
                                    Text(
                                      formInfo!,
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.orange[700],
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                  ],
                                  if (translation?.isNotEmpty == true) ...[
                                    Text(
                                      '翻译',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      translation!,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(fontSize: 12),
                                    ),
                                    const SizedBox(height: 16),
                                  ],
                                  if (explainsText.isNotEmpty) ...[
                                    Text(
                                      '基本释义',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      explainsText,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(fontSize: 12),
                                    ),
                                    const SizedBox(height: 16),
                                  ],
                                  if (webTranslationsText.isNotEmpty) ...[
                                    Text(
                                      '网络释义',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      webTranslationsText,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(fontSize: 12),
                                    ),
                                    const SizedBox(height: 16),
                                  ],
                                ],
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 解析 Markdown 格式的文本
  static List<Widget> _parseMarkdown(String text) {
    final List<Widget> widgets = [];
    final lines = text.split('\n');

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('##')) {
        widgets.add(
          Text(
            line.substring(2).trim(),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
        widgets.add(const SizedBox(height: 8));
      } else if (line.startsWith('#')) {
        widgets.add(
          Text(
            line.substring(1).trim(),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
        widgets.add(const SizedBox(height: 8));
      } else if (line.startsWith('- ') || line.startsWith('* ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Text(
              line.substring(2),
              style: const TextStyle(fontSize: 14),
            ),
          ),
        );
        widgets.add(const SizedBox(height: 4));
      } else {
        widgets.add(
          Text(
            line,
            style: const TextStyle(fontSize: 14),
          ),
        );
        widgets.add(const SizedBox(height: 8));
      }
    }

    return widgets;
  }
}
