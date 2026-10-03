import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';
import 'token_cloud_support.dart';

void main() {
  for (final scenario in [
    'success',
    'transfer-failed',
    'size-mismatch',
    'renamed-cleanup',
  ]) {
    test(
      'Guangya authenticated share transfer and cleanup: $scenario',
      () async {
        const platform = CloudPlatform.guangya;
        final vault = await tokenVault(
          platform,
          tokenCredential(platform, fields: {'expiresAt': '4102444800000'}),
        );
        final owner = vault.activeAccountId(platform)!;
        late CleanupOutbox outbox;
        var folderName = '', deleted = false, deletions = 0;
        final http = FakeHttp((r) {
          switch (r.uri.path) {
            case '/userres/v1/get_share_access_token':
              return guangyaResponse({'accessToken': 'share-fixture'});
            case '/userres/v1/get_share_download_url':
              expect(r.json['fileId'], tokenFile.id);
              return guangyaResponse({}, code: 207);
            case '/userres/v1/file/create_dir':
              expect(r.json['parentId'], '');
              expect(r.json['failIfNameExist'], isTrue);
              folderName = r.json.str('dirName');
              expect(folderName, startsWith('AsterLink临时转存_'));
              return guangyaResponse({'fileId': 'temporary', 'resType': 2});
            case '/userres/v1/restore_share':
              expect(outbox.pendingCount, 1);
              expect(r.json['parentId'], 'temporary');
              expect(r.json['fileIds'], [tokenFile.id]);
              return guangyaResponse(
                {},
                code: scenario == 'transfer-failed' ? 157 : 0,
              );
            case '/userres/v1/file/get_file_list':
              if (r.json.str('parentId').isEmpty) {
                return guangyaResponse({
                  'list': [
                    if (!deleted)
                      {
                        'fileId': 'temporary',
                        'fileName': scenario == 'renamed-cleanup'
                            ? '用户保留的目录'
                            : folderName,
                        'resType': 2,
                      },
                  ],
                });
              }
              expect(r.json['parentId'], 'temporary');
              return guangyaResponse({
                'list': [
                  {
                    'fileId': 'copied',
                    'fileName': tokenFile.name,
                    'fileSize': scenario == 'size-mismatch' ? 5 : 4,
                    'resType': 1,
                  },
                ],
              });
            case '/userres/v1/get_res_download_url':
              expect(r.json['fileId'], 'copied');
              return guangyaResponse({
                'signedURL': 'https://cdn.example/copied',
              });
            case '/userres/v1/file/delete_file':
              expect(r.json['fileIds'], ['temporary']);
              expect(r.headers['Authorization'], 'Bearer $accessToken');
              deleted = true;
              deletions++;
              return guangyaResponse({});
            default:
              throw StateError('Unexpected endpoint ${r.uri.path}');
          }
        });
        outbox = CleanupOutbox(vault.store, http);
        final repository = CloudRepository(http, vault, outbox);
        final prepared = repository.prepare(tokenShare(platform), tokenFile);
        final fails = {'transfer-failed', 'size-mismatch'}.contains(scenario);
        if (fails) {
          await expectLater(
            prepared,
            throwsA(
              isA<AppException>().having(
                (error) => error.message,
                'message',
                contains(scenario == 'transfer-failed' ? '空间不足' : '大小不一致'),
              ),
            ),
          );
          expect(
            http.calls.any((r) => r.uri.path.endsWith('/get_res_download_url')),
            isFalse,
          );
          expect(
            asJson(vault.store.data.obj('cleanups').values.single)['ready'],
            isTrue,
          );
        } else {
          final spec = await prepared;
          expect(spec.url, 'https://cdn.example/copied');
          expect(spec.fileName, tokenFile.name);
          expect(spec.cleanup, isNotNull);
          await outbox.ready(spec.cleanup);
          await outbox.drain();
          expect(
            deletions,
            0,
            reason: 'The active download lease must protect the file',
          );
          await outbox.release(spec.cleanup);
          await outbox.ready(spec.cleanup);
        }
        final item = asJson(vault.store.data.obj('cleanups').values.single);
        expect(item['accountId'], owner);
        expect(jsonEncode(item), isNot(contains(accessToken)));
        expect(jsonEncode(item), isNot(contains(refreshToken)));
        await outbox.drain();
        expect(deletions, scenario == 'renamed-cleanup' ? 0 : 1);
        expect(outbox.pendingCount, scenario == 'renamed-cleanup' ? 1 : 0);
        await outbox.drain();
        expect(deletions, scenario == 'renamed-cleanup' ? 0 : 1);
      },
    );
  }
}
