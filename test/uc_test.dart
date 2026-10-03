import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/uc.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

const _now = 1700000000000;
const _personal = BrowseSession(
  platform: CloudPlatform.uc,
  mode: BrowseMode.personal,
  title: 'UC',
  rootId: '0',
);
const _share = BrowseSession(
  platform: CloudPlatform.uc,
  mode: BrowseMode.share,
  title: 'UC',
  rootId: '0',
  metadata: {'shareId': 'share', 'stoken': 'a+b/c='},
);
const _file = CloudFile(
  id: 'file-1',
  name: '视频.mp4',
  size: 42,
  token: 'fid+token=',
  parentId: 'folder',
);
Credential _credential({
  bool fresh = false,
  String primary = '__pus=account; __puus=old; keep=a=b',
  int revision = 1,
}) => Credential('UC', {
  'primary': primary,
  if (fresh) 'ucSessionRefreshedAt': '$_now',
}, updatedAt: revision);
HttpResult _ok(Object data, {List<String> cookies = const []}) => HttpResult(
  200,
  jsonEncode({'status': 200, 'code': 0, 'data': data}),
  {'Set-Cookie': cookies},
);
HttpResult _download({
  List<String> cookies = const [],
  int size = 42,
  String? url,
  String fid = 'file-1',
}) => _ok([
  {
    'fid': fid,
    'file_name': _file.name,
    'size': size,
    'download_url': url ?? 'https://example.com/original?sign=a%2Bb',
  },
], cookies: cookies);
HttpResult _refresh({String value = 'renewed'}) => _ok(
  {},
  cookies: ['__puus=$value; Domain=.uc.cn; Path=/; Secure; HttpOnly'],
);
HttpResult get _expired => jsonResponse({
  'status': 401,
  'code': 31001,
  'message': 'require login [guest]',
}, 401);
Matcher _message(String value) => throwsA(
  isA<AppException>().having((e) => e.message, 'message', contains(value)),
);
UcConnector _connector(FakeHttp http, {Vault? vault}) =>
    UcConnector(http, store: vault, now: () => _now, taskDelay: Duration.zero);
