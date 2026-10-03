import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/platform/clipboard_links.dart';
import 'lanzou_folder_support.dart';
import 'lanzou_support.dart';

void main() {
  // MoePal 0x515204 + 0x387344: a matching Lanzou host and at least
  // one nonempty path segment, without an i/b prefix requirement.
  for (final entry in {
    'tools': 'tools',
    'tp/tools': 'tools',
    'release-2026': 'release-2026',
    '资料合集': '资料合集',
    '密码工具': '密码工具',
    '密码1234': '密码1234',
    'tp/密码1234': '密码1234',
    '%E8%B5%84%E6%96%99': '资料',
  }.entries) {
    final path = entry.key;
    test(
      'Custom Lanzou path is recognized across input and clipboard: $path',
      () {
        final text = '分享：https://author.lanzouj.com/$path?pwd=LongCode1234';
        final link = LinkParser.parse(text).single;
        expect(link.kind, LinkKind.cloudShare);
        expect(link.platform, CloudPlatform.lanzou);
        expect(link.shareId, entry.value);
        expect(link.passcode, 'LongCode1234');
        final suggestion = ClipboardLinkSuggestion.fromText(text)!;
        expect(suggestion.links.single.url, link.url);
        expect(suggestion.links.single.passcode, link.passcode);
        expect(ParsedLink.fromJson(link.toJson()).shareId, link.shareId);
      },
    );
  }

  test('Custom Lanzou names keep adjacent code labels separate', () {
    for (final label in [
      '提取码：LongCode1234',
      '提取码LongCode1234',
      '访问码是LongCode1234',
      '密码 LongCode1234',
      '口令为（LongCode1234）',
    ]) {
      final link = LinkParser.parse('author.lansox.net/tools$label').single;
      expect(link.url, 'https://author.lansox.net/tools');
      expect(link.shareId, 'tools');
      expect(link.passcode, 'LongCode1234');
    }
    expect(
      LinkParser.parse('https://author.lansox.net/').single.isCloudShare,
      isFalse,
    );
    expect(
      LinkParser.parse('https://lansox.net.evil.test/tools').single.platform,
      isNull,
    );
  });

  for (final path in ['tools', 'tp/tools', 'bCustomName']) {
    test(
      'Custom Lanzou file resolves once and reaches its download: $path',
      () async {
        final fixture = LanzouFixture();
        final link = LinkParser.parse(
          'https://author.lanzouu.com/$path',
        ).single;
        final session = await fixture.connector.openShare(link, null);
        expect(session.rootId, '0');
        final file = (await fixture.connector.list(
          session,
          session.rootId,
          null,
        )).single;
        expect(file.id, link.shareId);
        expect(
          (await fixture.connector.download(session, file, null)).url,
          lanzouTestFinal,
        );
        expect(
          fixture.http.calls.where(
            (r) => r.method == 'GET' && r.uri.path == '/$path',
          ),
          hasLength(1),
        );
      },
    );
  }

  test(
    'Custom folder keeps its complete path through children, refresh and download',
    () async {
      final fixture = LanzouFolderFixture();
      const url = 'https://author.lanzouu.com/tp/tools';
      const child = 'https://author.lanzouu.com/tp/archive';
      fixture.folders['/tp/tools'] = lanzouFolderPage(
        password: true,
        children:
            '<div class="mbxfolder"><a href="$child"><div class="filename">Archive</div></a></div>',
      );
      fixture.folders['/tp/archive'] = lanzouFolderPage(fid: '322');
      final session = await fixture.connector.openShare(
        LinkParser.parse('$url 提取码：LongCode1234').single,
        null,
      );
      expect(session.rootId, url);
      final files = await fixture.connector.list(session, session.rootId, null);
      expect(files.singleWhere((f) => f.isDirectory).id, child);
      final nested = (await fixture.connector.list(
        session,
        child,
        null,
      )).single;
      expect(
        (await fixture.connector.download(session, nested, null)).url,
        lanzouTestFinal,
      );
      await fixture.connector.list(session, session.rootId, null);
      expect(
        fixture.http.calls.where(
          (r) => r.method == 'GET' && r.uri.path == '/tp/tools',
        ),
        hasLength(2),
      );
      for (final request in fixture.http.calls.where(
        (r) => r.uri.path == '/filemoreajax.php',
      )) {
        expect(
          Uri.splitQueryString(request.body as String)['pwd'],
          'LongCode1234',
        );
      }
    },
  );

  test(
    'Custom folder page cannot expose a previous listing after refresh fails',
    () async {
      final fixture = LanzouFolderFixture();
      const url = 'https://author.lanzouu.com/tools';
      fixture.folders['/tools'] = lanzouFolderPage();
      final link = LinkParser.parse(url).single;
      final session = await fixture.connector.openShare(link, null);
      await fixture.connector.list(session, session.rootId, null);
      fixture.folderOverride = (r) =>
          r.uri.path == '/tools' ? const HttpResult(503, '') : null;
      await expectLater(
        fixture.connector.openShare(link, null),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        fixture.connector.list(session, session.rootId, null),
        throwsA(isA<AppException>()),
      );
    },
  );
}
