import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/baidu.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

const _personal = BrowseSession(
  platform: CloudPlatform.baidu,
  mode: BrowseMode.personal,
  title: 'fixture',
  rootId: '/',
);
const _encodedKey = 'a%2Bb%2Fc%3D';
const _share = BrowseSession(
  platform: CloudPlatform.baidu,
  mode: BrowseMode.share,
  title: 'fixture',
  rootId: '/',
  metadata: {
    'shortId': 'fixture',
    'sekey': _encodedKey,
    'shareId': '123',
    'uk': '456',
  },
);
const _file = CloudFile(
  id: '789',
  name: '测试 + 文件.mp4',
  token: '/视频/测试 + 文件.mp4',
  size: 42,
);
Credential _credential([Map<String, String> extra = const {}]) => Credential(
  'fixture',
  {'primary': 'BDUSS=fixture; BDCLND=old; bdclnd=also-old', ...extra},
  updatedAt: 1,
);
ParsedLink _link({String? passcode}) => ParsedLink(
  source: 'fixture',
  url: 'https://pan.baidu.com/s/1fixture',
  kind: LinkKind.cloudShare,
  platform: CloudPlatform.baidu,
  shareId: 'fixture',
  passcode: passcode,
);
Map<String, String> _form(RecordedRequest r) =>
    Uri.splitQueryString(r.body as String);
