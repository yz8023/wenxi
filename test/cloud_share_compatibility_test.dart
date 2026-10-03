import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/aliyun.dart';
import 'package:asterlink/data/providers/guangya.dart';
import 'package:asterlink/data/providers/wopan.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/platform/clipboard_links.dart';
import 'native_login_support.dart';
import 'support.dart';
import 'token_cloud_support.dart';

// Independent AES-CBC fixture produced with Python cryptography. The decoded
// array contains a file with an fid and a directory using the fileId alias.
const _encryptedShare =
    'EL3pZgDN1drs1cfusgDsI4b7G8bSlZx6c5UP6um0hH+D51O06R4sRx0WQX/4aRLRmoBkubiS35XB8YAEx/6oeXfI4DN+wCT0OjfsBP5AIiboJxPcz35k+ACd/3TChSJA58urzgr6O/zU+t4qKSSJ7JXqM6dowFMm8kAKBXTehjFmfB3OEHNBshJoAd4meMef1fcb7178FAk2b4yQDgwJFVMDwmLjp2RDZ+2KaihDvYP56dkp+FOIMxShDneVdQxU';
const _short = 'https://pan.wo.cn/s/1TEST123456';
const _shortService = 'https://panservice.mail.wo.cn/s/1TEST123456';
const _full =
    'https://panservice.mail.wo.cn/h5/wocloudshare/?clientId=1001000035&shareId=0123456789abcdef0123456789abcdef&shareCode=Te5t';
HttpResult _wo(Object? data, {String code = '0000', String message = ''}) =>
    jsonResponse({
      'STATUS': '200',
      'RSP': {'RSP_CODE': code, 'RSP_DESC': message, 'DATA': data},
    });