AccountLoginService _login(Vault vault, UcConnector connector) =>
    AccountLoginService(
      vault,
      (_, c) => connector.account(c),
      webAuthenticators: {CloudPlatform.uc: connector.authenticate},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UC download sessions', () {
    test(
      'Old sessions refresh without __puus and deliver the renewed Cookie to Gopeed',
      () async {
        final vault = Vault(StateStore.memory()), old = _credential();
        await vault.putCredential(CloudPlatform.uc, old);
        final http = FakeHttp(
          (r) => r.uri.path.endsWith('/config') ? _refresh() : _download(),
        );
        final spec = await _connector(
          http,
          vault: vault,
        ).download(_personal, _file, old);
        expect(http.calls.length, 2);
        expect(http.calls.first.uri.path, '/1/clouddrive/config');
        final probing = LoginCredentials.cookiePairs(
          http.calls.first.headers['Cookie']!,
        );
        expect(probing.containsKey('__puus'), isFalse);
        expect(probing['__pus'], 'account');
        expect(probing['keep'], 'a=b');
        final download = http.calls.last;
        expect(download.headers['User-Agent'], UcConnector.cloudUa);
        expect(download.uri.queryParameters, containsPair('sys', 'win32'));
        expect(download.uri.queryParameters, containsPair('ve', '1.6.1'));
        expect(download.uri.queryParameters.containsKey('entry'), isFalse);
        expect(download.json['fids'], ['file-1']);
        expect(
          LoginCredentials.cookiePairs(download.headers['Cookie']!)['__puus'],
          'renewed',
        );
        expect(spec.headers['Cookie'], download.headers['Cookie']);
        expect(spec.headers['User-Agent'], UcConnector.webUa);
        expect(spec.headers['Referer'], 'https://drive.uc.cn/');
        expect(spec.headers['Origin'], 'https://drive.uc.cn');
        expect(spec.headers.containsKey('Content-Type'), isFalse);
        expect(spec.url, 'https://example.com/original?sign=a%2Bb');
        final stored = vault.credential(CloudPlatform.uc)!;
        expect(stored.primary, spec.headers['Cookie']);
        expect(stored.updatedAt, old.updatedAt);
        expect(stored.field('ucSessionRefreshedAt'), '$_now');
      },
    );

    test(
      'Fresh sessions skip proactive refresh and later download responses renew them',
      () async {
        final vault = Vault(StateStore.memory()), c = _credential(fresh: true);
        await vault.putCredential(CloudPlatform.uc, c);
        final http = FakeHttp((r) {
          expect(r.uri.path, '/1/clouddrive/file/download');
          return _download(
            cookies: [
              '  __puus=next; Path=/; HttpOnly',
              '__pus=next-account; Path=/',
              'tracking=ignored; Path=/',
            ],
          );
        });
        final spec = await _connector(
          http,
          vault: vault,
        ).download(_personal, _file, c);
        expect(http.calls.length, 1);
        final pairs = LoginCredentials.cookiePairs(spec.headers['Cookie']!);
        expect(pairs['__puus'], 'next');
        expect(pairs['__pus'], 'next-account');
        expect(pairs['keep'], 'a=b');
        expect(pairs.containsKey('tracking'), isFalse);
        expect(pairs.containsKey('Path'), isFalse);
        expect(vault.credential(CloudPlatform.uc)!.updatedAt, 1);
      },
    );

    test(
      'A 401 on a recently saved Cookie triggers one refresh and one retry',
      () async {
        var requests = 0;
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('/config')) return _refresh();
          return requests++ == 0 ? _expired : _download();
        });
        final spec = await _connector(
          http,
        ).download(_personal, _file, _credential(fresh: true));
        expect(requests, 2);
        expect(http.calls.length, 3);
        expect(spec.headers['Cookie'], contains('__puus=renewed'));
        expect(http.calls[0].json, http.calls[2].json);
      },
    );

    test(
      'Business login error 31001 is retried even when HTTP status is 200',
      () async {
        var requests = 0;
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('/config')) return _refresh();
          return requests++ == 0
              ? jsonResponse({
                  'status': 200,
                  'code': 31001,
                  'message': 'require login',
                })
              : _download();
        });
        await _connector(
          http,
        ).download(_personal, _file, _credential(fresh: true));
        expect(requests, 2);
        expect(http.calls.length, 3);
      },
    );

    test(
      'Still-expired sessions stop after one retry and require login',
      () async {
        final http = FakeHttp(
          (r) => r.uri.path.endsWith('/config') ? _refresh() : _expired,
        );
        await expectLater(
          _connector(http).download(_personal, _file, _credential(fresh: true)),
          throwsA(isA<AccountLoginRequired>()),
        );
        expect(
          http.calls.where((r) => r.uri.path.endsWith('/config')).length,
          1,
        );
        expect(
          http.calls.where((r) => r.uri.path.endsWith('/download')).length,
          2,
        );
      },
    );

    test(
      'Refresh network errors do not prevent an existing usable session downloading',
      () async {
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('/config')) {
            throw const AppException('fixture offline');
          }
          return _download();
        });
        final spec = await _connector(
          http,
        ).download(_personal, _file, _credential());
        expect(spec.headers['Cookie'], contains('__puus=old'));
        expect(http.calls.length, 2);
      },
    );

    test(
      'Config without a new session Cookie cannot claim the session was refreshed',
      () async {
        final vault = Vault(StateStore.memory()), c = _credential();
        await vault.putCredential(CloudPlatform.uc, c);
        final http = FakeHttp(
          (r) => r.uri.path.endsWith('/config') ? _ok({}) : _expired,
        );
        await expectLater(
          _connector(http, vault: vault).download(_personal, _file, c),
          throwsA(isA<AccountLoginRequired>()),
        );
        expect(vault.credential(CloudPlatform.uc)!.sameAs(c), isTrue);
        expect(http.calls.length, 2);
      },
    );

    test(
      'Malformed or cleared Set-Cookie values cannot erase the working Cookie',
      () async {
        final http = FakeHttp(
          (_) => _download(
            cookies: [
              '__puus=; Max-Age=0',
              '__pus=bad\r\nvalue; Path=/',
              'invalid',
              'unrelated=ignored',
            ],
          ),
        );
        final c = _credential(fresh: true);
        final spec = await _connector(http).download(_personal, _file, c);
        expect(spec.headers['Cookie'], c.primary);
      },
    );

    test(
      'Cancellation during refresh prevents persistence and download requests',
      () async {
        final vault = Vault(StateStore.memory()),
            c = _credential(),
            scope = RequestScope();
        await vault.putCredential(CloudPlatform.uc, c);
        final http = FakeHttp((_) {
          scope.cancel();
          return _refresh();
        });
        await expectLater(
          scope.run(
            () => _connector(http, vault: vault).download(_personal, _file, c),
          ),
          _message('请求已取消'),
        );
        expect(http.calls.length, 1);
        expect(vault.credential(CloudPlatform.uc)!.sameAs(c), isTrue);
      },
    );

    for (final logout in [false, true]) {
      test(
        'Late refresh cannot write cookies after ${logout ? 'logout' : 'account replacement'}',
        () async {
          final vault = Vault(StateStore.memory()),
              c = _credential(),
              reply = Completer<HttpResult>();
          await vault.putCredential(CloudPlatform.uc, c);
          final http = FakeHttp((_) => reply.future);
          final pending = expectLater(
            _connector(http, vault: vault).download(_personal, _file, c),
            _message('账号已变化'),
          );
          await until(() => http.calls.length == 1);
          final replacement = _credential(
            primary: '__pus=other; __puus=other',
            revision: 2,
          );
          if (logout) {
            await vault.removeCredential(CloudPlatform.uc);
          } else {
            await vault.putCredential(CloudPlatform.uc, replacement);
          }
          reply.complete(_refresh(value: 'old-account-late-response'));
          await pending;
          expect(http.calls.length, 1);
          if (logout) {
            expect(vault.credential(CloudPlatform.uc), isNull);
          } else {
            expect(
              vault.credential(CloudPlatform.uc)!.sameAs(replacement),
              isTrue,
            );
          }
        },
      );
    }

    test(
      'Concurrent responses cannot roll back a Cookie already saved by another request',
      () async {
        final vault = Vault(StateStore.memory()), c = _credential(fresh: true);
        await vault.putCredential(CloudPlatform.uc, c);
        final replies = [Completer<HttpResult>(), Completer<HttpResult>()];
        var index = 0;
        final http = FakeHttp((_) => replies[index++].future),
            connector = _connector(http, vault: vault);
        final first = connector.download(_personal, _file, c);
        final second = connector.download(_personal, _file, c);
        await until(() => http.calls.length == 2);
        replies[1].complete(_download(cookies: ['__puus=winner; Path=/']));
        final b = await second;
        replies[0].complete(_download(cookies: ['__puus=late-stale; Path=/']));
        final a = await first;
        expect(a.headers['Cookie'], b.headers['Cookie']);
        expect(
          vault.credential(CloudPlatform.uc)!.primary,
          contains('__puus=winner'),
        );
        expect(vault.credential(CloudPlatform.uc)!.updatedAt, 1);
      },
    );

    test(
      'CloudRepository accepts session renewal without changing download account identity',
      () async {
        final store = StateStore.memory(),
            vault = Vault(store),
            c = _credential();
        await vault.putCredential(CloudPlatform.uc, c);
        final http = FakeHttp(
          (r) => r.uri.path.endsWith('/config') ? _refresh() : _download(),
        );
        final repository = CloudRepository(
          http,
          vault,
          CleanupOutbox(store, http),
        );
        final spec = await repository.prepare(_personal, _file);
        expect(spec.source!['accountRevision'], 1);
        expect(spec.headers['Cookie'], contains('__puus=renewed'));
        http.calls.clear();
        await repository.prepare(_personal, _file);
        expect(http.calls.length, 1);
        expect(http.calls.single.uri.path, '/1/clouddrive/file/download');
      },
    );
  });

  group('UC download responses', () {
    for (final name in ['sample.zip', '视频.mp4']) {
      test(
        'Share $name transfers before requesting a personal download URL',
        () async {
          final staged = <DownloadCleanup>[];
          var polls = 0;
          final http = FakeHttp((r) {
            switch (r.uri.path) {
              case '/1/clouddrive/config':
                return _refresh();
              case '/1/clouddrive/file/sort':
                return _ok({
                  'list': [
                    {'fid': 'base', 'file_name': '文析助手临时转存', 'dir': true},
                  ],
                });
              case '/1/clouddrive/file':
                expect(r.json['pdir_fid'], 'base');
                return _ok({'fid': 'temporary'});
              case '/1/clouddrive/share/sharepage/save':
                expect(r.json['pwd_id'], 'share');
                expect(r.json['stoken'], 'a+b/c=');
                expect(r.json['fid_list'], ['file-1']);
                expect(r.json['fid_token_list'], ['fid+token=']);
                expect(r.json['to_pdir_fid'], 'temporary');
                expect(staged, hasLength(1));
                return _ok({'task_id': 'save'});
              case '/1/clouddrive/task':
                polls++;
                return _ok(
                  polls == 1
                      ? {'status': 1}
                      : {
                          'status': 2,
                          'save_as': {
                            'save_as_top_fids': ['personal-file'],
                          },
                        },
                );
              case '/1/clouddrive/file/download':
                expect(polls, 2);
                expect(r.json, {
                  'fids': ['personal-file'],
                });
                expect(r.headers['Cookie'], contains('__puus=renewed'));
                expect(r.uri.queryParameters.containsKey('entry'), isFalse);
                return _download(
                  fid: 'personal-file',
                  cookies: ['__puus=from-download; Path=/'],
                );
              default:
                throw StateError('Unexpected request ${r.uri}');
            }
          });
          final spec =
              await UcConnector(
                http,
                now: () => _now,
                taskDelay: Duration.zero,
                stageCleanup: (c) async => staged.add(c),
              ).download(
                _share,
                CloudFile(
                  id: _file.id,
                  name: name,
                  size: 42,
                  token: _file.token,
                ),
                _credential(),
              );
          expect(spec.url, contains('/original'));
          expect(spec.headers['Cookie'], contains('__puus=from-download'));
          expect(spec.headers['Referer'], 'https://drive.uc.cn/');
          expect(spec.cleanup, same(staged.single));
          expect(jsonDecode(spec.cleanup!.body!)['filelist'], ['temporary']);
          expect(
            http.calls.any((r) => r.uri.path.contains('video_preview')),
            isFalse,
          );
          expect(
            http.calls.any((r) => r.uri.path.endsWith('/file/delete')),
            isFalse,
          );
        },
      );
    }

    test(
      'Failed share transfer never requests a download link and cleans only its temporary folder',
      () async {
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('/file/sort')) {
            return _ok({
              'list': [
                {'fid': 'base', 'file_name': '文析助手临时转存', 'dir': true},
              ],
            });
          }
          if (r.uri.path.endsWith('/file')) return _ok({'fid': 'temporary'});
          if (r.uri.path.endsWith('/save')) return _ok({'task_id': 'save'});
          if (r.uri.path.endsWith('/task')) return _ok({'status': 3});
          if (r.uri.path.endsWith('/file/delete')) {
            expect(r.json['filelist'], ['temporary']);
            return _ok({});
          }
          throw StateError('Unexpected request ${r.uri}');
        });
        await expectLater(
          _connector(http).download(_share, _file, _credential(fresh: true)),
          _message('异步任务失败'),
        );
        expect(
          http.calls.any((r) => r.uri.path.endsWith('/file/download')),
          isFalse,
        );
      },
    );

    test(
      'Failed transfer authentication does not issue download requests',
      () async {
        final http = FakeHttp(
          (r) => r.uri.path.endsWith('/config') ? _refresh() : _expired,
        );
        await expectLater(
          _connector(http).download(_share, _file, _credential()),
          throwsA(isA<AccountLoginRequired>()),
        );
        expect(
          http.calls.any((r) => r.uri.path.endsWith('/file/download')),
          isFalse,
        );
        expect(http.calls.length, 2);
      },
    );

    test('Cancelled share transfer does not issue download requests', () async {
      final scope = RequestScope();
      final http = FakeHttp((_) {
        scope.cancel();
        throw const AppException('请求已取消');
      });
      await expectLater(
        scope.run(
          () => _connector(
            http,
          ).download(_share, _file, _credential(fresh: true)),
        ),
        _message('请求已取消'),
      );
      expect(http.calls.length, 1);
    });

    test(
      'Missing share tokens fail before refresh or download calls',
      () async {
        final http = FakeHttp();
        await expectLater(
          _connector(http).download(
            _share,
            const CloudFile(id: 'file-1', name: 'sample.zip'),
            _credential(),
          ),
          _message('下载凭证'),
        );
        expect(http.calls, isEmpty);
      },
    );

    test(
      'Business errors cannot be mistaken for download success by status 200',
      () async {
        final http = FakeHttp(
          (_) => jsonResponse({
            'status': 200,
            'code': 32001,
            'message': 'fixture download denied',
            'data': [
              {'download_url': 'https://example.com/not-authorized'},
            ],
          }),
        );
        await expectLater(
          _connector(http).download(_personal, _file, _credential(fresh: true)),
          _message('fixture download denied'),
        );
        expect(http.calls.length, 1);
      },
    );

    test(
      'Non-HTTP and mismatched-size responses are not handed to the downloader',
      () async {
        for (final response in [
          _download(url: 'javascript:alert(1)'),
          _download(size: 9876),
        ]) {
          await expectLater(
            _connector(
              FakeHttp((_) => response),
            ).download(_personal, _file, _credential(fresh: true)),
            throwsA(isA<AppException>()),
          );
        }
      },
    );

    test(
      'Missing response size retains the known size for download verification',
      () async {
        final spec = await _connector(
          FakeHttp((_) => _download(size: 0)),
        ).download(_personal, _file, _credential(fresh: true));
        expect(spec.expectedSize, 42);
      },
    );
  });

  group('UC login and browsing', () {
    test(
      'Login saves renewed candidate cookies without modifying the old account mid-validation',
      () async {
        final vault = Vault(StateStore.memory()), old = _credential();
        await vault.putCredential(CloudPlatform.uc, old);
        final http = FakeHttp((r) {
          expect(vault.credential(CloudPlatform.uc)!.sameAs(old), isTrue);
          return _ok(
            {'nickname': 'new-user', 'use_capacity': 10, 'total_capacity': 100},
            cookies: ['__puus=new-candidate; Path=/'],
          );
        });
        final result = await _login(
          vault,
          _connector(http, vault: vault),
        ).submitWeb(CloudPlatform.uc, '__pus=new-account; __puus=candidate');
        expect(
          result.credential.primary,
          '__pus=new-account; __puus=new-candidate',
        );
        expect(result.credential.updatedAt, greaterThan(old.updatedAt));
        expect(
          vault.credential(CloudPlatform.uc)!.sameAs(result.credential),
          isTrue,
        );
        expect(result.account.total, 100);
      },
    );

    test('Expired candidate cannot replace an existing UC login', () async {
      final vault = Vault(StateStore.memory()), old = _credential();
      await vault.putCredential(CloudPlatform.uc, old);
      final http = FakeHttp((_) => _expired);
      await expectLater(
        _login(
          vault,
          _connector(http, vault: vault),
        ).submitWeb(CloudPlatform.uc, '__pus=new; __puus=invalid'),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(vault.credential(CloudPlatform.uc)!.sameAs(old), isTrue);
    });

    test(
      'Personal browsing is independent of capacity and uses the desktop client header',
      () async {
        final http = FakeHttp((r) {
          expect(r.uri.path, '/1/clouddrive/file/sort');
          return _ok({
            'list': [
              {'fid': 'folder', 'file_name': '目录', 'dir': '1'},
            ],
          });
        });
        final connector = _connector(http), c = _credential();
        final session = await connector.openPersonal(c);
        expect(http.calls, isEmpty);
        final folders = await connector.list(session, '', c);
        expect(folders.single.isDirectory, isTrue);
        expect(http.calls.single.headers['User-Agent'], UcConnector.cloudUa);
        expect(http.calls.single.uri.queryParameters['_fetch_sub_dirs'], '0');
        expect(http.calls.single.uri.queryParameters['pdir_fid'], '0');
      },
    );

    test(
      'Valid cloud capacity is retained if the optional account-info endpoint fails',
      () async {
        final http = FakeHttp(
          (r) => r.uri.path.endsWith('/member')
              ? _ok({
                  'use_capacity': '1099511627776',
                  'total_capacity': 2199023255552,
                })
              : const HttpResult(503, 'fixture account service unavailable'),
        );
        final account = await _connector(http).account(_credential());
        expect(account.used, 1099511627776);
        expect(account.total, 2199023255552);
        expect(account.nickname, 'UC 用户');
        expect(http.calls.first.headers['User-Agent'], UcConnector.cloudUa);
        expect(
          http.calls.last.uri.toString(),
          'https://drive.uc.cn/account/info',
        );
      },
    );

    test(
      'Incomplete lists and quotas surface errors instead of empty success',
      () async {
        final connector = _connector(FakeHttp((_) => _ok({})));
        await expectLater(
          connector.list(_personal, '0', _credential()),
          _message('文件列表响应不完整'),
        );
        await expectLater(connector.account(_credential()), _message('容量'));
      },
    );

    test(
      'Personal downloads without credentials fail before making network requests',
      () async {
        final http = FakeHttp();
        await expectLater(
          _connector(http).download(_personal, _file, null),
          throwsA(isA<AccountLoginRequired>()),
        );
        await expectLater(
          _connector(
            http,
          ).download(_personal, _file, _credential(primary: '__pus=only')),
          throwsA(isA<AccountLoginRequired>()),
        );
        expect(http.calls, isEmpty);
      },
    );
  });
}
