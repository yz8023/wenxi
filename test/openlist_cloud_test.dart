import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/ilanzou.dart';
import 'package:asterlink/data/providers/weiyun.dart';
import 'package:asterlink/data/providers/wopan.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/domain/web_tokens.dart';
import 'native_login_support.dart';
import 'support.dart';
import 'token_cloud_support.dart';

const _iToken = 'fixture-app-token:0123456789+/=&';
const _qqCookie =
    'uin=o12345; p_skey=fixture-login-cookie; wyctoken=csrf-before';
Credential _credential(
  CloudPlatform p, {
  Map<String, String> fields = const {},
}) => Credential(p.label, {
  'primary': p == CloudPlatform.ilanzou
      ? _iToken
      : p == CloudPlatform.weiyun
      ? _qqCookie
      : refreshToken,
  'accessToken': p == CloudPlatform.ilanzou ? _iToken : accessToken,
  if (p == CloudPlatform.wopan) 'refreshToken': refreshToken,
  'authType': 'webToken',
  'userId': '12345',
  'uuid': 'fixture-device-123',
  'rootId': 'main-root',
  'csrfCheckedAt': '$tokenClock',
  'expiresAt': '${tokenClock + 3600000}',
  ...fields,
}, updatedAt: 42);
Future<Vault> _vault(
  CloudPlatform p, {
  Map<String, String> fields = const {},
}) async {
  final vault = Vault(StateStore.memory());
  await vault.putCredential(p, _credential(p, fields: fields));
  return vault;
}

BrowseSession _personal(CloudPlatform p) => BrowseSession(
  platform: p,
  mode: BrowseMode.personal,
  title: 'fixture',
  rootId: p == CloudPlatform.weiyun ? 'main-root' : '0',
);
HttpResult _iResponse(Json data) => jsonResponse({'code': 200, ...data});
HttpResult _weiResponse(Json data) => jsonResponse({
  'ret': 0,
  'data': {
    'rsp_header': {'retcode': 0},
    'rsp_body': {'RspMsg_body': data},
  },
});
Json _weiBody(RecordedRequest r) =>
    asJson(jsonDecode(r.json.str('req_body'))).obj('ReqMsg_body');
Json _woParam(RecordedRequest r) => WopanProtocol.decode(
  r.json.obj('body')['param'],
  r.json.obj('header').str('channel'),
  r.headers['Accesstoken'] ?? '',
);
HttpResult _woResponse(RecordedRequest r, Json data) => jsonResponse({
  'STATUS': '200',
  'RSP': {
    'RSP_CODE': '0000',
    'DATA': WopanProtocol.encrypt(
      data,
      r.json.obj('header').str('channel'),
      r.headers['Accesstoken'] ?? '',
    ),
  },
});
HttpResult _woDefault(RecordedRequest r) => _woResponse(r, switch (r.json
    .obj('header')
    .str('key')) {
  'AppRefreshToken' => {
    'access_token': renewedAccess,
    'refresh_token': renewedRefresh,
    'expires_in': 3600,
  },
  'AppQueryUser' => {'userId': '12345', 'userName': 'fixture'},
  'QueryCloudUsageInfo' => {
    'usageInfo': {'byteUsedSize': 100, 'byteTotalSize': '2000'},
  },
  'QueryAllFiles' => {'files': []},
  'FamilyUserCurrentEncode' => {'defaultHomeId': 123, 'defaultHomeName': '家庭'},
  'CreateDirectory' => {'id': 'new-folder'},
  'ClassifyRule' => {
    'fileTypes': {
      'mp4': {'type': '1'},
    },
  },
  _ => {},
});