Matcher _message(String part) => throwsA(
  isA<AppException>().having((e) => e.message, 'message', contains(part)),
);
Json _shareFiles() => {
  'errno': 0,
  'share_id': '123',
  'uk': '456',
  'list': [
    {
      'fs_id': '9007199254740993',
      'path': '/共享目录 + 中文',
      'isdir': '1',
      'server_filename': '共享目录 + 中文',
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Baidu login and capacity', () {
    test(
      'Cookie-only login uses YunX default ID and reads byte quotas',
      () async {
        final http = FakeHttp(
          (r) => r.uri.path.endsWith('/quota')
              ? jsonResponse({
                  'errno': 0,
                  'used': '1099511627776',
                  'total': 2199023255552,
                })
              : jsonResponse({
                  'errno': 0,
                  'result': {'username': 'fixture'},
                }),
        );
        final vault = Vault(StateStore.memory());
        final connector = BaiduConnector(http);
        final result = await AccountLoginService(
          vault,
          (_, c) => connector.account(c),
        ).submitWeb(CloudPlatform.baidu, 'Cookie: BDUSS=test-only');
        expect(result.account.used, 1099511627776);
        expect(result.account.total, 2199023255552);
        expect(result.account.nickname, 'fixture');
        expect(
          vault.credential(CloudPlatform.baidu)!.primary,
          'BDUSS=test-only',
        );
        expect(
          http.calls.every((r) => r.uri.queryParameters['app_id'] == '250528'),
          isTrue,
        );
        expect(http.calls.first.uri.host, 'yun.baidu.com');
        expect(
          http.calls.first.headers['User-Agent'],
          BaiduConnector.netdiskUa,
        );
        expect(http.calls.last.headers['User-Agent'], BaiduConnector.webUa);
      },
    );

    test(
      'Custom and legacy IDs survive web login; clearing resets to default',
      () async {
        for (final extra in [
          {'appId': '777777'},
          {'secondary': '888888'},
        ]) {
          final old = _credential(extra);
          final vault = Vault(StateStore.memory());
          await vault.putCredential(CloudPlatform.baidu, old);
          final http = FakeHttp(
            (r) => r.uri.path.endsWith('/quota')
                ? jsonResponse({'errno': 0, 'used': 0, 'total': 1024})
                : jsonResponse({
                    'errno': 0,
                    'result': {'username': 'new'},
                  }),
          );
          final connector = BaiduConnector(http);
          final login = AccountLoginService(
            vault,
            (_, c) => connector.account(c),
          );
          final saved = await login.submitWeb(CloudPlatform.baidu, 'BDUSS=new');
          expect(connector.appId(saved.credential), extra.values.single);
          expect(
            http.calls.first.uri.queryParameters['app_id'],
            extra.values.single,
          );
          http.calls.clear();
          await login.submitWeb(CloudPlatform.baidu, 'BDUSS=newer', appId: '');
          expect(http.calls.first.uri.queryParameters['app_id'], '250528');
        }
      },
    );

    test('Invalid custom ID does not save unusable credentials', () async {
      final vault = Vault(StateStore.memory()), old = _credential();
      await vault.putCredential(CloudPlatform.baidu, old);
      final http = FakeHttp();
      final connector = BaiduConnector(http);
      await expectLater(
        AccountLoginService(
          vault,
          (_, c) => connector.account(c),
        ).submitWeb(CloudPlatform.baidu, 'BDUSS=new', appId: 'not-an-id'),
        _message('应用 ID 格式无效'),
      );
      expect(vault.credential(CloudPlatform.baidu)!.sameAs(old), isTrue);
      expect(http.calls, isEmpty);
    });

    test('Unavailable nickname does not hide a valid quota', () async {
      final http = FakeHttp(
        (r) => r.uri.path.endsWith('/quota')
            ? jsonResponse({'errno': 0, 'used': 0, 'total': 1024})
            : const HttpResult(503, 'unavailable'),
      );
      final account = await BaiduConnector(
        http,
      ).account(_credential({'nickname': 'saved-name'}));
      expect(account.nickname, 'saved-name');
      expect(account.used, 0);
      expect(account.total, 1024);
    });

    test(
      'Missing or invalid quota is an error instead of zero capacity',
      () async {
        for (final quota in <Json>[
          {'errno': 0},
          {'errno': 0, 'used': 3},
          {'errno': 0, 'used': -1, 'total': 1024},
          {'errno': 0, 'used': 0, 'total': 0},
        ]) {
          final http = FakeHttp((_) => jsonResponse(quota));
          await expectLater(
            BaiduConnector(http).account(_credential()),
            _message('容量'),
          );
          expect(http.calls.length, 1);
        }
      },
    );

    test(
      'Personal browsing does not depend on nickname or quota endpoints',
      () async {
        final http = FakeHttp((r) {
          expect(r.uri.path, '/api/list');
          return jsonResponse({'errno': 0, 'list': []});
        });
        final connector = BaiduConnector(http), c = _credential();
        final session = await connector.openPersonal(c);
        expect(http.calls, isEmpty);
        expect(await connector.list(session, '', c), isEmpty);
        expect(http.calls.single.uri.queryParameters['dir'], '/');
        expect(http.calls.single.uri.queryParameters['app_id'], '250528');
      },
    );

    test(
      'Expired Cookie responses cannot overwrite the previous account',
      () async {
        for (final response in [
          jsonResponse({'errno': -6}),
          const HttpResult(401, '<html>login required</html>'),
        ]) {
          final vault = Vault(StateStore.memory()), old = _credential();
          await vault.putCredential(CloudPlatform.baidu, old);
          final connector = BaiduConnector(FakeHttp((_) => response));
          await expectLater(
            AccountLoginService(
              vault,
              (_, c) => connector.account(c),
            ).submitWeb(CloudPlatform.baidu, 'BDUSS=expired'),
            throwsA(isA<AccountLoginRequired>()),
          );
          expect(vault.credential(CloudPlatform.baidu)!.sameAs(old), isTrue);
        }
      },
    );

    test(
      'Incomplete Cookie is rejected before any authenticated requests',
      () async {
        final http = FakeHttp(), connector = BaiduConnector(http);
        final incomplete = _credential({'primary': 'BDCLND=share-only'});
        await expectLater(
          connector.openPersonal(incomplete),
          throwsA(isA<AccountLoginRequired>()),
        );
        await expectLater(
          connector.download(_personal, _file, incomplete),
          throwsA(isA<AccountLoginRequired>()),
        );
        expect(http.calls, isEmpty);
      },
    );
  });

  group('Baidu share browsing and transfer', () {
    test(
      'surl input and pass parameter reach share verification intact',
      () async {
        final http = FakeHttp(
          (r) => r.uri.path.endsWith('/verify')
              ? jsonResponse({'errno': 0, 'randsk': _encodedKey})
              : jsonResponse(_shareFiles()),
        );
        final link = LinkParser.parse(
          'https://pan.baidu.com/share/init?surl=Abc_Def&pass=a%2B12 提取码：b123',
        ).single;
        final session = await BaiduConnector(
          http,
        ).openShare(link, _credential());
        expect(http.calls.first.uri.queryParameters['surl'], 'Abc_Def');
        expect(_form(http.calls.first)['pwd'], 'a+12');
        expect(session.meta('shortId'), 'Abc_Def');
        expect(session.sourceLink!.url, link.url);
      },
    );

    test(
      'Encoded randsk is sent once and replaces stale BDCLND in subfolders',
      () async {
        final http = FakeHttp(
          (r) => r.uri.path.endsWith('/verify')
              ? jsonResponse({'errno': 0, 'randsk': _encodedKey})
              : jsonResponse(_shareFiles()),
        );
        final connector = BaiduConnector(http), c = _credential();
        final session = await connector.openShare(_link(passcode: 'a+12'), c);
        final folders = await connector.list(session, '/共享目录 + 中文', c);
        expect(_form(http.calls.first)['pwd'], 'a+12');
        final request = http.calls.last;
        expect(request.uri.queryParameters['sekey'], 'a+b/c=');
        expect(request.url, contains('sekey=a%2Bb%2Fc%3D'));
        expect(request.url, isNot(contains('%252B')));
        expect(request.headers['Cookie'], 'BDUSS=fixture; BDCLND=$_encodedKey');
        expect(request.headers['Referer'], 'https://pan.baidu.com/s/1fixture');
        expect(http.calls[1].uri.queryParameters['root'], '1');
        expect(request.uri.queryParameters['root'], '0');
        expect(request.uri.queryParameters['dir'], '/共享目录 + 中文');
        expect(folders.single.isDirectory, isTrue);
        expect(folders.single.id, '9007199254740993');
        expect(folders.single.token, '/共享目录 + 中文');
      },
    );

    test(
      'Public share omits sekey and removes credentials of a previous share',
      () async {
        final http = FakeHttp((_) => jsonResponse(_shareFiles()));
        await BaiduConnector(http).openShare(_link(), _credential());
        expect(
          http.calls.single.uri.queryParameters.containsKey('sekey'),
          isFalse,
        );
        expect(http.calls.single.headers['Cookie'], 'BDUSS=fixture');
      },
    );

    test(
      'Missing passcode and expired shares have different actionable errors',
      () async {
        for (final code in [2, -12, -9]) {
          final http = FakeHttp((_) => jsonResponse({'errno': code}));
          await expectLater(
            BaiduConnector(http).openShare(_link(), null),
            _message(code == -9 ? '失效' : '提取码'),
          );
        }
      },
    );

    test(
      'Malformed share keys do not issue list or transfer requests',
      () async {
        final http = FakeHttp(
          (_) => jsonResponse({'errno': 0, 'randsk': 'bad%'}),
        );
        await expectLater(
          BaiduConnector(http).openShare(_link(passcode: '1234'), null),
          _message('分享凭证无效'),
        );
        expect(http.calls.length, 1);
      },
    );

    test(
      'Shared folder navigation keeps the numeric ID needed for saving',
      () async {
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('/gettemplatevariable')) {
            return jsonResponse({
              'errno': 0,
              'result': {'bdstoken': 'token'},
            });
          }
          if (r.uri.path.endsWith('/transfer')) {
            return jsonResponse({
              'errno': 0,
              'extra': {
                'list': [
                  {'to_fs_id': '654', 'to': '/目标/目录'},
                ],
              },
            });
          }
          return jsonResponse(_shareFiles());
        });
        final vault = Vault(StateStore.memory());
        final repository = CloudRepository(
          http,
          vault,
          CleanupOutbox(vault.store, http),
        );
        final connector = BaiduConnector(http), c = _credential();
        final folder = (await connector.list(_share, '/', c)).single;
        expect(repository.directoryId(_share, folder), '/共享目录 + 中文');
        await connector.saveShare(_share, [folder], '/目标 + 文件夹', c);
        final request = http.calls.last;
        expect(jsonDecode(_form(request)['fsidlist']!), ['9007199254740993']);
        expect(_form(request)['path'], '/目标 + 文件夹');
        expect(request.uri.queryParameters['sekey'], 'a+b/c=');
        expect(request.headers['Cookie'], 'BDUSS=fixture; BDCLND=$_encodedKey');
      },
    );

    test('Legacy share sessions can recover missing share_id and uk', () async {
      final fixture = _DownloadFixture();
      final session = BrowseSession(
        platform: CloudPlatform.baidu,
        mode: BrowseMode.share,
        title: 'legacy',
        rootId: '/',
        metadata: {'shortId': 'fixture', 'sekey': _encodedKey},
      );
      await fixture.connector.saveShare(session, [_file], '/目标', _credential());
      expect(
        fixture.http.calls.any((r) => r.uri.path.endsWith('/xpan/share')),
        isTrue,
      );
      final request = fixture.http.calls.last;
      expect(request.uri.queryParameters['shareid'], '123');
      expect(request.uri.queryParameters['from'], '456');
    });

    test(
      'Personal pagination preserves folder identity and every file',
      () async {
        final http = FakeHttp((r) {
          final page = int.parse(r.uri.queryParameters['page']!);
          return jsonResponse({
            'errno': 0,
            'list': [
              for (var i = (page - 1) * 100; i < (page == 1 ? 100 : 103); i++)
                {
                  'fs_id': i + 1,
                  'path': '/目录/$i',
                  'server_filename': '$i',
                  'isdir': i == 0 ? '1' : '0',
                },
            ],
          });
        });
        final files = await BaiduConnector(
          http,
        ).list(_personal, '/目录', _credential());
        expect(files.length, 103);
        expect(files.first.isDirectory, isTrue);
        expect(files.first.id, '1');
        expect(files.first.token, '/目录/0');
        expect(files.last.parentId, '/目录');
        expect(http.calls.length, 2);
      },
    );

    test(
      'Incomplete file-list responses are not shown as empty folders',
      () async {
        await expectLater(
          BaiduConnector(
            FakeHttp((_) => jsonResponse({'errno': 0})),
          ).list(_personal, '/', _credential()),
          _message('文件列表响应不完整'),
        );
      },
    );
  });

  group('Baidu downloads', () {
    test(
      'Personal files use path lookup and prefer a plain HTTPS candidate',
      () async {
        final fixture = _DownloadFixture();
        fixture.locate = {
          'urls': [
            {'url': 'https://example.com/encrypted', 'encrypt': 1},
            {'url': 'http://example.com/plain', 'encrypt': 0},
            {'url': 'https://example.com/plain?sign=a%2Bb', 'encrypt': '0'},
          ],
        };
        final spec = await fixture.connector.download(
          _personal,
          _file,
          _credential(),
        );
        expect(spec.url, 'https://example.com/plain?sign=a%2Bb');
        expect(spec.expectedSize, 42);
        expect(spec.fileName, _file.name);
        expect(spec.headers['User-Agent'], BaiduConnector.netdiskUa);
        expect(spec.cleanup, isNull);
        final r = fixture.http.calls.single;
        expect(r.method, 'POST');
        expect(r.uri.queryParameters['method'], 'locatedownload');
        expect(r.uri.queryParameters['path'], _file.token);
        expect(r.uri.queryParameters['app_id'], '250528');
        expect(r.body, '0');
      },
    );

    test(
      'All-encrypted or failed path lookup falls back to filemetas',
      () async {
        for (final response in <Json>[
          {
            'urls': [
              {'url': 'https://example.com/encrypted', 'encrypt': 1},
            ],
          },
          {'error_code': 31066, 'error_msg': 'fixture path unavailable'},
        ]) {
          final fixture = _DownloadFixture()..locate = response;
          final spec = await fixture.connector.download(
            _personal,
            _file,
            _credential(),
          );
          expect(spec.url, 'https://example.com/fallback?sign=a%2Bb');
          expect(fixture.http.calls.last.uri.path, '/api/filemetas');
          expect(
            jsonDecode(fixture.http.calls.last.uri.queryParameters['fsids']!),
            ['789'],
          );
        }
      },
    );

    test('Files without a path still download using fs_id', () async {
      final fixture = _DownloadFixture();
      final spec = await fixture.connector.download(
        _personal,
        const CloudFile(id: '789', name: 'legacy.mp4'),
        _credential(),
      );
      expect(spec.url, contains('/fallback'));
      expect(
        fixture.http.calls.any(
          (r) => r.uri.queryParameters['method'] == 'locatedownload',
        ),
        isFalse,
      );
    });

    test(
      'Expired authentication is not disguised by a fallback request',
      () async {
        final fixture = _DownloadFixture()..locate = {'errno': -6};
        await expectLater(
          fixture.connector.download(_personal, _file, _credential()),
          throwsA(isA<AccountLoginRequired>()),
        );
        expect(fixture.http.calls.length, 1);
      },
    );

    test(
      'Cancelled path lookup does not start another download request',
      () async {
        final scope = RequestScope();
        final http = FakeHttp((_) {
          scope.cancel();
          throw const AppException('请求已取消');
        });
        await expectLater(
          scope.run(
            () =>
                BaiduConnector(http).download(_personal, _file, _credential()),
          ),
          _message('请求已取消'),
        );
        expect(http.calls.length, 1);
      },
    );

    test(
      'PCS errors remain errors even if a response also contains a URL',
      () async {
        final fixture = _DownloadFixture()
          ..locate = {
            'error_code': 31034,
            'error_msg': 'fixture permission denied',
            'urls': [
              {'url': 'https://example.com/not-usable', 'encrypt': 0},
            ],
          };
        await expectLater(
          fixture.connector.download(
            _personal,
            const CloudFile(id: '/legacy.mp4', name: 'legacy.mp4'),
            _credential(),
          ),
          _message('fixture permission denied'),
        );
        expect(fixture.http.calls.length, 1);
      },
    );

    test(
      'Share resolution retains each unique temporary folder until cleanup',
      () async {
        final fixture = _DownloadFixture();
        final first = await fixture.connector.download(
          _share,
          _file,
          _credential(),
        );
        final second = await fixture.connector.download(
          _share,
          _file,
          _credential(),
        );
        expect(fixture.deleted, isEmpty);
        expect(fixture.staged.length, 2);
        final a =
            jsonDecode(Uri.splitQueryString(first.cleanup!.body!)['filelist']!)
                as List;
        final b =
            jsonDecode(Uri.splitQueryString(second.cleanup!.body!)['filelist']!)
                as List;
        expect(a.single, startsWith('/文析助手临时转存/tr_'));
        expect(b.single, isNot(a.single));
        expect(fixture.created, containsAll([a.single, b.single]));
        expect(fixture.tokenRequests, 2);
        expect(Uri.parse(first.cleanup!.url).queryParameters['newVerify'], '1');
        expect(
          fixture.http.calls
              .where((r) => r.uri.path.endsWith('/transfer'))
              .every((r) => r.uri.queryParameters['bdstoken'] == 'token'),
          isTrue,
        );
      },
    );

    test(
      'Failed share transfer only cleans the folder created for that request',
      () async {
        final fixture = _DownloadFixture()..transferError = true;
        await expectLater(
          fixture.connector.download(_share, _file, _credential()),
          _message('fixture transfer failed'),
        );
        expect(fixture.deleted.single, fixture.created.last);
        expect(fixture.deleted, isNot(contains('/文析助手临时转存')));
        expect(fixture.staged.length, 1);
      },
    );

    test('Cleanup staging failure cleans its folder before stopping', () async {
      final fixture = _DownloadFixture()..stageError = true;
      await expectLater(
        fixture.connector.download(_share, _file, _credential()),
        _message('fixture storage failed'),
      );
      expect(fixture.deleted.single, fixture.created.last);
      expect(
        fixture.http.calls.any((r) => r.uri.path.endsWith('/transfer')),
        isFalse,
      );
    });

    test(
      'Unexpected transfer paths cannot be used to resolve another file',
      () async {
        final fixture = _DownloadFixture()
          ..transferredPath = '/existing-user-file.mp4';
        await expectLater(
          fixture.connector.download(_share, _file, _credential()),
          _message('百度转存未返回完整文件路径'),
        );
        expect(fixture.deleted.single, fixture.created.last);
        expect(
          fixture.http.calls.any(
            (r) => r.uri.queryParameters['method'] == 'locatedownload',
          ),
          isFalse,
        );
      },
    );
  });

  group('Baidu file operations', () {
    test(
      'Rename, move and delete send YunX parameters and escaped full paths',
      () async {
        final fixture = _DownloadFixture(), c = _credential();
        const file = CloudFile(
          id: '123',
          name: '引号" + &.txt',
          token: '/资料/引号" + &.txt',
        );
        await fixture.connector.rename(_personal, file, '新的"文件 + &.txt', c);
        final rename = fixture.http.calls.last;
        expect(rename.uri.host, 'yun.baidu.com');
        expect(rename.uri.queryParameters['async'], '0');
        expect(jsonDecode(_form(rename)['filelist']!), [
          {'path': file.token, 'newname': '新的"文件 + &.txt'},
        ]);
        await fixture.connector.move(_personal, [file], '/目标 + &', c);
        final move = fixture.http.calls.last;
        expect(move.uri.host, 'pan.baidu.com');
        expect(move.uri.queryParameters['async'], '2');
        expect(jsonDecode(_form(move)['filelist']!), [
          {'path': file.token, 'dest': '/目标 + &', 'newname': file.name},
        ]);
        await fixture.connector.delete(_personal, [file], c);
        final delete = fixture.http.calls.last;
        expect(delete.uri.host, 'pan.baidu.com');
        expect(delete.uri.queryParameters['newVerify'], '1');
        expect(delete.uri.queryParameters['async'], '2');
        expect(jsonDecode(_form(delete)['filelist']!), [file.token]);
      },
    );

    test(
      'Batch file errors are reported even when the envelope says success',
      () async {
        final fixture = _DownloadFixture()
          ..managerResult = {
            'errno': 0,
            'info': [
              {'errno': -9, 'errmsg': 'fixture file missing'},
            ],
          };
        await expectLater(
          fixture.connector.delete(_personal, [_file], _credential()),
          _message('fixture file missing'),
        );
      },
    );

    test(
      'A created folder can be shared using its returned numeric fs_id',
      () async {
        final fixture = _DownloadFixture(), c = _credential();
        final folder = await fixture.connector.createFolder(
          _personal,
          '/',
          '新目录',
          c,
        );
        expect(folder.id, '678');
        expect(folder.token, '/新目录');
        final share = await fixture.connector.createShare(
          _personal,
          [folder],
          const ShareOptions('fixture', expiryDays: 7, passcode: 'a123'),
          c,
        );
        final body = _form(fixture.http.calls.last);
        expect(jsonDecode(body['fid_list']!), [678]);
        expect(body['period'], '7');
        expect(body['pwd'], 'a123');
        expect(share.url, 'https://pan.baidu.com/s/1fixture');
        expect(share.passcode, 'a123');
      },
    );

    test(
      'Existing user folders are not falsely reported as newly created',
      () async {
        final fixture = _DownloadFixture()..createError = -8;
        await expectLater(
          fixture.connector.createFolder(_personal, '/', '已有目录', _credential()),
          throwsA(isA<AppException>()),
        );
      },
    );
  });
}

