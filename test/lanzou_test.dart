import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/lanzou_protocol.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'lanzou_support.dart';

Matcher _fails(String fragment) => throwsA(
  isA<AppException>().having((e) => e.message, 'message', contains(fragment)),
);

void main() {
  group('Anonymous Lanzou links', () {
    for (final host in [
      'lanzou.com',
      'www.lanzous.com',
      'author.lanzoux.com',
      'author.lanzouu.com',
      'sub.author.lanzouq.com',
      'author.lanzouuu.com',
      'author.lanzou123.com',
      'author.lanzou-app-2.net',
      'author.lanzox.org',
      'author.lansou.cn',
      'author.lansox.com',
    ]) {
      test('Recognizes $host with scheme-less prose and its own passcode', () {
        final link = LinkParser.parse('文件：$host/iExample123提取码：Ab12。').single;
        expect(link.platform, CloudPlatform.lanzou);
        expect(link.kind, LinkKind.cloudShare);
        expect(link.shareId, 'iExample123');
        expect(link.url, 'https://$host/iExample123');
        expect(link.passcode, 'Ab12');
      });
    }
    test(
      'Host boundaries and folder URLs cannot turn into HTTP file downloads',
      () {
        for (final host in [
          'lanzouu.com.evil.test',
          'notlanzouu.com',
          'lanzouu.com.cn',
          'lanzouu.co',
          'lanzn.com',
          'lanzoxx.com',
        ]) {
          expect(CloudPlatform.fromHost(host), isNull);
        }
        final folder = LinkParser.parse(
          'https://author.lanzouu.com/bExample123?pwd=Ab12',
        ).single;
        expect(folder.kind, LinkKind.cloudShare);
        expect(folder.passcode, 'Ab12');
      },
    );
    test(
      'All MoePal domain families accept each suffix and case-insensitive hosts',
      () {
        for (final root in [
          'lanzou',
          'lanzouq',
          'lanzou2026',
          'lanzou-app-2',
          'lanzox',
          'lansou',
          'lansox',
        ]) {
          for (final suffix in ['com', 'net', 'org', 'cn']) {
            for (final prefix in ['', 'author.', 'www.author.']) {
              final host = '$prefix$root.$suffix';
              final link = LinkParser.parse(
                'https://${host.toUpperCase()}/bFolder123?pwd=Ab12',
              ).single;
              expect(link.platform, CloudPlatform.lanzou, reason: host);
              expect(link.kind, LinkKind.cloudShare, reason: host);
              expect(link.shareId, 'bFolder123');
              expect(link.url, 'https://$host/bFolder123?pwd=Ab12');
              expect(link.passcode, 'Ab12');
            }
          }
        }
      },
    );
    test(
      'Alias-looking text inside another URL or hostname is never extracted as a share',
      () {
        for (final text in [
          'https://lanzou123.com.evil.test/iExample123',
          'https://notlansou.cn/iExample123',
          'https://example.com/author.lanzou-app-2.net/iExample123',
          'https://author.lansox.org@evil.test/iExample123',
          '文件：notlansou.cn/iExample123',
          '文件：author.lanzou123.com.evil.test/iExample123',
        ]) {
          expect(
            LinkParser.parse(
              text,
            ).where((link) => link.kind == LinkKind.cloudShare),
            isEmpty,
            reason: text,
          );
        }
      },
    );
  });

  test(
    'Current password templates ignore commented signs and empty reassignments',
    () {
      final page = LanzouPage(lanzouTestPasswordPage);
      expect(page.passwordRequired, isTrue);
      expect(page.ajaxUrl, '/ajaxfile.php?file=43');
      expect(page.parameters(passcode: 'p&+'), {
        'action': 'downprocess',
        'sign': 'password-sign',
        'p': 'p&+',
        'kd': '1',
      });
      expect(page.displaySize, 4);
    },
  );
  test(
    'Legacy inline query page uses its actual data and never executes JS',
    () {
      final page = LanzouPage(r'''<script>
/* data:{action:'downprocess',sign:'decoy'} */
$.ajax({url:'/ajaxm.php?file=7', data:{action:'downprocess',sign:'literal\x2bsign',websignkey:'Em2R',websign:2}});
eval('throw new Error("must not execute")');
</script>''');
      expect(page.parameters()['sign'], 'literal+sign');
      expect(page.parameters()['websignkey'], 'Em2R');
      expect(page.parameters()['websign'], '2');
    },
  );
  test(
    'HTML metadata accepts modern/legacy names, entities and rounded sizes',
    () {
      expect(LanzouPage(lanzouTestPage).name, 'Example & 1.zip');
      expect(LanzouPage(lanzouTestPage).displaySize, 1572864);
      final legacy = LanzouPage(
        '''<html><head><meta name="description" content="文件大小：63.8 M"></head><body>
<div style="font-size: 30px;text-align:center">Legacy.exe</div></body></html>''',
      );
      expect(legacy.name, 'Legacy.exe');
      expect(legacy.displaySize, (63.8 * 1024 * 1024).round());
      expect(
        LanzouPage('<script>var filename="Script.zip";</script>').name,
        'Script.zip',
      );
      expect(
        LanzouPage('<div class="b"><span>Mobile.zip</span></div>').name,
        'Mobile.zip',
      );
    },
  );
  test('Known acw cookie transform is bounded to the fixed public format', () {
    expect(lanzouChallengeCookie('var arg1="not-valid";'), isNull);
    final cookie = lanzouChallengeCookie(lanzouTestChallenge);
    expect(cookie, isNotNull);
    expect(cookie, 'd2c7186598ab1a508a4f6064e4fa746323ab17c6');
  });

  group('Lanzou share and download protocol', () {
    test(
      'New domain aliases retain the original host through password parsing and download',
      () async {
        final fixture = LanzouFixture()..page = lanzouTestPasswordPage;
        const url = 'https://author.lanzou-app-2.net/iExample123?pwd=Ab12';
        final session = await fixture.connector.openShare(
          LinkParser.parse(url).single,
          null,
        );
        expect(session.sourceLink!.url, url);
        final post = fixture.http.calls.singleWhere(
          (request) => request.method == 'POST',
        );
        expect(post.uri.host, 'author.lanzou-app-2.net');
        expect(Uri.splitQueryString(post.body as String)['p'], 'Ab12');
        final download = await fixture.download(session);
        expect(download.url, lanzouTestFinal);
        expect(download.headers['Referer'], 'https://author.lanzou-app-2.net/');
        expect(download.headers['Cookie'], isNull);
      },
    );
    test(
      'Share redirects may use another recognized alias without sharing its cookies',
      () async {
        final fixture = LanzouFixture();
        const redirected = 'https://author.lansox.org/iExample123';
        fixture.override = (request) {
          if (request.url == lanzouTestUrl) {
            return const HttpResult(302, '', {
              'location': [redirected],
              'set-cookie': ['origin_only=secret; Path=/; Secure'],
            });
          }
          return null;
        };
        final session = await fixture.open();
        final target = fixture.http.calls.firstWhere(
          (request) => request.url == redirected,
        );
        expect(target.headers['Cookie'], isNull);
        final post = fixture.http.calls.singleWhere(
          (request) => request.method == 'POST',
        );
        expect(post.uri.host, 'author.lansox.org');
        expect(post.headers['Cookie'], isNull);
        final download = await fixture.download(session);
        expect(download.url, lanzouTestFinal);
        expect(download.headers['Referer'], 'https://author.lansox.org/');
      },
    );
    test(
      'Current download-node confirmation posts its fixed button form and follows the returned URL',
      () async {
        const gate = '''<html><script>function down_r(el){
        \$.ajax({url:'ajax.php',data:{'file':'opaque-file','el':el,'sign':'gate-sign'}});
      }</script></html>''';
        final fixture = LanzouFixture();
        fixture.override = (r) {
          if (r.uri.host != 'download.lanzouj.com') return null;
          if (r.uri.path == '/file/ajax.php') {
            expect(r.method, 'POST');
            expect(Uri.splitQueryString(r.body as String), {
              'file': 'opaque-file',
              'sign': 'gate-sign',
              'el': '2',
            });
            return HttpResult(200, encoded({'zt': 1, 'url': lanzouTestFinal}));
          }
          return const HttpResult(200, gate, {
            'content-type': ['text/html'],
          });
        };
        expect(
          (await fixture.download(await fixture.open())).url,
          lanzouTestFinal,
        );
        expect(
          fixture.http.calls.where((r) => r.uri.path == '/file/ajax.php'),
          hasLength(1),
        );
      },
    );
    test(
      'Relative redirects retain signed escapes and query ordering',
      () async {
        final fixture = LanzouFixture();
        fixture.override = (r) {
          if (r.uri.path == '/file/ticket') {
            return const HttpResult(302, '', {
              'location': ['../delivery/data%2fpart?key=a%2bb&key=two'],
            });
          }
          if (r.uri.path.startsWith('/delivery/')) {
            return const HttpResult(200, '', {
              'content-type': ['application/octet-stream'],
              'content-length': ['4'],
            });
          }
          return null;
        };
        expect(
          (await fixture.download(await fixture.open())).url,
          'https://download.lanzouj.com/delivery/data%2fpart?key=a%2bb&key=two',
        );
      },
    );
    test(
      'No credentials or transfer; same-domain page cookies and exact signed final URL',
      () async {
        final fixture = LanzouFixture();
        final session = await fixture.open();
        final files = await fixture.connector.list(
          session,
          '0',
          Credential('ignored', {'primary': 'private-account'}),
        );
        expect(files.single.size, 1572864);
        expect(files.single.name, 'Example & 1.zip');
        expect(fixture.http.calls, hasLength(3));
        final post = fixture.http.calls.last;
        expect(post.uri.host, 'author.lanzouu.com');
        expect(
          post.headers['Referer'],
          contains('/fn?ticket=fixture&version=2'),
        );
        expect(post.headers['Cookie'], contains('share_session=anonymous'));
        expect(Uri.splitQueryString(post.body as String), {
          'action': 'downprocess',
          'sign': 'opaque-sign',
          'signs': 'a&b+=?',
          'websignkey': 'a&b+=?',
          'websign': '',
          'kd': '1',
          'ves': '1',
        });
        final spec = await fixture.download(session);
        expect(spec.url, lanzouTestFinal);
        expect(spec.expectedSize, 1234567); // Never the rounded page size.
        expect(spec.cleanup, isNull);
        expect(spec.headers['Cookie'], isNull);
        expect(spec.headers['Referer'], 'https://author.lanzouu.com/');
        expect(fixture.http.redirects, everyElement(isFalse));
        expect(fixture.http.peeks, isEmpty);
        expect(
          fixture.http.calls
              .where((r) => r.uri.host == 'cdn.example')
              .single
              .method,
          'HEAD',
        );
        expect(
          fixture.http.calls.any(
            (r) => r.headers.toString().contains('private-account'),
          ),
          isFalse,
        );
      },
    );
    test(
      'Password pages also work with query parameters and escaped form input',
      () async {
        final fixture = LanzouFixture()..page = lanzouTestPasswordPage;
        final link = LinkParser.parse(
          '$lanzouTestUrl?source=message',
        ).single.withPasscode('a&+');
        await fixture.connector.openShare(link, null);
        expect(fixture.http.calls.where((r) => r.uri.path == '/fn'), isEmpty);
        expect(
          Uri.splitQueryString(fixture.http.calls.last.body as String)['p'],
          'a&+',
        );
        expect(fixture.http.calls.last.uri.path, '/ajaxfile.php');
      },
    );
    test(
      'Missing passwords, wrong passwords and deleted files fail clearly',
      () async {
        final fixture = LanzouFixture()..page = lanzouTestPasswordPage;
        await expectLater(fixture.open(), _fails('需要提取码'));
        expect(fixture.http.calls.where((r) => r.method == 'POST'), isEmpty);
        fixture.result = {'zt': 0, 'inf': '密码不正确 private-secret'};
        await expectLater(fixture.open('bad'), _fails('提取码错误'));
        fixture.page = '<html><body>文件取消分享了</body></html>';
        await expectLater(fixture.open(), _fails('取消分享'));
      },
    );
    test(
      'Share cookie challenge retries once without changing origin, UA or referer',
      () async {
        final fixture = LanzouFixture();
        var challenged = false;
        fixture.override = (r) {
          if (r.uri.path != '/iExample123' || challenged) return null;
          challenged = true;
          return const HttpResult(200, lanzouTestChallenge);
        };
        await fixture.open();
        final first = fixture.http.calls[0], second = fixture.http.calls[1];
        expect(second.url, first.url);
        expect(second.headers['User-Agent'], first.headers['User-Agent']);
        expect(second.headers['Referer'], first.headers['Referer']);
        expect(second.headers['Cookie'], contains('acw_sc__v2='));
        fixture.override = (_) => const HttpResult(200, lanzouTestChallenge);
        await expectLater(fixture.open(), _fails('进一步验证'));
      },
    );
    test(
      'Cross-origin iframes and forged share redirects are not fetched',
      () async {
        final fixture = LanzouFixture()
          ..page = '<iframe src="https://evil.test/fn"></iframe>';
        await expectLater(fixture.open(), _fails('蓝奏'));
        expect(fixture.http.calls, hasLength(1));
        fixture.override = (_) => const HttpResult(302, '', {
          'location': ['https://evil.test/steal'],
        });
        await expectLater(fixture.open(), _fails('蓝奏'));
        expect(
          fixture.http.calls.any((r) => r.uri.host == 'evil.test'),
          isFalse,
        );
      },
    );
    test(
      'HEAD rejection uses a bounded GET and preserves redirect cookie isolation',
      () async {
        final fixture = LanzouFixture();
        fixture.override = (r) =>
            r.uri.path.startsWith('/file/') && r.method == 'HEAD'
            ? const HttpResult(405, '')
            : null;
        final spec = await fixture.download(await fixture.open());
        expect(spec.url, lanzouTestFinal);
        expect(fixture.http.peeks.single.$2, 8192);
        expect(fixture.http.peeks.single.$3, isFalse);
        final peek = fixture.http.calls.singleWhere(
          (r) => r.uri.path.startsWith('/file/') && r.method == 'GET',
        );
        expect(peek.headers['Range'], 'bytes=0-8191');
        expect(peek.headers['Cookie'], contains('down_ip=1'));
        expect(peek.headers['Cookie'], isNot(contains('share_session')));
      },
    );
    test(
      'Partial GET uses Content-Range total, not the size of the probe',
      () async {
        final fixture = LanzouFixture();
        fixture.override = (r) => r.uri.host != 'cdn.example'
            ? null
            : r.method == 'HEAD'
            ? const HttpResult(403, '')
            : const HttpResult(206, 'bytes', {
                'content-type': ['application/octet-stream'],
                'content-length': ['5'],
                'content-range': ['bytes 0-4/100000'],
              });
        expect(
          (await fixture.download(await fixture.open())).expectedSize,
          100000,
        );
      },
    );
    test(
      'A returned HTML gate never becomes a successful file download',
      () async {
        final fixture = LanzouFixture();
        fixture.override = (r) => r.uri.host == 'cdn.example'
            ? const HttpResult(200, '<html>请完成验证</html>', {
                'content-type': ['text/html'],
              })
            : null;
        await expectLater(
          fixture.download(await fixture.open()),
          _fails('验证页面'),
        );
      },
    );
    test('An actual HTML attachment remains downloadable', () async {
      final fixture = LanzouFixture();
      fixture.override = (r) => r.uri.host == 'cdn.example'
          ? const HttpResult(200, '', {
              'content-type': ['text/html'],
              'content-disposition': ['attachment; filename="page.html"'],
              'content-length': ['123'],
            })
          : null;
      expect((await fixture.download(await fixture.open())).expectedSize, 123);
    });
    test(
      'Canceled parsing stops before posting or caching a successful result',
      () async {
        final fixture = LanzouFixture(), scope = RequestScope();
        fixture.override = (r) {
          if (r.uri.path == '/fn') scope.cancel();
          return null;
        };
        await expectLater(scope.run(fixture.open), _fails('取消'));
        expect(fixture.http.calls.any((r) => r.method == 'POST'), isFalse);
        fixture.override = null;
        expect(
          (await fixture.open()).sourceLink?.platform,
          CloudPlatform.lanzou,
        );
      },
    );
    test(
      'A repeated direct-link expiry refreshes once and cannot loop indefinitely',
      () async {
        final fixture = LanzouFixture();
        fixture.override = (r) =>
            r.uri.host == 'cdn.example' ? const HttpResult(403, '') : null;
        await expectLater(
          fixture.download(await fixture.open()),
          _fails('已失效'),
        );
        expect(
          fixture.http.calls.where((r) => r.method == 'POST'),
          hasLength(2),
        );
      },
    );
    test(
      'Cached parsing expires; final redirect targets are never cached',
      () async {
        final fixture = LanzouFixture(),
            session = await (LanzouFixture()).open();
        await fixture.download(session);
        await fixture.download(session);
        expect(
          fixture.http.calls.where((r) => r.method == 'POST'),
          hasLength(1),
        );
        expect(
          fixture.http.calls.where((r) => r.uri.host == 'cdn.example'),
          hasLength(2),
        );
        fixture.now = fixture.now.add(const Duration(minutes: 16));
        await fixture.download(session);
        expect(
          fixture.http.calls.where((r) => r.method == 'POST'),
          hasLength(2),
        );
      },
    );
    test(
      'Repository download refresh works with no account and persists no anonymous cookies',
      () async {
        final fixture = LanzouFixture(),
            store = StateStore.memory(),
            vault = Vault(StateStore.memory());
        final repo = CloudRepository(
          fixture.http,
          vault,
          CleanupOutbox(store, fixture.http),
        );
        repo.connectors[CloudPlatform.lanzou] = fixture.connector;
        final session = await repo.share(fixture.link());
        final spec = await repo.prepare(
          session,
          (await repo.list(session, '0')).single,
        );
        expect(spec.platform, CloudPlatform.lanzou);
        expect((await repo.refresh(spec)).url, lanzouTestFinal);
        expect(vault.credential(CloudPlatform.lanzou), isNull);
        expect(encoded(spec.source), isNot(contains('share_session')));
        expect(
          LoginCredentials.stored(
            CloudPlatform.lanzou,
            Credential('fake', {'primary': 'fake'}),
          ),
          isFalse,
        );
        await expectLater(repo.personal(CloudPlatform.lanzou), _fails('请先登录'));
      },
    );
  });
}