void main() {
  test(
    'new services have distinct accounts, login targets and transfer profiles',
    () {
      expect(CloudPlatform.fromHost('www.ilanzou.com'), CloudPlatform.ilanzou);
      expect(
        CloudPlatform.fromHost('fixture.lanzouq.com'),
        CloudPlatform.lanzou,
      );
      expect(CloudPlatform.fromHost('pan.wo.cn'), CloudPlatform.wopan);
      expect(CloudPlatform.fromHost('yun.139.com'), CloudPlatform.c139);
      for (final p in [
        CloudPlatform.ilanzou,
        CloudPlatform.weiyun,
        CloudPlatform.wopan,
      ]) {
        expect(WebLoginTarget.targets[p]!.userAgent, contains('Windows NT'));
        expect(p.supportsSharing, isFalse);
        expect(p.canCreateFolder, isTrue);
        expect(const AppSettings().connectionProfileFor(p), p.name);
      }
      expect(
        WebLoginTarget.targets[CloudPlatform.guangya]!.url,
        endsWith('#/oauth/login'),
      );
    },
  );

  test(
    'token inputs preserve reserved characters and normalize refresh-only Wopan credentials',
    () {
      final i = WebTokens.fields(
        CloudPlatform.ilanzou,
        jsonEncode({
          'appToken': _iToken,
          'uuid': 'fixture-device-123',
          'private': 'discard',
        }),
      );
      expect(i['accessToken'], _iToken);
      expect(i.containsKey('private'), isFalse);
      expect(
        WebTokens.fields(
          CloudPlatform.ilanzou,
          'fixture\r\napp-token:0123456789',
        ),
        isEmpty,
      );
      final w = LoginCredentials.candidate(
        CloudPlatform.wopan,
        refreshToken,
        null,
      );
      expect(w.field('refreshToken'), refreshToken);
      expect(w.field('accessToken'), isEmpty);
      expect(LoginCredentials.stored(CloudPlatform.wopan, w), isTrue);
      expect(
        WebTokens.fields(
          CloudPlatform.wopan,
          jsonEncode({
            'refreshToken': refreshToken,
            'accessToken': accessToken,
          }),
        )['accessToken'],
        accessToken,
      );
    },
  );

  group('ILanzou', () {
    test(
      'an HTTP-expired download token is renewed once before resolving the same file',
      () async {
        final vault = await _vault(
          CloudPlatform.ilanzou,
          fields: {'username': 'fixture', 'password': 'private'},
        );
        var logins = 0;
        final http = FakeHttp((r) {
          if (r.uri.path == '/unproved/login') {
            logins++;
            return _iResponse({
              'data': {'appToken': renewedAccess},
            });
          }
          expect(
            r.uri.queryParameters['downloadId'],
            'eba100684200a4e2e696d67a5e431d12',
          );
          return r.uri.queryParameters['appToken'] == _iToken
              ? const HttpResult(401, 'expired')
              : const HttpResult(302, '', {
                  'location': ['https://cdn.example/movie'],
                });
        });
        final spec = await ILanzouConnector(http, vault, now: () => tokenClock)
            .download(
              _personal(CloudPlatform.ilanzou),
              const CloudFile(id: 'f:42', name: 'movie.mp4'),
              vault.credential(CloudPlatform.ilanzou),
            );
        expect(logins, 1);
        expect(spec.url, 'https://cdn.example/movie');
        expect(vault.credential(CloudPlatform.ilanzou)!.updatedAt, 42);
      },
    );

    test(
      'AES ECB matches independent Node crypto fixtures and preserves a literal token colon',
      () {
        expect(
          ILanzouConnector.encrypt('$tokenClock'),
          '075f7acee0ba5fa11cc736bf91c9c242',
        );
        expect(
          ILanzouConnector.encrypt('42|12345'),
          'eba100684200a4e2e696d67a5e431d12',
        );
        expect(ILanzouConnector.tokenQueryValue(_iToken), contains(':'));
        expect(ILanzouConnector.tokenQueryValue(_iToken), contains('%26'));
        expect(
          Uri.decodeQueryComponent(ILanzouConnector.tokenQueryValue(_iToken)),
          _iToken,
        );
      },
    );

    test(
      'password login obtains an isolated device and validates the user before saving',
      () async {
        final vault = await _vault(CloudPlatform.ilanzou),
            before = vault.credential(CloudPlatform.ilanzou)!;
        final http = LoginHttp((r) {
          if (r.uri.path == '/unproved/getUuid') {
            return _iResponse({'uuid': 'new-device-12345'});
          }
          if (r.uri.path == '/unproved/login') {
            expect(r.json, {
              'loginName': 'fixture',
              'loginPwd': ' private password ',
            });
            expect(r.uri.queryParameters['appToken'], isNull);
            return _iResponse({
              'data': {'appToken': _iToken},
            });
          }
          expect(r.uri.path, '/proved/user/account/map');
          expect(r.uri.queryParameters['uuid'], 'new-device-12345');
          return _iResponse({
            'map': {
              'userId': 54321,
              'account': 'fixture',
              'usedSize': 2,
              'totalSize': 9,
              'vipSize': 1,
            },
          });
        });
        final result = await ILanzouConnector(
          http,
          vault,
          now: () => tokenClock,
        ).password('fixture', ' private password ');
        expect(result.account.total, 10240);
        expect(result.credential.field('userId'), '54321');
        expect(vault.credential(CloudPlatform.ilanzou)!.sameAs(before), isTrue);
        expect(http.redirects, everyElement(isFalse));
      },
    );

    test(
      'folder and file IDs remain distinct and pagination continues beyond a full page',
      () async {
        final vault = await _vault(CloudPlatform.ilanzou);
        final http = LoginHttp((r) {
          final page = int.parse(r.uri.queryParameters['offset']!);
          expect(r.uri.queryParameters['folderId'], '0');
          expect(r.uri.queryParameters['appToken'], _iToken);
          expect(r.url, contains('appToken=fixture-app-token:'));
          return _iResponse({
            'offset': page,
            'totalPage': 2,
            'list': page == 1
                ? List.generate(
                    60,
                    (i) => {
                      'fileType': 1,
                      'fileId': i + 1,
                      'fileName': 'file-$i',
                      'fileSize': 2,
                    },
                  )
                : [
                    {'fileType': 2, 'folderId': 1, 'folderName': 'folder'},
                  ],
          });
        });
        final files = await ILanzouConnector(http, vault, now: () => tokenClock)
            .list(
              _personal(CloudPlatform.ilanzou),
              '0',
              vault.credential(CloudPlatform.ilanzou),
            );
        expect(files, hasLength(61));
        expect(files.first.id, 'f:1');
        expect(files.last.id, 'd:1');
        expect(files.first.size, 2048);
      },
    );

    test(
      'repeated pagination fails rather than returning an incomplete directory',
      () async {
        final vault = await _vault(CloudPlatform.ilanzou);
        final http = FakeHttp(
          (_) => _iResponse({
            'totalPage': 3,
            'list': [
              {'fileType': 1, 'fileId': 1, 'fileName': 'same'},
            ],
          }),
        );
        await expectLater(
          ILanzouConnector(http, vault, now: () => tokenClock).list(
            _personal(CloudPlatform.ilanzou),
            '0',
            vault.credential(CloudPlatform.ilanzou),
          ),
          throwsA(isA<AppException>()),
        );
        expect(http.calls, hasLength(2));
      },
    );

    for (final jsonResolver in [false, true]) {
      test(
        'download resolver handles ${jsonResolver ? 'JSON' : 'redirect'} without trusting rounded KiB sizes',
        () async {
          final vault = await _vault(CloudPlatform.ilanzou);
          final http = LoginHttp((r) {
            expect(
              r.uri.queryParameters['downloadId'],
              'eba100684200a4e2e696d67a5e431d12',
            );
            return jsonResolver
                ? jsonResponse({
                    'data': {'url': 'https://cdn.example/movie'},
                  })
                : const HttpResult(302, '', {
                    'location': ['https://cdn.example/movie'],
                  });
          });
          final spec =
              await ILanzouConnector(
                http,
                vault,
                now: () => tokenClock,
              ).download(
                _personal(CloudPlatform.ilanzou),
                const CloudFile(id: 'f:42', name: 'video.mp4', size: 2048),
                vault.credential(CloudPlatform.ilanzou),
              );
          expect(spec.expectedSize, 0);
          expect(spec.url, 'https://cdn.example/movie');
          expect(spec.headers.containsKey('Cookie'), isFalse);
          expect(http.redirects, [false]);
        },
      );
    }

    test(
      'CDN challenges retry with only the challenge cookie and mutations are encoded separately',
      () async {
        final vault = await _vault(CloudPlatform.ilanzou);
        var calls = 0;
        final http = LoginHttp((r) {
          calls++;
          expect(r.json, {'folderIds': '7', 'fileIds': '8', 'status': 0});
          if (calls == 1) {
            return const HttpResult(409, '<html>403</html>', {
              'content-type': ['text/html'],
              'set-cookie': ['challenge=accepted; Path=/; Secure'],
            });
          }
          expect(r.headers['Cookie'], 'challenge=accepted');
          return _iResponse({});
        });
        await ILanzouConnector(http, vault, now: () => tokenClock).delete(
          _personal(CloudPlatform.ilanzou),
          [
            const CloudFile(id: 'd:7', name: 'dir', isDirectory: true),
            const CloudFile(id: 'f:8', name: 'file'),
          ],
          vault.credential(CloudPlatform.ilanzou)!,
        );
        expect(calls, 2);
      },
    );

    test(
      'concurrent token rejection signs in once and preserves the account revision',
      () async {
        final vault = await _vault(
          CloudPlatform.ilanzou,
          fields: {'username': 'fixture', 'password': 'private'},
        );
        var refreshes = 0;
        final http = FakeHttp((r) {
          if (r.uri.path == '/unproved/login') {
            refreshes++;
            return _iResponse({
              'data': {'appToken': renewedAccess},
            });
          }
          return r.uri.queryParameters['appToken'] == _iToken
              ? jsonResponse({'code': -2})
              : _iResponse({'totalPage': 1, 'list': []});
        });
        final connector = ILanzouConnector(http, vault, now: () => tokenClock),
            c = vault.credential(CloudPlatform.ilanzou)!;
        await Future.wait([
          connector.list(_personal(CloudPlatform.ilanzou), '0', c),
          connector.list(_personal(CloudPlatform.ilanzou), '0', c),
        ]);
        expect(refreshes, 1);
        expect(vault.credential(CloudPlatform.ilanzou)!.updatedAt, 42);
        expect(
          vault.credential(CloudPlatform.ilanzou)!.field('accessToken'),
          renewedAccess,
        );
      },
    );
  });

  group('Weiyun', () {
    test(
      'QQ, WeChat and OpenID credentials produce the correct protocol authentication',
      () async {
        for (final fixture in [
          (_qqCookie, 0, 27),
          (
            'wy_uf=1; openid=wx-fixture; wy_appid=app; access_token=weixin-token; wyctoken=csrf',
            1,
            192,
          ),
          ('wy_uf=2; weiyun_qq_openid=qq-fixture; wyctoken=csrf', 3, 1540),
        ]) {
          expect(
            LoginCredentials.plausible(CloudPlatform.weiyun, fixture.$1),
            isTrue,
          );
          final vault = await _vault(
            CloudPlatform.weiyun,
            fields: {'primary': fixture.$1},
          );
          final http = LoginHttp((r) {
            final header = asJson(jsonDecode(r.json.str('req_header')));
            expect(header['user_flag'], fixture.$2);
            expect(header['cmd'], 2201);
            expect(
              _weiBody(
                r,
              ).obj('ext_req_head').obj('token_info')['login_key_type'],
              fixture.$3,
            );
            return _weiResponse({
              'uin': 12345,
              'main_dir_key': 'main-root',
              'nick_name': 'fixture',
              'total_space': 500,
              'used_space': 10,
            });
          });
          final account = await WeiyunConnector(
            http,
            vault,
            now: () => tokenClock,
          ).account(vault.credential(CloudPlatform.weiyun)!);
          expect(account.used, 10);
          expect(http.redirects, [false]);
        }
      },
    );

    test(
      'mixed folder/file pagination counts both types in the next offset',
      () async {
        final vault = await _vault(CloudPlatform.weiyun);
        final http = FakeHttp((r) {
          final start = _weiBody(
            r,
          ).obj('.weiyun.DiskDirListMsgReq_body').integer('start');
          expect(r.uri.path, '/webapp/json/weiyunQdisk/DiskDirList');
          return _weiResponse(
            start == 0
                ? {
                    'dir_list': [
                      {'dir_key': 'folder', 'dir_name': 'folder'},
                    ],
                    'file_list': [
                      {
                        'file_id': 'first',
                        'filename': 'first.mp4',
                        'file_size': 10,
                      },
                    ],
                    'finish_flag': false,
                    'pdir_key': 'upper',
                  }
                : {
                    'file_list': [
                      {
                        'file_id': 'second',
                        'filename': 'second.mp4',
                        'file_size': 20,
                      },
                    ],
                    'finish_flag': true,
                    'total_dir_count': 1,
                    'total_file_count': 2,
                  },
          );
        });
        final files = await WeiyunConnector(http, vault, now: () => tokenClock)
            .list(
              _personal(CloudPlatform.weiyun),
              'main-root',
              vault.credential(CloudPlatform.weiyun),
            );
        expect(files.map((f) => f.id), ['folder', 'first', 'second']);
        expect(
          _weiBody(
            http.calls.last,
          ).obj('.weiyun.DiskDirListMsgReq_body')['start'],
          2,
        );
      },
    );

    test('download carries only the file authorization cookie', () async {
      final vault = await _vault(CloudPlatform.weiyun);
      final http = FakeHttp((r) {
        expect(_weiBody(r).obj('.weiyun.DiskFileBatchDownloadMsgReq_body'), {
          'file_list': [
            {'pdir_key': 'main-root', 'file_id': 'file'},
          ],
          'download_type': 0,
        });
        return _weiResponse({
          'file_list': [
            {
              'retcode': 0,
              'download_url': 'https://cdn.example/video',
              'cookie_name': 'FTN',
              'cookie_value': 'file-only',
            },
          ],
        });
      });
      final spec = await WeiyunConnector(http, vault, now: () => tokenClock)
          .download(
            _personal(CloudPlatform.weiyun),
            const CloudFile(
              id: 'file',
              name: 'video.mp4',
              size: 123,
              parentId: 'main-root',
            ),
            vault.credential(CloudPlatform.weiyun),
          );
      expect(spec.headers['Cookie'], 'FTN=file-only');
      expect(
        spec.headers.values.join(),
        isNot(contains('fixture-login-cookie')),
      );
      expect(spec.expectedSize, 123);
    });

    test(
      'expired WeChat credentials refresh the token and CSRF without changing accounts',
      () async {
        const cookie =
            'wy_uf=1; openid=wx-fixture; wy_appid=app; access_token=old-weixin; refresh_token=old-refresh; wyctoken=old-csrf';
        final vault = await _vault(
          CloudPlatform.weiyun,
          fields: {'primary': cookie},
        );
        var queries = 0, touches = 0;
        final http = LoginHttp((r) {
          if (r.uri.host == 'api.weixin.qq.com') {
            expect(r.headers.containsKey('Cookie'), isFalse);
            return jsonResponse({
              'openid': 'wx-fixture',
              'access_token': 'new-weixin',
              'refresh_token': 'new-refresh',
            });
          }
          if (r.uri.path == '/disk') {
            touches++;
            return touches == 1
                ? const HttpResult(302, '')
                : const HttpResult(200, '<html>disk</html>', {
                    'set-cookie': [
                      'wyctoken=new-csrf; Domain=.weiyun.com; Path=/',
                    ],
                  });
          }
          queries++;
          if (queries == 1) return const HttpResult(403, 'expired');
          expect(r.uri.queryParameters['g_tk'], 'new-csrf');
          expect(r.headers['Cookie'], contains('access_token=new-weixin'));
          return _weiResponse({
            'dir_list': [],
            'file_list': [],
            'finish_flag': true,
          });
        });
        await WeiyunConnector(http, vault, now: () => tokenClock).list(
          _personal(CloudPlatform.weiyun),
          'main-root',
          vault.credential(CloudPlatform.weiyun),
        );
        expect(vault.credential(CloudPlatform.weiyun)!.updatedAt, 42);
        expect(
          vault.credential(CloudPlatform.weiyun)!.primary,
          contains('refresh_token=new-refresh'),
        );
        expect(
          http.calls.where((r) => r.uri.host == 'api.weixin.qq.com'),
          hasLength(1),
        );
      },
    );

    test('moving a folder to a descendant never sends a mutation', () async {
      final vault = await _vault(CloudPlatform.weiyun);
      final http = FakeHttp((r) {
        expect(r.uri.path, endsWith('/LibDirPathGet'));
        return _weiResponse({
          'items': [
            {'dir_key': 'parent'},
            {'dir_key': 'child', 'pdir_key': 'parent'},
          ],
        });
      });
      await expectLater(
        WeiyunConnector(http, vault, now: () => tokenClock).move(
          _personal(CloudPlatform.weiyun),
          [
            const CloudFile(
              id: 'parent',
              name: 'parent',
              isDirectory: true,
              parentId: 'main-root',
            ),
          ],
          'child',
          vault.credential(CloudPlatform.weiyun)!,
        ),
        throwsA(isA<AppException>()),
      );
      expect(http.calls, hasLength(1));
    });

    test(
      'empty and malformed account payloads cannot replace an existing login',
      () async {
        final vault = await _vault(CloudPlatform.weiyun),
            before = vault.credential(CloudPlatform.weiyun)!;
        final connector = WeiyunConnector(
          FakeHttp(
            (r) => r.uri.path == '/disk'
                ? const HttpResult(200, '', {
                    'set-cookie': ['wyctoken=new; Path=/'],
                  })
                : _weiResponse({}),
          ),
          vault,
          now: () => tokenClock,
        );
        final login = AccountLoginService(
          vault,
          (_, c) => connector.account(c),
          webAuthenticators: {CloudPlatform.weiyun: connector.authenticate},
        );
        await expectLater(
          login.submitWeb(CloudPlatform.weiyun, _qqCookie),
          throwsA(isA<AppException>()),
        );
        expect(vault.credential(CloudPlatform.weiyun)!.sameAs(before), isTrue);
      },
    );
  });

  group('Wopan', () {
    test(
      'AES CBC and request signing match independent Node crypto fixtures',
      () {
        expect(
          WopanProtocol.encrypt(
            {
              'refreshToken': refreshToken,
              'clientSecret': WopanProtocol.clientSecret,
            },
            'api-user',
            '',
          ),
          'r9J3oKWUtWa4ySsAo8AHDPNCtj8+F/9P+YeRkOB5np14tJoYrB8FptN1Bqtq7uQogtBREjfo6+xi6/VZFMPSczyxHDv88Pkz6HlUX0iECNO0knNUsj1olhE5i4Nvxft9',
        );
        expect(
          WopanProtocol.header(
            'api-user',
            'AppRefreshToken',
            tokenClock,
            100001,
          )['sign'],
          '5a2e8e80f8ffc78058bfa9e76792b3e6',
        );
        expect(
          () => WopanProtocol.decode('invalid', 'wohome', accessToken),
          throwsA(isA<AppException>()),
        );
      },
    );

    test(
      'a refresh-only login validates user and quota with the correct channel keys',
      () async {
        final vault = await _vault(CloudPlatform.wopan),
            before = vault.credential(CloudPlatform.wopan)!;
        final http = LoginHttp((r) {
          final name = r.json.obj('header').str('key'), param = _woParam(r);
          if (name == 'AppRefreshToken') {
            expect(param, {
              'refreshToken': refreshToken,
              'clientSecret': WopanProtocol.clientSecret,
            });
          }
          if (name == 'AppQueryUser') {
            expect(param['accessToken'], renewedAccess);
          }
          if (name == 'QueryCloudUsageInfo') expect(param['phoneNum'], '12345');
          return _woDefault(r);
        });
        final result = await WopanConnector(http, vault, now: () => tokenClock)
            .authenticate(
              LoginCredentials.candidate(
                CloudPlatform.wopan,
                refreshToken,
                null,
              ),
            );
        expect(result.credential.field('refreshToken'), renewedRefresh);
        expect(result.credential.primary, renewedRefresh);
        expect(result.account.total, 2000);
        expect(vault.credential(CloudPlatform.wopan)!.sameAs(before), isTrue);
        expect(http.redirects, everyElement(isFalse));
      },
    );

    test(
      'download uses fid rather than the file-list id and refuses another file URL',
      () async {
        final vault = await _vault(CloudPlatform.wopan);
        var wrong = false;
        final http = FakeHttp((r) {
          expect(r.json.obj('header')['key'], 'GetDownloadUrlV2');
          expect(_woParam(r)['fidList'], ['download-fid']);
          return _woResponse(r, {
            'list': [
              {
                'fid': wrong ? 'another-fid' : 'download-fid',
                'downloadUrl': 'https://cdn.example/video',
              },
            ],
          });
        });
        final connector = WopanConnector(http, vault, now: () => tokenClock);
        const file = CloudFile(
          id: 'list-id',
          name: 'video.mp4',
          size: 123,
          token: '{"fid":"download-fid"}',
        );
        final spec = await connector.download(
          _personal(CloudPlatform.wopan),
          file,
          vault.credential(CloudPlatform.wopan),
        );
        expect(spec.expectedSize, 123);
        expect(spec.headers.containsKey('Accesstoken'), isFalse);
        wrong = true;
        await expectLater(
          connector.download(
            _personal(CloudPlatform.wopan),
            file,
            vault.credential(CloudPlatform.wopan),
          ),
          throwsA(isA<AppException>()),
        );
      },
    );

    test(
      'concurrent expiration performs one refresh and keeps queued downloads bound to the revision',
      () async {
        final vault = await _vault(
          CloudPlatform.wopan,
          fields: {'expiresAt': '${tokenClock - 1}'},
        );
        var refreshes = 0;
        final http = FakeHttp((r) {
          if (r.json.obj('header')['key'] == 'AppRefreshToken') refreshes++;
          return _woDefault(r);
        });
        final connector = WopanConnector(http, vault, now: () => tokenClock),
            credential = vault.credential(CloudPlatform.wopan)!;
        await Future.wait([
          connector.list(_personal(CloudPlatform.wopan), '0', credential),
          connector.list(_personal(CloudPlatform.wopan), '0', credential),
        ]);
        expect(refreshes, 1);
        expect(vault.credential(CloudPlatform.wopan)!.updatedAt, 42);
      },
    );

    test(
      'account removal while refresh is pending prevents late token restoration',
      () async {
        final vault = await _vault(
          CloudPlatform.wopan,
          fields: {'expiresAt': '${tokenClock - 1}'},
        );
        final delayed = Completer<HttpResult>();
        late RecordedRequest request;
        final http = FakeHttp((r) {
          request = r;
          return delayed.future;
        });
        final pending = WopanConnector(http, vault, now: () => tokenClock).list(
          _personal(CloudPlatform.wopan),
          '0',
          vault.credential(CloudPlatform.wopan),
        );
        final failure = expectLater(
          pending,
          throwsA(isA<AccountLoginRequired>()),
        );
        await Future<void>.delayed(Duration.zero);
        await vault.removeCredential(CloudPlatform.wopan);
        delayed.complete(_woDefault(request));
        await failure;
        expect(vault.credential(CloudPlatform.wopan), isNull);
        expect(http.calls, hasLength(1));
      },
    );

    test(
      'family listing includes the selected family and cannot mutate its files',
      () async {
        final vault = await _vault(CloudPlatform.wopan);
        final http = FakeHttp(_woDefault),
            connector = WopanConnector(http, vault, now: () => tokenClock),
            c = vault.credential(CloudPlatform.wopan)!;
        final spaces = await connector.familySpaces(c);
        final family = await connector.openFamily(spaces.single, c);
        await connector.list(family, '0', c);
        expect(_woParam(http.calls.last)['familyId'], '123');
        expect(_woParam(http.calls.last)['spaceType'], '1');
        final count = http.calls.length;
        await expectLater(
          connector.delete(family, [
            const CloudFile(id: 'file', name: 'file'),
          ], c),
          throwsA(isA<AppException>()),
        );
        expect(http.calls, hasLength(count));
      },
    );

    test(
      'file mutations separate directory and file IDs and do not use the download fid',
      () async {
        final vault = await _vault(CloudPlatform.wopan);
        final http = FakeHttp(_woDefault),
            connector = WopanConnector(http, vault, now: () => tokenClock),
            c = vault.credential(CloudPlatform.wopan)!;
        final files = [
          const CloudFile(id: 'directory', name: 'dir', isDirectory: true),
          const CloudFile(
            id: 'list-file',
            name: 'video.mp4',
            token: '{"fid":"download-fid"}',
          ),
        ];
        await connector.move(
          _personal(CloudPlatform.wopan),
          files,
          'target',
          c,
        );
        expect(_woParam(http.calls.last)['dirList'], ['directory']);
        expect(_woParam(http.calls.last)['fileList'], ['list-file']);
        await connector.delete(_personal(CloudPlatform.wopan), files, c);
        expect(_woParam(http.calls.last)['spaceType'], '0');
        expect(_woParam(http.calls.last)['fileList'], ['list-file']);
        await connector.rename(
          _personal(CloudPlatform.wopan),
          files.last,
          'new.mp4',
          c,
        );
        expect(_woParam(http.calls.last)['fileType'], '1');
        expect(_woParam(http.calls.last)['id'], 'list-file');
        final folder = await connector.createFolder(
          _personal(CloudPlatform.wopan),
          '0',
          'new',
          c,
        );
        expect(folder.id, 'new-folder');
        expect(_woParam(http.calls.last)['familyId'], '123');
      },
    );
  });
}
