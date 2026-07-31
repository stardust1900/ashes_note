import 'package:flutter_test/flutter_test.dart';
import 'package:ashes_note/entity/entities_notebook.dart';
import 'package:ashes_note/models/notes/note_index_models.dart';
import 'package:ashes_note/services/notes/note_link_index.dart';

Note makeNote(String notebook, String title, String content) {
  final t = title.endsWith('.md') ? title : '$title.md';
  return Note(
    id: '$notebook/$t',
    title: t,
    content: content,
    lastModified: DateTime(2026, 1, 1),
    notebookName: notebook,
  );
}

Notebook makeNotebook(String name, List<Note> notes) =>
    Notebook(name: name, notes: notes);

void main() {
  group('resolve - 解析优先级', () {
    late NoteLinkIndex index;

    setUp(() {
      index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('读书', [
            makeNote('读书', '卡片法', ''),
            makeNote('读书', '独有', ''),
          ]),
          makeNotebook('工作', [makeNote('工作', '卡片法', '')]),
        ]);
    });

    test('带笔记本前缀精确命中', () {
      final r = index.resolve('工作/卡片法');
      expect(r, isA<LinkResolved>());
      expect((r as LinkResolved).target.id, '工作/卡片法.md');
    });

    test('前缀大小写不敏感', () {
      expect(index.resolve('读书/卡片法.MD'), isA<LinkResolved>());
    });

    test('全局唯一标题直接命中', () {
      final r = index.resolve('独有');
      expect((r as LinkResolved).target.id, '读书/独有.md');
    });

    test('重名时当前笔记本优先', () {
      final r = index.resolve('卡片法', currentNotebook: '工作');
      expect((r as LinkResolved).target.id, '工作/卡片法.md');
    });

    test('重名且无当前笔记本时返回 ambiguous', () {
      final r = index.resolve('卡片法');
      expect(r, isA<LinkAmbiguous>());
      expect((r as LinkAmbiguous).candidates, hasLength(2));
    });

    test('重名但当前笔记本无同名时仍为 ambiguous', () {
      expect(index.resolve('卡片法', currentNotebook: '其他'), isA<LinkAmbiguous>());
    });

    test('不存在的目标返回 missing', () {
      final r = index.resolve('不存在');
      expect(r, isA<LinkMissing>());
      expect((r as LinkMissing).rawTarget, '不存在');
    });

    test('指定了不存在笔记本的目标返回 missing 并保留该笔记本', () {
      final r = index.resolve('新本/新篇') as LinkMissing;
      expect(r.suggestedNotebook, '新本');
      expect(r.suggestedTitle, '新篇');
    });

    test('空目标返回 missing', () {
      expect(index.resolve('  '), isA<LinkMissing>());
    });

    test('missing 时 preferredNotebook 用于建议创建位置', () {
      final r = index.resolve('新篇', currentNotebook: '读书') as LinkMissing;
      expect(r.suggestedNotebook, '读书');
    });
  });

  group('反向链接', () {
    test('单向引用产生一条反链', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '引用 [[B]]'),
            makeNote('nb', 'B', ''),
          ]),
        ]);

      final backlinks = index.backlinksOf('nb/B.md');
      expect(backlinks, hasLength(1));
      expect(backlinks.first.sourceRef.id, 'nb/A.md');
      expect(backlinks.first.snippet, contains('B'));
    });

    test('同一来源多次引用合并为一条并记录次数', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '[[B]] 又 [[B]] 再 [[B]]'),
            makeNote('nb', 'B', ''),
          ]),
        ]);

      final backlinks = index.backlinksOf('nb/B.md');
      expect(backlinks, hasLength(1));
      expect(backlinks.first.matchCount, 3);
    });

    test('双向互引各自都有反链', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '[[B]]'),
            makeNote('nb', 'B', '[[A]]'),
          ]),
        ]);

      expect(index.backlinksOf('nb/A.md'), hasLength(1));
      expect(index.backlinksOf('nb/B.md'), hasLength(1));
    });

    test('无人引用时反链为空', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [makeNote('nb', 'A', '')]),
        ]);
      expect(index.backlinksOf('nb/A.md'), isEmpty);
    });

    test('代码块内的引用不产生反链', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '```\n[[B]]\n```'),
            makeNote('nb', 'B', ''),
          ]),
        ]);
      expect(index.backlinksOf('nb/B.md'), isEmpty);
    });

    test('歧义链接对所有候选都记反链', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('x', [makeNote('x', 'Src', '[[同名]]')]),
          makeNotebook('a', [makeNote('a', '同名', '')]),
          makeNotebook('b', [makeNote('b', '同名', '')]),
        ]);

      expect(index.backlinksOf('a/同名.md'), hasLength(1));
      expect(index.backlinksOf('b/同名.md'), hasLength(1));
    });
  });

  group('出链与未解析', () {
    test('出链数量与解析状态正确', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '[[B]] 和 [[不存在]]'),
            makeNote('nb', 'B', ''),
          ]),
        ]);

      expect(index.outlinksOf('nb/A.md'), hasLength(2));
      final unresolved = index.unresolvedOf('nb/A.md');
      expect(unresolved, hasLength(1));
      expect(unresolved.first.match.target, '不存在');
    });

    test('无链接的笔记出链为空', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [makeNote('nb', 'A', '纯文本')]),
        ]);
      expect(index.outlinksOf('nb/A.md'), isEmpty);
    });
  });

  group('增量更新 updateNote', () {
    test('新增链接后反链立即可见', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', ''),
            makeNote('nb', 'B', ''),
          ]),
        ]);
      expect(index.backlinksOf('nb/B.md'), isEmpty);

      index.updateNote(makeNote('nb', 'A', '现在引用 [[B]]'));
      expect(index.backlinksOf('nb/B.md'), hasLength(1));
    });

    test('移除链接后反链同步消失，不留残影', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '[[B]]'),
            makeNote('nb', 'B', ''),
          ]),
        ]);
      expect(index.backlinksOf('nb/B.md'), hasLength(1));

      index.updateNote(makeNote('nb', 'A', '不再引用了'));
      expect(index.backlinksOf('nb/B.md'), isEmpty);
      expect(index.outlinksOf('nb/A.md'), isEmpty);
    });

    test('反复更新不产生重复反链', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '[[B]]'),
            makeNote('nb', 'B', ''),
          ]),
        ]);

      for (var i = 0; i < 5; i++) {
        index.updateNote(makeNote('nb', 'A', '[[B]]'));
      }
      expect(index.backlinksOf('nb/B.md'), hasLength(1));
    });

    test('新建笔记会让此前未解析的链接自动生效', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [makeNote('nb', 'A', '[[稍后创建]]')]),
        ]);
      expect(index.unresolvedOf('nb/A.md'), hasLength(1));

      index.updateNote(makeNote('nb', '稍后创建', ''));

      expect(index.unresolvedOf('nb/A.md'), isEmpty);
      expect(index.backlinksOf('nb/稍后创建.md'), hasLength(1));
    });

    test('带笔记本前缀的未解析链接在目标创建后生效', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [makeNote('nb', 'A', '[[其他/目标]]')]),
        ]);
      expect(index.unresolvedOf('nb/A.md'), hasLength(1));

      index.updateNote(makeNote('其他', '目标', ''), notebookName: '其他');
      expect(index.unresolvedOf('nb/A.md'), isEmpty);
    });
  });

  group('删除 removeNote', () {
    test('删除目标后来源链接降级为未解析', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '[[B]]'),
            makeNote('nb', 'B', ''),
          ]),
        ]);

      index.removeNote('nb/B.md');

      expect(index.contains('nb/B.md'), isFalse);
      expect(index.backlinksOf('nb/B.md'), isEmpty);
      expect(index.unresolvedOf('nb/A.md'), hasLength(1));
    });

    test('删除来源后目标反链消失', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '[[B]]'),
            makeNote('nb', 'B', ''),
          ]),
        ]);

      index.removeNote('nb/A.md');
      expect(index.backlinksOf('nb/B.md'), isEmpty);
    });

    test('删除不存在的笔记安全无副作用', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [makeNote('nb', 'A', '')]),
        ]);
      index.removeNote('nb/不存在.md');
      expect(index.noteCount, 1);
    });

    test('删除整个笔记本清空其下所有笔记', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('删我', [
            makeNote('删我', 'A', ''),
            makeNote('删我', 'B', ''),
          ]),
          makeNotebook('留着', [makeNote('留着', 'C', '')]),
        ]);

      index.removeNotebook('删我');

      expect(index.noteCount, 1);
      expect(index.contains('留着/C.md'), isTrue);
    });
  });

  group('改名 renameNote', () {
    test('改名后新 id 生效、旧 id 失效', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [makeNote('nb', '旧名', '内容')]),
        ]);

      index.renameNote('nb/旧名.md', makeNote('nb', '新名', '内容'));

      expect(index.contains('nb/旧名.md'), isFalse);
      expect(index.contains('nb/新名.md'), isTrue);
    });

    test('改名后指向旧标题的链接变为未解析', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '[[旧名]]'),
            makeNote('nb', '旧名', ''),
          ]),
        ]);

      index.renameNote('nb/旧名.md', makeNote('nb', '新名', ''));

      expect(index.unresolvedOf('nb/A.md'), hasLength(1));
      expect(index.backlinksOf('nb/新名.md'), isEmpty);
    });

    test('改名为此前被引用的名字会自动接上反链', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '[[期待的名字]]'),
            makeNote('nb', '旧名', ''),
          ]),
        ]);

      index.renameNote('nb/旧名.md', makeNote('nb', '期待的名字', ''));

      expect(index.unresolvedOf('nb/A.md'), isEmpty);
      expect(index.backlinksOf('nb/期待的名字.md'), hasLength(1));
    });

    test('改名后自身出链被保留', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', '旧名', '[[目标]]'),
            makeNote('nb', '目标', ''),
          ]),
        ]);

      index.renameNote('nb/旧名.md', makeNote('nb', '新名', '[[目标]]'));

      expect(index.outlinksOf('nb/新名.md'), hasLength(1));
      expect(index.backlinksOf('nb/目标.md').first.sourceRef.id, 'nb/新名.md');
    });
  });

  group('searchTitles 补全候选', () {
    late NoteLinkIndex index;

    setUp(() {
      index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('读书', [
            makeNote('读书', '卡片法', ''),
            makeNote('读书', '卡片盒', ''),
          ]),
          makeNotebook('工作', [makeNote('工作', '周报', '')]),
        ]);
    });

    test('空查询返回全部', () {
      expect(index.searchTitles(''), hasLength(3));
    });

    test('子串匹配', () {
      expect(index.searchTitles('卡片'), hasLength(2));
    });

    test('可按笔记本路径匹配', () {
      expect(index.searchTitles('工作/'), hasLength(1));
    });

    test('当前笔记本的候选排在前面', () {
      final r = index.searchTitles('', currentNotebook: '工作');
      expect(r.first.notebookName, '工作');
    });

    test('limit 生效', () {
      expect(index.searchTitles('', limit: 2), hasLength(2));
    });

    test('无匹配返回空', () {
      expect(index.searchTitles('完全不存在的'), isEmpty);
    });
  });

  group('buildGraph 图谱', () {
    test('节点与边数量正确', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '[[B]]'),
            makeNote('nb', 'B', '[[C]]'),
            makeNote('nb', 'C', ''),
          ]),
        ]);

      final g = index.buildGraph();
      expect(g.nodes, hasLength(3));
      expect(g.edges, hasLength(2));
    });

    test('入度出度统计正确', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '[[C]]'),
            makeNote('nb', 'B', '[[C]]'),
            makeNote('nb', 'C', ''),
          ]),
        ]);

      final c = index.buildGraph().nodes.firstWhere((n) => n.id == 'nb/C.md');
      expect(c.inDegree, 2);
      expect(c.outDegree, 0);
    });

    test('未解析链接不产生边', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [makeNote('nb', 'A', '[[不存在]]')]),
        ]);
      expect(index.buildGraph().edges, isEmpty);
    });

    test('自引用不产生边', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [makeNote('nb', 'A', '[[A]]')]),
        ]);
      expect(index.buildGraph().edges, isEmpty);
    });

    test('重复引用只产生一条边', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '[[B]] [[B]] [[B]]'),
            makeNote('nb', 'B', ''),
          ]),
        ]);
      expect(index.buildGraph().edges, hasLength(1));
    });

    test('可过滤孤立节点', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '[[B]]'),
            makeNote('nb', 'B', ''),
            makeNote('nb', '孤岛', ''),
          ]),
        ]);

      final g = index.buildGraph(includeIsolated: false);
      expect(g.nodes.map((n) => n.id), isNot(contains('nb/孤岛.md')));
      expect(g.nodes, hasLength(2));
    });

    test('邻域模式只取指定深度', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '[[B]]'),
            makeNote('nb', 'B', '[[C]]'),
            makeNote('nb', 'C', '[[D]]'),
            makeNote('nb', 'D', ''),
          ]),
        ]);

      final g = index.buildGraph(focusId: 'nb/A.md', depth: 1);
      expect(g.nodes.map((n) => n.id), containsAll(['nb/A.md', 'nb/B.md']));
      expect(g.nodes, hasLength(2));
    });

    test('邻域深度 2 覆盖更远节点', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [
            makeNote('nb', 'A', '[[B]]'),
            makeNote('nb', 'B', '[[C]]'),
            makeNote('nb', 'C', ''),
          ]),
        ]);

      final g = index.buildGraph(focusId: 'nb/A.md', depth: 2);
      expect(g.nodes, hasLength(3));
    });

    test('标签信息被带入节点', () {
      final index = NoteLinkIndex()
        ..buildAll([
          makeNotebook('nb', [makeNote('nb', 'A', '')]),
        ]);

      final g = index.buildGraph(tagsByNote: {'nb/A.md': ['读书']});
      expect(g.nodes.first.tags, ['读书']);
    });

    test('空索引返回空图', () {
      expect(NoteLinkIndex().buildGraph().nodes, isEmpty);
    });
  });

  group('buildAll 幂等性', () {
    test('重复构建结果一致', () {
      final notebooks = [
        makeNotebook('nb', [
          makeNote('nb', 'A', '[[B]]'),
          makeNote('nb', 'B', ''),
        ]),
      ];

      final index = NoteLinkIndex()..buildAll(notebooks);
      final first = index.backlinksOf('nb/B.md').length;
      index.buildAll(notebooks);

      expect(index.backlinksOf('nb/B.md'), hasLength(first));
      expect(index.noteCount, 2);
    });
  });
}