void main() {
  group('Guangya current share response', () {
    for (final emptyMiddle in [false, true]) {
      test(
        'numeric cursors tolerate filtered entries: empty=$emptyMiddle',
        () async {
          const platform = CloudPlatform.guangya;
          final vault = await tokenVault(platform);
          final seen = <Object?>[];
          final http = FakeHttp((r) {
            expect(r.headers.containsKey('Authorization'), isFalse);
            if (r.uri.path.endsWith('get_share_access_token')) {
              return guangyaResponse({'accessToken': 'public-share-token'});
            }
            expect(r.uri.path, '/userres/v1/get_share_page_files_list');
            expect(r.json.containsKey('hasMore'), isFalse);
            seen.add(r.json['cursor']);
            final cursor = r.json.integer('cursor');
            final next = cursor + 100;
            return jsonResponse({
              'msg': 'success',
              'data': {
                'total': emptyMiddle ? 205 : 5,
                'cursor': next,
                'list': [
                  if (!emptyMiddle || cursor != 100)
                    for (var i = 0; i < (emptyMiddle ? 1 : 4); i++)
                      {
                        'fileId': 'file-$cursor-$i',
                        'fileName': 'movie.mp4',
                        'resType': 1,
                        'dirType': 1,
                        'fileSize': 564090134,
                        'ctime': 1730000000,
                        'utime': 1769000748,
                      },
                ],
              },
            });
          });
          final files = await GuangyaConnector(
            http,
            vault,
            now: () => tokenClock,
          ).list(tokenShare(platform), 'root', null);
          expect(files, hasLength(emptyMiddle ? 2 : 4));
          expect(seen, emptyMiddle ? [null, 100, 200] : [null]);
          expect(files.first.isDirectory, isFalse);
          expect(files.first.size, 564090134);
          expect(
            DateTime.parse(files.first.modifiedAt).millisecondsSinceEpoch,
            1769000748000,
          );
        },
      );
    }

    test('a repeated numeric cursor fails instead of looping', () async {
      const platform = CloudPlatform.guangya;
      final vault = await tokenVault(platform);
      final http = FakeHttp(
        (r) => r.uri.path.endsWith('get_share_access_token')
            ? guangyaResponse({'accessToken': 'public-share-token'})
            : guangyaResponse({'total': 205, 'cursor': 100, 'list': []}),
      );
      await expectLater(
        GuangyaConnector(
          http,
          vault,
          now: () => tokenClock,
        ).list(tokenShare(platform), 'root', null),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'reason',
            contains('分页异常'),
          ),
        ),
      );
      expect(http.calls, hasLength(3));
    });

    for (final assets in <Json>[
      {},
      {'totalSpaceSize': null, 'usedSpaceSize': 0},
      {'totalSpaceSize': 'invalid', 'usedSpaceSize': 0},
      {'totalSpaceSize': 1024, 'usedSpaceSize': -1},
    ]) {
      test(
        'missing or invalid independent quota cannot become zero: $assets',
        () async {
          const platform = CloudPlatform.guangya;
          final vault = await tokenVault(platform);
          final http = FakeHttp(
            (r) => r.uri.path == '/v1/user/me'
                ? jsonResponse({
                    'sub': 'user-1',
                    'nickname': 'fixture',
                    'total_size': 999,
                  })
                : guangyaResponse(assets),
          );
          await expectLater(
            GuangyaConnector(
              http,
              vault,
              now: () => tokenClock,
            ).account(vault.credential(platform)!),
            throwsA(
              isA<AppException>().having(
                (e) => e.message,
                'reason',
                contains('容量信息'),
              ),
            ),
          );
        },
      );
    }

    test(
      'official code 207 requests login for an anonymous download',
      () async {
        const platform = CloudPlatform.guangya;
        final vault = await tokenVault(platform);
        final http = FakeHttp(
          (r) => r.uri.path.endsWith('get_share_access_token')
              ? guangyaResponse({'accessToken': 'public-share-token'})
              : guangyaResponse({}, code: 207, message: '分享者未开启免登录下载'),
        );
        await expectLater(
          GuangyaConnector(
            http,
            vault,
            now: () => tokenClock,
          ).download(tokenShare(platform), tokenFile, null),
          throwsA(isA<AccountLoginRequired>()),
        );
      },
    );
  });

  group('Wopan public shares', () {
    test(
      'public short links use the official share service and retain query data',
      () async {
        for (final scheme in ['http', 'https']) {
          final vault = await tokenVault(CloudPlatform.wopan);
          final http = FakeHttp((r) {
            if (r.method == 'GET') {
              expect(
                r.url,
                'https://panservice.mail.wo.cn/s/1F1t6r76400?from=copy',
              );
              expect(r.headers.containsKey('Accesstoken'), isFalse);
              expect(r.headers.containsKey('Cookie'), isFalse);
              return const HttpResult(302, '', {
                'location': [_full],
              });
            }
            return _wo(_encryptedShare);
          });
          final link = LinkParser.parse(
            '$scheme://pan.wo.cn/s/1F1t6r76400?from=copy',
          ).single.withPasscode('manual');
          final share = await WopanConnector(http, vault).openShare(link, null);
          expect(share.meta('passcode'), 'manual');
          expect(share.sourceLink!.url, link.url);
          expect(http.calls.where((r) => r.method == 'GET'), hasLength(1));
        }
      },
    );

    test(
      'short-link resolution retries a transient response before following the official redirect',
      () async {
        final vault = await tokenVault(CloudPlatform.wopan);
        var redirects = 0;
        final http = FakeHttp((r) {
          if (r.method == 'GET') {
            redirects++;
            expect(r.url, _shortService);
            if (redirects == 1) return const HttpResult(503, '');
            return const HttpResult(302, '', {
              'location': [_full],
            });
          }
          return _wo(_encryptedShare);
        });
        final share = await WopanConnector(
          http,
          vault,
          now: () => tokenClock,
        ).openShare(LinkParser.parse(_short).single, null);
        expect(share.rootId, '0');
        expect(redirects, 2);
        expect(http.calls.where((r) => r.method == 'POST'), hasLength(1));
      },
    );

    test('short, full and hash URLs retain share codes and capabilities', () {
      for (final url in [
        _short,
        _full,
        'https://pan.wo.cn/#/share_code?shareId=Share123&shareCode=a123',
      ]) {
        final parsed = LinkParser.parse(url).single;
        expect(parsed.platform, CloudPlatform.wopan);
        expect(parsed.kind, LinkKind.cloudShare);
        expect(parsed.platform!.supportsShareParsing, isTrue);
        expect(parsed.platform!.supportsSharing, isFalse);
        expect(parsed.platform!.shareRequiresAccount, isFalse);
        expect(
          ClipboardLinkSuggestion.fromText(url)!.label,
          isNot(contains('暂不支持')),
        );
      }
      expect(LinkParser.parse(_full).single.passcode, 'Te5t');
    });

    for (final manual in [false, true]) {
      test(
        'redirect, encrypted array and explicit code: manual=$manual',
        () async {
          final vault = await tokenVault(CloudPlatform.wopan);
          final http = LoginHttp((r) {
            expect(r.headers.containsKey('Accesstoken'), isFalse);
            expect(r.headers.containsKey('Cookie'), isFalse);
            if (r.method == 'GET') {
              expect(r.url, _shortService);
              return const HttpResult(302, '', {
                'location': [_full],
              });
            }
            expect(r.uri.path, '/wohome/dispatcher');
            expect(r.json.obj('header').str('channel'), '100002');
            expect(r.json.obj('header').str('key'), 'ShareFileDetail');
            final body = r.json.obj('body');
            expect(body['clientId'], '1001000035');
            expect(body['secretType'], 'ClientSecret');
            expect(WopanProtocol.decode(body['param'], 'api-user', ''), {
              'shareId': '0123456789abcdef0123456789abcdef',
              'shareCode': manual ? 'z999' : 'Te5t',
            });
            return _wo(_encryptedShare);
          });
          final connector = WopanConnector(http, vault, now: () => tokenClock);
          final link = LinkParser.parse(_short).single;
          final share = await connector.openShare(
            manual ? link.withPasscode('z999') : link,
            null,
          );
          final files = await connector.list(share, share.rootId, null);
          expect(share.rootId, '0');
          expect(files.map((f) => f.id), ['file-a', 'folder-b']);
          expect(files.first.isDirectory, isFalse);
          expect(files.first.size, 100);
          expect(files.first.modifiedAt, '2026-09-20 12:30:45');
          expect(files.last.isDirectory, isTrue);
          expect(http.redirects.first, isFalse);
          await expectLater(
            connector.list(share, 'folder-b', null),
            throwsA(isA<AccountLoginRequired>()),
          );
          await expectLater(
            connector.download(share, files.first, null),
            throwsA(isA<AccountLoginRequired>()),
          );
          expect(http.calls, hasLength(3));
        },
      );
    }

    test(
      'logged-in child listings and download use the share id and exact fid',
      () async {
        const p = CloudPlatform.wopan;
        final vault = await tokenVault(p);
        final http = FakeHttp((r) {
          final key = r.json.obj('header').str('key');
          if (key == 'ShareFileDetail') return _wo(_encryptedShare);
          expect(r.headers['Accesstoken'], accessToken);
          final param = WopanProtocol.decode(
            r.json.obj('body')['param'],
            'wohome',
            accessToken,
          );
          Json result;
          if (key == 'QueryShareFiles') {
            expect(param, {
              'directoryId': 'folder-b',
              'id': '0123456789abcdef0123456789abcdef',
              'clientId': '1001000021',
            });
            result = {
              'files': [
                {
                  'id': 'child',
                  'name': 'child.mp4',
                  'size': 80,
                  'type': 1,
                  'fid': 'child-fid',
                },
              ],
            };
          } else {
            expect(key, 'GetDownloadUrlV2');
            expect(param['fidList'], ['child-fid']);
            result = {
              'list': [
                {
                  'fid': 'unrelated-fid',
                  'downloadUrl': 'https://cdn.example/wrong',
                },
                {
                  'fid': 'child-fid',
                  'downloadUrl': 'https://cdn.example/child?sign=a%2Bb',
                },
              ],
            };
          }
          return _wo(WopanProtocol.encrypt(result, 'wohome', accessToken));
        });
        final connector = WopanConnector(http, vault, now: () => tokenClock);
        final share = await connector.openShare(
          LinkParser.parse(_full).single,
          null,
        );
        final files = await connector.list(
          share,
          'folder-b',
          vault.credential(p),
        );
        final download = await connector.download(
          share,
          files.single,
          vault.credential(p),
        );
        expect(download.url, 'https://cdn.example/child?sign=a%2Bb');
        expect(download.expectedSize, 80);
        expect(download.headers.keys, isNot(contains('Accesstoken')));
        expect(download.headers.keys, isNot(contains('Cookie')));
      },
    );

    test('the official deleted-share response is preserved', () async {
      final vault = await tokenVault(CloudPlatform.wopan);
      final http = FakeHttp((_) => _wo('', code: '130013', message: '分享文件已删除'));
      await expectLater(
        WopanConnector(
          http,
          vault,
          now: () => tokenClock,
        ).openShare(LinkParser.parse(_full).single, null),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'reason',
            contains('分享文件已删除'),
          ),
        ),
      );
    });

    for (final destination in [
      'https://untrusted.invalid/share?shareId=bad',
      'https://pan.wo.cn.attacker.invalid/s/next',
      'https://user@pan.wo.cn/s/next',
      'https://pan.wo.cn:8443/s/next',
      _short,
    ]) {
      test('short-link redirect cannot escape or loop: $destination', () async {
        final vault = await tokenVault(CloudPlatform.wopan);
        final http = FakeHttp(
          (_) => HttpResult(302, '', {
            'location': [destination],
          }),
        );
        await expectLater(
          WopanConnector(
            http,
            vault,
            now: () => tokenClock,
          ).openShare(LinkParser.parse(_short).single, null),
          throwsA(isA<AppException>()),
        );
        expect(http.calls, hasLength(1));
      });
    }

    test('a URL embedded as the fragment is not a share route', () async {
      final vault = await tokenVault(CloudPlatform.wopan);
      final http = FakeHttp((r) {
        expect(r.method, 'GET');
        return const HttpResult(200, '<html></html>');
      });
      final link = LinkParser.parse(
        'https://pan.wo.cn/#//untrusted.invalid/?shareId=Injected',
      ).single;
      await expectLater(
        WopanConnector(
          http,
          vault,
          now: () => tokenClock,
        ).openShare(link, null),
        throwsA(isA<AppException>()),
      );
    });
  });

  group('Aliyun original-file download', () {
    for (final key in ['download_url', 'cdn_url', 'url']) {
      test('dedicated $key works without requesting file details', () async {
        const p = CloudPlatform.aliyun;
        final vault = await tokenVault(p);
        final http = FakeHttp((r) {
          expect(r.uri.path, '/v2/file/get_download_url');
          return jsonResponse({
            'file_id': tokenFile.id,
            'size': 4,
            key: 'https://cdn.example/original',
          });
        });
        final spec = await AliyunConnector(
          http,
          vault,
          now: () => tokenClock,
        ).download(tokenPersonal(p), tokenFile, vault.credential(p));
        expect(spec.url, 'https://cdn.example/original');
        expect(http.calls, hasLength(1));
      });
    }

    test(
      'an invalid primary address cannot hide a usable CDN candidate',
      () async {
        const p = CloudPlatform.aliyun;
        final vault = await tokenVault(p);
        final http = FakeHttp(
          (_) => jsonResponse({
            'download_url': 'https://cdn.example/bad\nheader',
            'cdn_url': 'https://cdn.example/original',
          }),
        );
        final spec = await AliyunConnector(
          http,
          vault,
          now: () => tokenClock,
        ).download(tokenPersonal(p), tokenFile, vault.credential(p));
        expect(spec.url, 'https://cdn.example/original');
        expect(http.calls, hasLength(1));
      },
    );

    test(
      'only an unavailable endpoint falls back to an explicit original URL',
      () async {
        const p = CloudPlatform.aliyun;
        final vault = await tokenVault(p);
        final http = FakeHttp(
          (r) => r.uri.path == '/v2/file/get_download_url'
              ? const HttpResult(404, '<html>not found</html>')
              : jsonResponse({
                  'file_id': tokenFile.id,
                  'size': 4,
                  'download_url': 'https://cdn.example/original',
                }),
        );
        final spec = await AliyunConnector(
          http,
          vault,
          now: () => tokenClock,
        ).download(tokenPersonal(p), tokenFile, vault.credential(p));
        expect(spec.url, 'https://cdn.example/original');
        expect(http.calls.map((r) => r.uri.path), [
          '/v2/file/get_download_url',
          '/v2/file/get',
        ]);
      },
    );

    test(
      'file-detail preview URLs cannot become original-file downloads',
      () async {
        const p = CloudPlatform.aliyun;
        final vault = await tokenVault(p);
        final http = FakeHttp(
          (r) => jsonResponse(
            r.uri.path == '/v2/file/get_download_url'
                ? {}
                : {
                    'file_id': tokenFile.id,
                    'size': 4,
                    'url': 'https://cdn.example/preview',
                  },
          ),
        );
        await expectLater(
          AliyunConnector(
            http,
            vault,
            now: () => tokenClock,
          ).download(tokenPersonal(p), tokenFile, vault.credential(p)),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'reason',
              contains('原文件下载地址'),
            ),
          ),
        );
      },
    );

    for (final (status, code) in [
      (403, 'Forbidden'),
      (404, 'NotFound.FileId'),
      (429, 'TooManyRequests'),
    ]) {
      test(
        'download failure is retained without a detail fallback: $status $code',
        () async {
          const p = CloudPlatform.aliyun;
          final vault = await tokenVault(p);
          final http = FakeHttp(
            (_) =>
                jsonResponse({'code': code, 'display_message': '下载受限'}, status),
          );
          await expectLater(
            AliyunConnector(
              http,
              vault,
              now: () => tokenClock,
            ).download(tokenPersonal(p), tokenFile, vault.credential(p)),
            throwsA(
              isA<AliyunApiException>().having((e) => e.code, 'code', code),
            ),
          );
          expect(http.calls, hasLength(1));
        },
      );
    }

    for (final detail in [false, true]) {
      test(
        'file identity is checked on either download response: detail=$detail',
        () async {
          const p = CloudPlatform.aliyun;
          final vault = await tokenVault(p);
          final http = FakeHttp(
            (r) => jsonResponse(
              detail && r.uri.path == '/v2/file/get_download_url'
                  ? {}
                  : {
                      'file_id': 'wrong-file',
                      'download_url': 'https://cdn.example/wrong',
                    },
            ),
          );
          await expectLater(
            AliyunConnector(
              http,
              vault,
              now: () => tokenClock,
            ).download(tokenPersonal(p), tokenFile, vault.credential(p)),
            throwsA(
              isA<AppException>().having(
                (e) => e.message,
                'reason',
                contains('标识不一致'),
              ),
            ),
          );
        },
      );
    }
  });
}
