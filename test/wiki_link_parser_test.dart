import 'package:flutter_test/flutter_test.dart';
import 'package:ashes_note/models/notes/note_index_models.dart';
import 'package:ashes_note/services/notes/wiki_link_parser.dart';

void main() {
  group('parseLinks - 基本形态', () {
    test('解析纯标题链接', () {
      final links = parseLinks('见 [[卡片法]] 一文。');
      expect(links, hasLength(1));
      expect(links.first.target, '卡片法');
      expect(links.first.alias, isNull);
      expect(links.first.displayText, '卡片法');
    });

    test('解析带笔记本前缀的链接', () {
      final links = parseLinks('参考 [[读书笔记/卡片法]]。');
      expect(links, hasLength(1));
      expect(links.first.target, '读书笔记/卡片法');
      expect(links.first.displayText, '卡片法');
    });

    test('解析带别名的链接', () {
      final links = parseLinks('参考 [[读书笔记/卡片法|这篇]]。');
      expect(links, hasLength(1));
      expect(links.first.target, '读书笔记/卡片法');
      expect(links.first.alias, '这篇');
      expect(links.first.displayText, '这篇');
    });

    test('目标末尾的 .md 在展示时被去掉', () {
      final links = parseLinks('[[读书笔记/卡片法.md]]');
      expect(links.first.displayText, '卡片法');
    });

    test('一行内多个链接都能解析且偏移正确', () {
      const content = '[[A]] 和 [[B]]';
      final links = parseLinks(content);
      expect(links, hasLength(2));
      expect(content.substring(links[0].start, links[0].end), '[[A]]');
      expect(content.substring(links[1].start, links[1].end), '[[B]]');
    });

    test('目标与别名两侧空白被 trim', () {
      final links = parseLinks('[[  卡片法  |  别名  ]]');
      expect(links.first.target, '卡片法');
      expect(links.first.alias, '别名');
    });

    test('空别名回退为标题', () {
      final links = parseLinks('[[卡片法|]]');
      expect(links.first.alias, isNull);
      expect(links.first.displayText, '卡片法');
    });
  });

  group('parseLinks - 边界与非法输入', () {
    test('空目标不产生链接', () {
      expect(parseLinks('[[]]'), isEmpty);
      expect(parseLinks('[[   ]]'), isEmpty);
    });

    test('未闭合的括号不产生链接', () {
      expect(parseLinks('[[未闭合'), isEmpty);
      expect(parseLinks('未闭合]]'), isEmpty);
    });

    test('链接不跨行匹配', () {
      expect(parseLinks('[[前半\n后半]]'), isEmpty);
    });

    test('单层方括号不是 wiki 链接', () {
      expect(parseLinks('[普通链接](http://a.com)'), isEmpty);
    });

    test('无 [[ 的文本快速返回空', () {
      expect(parseLinks('完全没有链接的一段文字'), isEmpty);
    });

    test('空字符串安全', () {
      expect(parseLinks(''), isEmpty);
    });
  });

  group('代码区域保护', () {
    test('围栏代码块内的链接被忽略', () {
      const content = '''
正文 [[有效]]

```dart
// [[无效]]
```

结尾 [[也有效]]
''';
      final links = parseLinks(content);
      expect(links.map((e) => e.target), ['有效', '也有效']);
    });

    test('波浪号围栏同样生效', () {
      const content = '~~~\n[[无效]]\n~~~\n[[有效]]';
      final links = parseLinks(content);
      expect(links.map((e) => e.target), ['有效']);
    });

    test('行内代码内的链接被忽略', () {
      final links = parseLinks('写作 `[[无效]]` 但 [[有效]]');
      expect(links.map((e) => e.target), ['有效']);
    });

    test('缩进代码块内的链接被忽略', () {
      const content = '正文 [[有效]]\n\n    [[无效]]\n';
      final links = parseLinks(content);
      expect(links.map((e) => e.target), ['有效']);
    });

    test('未闭合围栏后的内容全部视为代码', () {
      const content = '[[有效]]\n```\n[[无效]]\n';
      final links = parseLinks(content);
      expect(links.map((e) => e.target), ['有效']);
    });
  });

  group('splitTarget', () {
    test('拆分带笔记本的目标', () {
      final r = splitTarget('读书笔记/卡片法');
      expect(r.notebook, '读书笔记');
      expect(r.title, '卡片法');
    });

    test('无斜杠时笔记本为 null', () {
      final r = splitTarget('卡片法');
      expect(r.notebook, isNull);
      expect(r.title, '卡片法');
    });

    test('多级路径取最后一段为标题', () {
      final r = splitTarget('a/b/c');
      expect(r.notebook, 'a/b');
      expect(r.title, 'c');
    });

    test('斜杠结尾视为无笔记本', () {
      final r = splitTarget('读书笔记/');
      expect(r.notebook, isNull);
    });
  });

  group('URI 构造与反解', () {
    test('存在的链接往返一致', () {
      final uri = buildOpenUri(
        rawTarget: '读书笔记/卡片法',
        notebookName: '读书笔记',
        title: '卡片法.md',
        exists: true,
      );
      final intent = parseOpenUri(uri)!;
      expect(intent.rawTarget, '读书笔记/卡片法');
      expect(intent.notebookName, '读书笔记');
      expect(intent.title, '卡片法.md');
      expect(intent.exists, isTrue);
      expect(intent.noteId, '读书笔记/卡片法.md');
    });

    test('不存在的链接 exists 为 false 且无 noteId', () {
      final uri = buildOpenUri(rawTarget: '还没写', exists: false);
      final intent = parseOpenUri(uri)!;
      expect(intent.exists, isFalse);
      expect(intent.noteId, isNull);
    });

    test('含特殊字符的目标能正确编码往返', () {
      const raw = 'a b/c&d=e?f#g';
      final uri = buildOpenUri(rawTarget: raw, exists: false);
      expect(parseOpenUri(uri)!.rawTarget, raw);
    });

    test('非本应用 scheme 返回 null', () {
      expect(parseOpenUri('https://example.com'), isNull);
    });

    test('无法解析的字符串返回 null', () {
      expect(parseOpenUri('::::'), isNull);
    });
  });

  group('rewriteForPreview', () {
    LinkResolution resolverAllMissing(String t) => LinkMissing(t, null);

    test('无链接时原样返回', () {
      const content = '普通文本';
      expect(rewriteForPreview(content, resolverAllMissing), content);
    });

    test('已存在的链接重写为可点击 Markdown 链接', () {
      String rewritten = rewriteForPreview(
        '见 [[卡片法]]。',
        (t) => LinkResolved(NoteRef.of('读书笔记', t)),
      );
      expect(rewritten, startsWith('见 [卡片法](ashesnote://open?'));
      expect(rewritten, endsWith('。'));
    });

    test('别名作为链接显示文本', () {
      final rewritten = rewriteForPreview(
        '[[卡片法|这篇好文]]',
        (t) => LinkResolved(NoteRef.of('读书笔记', t)),
      );
      expect(rewritten, contains('[这篇好文]('));
    });

    test('代码块内的链接不被重写', () {
      const content = '```\n[[无效]]\n```';
      expect(rewriteForPreview(content, resolverAllMissing), content);
    });

    test('多个链接重写后偏移不错位', () {
      final rewritten = rewriteForPreview(
        'X[[A]]Y[[B]]Z',
        (t) => LinkResolved(NoteRef.of('nb', t)),
      );
      expect(rewritten, startsWith('X[A]('));
      expect(rewritten, contains(')Y[B]('));
      expect(rewritten, endsWith('Z'));
    });

    test('别名中的方括号会使该处不被识别为链接', () {
      // 目标与别名内均不允许出现方括号，避免与 Markdown 语法冲突。
      const content = r'[[目标|带]括号]]';
      expect(parseLinks(content), isEmpty);
      expect(rewriteForPreview(content, resolverAllMissing), content);
    });
  });

  group('detectAutocomplete', () {
    test('刚输入 [[ 时触发，前缀为空', () {
      final ctx = detectAutocomplete('见 [[', 4)!;
      expect(ctx.prefix, '');
      expect(ctx.triggerStart, 2);
      expect(ctx.hasClosing, isFalse);
    });

    test('输入部分前缀后触发', () {
      final ctx = detectAutocomplete('见 [[卡片', 6)!;
      expect(ctx.prefix, '卡片');
    });

    test('已自动补全右括号时 hasClosing 为 true', () {
      final ctx = detectAutocomplete('[[卡片]]', 4)!;
      expect(ctx.prefix, '卡片');
      expect(ctx.hasClosing, isTrue);
    });

    test('光标越过 ]] 之后不触发', () {
      expect(detectAutocomplete('[[卡片]] 后续', 9), isNull);
    });

    test('单个 [ 不触发', () {
      expect(detectAutocomplete('[卡片', 3), isNull);
    });

    test('换行后不触发', () {
      expect(detectAutocomplete('[[卡片\n换行', 7), isNull);
    });

    test('代码块内不触发', () {
      const text = '```\n[[卡片\n```';
      expect(detectAutocomplete(text, 8), isNull);
    });

    test('前缀过长时停止补全', () {
      final text = '[[${'x' * 80}';
      expect(detectAutocomplete(text, text.length), isNull);
    });

    test('光标位置非法时安全返回 null', () {
      expect(detectAutocomplete('[[a', 0), isNull);
      expect(detectAutocomplete('[[a', 999), isNull);
    });
  });

  group('applyAutocomplete', () {
    test('无右括号时插入完整链接', () {
      const text = '见 [[卡';
      final ctx = detectAutocomplete(text, text.length)!;
      final r = applyAutocomplete(text, ctx, NoteRef.of('读书笔记', '卡片法'));
      expect(r.newText, '见 [[读书笔记/卡片法]]');
      expect(r.newCaret, r.newText.length);
    });

    test('已有右括号时不重复添加', () {
      const text = '[[卡]]';
      final ctx = detectAutocomplete(text, 3)!;
      final r = applyAutocomplete(text, ctx, NoteRef.of('nb', '卡片法'));
      expect(r.newText, '[[nb/卡片法]]');
    });

    test('保留插入点后的原有文本', () {
      const text = '[[卡 尾巴';
      final ctx = detectAutocomplete(text, 3)!;
      final r = applyAutocomplete(text, ctx, NoteRef.of('nb', '卡片法'));
      expect(r.newText, '[[nb/卡片法]] 尾巴');
    });

    test('重选链接时整段删除旧链接，不残留新老混排', () {
      // 用户把光标放在已有「[[老链接]]」内部，删掉旧文字输入「新 」后触发补全。
      const text = '[[新 老]] 结尾';
      // 触发点：光标在「新」与空格之间（offset 3，仍处于未闭合 [[ 内）。
      final ctx = detectAutocomplete(text, 3)!;
      final r = applyAutocomplete(text, ctx, NoteRef.of('nb', '新链接'));
      expect(r.newText, '[[nb/新链接]] 结尾');
    });

    test('重选链接且旧链接含多字时整段删除', () {
      const text = '[[新读书笔记/旧标题]] 后文';
      final ctx = detectAutocomplete(text, 4)!;
      final r = applyAutocomplete(text, ctx, NoteRef.of('nb', '新标题'));
      expect(r.newText, '[[nb/新标题]] 后文');
    });
  });

  group('buildInsertion', () {
    test('带笔记本时生成完整路径', () {
      expect(buildInsertion(NoteRef.of('读书', '卡片法')), '[[读书/卡片法]]');
    });

    test('无笔记本时只写标题', () {
      expect(buildInsertion(NoteRef.of('', '卡片法')), '[[卡片法]]');
    });

    test('插入文本不含 .md 后缀', () {
      expect(buildInsertion(NoteRef.of('读书', '卡片法.md')), '[[读书/卡片法]]');
    });
  });

  group('buildSnippet', () {
    test('摘要包含链接文本且高亮区间正确', () {
      const content = '前面的内容 [[卡片法]] 后面的内容';
      final link = parseLinks(content).first;
      final s = buildSnippet(content, link);
      expect(s.snippet, contains('卡片法'));
      expect(
        s.snippet.substring(s.highlightStart, s.highlightStart + s.highlightLength),
        '卡片法',
      );
    });

    test('长文本两侧添加省略号', () {
      final content = '${'甲' * 200}[[卡片法]]${'乙' * 200}';
      final link = parseLinks(content).first;
      final s = buildSnippet(content, link);
      expect(s.snippet, startsWith('…'));
      expect(s.snippet, endsWith('…'));
    });

    test('换行被折叠为空格', () {
      const content = '第一行\n第二行 [[卡片法]]';
      final link = parseLinks(content).first;
      expect(buildSnippet(content, link).snippet, isNot(contains('\n')));
    });
  });

  group('归一化工具', () {
    test('normalizeKey 去后缀并转小写', () {
      expect(normalizeKey('  Card Note.MD '), 'card note');
    });

    test('normalizeKey 折叠内部空白', () {
      expect(normalizeKey('a   b'), 'a b');
    });

    test('ensureMdSuffix 幂等', () {
      expect(ensureMdSuffix('a'), 'a.md');
      expect(ensureMdSuffix('a.md'), 'a.md');
      expect(ensureMdSuffix('a.MD'), 'a.MD');
    });

    test('stripMdSuffix 大小写不敏感', () {
      expect(stripMdSuffix('a.MD'), 'a');
      expect(stripMdSuffix('a'), 'a');
    });

    test('normalizeTagName 保留大小写但折叠空白', () {
      expect(normalizeTagName('  Deep  Work '), 'Deep Work');
    });
  });

  group('NoteRef', () {
    test('fromId 反解笔记本与标题', () {
      final ref = NoteRef.fromId('读书笔记/卡片法.md');
      expect(ref.notebookName, '读书笔记');
      expect(ref.title, '卡片法.md');
      expect(ref.displayTitle, '卡片法');
    });

    test('无斜杠 id 的笔记本为空', () {
      expect(NoteRef.fromId('散记.md').notebookName, '');
    });

    test('of 自动补齐 .md', () {
      expect(NoteRef.of('nb', '标题').id, 'nb/标题.md');
    });

    test('相等性基于 id 与 exists', () {
      expect(NoteRef.of('a', 'b'), NoteRef.of('a', 'b'));
      expect(NoteRef.of('a', 'b'), isNot(NoteRef.of('a', 'b', exists: false)));
    });
  });
}
