import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/providers/aliyun.dart';
import 'package:asterlink/data/providers/aliyun_signature.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';
import 'token_cloud_support.dart';

const p = CloudPlatform.aliyun;
Matcher failure(String text) => throwsA(
  isA<AppException>().having((e) => e.message, 'message', contains(text)),
);

HttpResult batchResponse(RecordedRequest r, Json body, {int status = 200}) =>
    jsonResponse({
      'responses': [
        for (final request in r.json.list('requests'))
          {'id': request.str('id'), 'status': status, 'body': body},
      ],
    });

void main() {
  test(
    'device signatures match independent python-ecdsa RFC6979 and low-S vectors',
    () {
      final fixture = asJson(
        jsonDecode(
          File('test/fixtures/aliyun-signatures.json').readAsStringSync(),
        ),
      );
      final recoveries = <String>{};
      for (final v in fixture.list('vectors')) {
        final signed = AliyunSignature.sign(
          privateKey: v.str('privateKey'),
          deviceId: v.str('deviceId'),
          userId: v.str('userId'),
          nonce: v.integer('nonce'),
        );
        expect(signed.signature, v.str('signature'));
        expect(signed.publicKey, v.str('publicKey'));
        recoveries.add(signed.signature.substring(128));
      }
      expect(recoveries, containsAll(['00', '01']));
      for (final key in ['', '0' * 64, 'f' * 64]) {
        expect(
          () =>
              AliyunSignature.sign(privateKey: key, deviceId: 'd', userId: 'u'),
          failure('密钥'),
        );
      }
    },
  );

  for (final rejected in [false, true]) {
    test(
      'concurrent ${rejected ? 'invalid' : 'missing'} device sessions create once',
      () async {
        final signature = AliyunSignature.sign(
          privateKey: '1'.padLeft(64, '0'),
          deviceId: 'device-1',
          userId: 'user-1',
        ).signature;
        final vault = await tokenVault(
          p,
          tokenCredential(
            p,
            fields: {
              'signature': rejected ? signature : '',
              'sessionExpiresAt': '${rejected ? tokenClock + 1800000 : 0}',
            },
          ),
        );
        var creates = 0;
        final release = Completer<void>();
        final http = FakeHttp((r) async {
          if (r.uri.path.endsWith('/create_session')) {
            creates++;
            expect(r.headers['X-Signature'], signature);
            expect(r.json.str('pubKey'), startsWith('04'));
            expect(r.json.str('pubKey'), hasLength(130));
            expect(JsonHttp.isReadRequest(r.method, r.url), isFalse);
            await release.future;
            return jsonResponse({'result': true});
          }
          if (rejected && !release.isCompleted) {
            return jsonResponse({'code': 'DeviceSessionSignatureInvalid'}, 403);
          }
          return jsonResponse({'items': []});
        });
        final connector = AliyunConnector(http, vault, now: () => tokenClock),
            original = vault.credential(p)!;
        final pending = Future.wait(
          List.generate(
            8,
            (_) => connector.list(tokenPersonal(p), 'root', original),
          ),
        );
        await until(() => creates == 1);
        release.complete();
        await pending;
        expect(creates, 1);
        expect(vault.credential(p)!.field('deviceSessionId'), isNotEmpty);
      },
    );
  }

  test(
    'resource library is default and backup remains selectable without duplicate drives',
    () async {
      final vault = await tokenVault(p), http = FakeHttp(aliDefaultResponse);
      final connector = AliyunConnector(http, vault, now: () => tokenClock),
          c = vault.credential(p)!;
      final account = await connector.account(c);
      expect(account.total, 1000);
      final spaces = await connector.personalSpaces(c);
      expect(spaces.map((s) => s.id), ['resource', 'backup']);
      expect((await connector.openPersonal(c)).personalSpaceId, 'resource');
      expect(
        (await connector.openPersonalSpace(spaces.last, c)).personalSpaceId,
        'backup',
      );
      await expectLater(
        connector.openPersonalSpace(const CloudSpace('other-user', ''), c),
        failure('无法访问'),
      );
    },
  );

  test(
    'all marker pages stay in the selected drive and deduplicate overlap',
    () async {
      final vault = await tokenVault(p);
      final http = FakeHttp((r) {
        expect(r.json['drive_id'], 'backup');
        final second = r.json.str('marker') == 'next';
        expect(r.headers['Authorization'], 'Bearer $accessToken');
        expect(JsonHttp.isReadRequest(r.method, r.url), isTrue);
        return jsonResponse({
          'items': [
            aliFile('first'),
            if (second) aliFile('second', folder: true),
          ],
          'next_marker': second ? '' : 'next',
        });
      });
      final files = await AliyunConnector(
        http,
        vault,
        now: () => tokenClock,
      ).list(tokenPersonal(p, drive: 'backup'), 'root', vault.credential(p));
      expect(files.map((f) => f.id), ['first', 'second']);
      expect(files.last.isDirectory, isTrue);
      expect(http.calls, hasLength(2));
    },
  );

  for (final data in [
    <String, dynamic>{},
    {'items': [], 'next_marker': 'again'},
    {
      'items': [aliFile('first')],
      'next_marker': 'again',
    },
  ]) {
    test(
      'missing or repeated file pages fail explicitly: ${data.keys}',
      () async {
        final vault = await tokenVault(p),
            http = FakeHttp((_) => jsonResponse(data));
        await expectLater(
          AliyunConnector(
            http,
            vault,
            now: () => tokenClock,
          ).list(tokenPersonal(p), 'root', vault.credential(p)),
          throwsA(isA<AppException>()),
        );
        expect(http.calls.length, lessThanOrEqualTo(2));
      },
    );
  }

  test(
    'anonymous shares use a fresh share token and never send the account token',
    () async {
      final vault = await tokenVault(p);
      var tokenReads = 0;
      final http = FakeHttp((r) {
        expect(r.headers.containsKey('Authorization'), isFalse);
        if (r.uri.path.endsWith('/get_share_token')) {
          tokenReads++;
          expect(r.json, {'share_id': 'Share123', 'share_pwd': 'a123'});
          return jsonResponse({'share_token': 'share-$tokenReads'});
        }
        if (r.uri.path == '/adrive/v2/file/list_by_share') {
          expect(r.headers['X-Share-Token'], 'share-2');
          expect(r.json['share_id'], 'Share123');
          expect(r.json.containsKey('drive_id'), isFalse);
          return jsonResponse({
            'items': [aliFile('first')],
          });
        }
        return aliDefaultResponse(r);
      });
      final connector = AliyunConnector(http, vault, now: () => tokenClock);
      final session = await connector.openShare(
        tokenShare(p).sourceLink!,
        null,
      );
      expect(session.title, '旅行影像');
      expect(await connector.list(session, 'root', null), hasLength(1));
      await expectLater(
        connector.download(session, tokenFile, null),
        throwsA(isA<AccountLoginRequired>()),
      );
    },
  );

  for (final fallback in [false, true]) {
    test(
      'original file download ${fallback ? 'fallback' : 'direct'} keeps CDN headers free of account secrets',
      () async {
        final vault = await tokenVault(p);
        final http = FakeHttp((r) {
          expect(r.json['drive_id'], 'backup');
          expect(r.json['file_id'], 'file-1');
          expect(
            r.headers['X-Canary'],
            'client=Android,app=adrive,version=v4.1.0',
          );
          expect(r.headers['User-Agent'], contains('Windows NT'));
          return jsonResponse({
            ...aliFile('file-1'),
            if (!fallback || r.uri.path == '/v2/file/get')
              'download_url': 'https://cdn.example/file?signature=aa%2B%2F',
          });
        });
        final result = await AliyunConnector(http, vault, now: () => tokenClock)
            .download(
              tokenPersonal(p, drive: 'backup'),
              tokenFile,
              vault.credential(p),
            );
        expect(result.expectedSize, 4);
        expect(result.profile, 'aliyun');
        expect(result.url, endsWith('signature=aa%2B%2F'));
        expect(result.headers.keys, unorderedEquals(['Referer', 'User-Agent']));
        expect(result.headers['Referer'], 'https://www.aliyundrive.com/');
        expect(http.calls.length, fallback ? 2 : 1);
      },
    );
  }

  for (final url in [
    '',
    'file:///tmp/private',
    'javascript:alert(1)',
    'https://user:secret@cdn.example/file',
    'https://cdn.example/f\nInjected',
  ]) {
    test('invalid download URL is rejected: $url', () async {
      final vault = await tokenVault(p);
      final http = FakeHttp((_) => jsonResponse({'url': url}));
      await expectLater(
        AliyunConnector(
          http,
          vault,
          now: () => tokenClock,
        ).download(tokenPersonal(p), tokenFile, vault.credential(p)),
        failure('下载地址'),
      );
    });
  }

  test(
    'size changes are rejected before a download URL fallback loses file metadata',
    () async {
      final vault = await tokenVault(p),
          http = FakeHttp((_) => jsonResponse({'size': 5}));
      await expectLater(
        AliyunConnector(
          http,
          vault,
          now: () => tokenClock,
        ).download(tokenPersonal(p), tokenFile, vault.credential(p)),
        failure('大小已变化'),
      );
      expect(http.calls, hasLength(1));
    },
  );

  test(
    'move carries the source and target drives and batch failures are not hidden',
    () async {
      final vault = await tokenVault(p);
      final http = FakeHttp((r) {
        expect(r.uri.path, '/adrive/v4/batch');
        expect(JsonHttp.isReadRequest(r.method, r.url), isFalse);
        final requests = r.json.list('requests');
        for (final request in requests) {
          expect(request.obj('body')['drive_id'], 'backup');
          expect(request.obj('body')['to_drive_id'], 'resource');
          expect(request.obj('body')['to_parent_file_id'], 'target');
        }
        return jsonResponse({
          'responses': [
            {'id': '0', 'status': 200, 'body': {}},
            {
              'id': '1',
              'status': 409,
              'body': {'code': 'QuotaExhausted.Drive'},
            },
          ],
        });
      });
      final connector = AliyunConnector(http, vault, now: () => tokenClock);
      await expectLater(
        connector.move(
          tokenPersonal(p, drive: 'backup'),
          [tokenFile, const CloudFile(id: 'second', name: 'second')],
          connector.destinationId(tokenPersonal(p), 'target'),
          vault.credential(p)!,
        ),
        failure('空间不足'),
      );
      expect(http.calls, hasLength(1));
    },
  );

  test('missing batch replies cannot look like a successful rename', () async {
    final vault = await tokenVault(p),
        http = FakeHttp((_) => jsonResponse({'responses': []}));
    await expectLater(
      AliyunConnector(
        http,
        vault,
        now: () => tokenClock,
      ).rename(tokenPersonal(p), tokenFile, '新名称.mp4', vault.credential(p)!),
      failure('完整操作结果'),
    );
  });

  for (final state in ['succeed', 'failed', 'timeout']) {
    test('asynchronous move handles $state without resubmitting', () async {
      final vault = await tokenVault(p);
      var submissions = 0, polls = 0;
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('/batch')) {
          submissions++;
          return batchResponse(r, {'async_task_id': 'task'});
        }
        polls++;
        return jsonResponse({
          'state': polls == 1 || state == 'timeout' ? 'Running' : state,
          'message': state == 'failed' ? '空间不足' : '',
        });
      });
      final result = AliyunConnector(
        http,
        vault,
        now: () => tokenClock,
        taskDelay: Duration.zero,
      ).move(tokenPersonal(p), [tokenFile], 'target', vault.credential(p)!);
      if (state == 'succeed') {
        await result;
      } else {
        await expectLater(result, failure(state == 'failed' ? '空间不足' : '处理中'));
      }
      expect(submissions, 1);
      expect(polls, state == 'timeout' ? 80 : 2);
    });
  }

  test(
    'folder creation, rename, deletion and share expiry preserve user intent',
    () async {
      final vault = await tokenVault(p);
      final http = FakeHttp((r) {
        expect(JsonHttp.isReadRequest(r.method, r.url), isFalse);
        switch (r.uri.path) {
          case '/adrive/v2/file/createWithFolders':
            expect(r.json['name'], '旅行');
            expect(r.json['check_name_mode'], 'refuse');
            return jsonResponse(
              aliFile('new-folder', folder: true, name: '旅行'),
            );
          case '/adrive/v4/batch':
            expect(
              r.json.list('requests').single.obj('body')['name'],
              '海边.mp4',
            );
            return batchResponse(r, {});
          case '/v2/recyclebin/trash':
            expect(r.json, {'drive_id': 'backup', 'file_id': 'file-1'});
            return jsonResponse({});
          case '/adrive/v2/share_link/create':
            expect(r.json['share_pwd'], 'a123');
            expect(r.json['file_id_list'], ['file-1']);
            expect(
              DateTime.parse(r.json.str('expiration')).millisecondsSinceEpoch,
              tokenClock + 7 * 24 * 3600 * 1000,
            );
            return jsonResponse({
              'share_id': 'Created123',
              'share_pwd': 'a123',
            });
          default:
            throw StateError(r.url);
        }
      });
      final connector = AliyunConnector(http, vault, now: () => tokenClock),
          c = vault.credential(p)!;
      final session = tokenPersonal(p, drive: 'backup');
      expect(
        (await connector.createFolder(session, 'root', '旅行', c)).isDirectory,
        isTrue,
      );
      await connector.rename(session, tokenFile, '海边.mp4', c);
      await connector.delete(session, [tokenFile], c);
      final share = await connector.createShare(
        session,
        [tokenFile],
        const ShareOptions('旅行', expiryDays: 7, passcode: 'a123'),
        c,
      );
      expect(share.url, 'https://www.alipan.com/s/Created123');
      expect(share.passcode, 'a123');
    },
  );

  test('a network failure never replays folder creation', () async {
    final vault = await tokenVault(p),
        http = FakeHttp(
          (_) => throw const HttpRequestFailure(
            'lost',
            kind: 'connectionError',
            retryable: true,
          ),
        );
    await expectLater(
      AliyunConnector(
        RetryingJsonHttp(http),
        vault,
        now: () => tokenClock,
      ).createFolder(tokenPersonal(p), 'root', 'folder', vault.credential(p)!),
      throwsA(isA<HttpRequestFailure>()),
    );
    expect(http.calls, hasLength(1));
  });

  for (final mismatch in [false, true]) {
    test(
      'share download stages cleanup before copying and ${mismatch ? 'rejects wrong size' : 'uses the copied identity'}',
      () async {
        final vault = await tokenVault(p);
        DownloadCleanup? cleanup;
        var polls = 0;
        final http = FakeHttp((r) {
          switch (r.uri.path) {
            case '/adrive/v2/file/createWithFolders':
              expect(r.json.str('name'), startsWith('AsterLink临时转存_'));
              expect(r.json['parent_file_id'], 'root');
              return jsonResponse(
                aliFile('temporary', name: r.json.str('name'), folder: true),
              );
            case '/adrive/v4/batch':
              expect(cleanup, isNotNull);
              expect(r.headers['X-Share-Token'], 'fixture-share-token');
              final body = r.json.list('requests').single.obj('body');
              expect(body['to_parent_file_id'], 'temporary');
              expect(body['to_drive_id'], 'resource');
              expect(body['share_id'], 'Share123');
              return batchResponse(r, {'file_id': 'copied'});
            case '/adrive/v3/file/list':
              polls++;
              return jsonResponse({
                'items': [
                  aliFile('unrelated', parent: 'temporary'),
                  if (polls > 1)
                    {
                      ...aliFile('copied', parent: 'temporary'),
                      'size': mismatch ? 5 : 4,
                    },
                ],
              });
            case '/v2/file/get_download_url':
              expect(r.json['file_id'], 'copied');
              expect(
                r.headers['X-Canary'],
                'client=Android,app=adrive,version=v4.1.0',
              );
              return jsonResponse({
                ...aliFile('copied'),
                'url': 'https://cdn.example/copied',
              });
            default:
              return aliDefaultResponse(r);
          }
        });
        final connector = AliyunConnector(
          http,
          vault,
          now: () => tokenClock,
          taskDelay: Duration.zero,
          stageCleanup: (value) async => cleanup = value,
        );
        final result = connector.download(
          tokenShare(p),
          tokenFile,
          vault.credential(p),
        );
        if (mismatch) {
          await expectLater(result, failure('大小不一致'));
          expect(http.calls.any((r) => r.uri.path.endsWith('/trash')), isFalse);
        } else {
          final spec = await result;
          expect(spec.cleanup, same(cleanup));
          expect(spec.fileName, tokenFile.name);
          expect(spec.headers['Referer'], 'https://www.aliyundrive.com/');
        }
        expect(cleanup!.action!['driveId'], 'resource');
        expect(cleanup!.action!['accountRevision'], 42);
        expect(jsonEncode(cleanup!.toJson()), isNot(contains(accessToken)));
      },
    );
  }

  for (final state in ['exists', 'missing', 'recycled', 'renamed']) {
    test(
      'temporary cleanup verifies the folder and is idempotent: $state',
      () async {
        const name = 'AsterLink临时转存_00000000-0000-0000-0000-000000000000';
        final vault = await tokenVault(p);
        var deletions = 0;
        final http = FakeHttp((r) {
          expect(r.json['drive_id'], 'backup');
          expect(r.json['file_id'], 'temporary');
          if (r.uri.path.endsWith('/trash')) {
            deletions++;
            return jsonResponse({});
          }
          if (state == 'missing' || state == 'recycled') {
            return jsonResponse({
              'code': state == 'missing'
                  ? 'NotFound.FileId'
                  : 'ForbiddenFileInTheRecycleBin',
            }, 404);
          }
          return jsonResponse(
            aliFile(
              'temporary',
              name: state == 'renamed' ? 'my-files' : name,
              folder: true,
            ),
          );
        });
        final result = AliyunConnector(http, vault, now: () => tokenClock)
            .deleteTemporaryFolder(
              tokenPersonal(p, drive: 'backup'),
              'temporary',
              name,
              vault.credential(p)!,
            );
        if (state == 'renamed') {
          await expectLater(result, failure('已被修改'));
        } else {
          await result;
        }
        expect(deletions, state == 'exists' ? 1 : 0);
      },
    );
  }
}