class _DownloadFixture {
  _DownloadFixture() {
    http = FakeHttp(_respond);
    connector = BaiduConnector(
      http,
      stageCleanup: (cleanup) async {
        if (stageError) throw const AppException('fixture storage failed');
        staged.add(cleanup);
      },
    );
  }
  late final FakeHttp http;
  late final BaiduConnector connector;
  Json locate = {
    'urls': [
      {'url': 'https://example.com/plain', 'encrypt': 0},
    ],
  };
  Json managerResult = {'errno': 0};
  bool transferError = false, stageError = false;
  String? transferredPath;
  int? createError;
  int tokenRequests = 0;
  final created = <String>[], deleted = <String>[];
  final staged = <DownloadCleanup>[];

  HttpResult _respond(RecordedRequest r) {
    switch (r.uri.path) {
      case '/api/gettemplatevariable':
        tokenRequests++;
        return jsonResponse({
          'errno': 0,
          'result': {'bdstoken': 'token'},
        });
      case '/api/create':
        final path = _form(r)['path']!;
        created.add(path);
        return jsonResponse({
          'errno': createError ?? (path == '/文析助手临时转存' ? -8 : 0),
          'fs_id': 678,
          'path': path,
        });
      case '/share/transfer':
        if (transferError) {
          return jsonResponse({
            'errno': 2,
            'errmsg': 'fixture transfer failed',
          });
        }
        return jsonResponse({
          'errno': 0,
          'extra': {
            'list': [
              {
                'to_fs_id': '654',
                'to': transferredPath ?? '${_form(r)['path']}/${_file.name}',
              },
            ],
          },
        });
      case '/rest/2.0/pcs/file':
        return jsonResponse(locate);
      case '/api/filemetas':
        return jsonResponse({
          'errno': 0,
          'info': [
            {'dlink': 'https://example.com/fallback?sign=a%2Bb'},
          ],
        });
      case '/api/filemanager':
        if (r.uri.queryParameters['opera'] == 'delete') {
          deleted.addAll(
            (jsonDecode(_form(r)['filelist']!) as List).cast<String>(),
          );
        }
        return jsonResponse(managerResult);
      case '/rest/2.0/xpan/share':
        return jsonResponse(_shareFiles());
      case '/share/set':
        return jsonResponse({
          'errno': 0,
          'shorturl': 'https://pan.baidu.com/s/1fixture',
        });
      default:
        throw StateError('Unexpected fixture endpoint: ${r.uri.path}');
    }
  }
}
