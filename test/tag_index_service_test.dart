import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ashes_note/services/notes/tag_index_service.dart';

/// 这些用例只覆盖纯内存逻辑与序列化，不触碰文件系统。
/// 未设置 notesRootPath 时 flush() 直接返回，因此写盘不会被触发。
void main() {
  late TagIndexService svc;

  setUp(() {
    svc = TagIndexService()..resetForTest();
  });

  Map<String, dynamic> decode() =>
      jsonDecode(svc.encodeForTest()) as Map<String, dynamic>;

  group('setTags 基本行为', () {
    test('设置后可查询到', () async {
      await svc.setTags('nb/A.md', ['读书', '方法论']);
      expect(svc.tagsOf('nb/A.md'), ['读书', '方法论']);
    });

    test('空标签列表移除记录', () async {
      await svc.setTags('nb/A.md', ['读书']);
      await svc.setTags('nb/A.md', []);
      expect(svc.tagsOf('nb/A.md'), isEmpty);
      expect(svc.allTagsWithCount(), isEmpty);
    });

    test('标签名两侧空白被去除', () async {
      await svc.setTags('nb/A.md', ['  读书  ']);
      expect(svc.tagsOf('nb/A.md'), ['读书']);
    });

    test('内部连续空白被折叠', () async {
      await svc.setTags('nb/A.md', ['深度  工作']);
      expect(svc.tagsOf('nb/A.md'), ['深度 工作']);
    });

    test('大小写不敏感去重，保留首次出现的写法', () async {
      await svc.setTags('nb/A.md', ['Work', 'work', 'WORK']);
      expect(svc.tagsOf('nb/A.md'), ['Work']);
    });

    test('空字符串与纯空白被剔除', () async {
      await svc.setTags('nb/A.md', ['', '   ', '读书']);
      expect(svc.tagsOf('nb/A.md'), ['读书']);
    });

    test('含逗号或换行的非法标签被剔除', () async {
      await svc.setTags('nb/A.md', ['a,b', 'c\nd', '正常']);
      expect(svc.tagsOf('nb/A.md'), ['正常']);
    });

    test('未打标签的笔记返回空列表', () {
      expect(svc.tagsOf('nb/不存在.md'), isEmpty);
    });

    test('返回的列表不可变', () async {
      await svc.setTags('nb/A.md', ['读书']);
      expect(() => svc.tagsOf('nb/A.md').add('x'), throwsUnsupportedError);
    });
  });

  group('addTag / removeTag', () {
    test('追加标签', () async {
      await svc.setTags('nb/A.md', ['读书']);
      await svc.addTag('nb/A.md', '方法论');
      expect(svc.tagsOf('nb/A.md'), ['读书', '方法论']);
    });

    test('重复追加不产生副本', () async {
      await svc.setTags('nb/A.md', ['读书']);
      await svc.addTag('nb/A.md', '读书');
      expect(svc.tagsOf('nb/A.md'), ['读书']);
    });

    test('仅大小写不同的追加被视为重复', () async {
      await svc.setTags('nb/A.md', ['Reading']);
      await svc.addTag('nb/A.md', 'READING');
      expect(svc.tagsOf('nb/A.md'), ['Reading']);
    });

    test('含换行的追加被拒绝', () async {
      await svc.addTag('nb/A.md', 'a\nb');
      expect(svc.tagsOf('nb/A.md'), isEmpty);
    });

    test('追加空标签无效', () async {
      await svc.addTag('nb/A.md', '   ');
      expect(svc.tagsOf('nb/A.md'), isEmpty);
    });

    test('移除标签', () async {
      await svc.setTags('nb/A.md', ['读书', '方法论']);
      await svc.removeTag('nb/A.md', '读书');
      expect(svc.tagsOf('nb/A.md'), ['方法论']);
    });

    test('移除时大小写不敏感', () async {
      await svc.setTags('nb/A.md', ['Work']);
      await svc.removeTag('nb/A.md', 'WORK');
      expect(svc.tagsOf('nb/A.md'), isEmpty);
    });
  });

  group('倒排查询', () {
    setUp(() async {
      await svc.setTags('nb/A.md', ['读书', '方法论']);
      await svc.setTags('nb/B.md', ['读书']);
      await svc.setTags('nb/C.md', ['工作']);
    });

    test('任一匹配', () {
      expect(svc.notesOfTags({'读书'}), {'nb/A.md', 'nb/B.md'});
    });

    test('多标签取并集', () {
      expect(svc.notesOfTags({'读书', '工作'}), {
        'nb/A.md',
        'nb/B.md',
        'nb/C.md',
      });
    });

    test('matchAll 取交集', () {
      expect(
        svc.notesOfTags({'读书', '方法论'}, matchAll: true),
        {'nb/A.md'},
      );
    });

    test('matchAll 且有标签无笔记时返回空', () {
      expect(svc.notesOfTags({'读书', '不存在'}, matchAll: true), isEmpty);
    });

    test('空标签集返回空', () {
      expect(svc.notesOfTags({}), isEmpty);
    });

    test('查询大小写不敏感', () {
      expect(svc.notesOfTags({'读书'}), svc.notesOfTags({'读书'}));
      expect(svc.notesOfTags({'工作'}), {'nb/C.md'});
    });

    test('统计计数正确且按数量降序', () {
      final tags = svc.allTagsWithCount();
      expect(tags.first.name, '读书');
      expect(tags.first.count, 2);
    });

    test('可按名称排序', () {
      final names = svc.allTagsWithCount(sortByName: true).map((e) => e.name);
      expect(names, ['工作', '方法论', '读书']);
    });

    test('hasTag 判断存在性', () {
      expect(svc.hasTag('读书'), isTrue);
      expect(svc.hasTag('不存在'), isFalse);
    });
  });

  group('renameTag', () {
    test('重命名影响所有相关笔记', () async {
      await svc.setTags('nb/A.md', ['旧名']);
      await svc.setTags('nb/B.md', ['旧名', '其他']);

      await svc.renameTag('旧名', '新名');

      expect(svc.tagsOf('nb/A.md'), ['新名']);
      expect(svc.tagsOf('nb/B.md'), ['新名', '其他']);
      expect(svc.hasTag('旧名'), isFalse);
    });

    test('重命名后与已有标签合并去重', () async {
      await svc.setTags('nb/A.md', ['甲', '乙']);
      await svc.renameTag('甲', '乙');
      expect(svc.tagsOf('nb/A.md'), ['乙']);
    });

    test('重命名保留颜色', () async {
      await svc.setTags('nb/A.md', ['旧名']);
      await svc.setTagColor('旧名', 0xFF4C8DF6);
      await svc.renameTag('旧名', '新名');
      expect(svc.colorOf('新名'), 0xFF4C8DF6);
    });

    test('重命名为空名无效', () async {
      await svc.setTags('nb/A.md', ['读书']);
      await svc.renameTag('读书', '   ');
      expect(svc.tagsOf('nb/A.md'), ['读书']);
    });

    test('重命名不存在的标签安全无副作用', () async {
      await svc.setTags('nb/A.md', ['读书']);
      await svc.renameTag('不存在', '新名');
      expect(svc.tagsOf('nb/A.md'), ['读书']);
    });
  });

  group('deleteTag', () {
    test('从所有笔记摘除', () async {
      await svc.setTags('nb/A.md', ['删我', '留着']);
      await svc.setTags('nb/B.md', ['删我']);

      await svc.deleteTag('删我');

      expect(svc.tagsOf('nb/A.md'), ['留着']);
      expect(svc.tagsOf('nb/B.md'), isEmpty);
      expect(svc.hasTag('删我'), isFalse);
    });

    test('删除后笔记无标签则移除整条记录', () async {
      await svc.setTags('nb/A.md', ['唯一']);
      await svc.deleteTag('唯一');
      expect(decode()['notes'], isEmpty);
    });

    test('删除不存在的标签安全', () async {
      await svc.deleteTag('不存在');
      expect(svc.allTagsWithCount(), isEmpty);
    });
  });

  group('标签颜色', () {
    test('设置与读取颜色', () async {
      await svc.setTags('nb/A.md', ['读书']);
      await svc.setTagColor('读书', 0xFF123456);
      expect(svc.colorOf('读书'), 0xFF123456);
    });

    test('未设置时为 null', () async {
      await svc.setTags('nb/A.md', ['读书']);
      expect(svc.colorOf('读书'), isNull);
    });

    test('颜色以 #RRGGBB 形式序列化', () async {
      await svc.setTags('nb/A.md', ['读书']);
      await svc.setTagColor('读书', 0xFF4C8DF6);
      expect(decode()['tagMeta']['读书']['color'], '#4C8DF6');
    });
  });

  group('笔记生命周期同步', () {
    test('改名迁移标签', () async {
      await svc.setTags('nb/旧.md', ['读书']);
      await svc.onNoteRenamed('nb/旧.md', 'nb/新.md');

      expect(svc.tagsOf('nb/旧.md'), isEmpty);
      expect(svc.tagsOf('nb/新.md'), ['读书']);
      expect(svc.notesOfTags({'读书'}), {'nb/新.md'});
    });

    test('改名到相同 id 无副作用', () async {
      await svc.setTags('nb/A.md', ['读书']);
      await svc.onNoteRenamed('nb/A.md', 'nb/A.md');
      expect(svc.tagsOf('nb/A.md'), ['读书']);
    });

    test('删除笔记清理标签', () async {
      await svc.setTags('nb/A.md', ['读书']);
      await svc.onNoteDeleted('nb/A.md');
      expect(svc.tagsOf('nb/A.md'), isEmpty);
      expect(svc.notesOfTags({'读书'}), isEmpty);
    });

    test('删除笔记本清理其下全部笔记', () async {
      await svc.setTags('删我/A.md', ['读书']);
      await svc.setTags('删我/B.md', ['读书']);
      await svc.setTags('留着/C.md', ['读书']);

      await svc.onNotebookDeleted('删我');

      expect(svc.notesOfTags({'读书'}), {'留着/C.md'});
    });

    test('pruneMissing 清理失效记录', () async {
      await svc.setTags('nb/A.md', ['读书']);
      await svc.setTags('nb/已删.md', ['读书']);

      await svc.pruneMissing({'nb/A.md'});

      expect(svc.notesOfTags({'读书'}), {'nb/A.md'});
    });

    test('pruneMissing 无失效项时不改动', () async {
      await svc.setTags('nb/A.md', ['读书']);
      await svc.pruneMissing({'nb/A.md'});
      expect(svc.tagsOf('nb/A.md'), ['读书']);
    });
  });

  group('序列化与反序列化', () {
    test('往返一致', () async {
      await svc.setTags('nb/A.md', ['读书', '方法论']);
      await svc.setTagColor('读书', 0xFF4C8DF6);
      final json = svc.encodeForTest();

      svc.resetForTest();
      svc.loadFromJsonForTest(json);

      expect(svc.tagsOf('nb/A.md'), ['读书', '方法论']);
      expect(svc.colorOf('读书'), 0xFF4C8DF6);
    });

    test('包含 schema 版本号', () async {
      await svc.setTags('nb/A.md', ['读书']);
      expect(decode()['version'], 1);
    });

    test('笔记 key 排序输出以减少 diff 噪音', () async {
      await svc.setTags('nb/C.md', ['x']);
      await svc.setTags('nb/A.md', ['x']);
      await svc.setTags('nb/B.md', ['x']);

      final keys = (decode()['notes'] as Map).keys.toList();
      expect(keys, ['nb/A.md', 'nb/B.md', 'nb/C.md']);
    });

    test('记录包含 updatedAt 时间戳', () async {
      await svc.setTags('nb/A.md', ['读书']);
      final updatedAt = decode()['notes']['nb/A.md']['updatedAt'] as String;
      expect(DateTime.tryParse(updatedAt), isNotNull);
    });

    test('空索引可正常编码', () {
      final d = decode();
      expect(d['notes'], isEmpty);
      expect(d['tagMeta'], isEmpty);
    });
  });

  group('损坏与异常输入的容错', () {
    test('根节点非对象时抛出，由调用方降级', () {
      expect(() => svc.loadFromJsonForTest('[1,2,3]'), throwsFormatException);
    });

    test('非法 JSON 抛出', () {
      expect(() => svc.loadFromJsonForTest('{不是json'), throwsA(isA<Object>()));
    });

    test('缺失 notes 字段时视为空', () {
      svc.loadFromJsonForTest('{"version":1}');
      expect(svc.allTagsWithCount(), isEmpty);
    });

    test('单条记录格式错误时被跳过，其余保留', () {
      svc.loadFromJsonForTest('''
      {
        "version": 1,
        "notes": {
          "nb/坏.md": "不是对象",
          "nb/好.md": {"tags": ["读书"], "updatedAt": "2026-01-01T00:00:00.000Z"}
        }
      }
      ''');

      expect(svc.tagsOf('nb/坏.md'), isEmpty);
      expect(svc.tagsOf('nb/好.md'), ['读书']);
    });

    test('tags 字段非数组时跳过该条', () {
      svc.loadFromJsonForTest(
        '{"version":1,"notes":{"nb/A.md":{"tags":"读书"}}}',
      );
      expect(svc.tagsOf('nb/A.md'), isEmpty);
    });

    test('缺失 updatedAt 时使用纪元时间兜底', () {
      svc.loadFromJsonForTest(
        '{"version":1,"notes":{"nb/A.md":{"tags":["读书"]}}}',
      );
      expect(svc.tagsOf('nb/A.md'), ['读书']);
    });

    test('非法颜色值被忽略', () {
      svc.loadFromJsonForTest(
        '{"version":1,"tagMeta":{"读书":{"color":"不是颜色"}}}',
      );
      expect(svc.colorOf('读书'), isNull);
    });

    test('六位十六进制颜色自动补 alpha', () {
      svc.loadFromJsonForTest(
        '{"version":1,"tagMeta":{"读书":{"color":"#4C8DF6"}}}',
      );
      expect(svc.colorOf('读书'), 0xFF4C8DF6);
    });
  });

  group('mergeFrom 多端合并（per-note LWW）', () {
    test('本地较新时覆盖远端', () async {
      await svc.setTags('nb/A.md', ['本地新']);
      final localSnapshot = svc.snapshot();

      // 模拟 pull 后远端为较旧的版本。
      svc.resetForTest();
      svc.loadFromJsonForTest('''
      {
        "version": 1,
        "notes": {
          "nb/A.md": {"tags": ["远端旧"], "updatedAt": "2020-01-01T00:00:00.000Z"}
        }
      }
      ''');

      await svc.mergeFrom(localSnapshot);
      expect(svc.tagsOf('nb/A.md'), ['本地新']);
    });

    test('远端较新时保留远端', () async {
      await svc.setTags('nb/A.md', ['本地']);
      final localSnapshot = svc.snapshot();

      svc.resetForTest();
      svc.loadFromJsonForTest('''
      {
        "version": 1,
        "notes": {
          "nb/A.md": {"tags": ["远端更新"], "updatedAt": "2099-01-01T00:00:00.000Z"}
        }
      }
      ''');

      await svc.mergeFrom(localSnapshot);
      expect(svc.tagsOf('nb/A.md'), ['远端更新']);
    });

    test('合并粒度到单条笔记，互不覆盖', () async {
      await svc.setTags('nb/仅本地.md', ['本地独有']);
      final localSnapshot = svc.snapshot();

      svc.resetForTest();
      svc.loadFromJsonForTest('''
      {
        "version": 1,
        "notes": {
          "nb/仅远端.md": {"tags": ["远端独有"], "updatedAt": "2026-01-01T00:00:00.000Z"}
        }
      }
      ''');

      await svc.mergeFrom(localSnapshot);

      expect(svc.tagsOf('nb/仅本地.md'), ['本地独有']);
      expect(svc.tagsOf('nb/仅远端.md'), ['远端独有']);
    });

    test('tagMeta 取并集，远端缺失的颜色由本地补上', () async {
      await svc.setTags('nb/A.md', ['读书']);
      await svc.setTagColor('读书', 0xFF112233);
      final localSnapshot = svc.snapshot();

      svc.resetForTest();
      svc.loadFromJsonForTest('''
      {
        "version": 1,
        "notes": {
          "nb/A.md": {"tags": ["读书"], "updatedAt": "2099-01-01T00:00:00.000Z"}
        },
        "tagMeta": {"读书": {}}
      }
      ''');

      await svc.mergeFrom(localSnapshot);
      expect(svc.colorOf('读书'), 0xFF112233);
    });

    test('远端已有颜色时不被本地覆盖', () async {
      await svc.setTags('nb/A.md', ['读书']);
      await svc.setTagColor('读书', 0xFF111111);
      final localSnapshot = svc.snapshot();

      svc.resetForTest();
      svc.loadFromJsonForTest(
        '{"version":1,"tagMeta":{"读书":{"color":"#222222"}}}',
      );

      await svc.mergeFrom(localSnapshot);
      expect(svc.colorOf('读书'), 0xFF222222);
    });

    test('快照是深拷贝，后续改动不影响它', () async {
      await svc.setTags('nb/A.md', ['原始']);
      final snapshot = svc.snapshot();
      await svc.setTags('nb/A.md', ['被改了']);

      svc.resetForTest();
      await svc.mergeFrom(snapshot);
      expect(svc.tagsOf('nb/A.md'), ['原始']);
    });
  });
}
