import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/providers/baidu.dart';
import 'package:asterlink/data/providers/quark.dart';
import 'package:asterlink/data/providers/uc.dart';
import 'package:asterlink/data/providers/pan123.dart';
import 'package:asterlink/data/providers/c139.dart';
import 'package:asterlink/data/providers/xunlei.dart';
import 'package:asterlink/data/providers/xunlei_protocol.dart';
import 'package:asterlink/data/providers/xunlei_login.dart';
import 'support.dart';

BrowseSession personal(CloudPlatform p) => BrowseSession(
  platform: p,
  mode: BrowseMode.personal,
  title: 'fixture',
  rootId: '0',
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [CloudPlatform.quark, CloudPlatform.uc]) {
    test(
      '${platform.key} list, rename, move and delete retain request contracts',
      () async {
        var name = 'one.zip';
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('file/rename')) {
            name = r.json.str('file_name');
          }
          return jsonResponse({
            'status': 200,
            'code': 0,
            'data': r.uri.path.endsWith('file/sort')
                ? {
                    'list': [
                      {
                        'fid': 'file-1',
                        'file_name': name,
                        'size': 123,
                        'pdir_fid': 'parent',
                        'dir': false,
                      },
                      {'fid': 'folder-2', 'file_name': 'folder', 'dir': true},
                    ],
                  }
                : {},
          });
        });
        final c = Credential('fixture', {'primary': '__pus=a; __puus=b'});
        final connector = platform == CloudPlatform.uc
                ? UcConnector(http, taskDelay: Duration.zero)
                : QuarkConnector(http, taskDelay: Duration.zero),
            session = personal(platform);
        final files = await connector.list(session, 'parent', c);
        expect(files.length, 2);
        expect(files.last.isDirectory, isTrue);
        expect(
          http.calls.first.uri.host,
          platform == CloudPlatform.quark
              ? 'drive-pc.quark.cn'
              : 'pc-api.uc.cn',
        );
        expect(
          http.calls.first.uri.queryParameters['_size'],
          platform == CloudPlatform.quark ? '100' : '50',
        );
        expect(http.calls.first.headers['Cookie'], c.primary);
        await connector.rename(session, files.first, 'new.zip', c);
        expect(
          http.calls
              .where((r) => r.uri.path.endsWith('file/rename'))
              .single
              .json,
          {'fid': 'file-1', 'file_name': 'new.zip'},
        );
        await connector.move(session, files, 'target', c);
        final move = http.calls
            .where((r) => r.uri.path.endsWith('file/move'))
            .single;
        expect(move.json['to_pdir_fid'], 'target');
        expect(move.json['filelist'], ['file-1', 'folder-2']);
        await connector.delete(session, files, c);
        expect(http.calls.last.json['action_type'], 2);
        expect(http.calls.last.json['exclude_fids'], isEmpty);
      },
    );
  }
  test('UC shared directories use the transfer endpoint and origin', () async {
    final http = FakeHttp(
      (_) => jsonResponse({
        'status': 200,
        'data': {'list': []},
      }),
    );
    final connector = UcConnector(http);
    await connector.list(
      const BrowseSession(
        platform: CloudPlatform.uc,
        mode: BrowseMode.share,
        title: 'x',
        rootId: '0',
        metadata: {'shareId': 'share', 'stoken': 'token'},
      ),
      'parent',
      null,
    );
    final request = http.calls.single;
    expect(request.uri.path, '/1/clouddrive/transfer_share/detail');
    expect(request.uri.queryParameters['entry'], 'ft');
    expect(request.uri.queryParameters['pdir_fid'], 'parent');
    expect(request.headers['Origin'], 'https://fast.uc.cn');
  });
  test(
    'Baidu navigation retains fs_id for operations and full path for directory traversal',
    () async {
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('/gettemplatevariable')) {
          return jsonResponse({
            'errno': 0,
            'result': {'bdstoken': 'token'},
          });
        }
        if (r.uri.path.endsWith('/list')) {
          return jsonResponse({
            'errno': 0,
            'list': [
              {
                'fs_id': 12345,
                'path': '/docs',
                'server_filename': 'docs',
                'isdir': 1,
              },
            ],
          });
        }
        return jsonResponse({'errno': 0});
      });
      final c = Credential('fixture', {
            'primary': 'BDUSS=fixture',
            'appId': '12345',
          }),
          connector = BaiduConnector(http);
      final files = await connector.list(personal(CloudPlatform.baidu), '/', c);
      expect(files.single.id, '12345');
      expect(files.single.token, '/docs');
      await connector.rename(
        personal(CloudPlatform.baidu),
        files.single,
        'new-docs',
        c,
      );
      final request = http.calls.last;
      expect(request.uri.path, '/api/filemanager');
      expect(request.uri.queryParameters['opera'], 'rename');
      expect(
        jsonDecode(Uri.splitQueryString(request.body as String)['filelist']!),
        [
          {'path': '/docs', 'newname': 'new-docs'},
        ],
      );
    },
  );
  test(
    '123 uses web Token ahead of password and preserves cursor pagination and MD5',
    () async {
      final store = StateStore.memory(), vault = Vault(store);
      final http = FakeHttp((r) {
        final next = r.uri.queryParameters['next'];
        return jsonResponse({
          'code': 0,
          'data': {
            'Next': next == '0' ? 'page-2' : '-1',
            'InfoList': [
              {
                'FileId': next == '0' ? 1 : 2,
                'FileName': 'file.zip',
                'Size': 42,
                'Type': 0,
                'Etag': '0123456789abcdef0123456789abcdef',
              },
            ],
          },
        });
      });
      final c = Credential('fixture', {
        'primary': 'token',
        'authType': 'webToken',
        'secondary': 'unused',
      });
      final files = await Pan123Connector(
        http,
        vault,
      ).list(personal(CloudPlatform.pan123), '77', c);
      expect(files.length, 2);
      expect(files.first.hashType, 'md5');
      expect(http.calls.length, 2);
      expect(
        http.calls.every((r) => r.headers['authorization'] == 'Bearer token'),
        isTrue,
      );
      expect(http.calls.last.uri.queryParameters['next'], 'page-2');
      expect(http.calls.last.uri.queryParameters['parentFileId'], '77');
      expect(http.calls.first.headers['auth-key'], isNotEmpty);
    },
  );
  test(
    '123 candidate password authentication cannot validate the previous account token',
    () async {
      final store = StateStore.memory(), vault = Vault(store);
      await vault.putCredential(
        CloudPlatform.pan123,
        Credential('old', {
          'primary': 'old-user',
          'secondary': 'old-password',
        }, updatedAt: 1),
      );
      await vault.putSecret('pan123.access_token', 'old-token');
      final http = FakeHttp(
        (r) => r.uri.path.endsWith('/sign_in')
            ? jsonResponse({
                'code': 200,
                'data': {'token': 'new-token'},
              })
            : jsonResponse({
                'code': 0,
                'data': {
                  'Nickname': 'new-user',
                  'SpaceUsed': 4,
                  'SpacePermanent': 100,
                  'SpaceTemp': 0,
                },
              }),
      );
      final result = await Pan123Connector(http, vault).authenticate(
        Credential('new', {'primary': 'new-user', 'secondary': 'new-password'}),
      );
      expect(result.account.nickname, 'new-user');
      expect(http.calls.first.uri.path, '/api/user/sign_in');
      expect(http.calls.last.headers['authorization'], 'Bearer new-token');
      expect(vault.secret('pan123.access_token'), 'old-token');
    },
  );
  test(
    'C139 personal listing keeps Authorization, signature and cursor envelope',
    () async {
      final http = FakeHttp(
        (_) => jsonResponse({
          'code': '0000',
          'data': {
            'items': [
              {'fileId': 'a', 'name': 'docs', 'type': 'folder'},
            ],
          },
        }),
      );
      final c = Credential('fixture', {
        'primary': 'skey=test',
        'authorization': 'Basic fixture',
      });
      final files = await C139Connector(
        http,
      ).list(personal(CloudPlatform.c139), 'root', c);
      expect(files.single.isDirectory, isTrue);
      final request = http.calls.single;
      expect(request.uri.path, '/hcy/file/list');
      expect(request.headers['Authorization'], 'Basic fixture');
      expect(request.headers['mcloud-sign']!.split(',').length, 3);
      expect(request.json['parentFileId'], 'root');
      expect(request.json.obj('pageInfo')['pageCursor'], isNull);
    },
  );
  test(
    'C139 anonymous shares encrypt the protocol body without leaking account authorization',
    () async {
      final http = FakeHttp(
        (_) => jsonResponse({
          'code': '0000',
          'data': {
            'caLst': [],
            'coLst': [
              {'coID': 'a', 'coName': 'file.zip', 'coSize': 4},
            ],
          },
        }),
      );
      final files = await C139Connector(http).list(
        const BrowseSession(
          platform: CloudPlatform.c139,
          mode: BrowseMode.share,
          title: 'fixture',
          rootId: 'root',
          metadata: {'linkId': 'share-id', 'password': 'a123'},
        ),
        'root',
        null,
      );
      expect(files.single.name, 'file.zip');
      final request = http.calls.single;
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(request.body.toString().contains('share-id'), isFalse);
      final plain = asJson(
        jsonDecode(C139Protocol.decrypt(request.body as String)),
      );
      expect(plain.obj('getOutLinkInfoReq').str('linkID'), 'share-id');
      expect(plain.obj('getOutLinkInfoReq').str('passwd'), 'a123');
    },
  );
  test(
    'Xunlei personal downloads preserve repeated with parameters and checksum fields',
    () async {
      final store = StateStore.memory(), vault = Vault(store);
      final http = FakeHttp(
        (_) => jsonResponse({
          'id': 'file',
          'name': 'test.zip',
          'size': 4,
          'web_content_link': 'https://example.com/file',
        }),
      );
      final c = Credential('fixture', {
        'primary': 'access',
        'deviceId': 'device',
      });
      final result = await XunleiConnector(http, vault, XunleiDevices(vault))
          .download(
            personal(CloudPlatform.xunlei),
            const CloudFile(
              id: 'file',
              name: 'test.zip',
              size: 4,
              hashType: 'md5',
              hashValue: '0123456789abcdef0123456789abcdef',
            ),
            c,
          );
      expect(http.calls.single.uri.queryParametersAll['with'], [
        'hdr10',
        'subtitle_files',
        'task',
        'public_share_tag',
      ]);
      expect(http.calls.single.headers['Authorization'], 'Bearer access');
      expect(result.url, 'https://example.com/file');
      expect(result.checksumType, 'md5');
    },
  );
  test(
    'Xunlei password login exchanges sessionID, signs captcha and does not remember passwords unless enabled',
    () async {
      final store = StateStore.memory({
            'secrets': {
              'xunlei.device_id': '00000000000000000000000000000000',
              'xunlei.peer_id': '11111111111111111111111111111111',
            },
          }),
          vault = Vault(store);
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('/v3/login')) {
          return jsonResponse({
            'errorCode': 0,
            'sessionID': 'session-id',
            'userID': 'user-123',
            'nickName': 'Test user',
          });
        }
        if (r.uri.path.endsWith('/captcha/init')) {
          return jsonResponse({'captcha_token': 'captcha-token'});
        }
        return jsonResponse({
          'access_token': 'access-token',
          'refresh_token': 'refresh-token',
        });
      });
      final result = await XunleiLoginService(
        http,
        XunleiDevices(vault),
        now: () => 1700000000000,
      ).password('test@example.com', 'fixture-password');
      expect(http.calls[0].json['clientVersion'], '25.0.5.25');
      expect(http.calls[0].json['sdkVersion'], '513006');
      expect(
        http.calls[1].json.obj('meta')['captcha_sign'],
        '1.a388fee14ed707a34724ff836a3267de',
      );
      expect(http.calls[2].json['signin_token'], 'session-id');
      expect(http.calls[2].headers['X-Captcha-Token'], 'captcha-token');
      expect(result.credential.field('accessToken'), 'access-token');
      expect(result.credential.field('password'), isEmpty);
      expect(jsonEncode(store.data).contains('fixture-password'), isFalse);
      expect(
        jsonEncode(result.credential.toJson()).contains('session-id'),
        isFalse,
      );
    },
  );
  test(
    'Xunlei review challenges only expose trusted URLs and decoded challenge tokens',
    () async {
      final vault = Vault(StateStore.memory());
      for (final url in [
        'https://i.xunlei.com/verify?creditkey=a%2Bb&token=t',
        'https://i.xunlei.com.evil.test/?creditkey=x',
      ]) {
        final http = FakeHttp(
          (_) => jsonResponse({'errorCode': 1007, 'reviewurl': url}),
        );
        try {
          await XunleiLoginService(
            http,
            XunleiDevices(vault),
          ).password('test', 'fixture');
          fail('challenge expected');
        } on XunleiVerificationRequired catch (e) {
          expect(e.url, url.contains('evil') ? '' : url);
          expect(e.creditKey, url.contains('evil') ? '' : 'a+b');
        }
      }
    },
  );
  test(
    'Source refresh rejects changed accounts, missing files and changed content before resolution',
    () async {
      final store = StateStore.memory(),
          vault = Vault(store),
          http = FakeHttp();
      final c = Credential('fixture', {'primary': 'token'}, updatedAt: 1);
      await vault.putCredential(CloudPlatform.quark, c);
      final repository = CloudRepository(
            http,
            vault,
            CleanupOutbox(store, http),
          ),
          connector = _SourceConnector();
      repository.connectors[CloudPlatform.quark] = connector;
      const file = CloudFile(id: 'f', name: 'f.zip', size: 4, parentId: '0');
      final spec = DownloadSpec(
        url: 'https://example.com/old',
        fileName: 'f.zip',
        source: DownloadOrigin(personal(CloudPlatform.quark), file, 1).toJson(),
      );
      await vault.putCredential(
        CloudPlatform.quark,
        Credential('other', {'primary': 'other'}, updatedAt: 2),
      );
      await expectLater(repository.refresh(spec), throwsA(isA<AppException>()));
      expect(connector.lists, 0);
      expect(connector.opens, 0);
      await vault.putCredential(CloudPlatform.quark, c);
      connector.result = [];
      await expectLater(repository.refresh(spec), throwsA(isA<AppException>()));
      connector.result = [
        const CloudFile(id: 'f', name: 'f.zip', size: 5, parentId: '0'),
      ];
      await expectLater(repository.refresh(spec), throwsA(isA<AppException>()));
      expect(connector.resolves, 0);
      connector.result = [file];
      final fresh = await repository.refresh(spec);
      expect(fresh.url, 'https://example.com/new');
      expect(fresh.source!['accountRevision'], 1);
      expect(connector.resolves, 1);
      expect(connector.opens, 3);
    },
  );
}

class _SourceConnector implements CloudConnector {
  @override
  final platform = CloudPlatform.quark;
  int opens = 0, lists = 0, resolves = 0;
  List<CloudFile> result = [];
  @override
  Future<BrowseSession> openPersonal(Credential credential) async {
    opens++;
    return personal(platform);
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async {
    lists++;
    return result;
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    resolves++;
    return const DownloadSpec(
      url: 'https://example.com/new',
      fileName: 'f.zip',
      expectedSize: 4,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
