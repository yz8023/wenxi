import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_favorites.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'support.dart';
import 'token_cloud_support.dart';

Credential durableCredential(
  CloudPlatform p, {
  int revision = 42,
  String access = accessToken,
}) => tokenCredential(
  p,
  revision: revision,
  fields: {
    'accessToken': access,
    'expiresAt': '4102444800000',
    'sessionExpiresAt': '4102444800000',
  },
);

void main() {
  for (final p in [CloudPlatform.aliyun, CloudPlatform.guangya]) {
    test(
      '${p.key} queue preparation and refresh remain bound to their original account and space',
      () async {
        final vault = await tokenVault(p, durableCredential(p));
        final original = vault.activeAccountId(p)!;
        final http = FakeHttp((r) {
          expect(r.headers['Authorization'], 'Bearer $accessToken');
          if (p == CloudPlatform.guangya) {
            return guangyaResponse(
              r.uri.path.endsWith('/get_file_list')
                  ? {
                      'list': [
                        {
                          'fileId': 'file-1',
                          'fileName': 'movie.mp4',
                          'size': 4,
                          'resType': 1,
                        },
                      ],
                      'total': 1,
                    }
                  : {'signedURL': 'https://cdn.example/file'},
            );
          }
          if (r.uri.path.endsWith('/file/list')) {
            expect(r.json['drive_id'], 'backup');
            return jsonResponse({
              'items': [aliFile('file-1')],
            });
          }
          if (r.uri.path == '/v2/file/get_download_url') {
            expect(r.json['drive_id'], 'backup');
            return jsonResponse({
              ...aliFile('file-1'),
              'url': 'https://cdn.example/file',
            });
          }
          return aliDefaultResponse(r);
        });
        final repo = CloudRepository(
          http,
          vault,
          CleanupOutbox(vault.store, http),
        );
        final planned = repo.planDownload(
          tokenPersonal(p, drive: 'backup'),
          tokenFile,
        );
        expect(planned.needsPreparation, isTrue);
        expect(http.calls, isEmpty);
        final other = await vault.createAccount(p);
        await vault.withAccount(
          p,
          other,
          () => vault.putCredential(
            p,
            durableCredential(
              p,
              revision: 99,
              access: 'other-account-access-token',
            ),
          ),
        );
        await vault.activate(p, other);
        final prepared = await repo.refresh(planned);
        final refreshed = await repo.refresh(prepared);
        expect(refreshed.url, 'https://cdn.example/file');
        final source = DownloadOrigin.fromJson(refreshed.source!);
        expect(source.session.accountId, original);
        if (p == CloudPlatform.aliyun) {
          expect(source.session.personalSpaceId, 'backup');
        }
        expect(vault.activeAccountId(p), other);
        await vault.removeAccount(p, original);
        await expectLater(
          repo.refresh(planned),
          throwsA(isA<AccountLoginRequired>()),
        );
      },
    );
  }

  test(
    'Aliyun favorites and playback identities keep both drives distinct across persistence',
    () async {
      const p = CloudPlatform.aliyun;
      final vault = await tokenVault(p, durableCredential(p));
      final drivesRead = <String>[];
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('/file/list')) {
          drivesRead.add(r.json.str('drive_id'));
          return jsonResponse({
            'items': [aliFile('file-1')],
          });
        }
        return aliDefaultResponse(r);
      });
      final repo = CloudRepository(
        http,
        vault,
        CleanupOutbox(vault.store, http),
      );
      final favorites = CloudFavorites(vault.store, repo);
      final resource = tokenPersonal(p),
          backup = tokenPersonal(p, drive: 'backup');
      expect(
        favorites.key(resource, tokenFile),
        isNot(favorites.key(backup, tokenFile)),
      );
      expect(
        cloudPlaybackKey(resource, tokenFile, 42),
        isNot(cloudPlaybackKey(backup, tokenFile, 42)),
      );
      for (final session in [resource, backup]) {
        await favorites.toggle(session, tokenFile, [('root', '全部文件')]);
      }
      expect(favorites.all, hasLength(2));
      for (final favorite in favorites.all) {
        final opened = await favorites.open(favorite);
        expect(
          opened.session.personalSpaceId,
          favorite.session.personalSpaceId,
        );
        expect(opened.highlight, 'file-1');
      }
      expect(drivesRead, unorderedEquals(['resource', 'backup']));
    },
  );

  test(
    'failed Aliyun temporary transfer leaves a durable owner-bound cleanup that survives account switching',
    () async {
      const p = CloudPlatform.aliyun;
      final vault = await tokenVault(p, durableCredential(p));
      final original = vault.activeAccountId(p)!;
      late CleanupOutbox outbox;
      var folderName = '', deletions = 0;
      final http = FakeHttp((r) {
        if (r.uri.path == '/adrive/v2/file/createWithFolders') {
          folderName = r.json.str('name');
          return jsonResponse(
            aliFile('temporary', folder: true, name: folderName),
          );
        }
        if (r.uri.path.endsWith('/batch')) {
          expect(outbox.pendingCount, 1);
          return jsonResponse({
            'responses': [
              {
                'id': '0',
                'status': 403,
                'body': {'code': 'QuotaExhausted.Drive'},
              },
            ],
          });
        }
        if (r.uri.path == '/v2/file/get') {
          return jsonResponse(
            aliFile('temporary', folder: true, name: folderName),
          );
        }
        if (r.uri.path.endsWith('/trash')) {
          expect(r.json['drive_id'], 'resource');
          expect(r.json['file_id'], 'temporary');
          expect(r.headers['Authorization'], 'Bearer $accessToken');
          deletions++;
          return jsonResponse({});
        }
        return aliDefaultResponse(r);
      });
      outbox = CleanupOutbox(vault.store, http);
      final repo = CloudRepository(http, vault, outbox);
      await expectLater(
        repo.prepare(tokenShare(p), tokenFile),
        throwsA(isA<AppException>()),
      );
      final item = asJson(vault.store.data.obj('cleanups').values.single);
      expect(item['ready'], isTrue);
      expect(item['accountId'], original);
      final other = await vault.createAccount(p);
      await vault.withAccount(
        p,
        other,
        () => vault.putCredential(
          p,
          durableCredential(
            p,
            revision: 99,
            access: 'other-account-access-token',
          ),
        ),
      );
      await vault.activate(p, other);
      await outbox.drain();
      expect(deletions, 1);
      expect(outbox.pendingCount, 0);
      expect(vault.activeAccountId(p), other);
    },
  );
}
