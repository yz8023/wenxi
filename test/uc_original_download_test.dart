import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/file_types.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';
import 'uc_tv_support.dart';

const sample = CloudFile(id: 'video-1', name: '示例视频', size: 186678707);
HttpResult originalRange(int size) => HttpResult(206, 'xx', {
  'content-range': ['bytes 0-${size == 1 ? 0 : 1}/$size'],
  'content-length': [size == 1 ? '1' : '2'],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'The extensionless sample downloads original bytes without invoking playback',
    () async {
      final f = UcTvFixture();
      f.respond = (r) {
        if (r.uri.host == 'open-api-drive.uc.cn' && r.uri.path == '/file') {
          expect(r.uri.queryParameters['method'], 'download');
          expect(r.headers.containsKey('Cookie'), isFalse);
          return ucTvOriginal(size: sample.size);
        }
        if (r.uri.host == 'media.example') {
          expect(r.headers['Range'], 'bytes=0-1');
          expect(r.headers['Accept-Encoding'], 'identity');
          expect(r.headers.containsKey('Cookie'), isFalse);
          expect(r.headers.containsKey('Authorization'), isFalse);
          expect(r.headers.containsKey('x-pan-token'), isFalse);
          return originalRange(sample.size);
        }
        return null;
      };
      expect(fileKind(sample.name), FileKind.other);
      final spec = await f.repository.prepare(ucTvPersonal, sample);
      expect(spec.fileName, sample.name);
      expect(spec.expectedSize, sample.size);
      expect(spec.headers, isEmpty);
      expect(spec.source!['accountRevision'], 7);
      expect(spec.checksumValue, isNull);
      expect(f.calls('/file'), hasLength(1));
      expect(f.calls('/1/clouddrive/file/download'), isEmpty);
      expect(f.calls('/oauth/authorize'), isEmpty);
    },
  );

  test(
    'A web replacement requests explicit authorization without exchanging tokens',
    () async {
      final f = UcTvFixture(credential: ucTvCredential(authorized: false));
      f.respond = (r) {
        if (r.uri.path == '/1/clouddrive/file/download') {
          return jsonResponse({
            'status': 200,
            'code': 0,
            'data': [
              {
                'fid': sample.id,
                'file_name': sample.name,
                'size': sample.size,
                'md5': 'ffc6341c056de41cf4ab95343d9c22fe',
                'download_url': 'https://media.example/notice',
              },
            ],
          });
        }
        if (r.uri.host == 'media.example') {
          return const HttpResult(206, 'x', {
            'content-range': ['bytes 0-0/15340287'],
            'content-length': ['1'],
          });
        }
        return null;
      };
      await expectLater(
        f.repository.prepare(ucTvPersonal, sample),
        throwsA(
          isA<UcTvAuthorizationRequired>().having(
            (error) => error.message,
            'action',
            contains('TV 播放授权'),
          ),
        ),
      );
      expect(f.calls('/file'), isEmpty);
      expect(f.calls('/ucdrive/token'), isEmpty);
      expect(f.calls('/oauth/authorize'), isEmpty);
    },
  );

  test(
    'Original download preserves a listed checksum and the signed URL',
    () async {
      final f = UcTvFixture();
      const file = CloudFile(
        id: 'video-1',
        name: 'file.bin',
        size: 400,
        hashType: 'md5',
        hashValue: '0123456789abcdef0123456789abcdef',
      );
      const url = 'https://media.example/original.mp4?sign=a%2Bb&part=1&part=2';
      f.respond = (r) => r.uri.path == '/file'
          ? ucTvOk({
              'data': {'fid': file.id, 'size': file.size, 'download_url': url},
            })
          : null;
      final spec = await f.repository.prepare(ucTvPersonal, file);
      expect(spec.url, url);
      expect(spec.checksumType, 'md5');
      expect(spec.checksumValue, file.hashValue);
      expect(spec.expectedSize, 400);
    },
  );

  test(
    'Original download refreshes a rejected token once and keeps account identity',
    () async {
      final f = UcTvFixture();
      final owner = f.credential;
      f.respond = (r) =>
          r.uri.path == '/file' &&
              r.uri.queryParameters['access_token'] == 'tv-access-private'
          ? ucTvError(10001)
          : null;
      final spec = await f.repository.prepare(ucTvPersonal, ucTvVideo);
      expect(spec.expectedSize, 400);
      expect(f.calls('/file'), hasLength(2));
      expect(f.calls('/ucdrive/token'), hasLength(1));
      expect(f.credential.updatedAt, owner.updatedAt);
      expect(f.credential.primary, owner.primary);
      expect(f.credential.field('tv_access_token'), 'new-tv-access');
    },
  );

  test(
    'Repeated authorization rejection stops without downloading a web substitute',
    () async {
      final f = UcTvFixture();
      f.respond = (r) => r.uri.path == '/file' ? ucTvError(10001) : null;
      await expectLater(
        f.repository.prepare(ucTvPersonal, ucTvVideo),
        throwsA(isA<UcTvAuthorizationRequired>()),
      );
      expect(f.calls('/file'), hasLength(2));
      expect(f.calls('/ucdrive/token'), hasLength(1));
      expect(f.credential.field('tv_status'), 'expired');
      expect(f.calls('/1/clouddrive/file/download'), isEmpty);
      expect(f.http.calls.where((r) => r.uri.host == 'media.example'), isEmpty);
    },
  );

  test(
    'An already expired optional grant leaves usable web downloads available',
    () async {
      final f = UcTvFixture(credential: ucTvCredential(expiresAt: ucTvNow));
      f.respond = (r) => r.uri.path == '/ucdrive/token'
          ? jsonResponse({
              'code': 200,
              'data': {'status': -1, 'errno': 11000},
            })
          : null;
      final spec = await f.repository.prepare(ucTvPersonal, ucTvVideo);
      expect(spec.expectedSize, 400);
      expect(spec.headers['Cookie'], contains('web-session'));
      expect(f.calls('/file'), isEmpty);
      expect(f.calls('/1/clouddrive/file/download'), hasLength(1));
    },
  );

  test(
    'An expired grant without a refresh token is marked for a new QR',
    () async {
      final credential = ucTvCredential(
        expiresAt: ucTvNow,
      ).withFields({'tv_refresh_token': ''}, preserveRevision: true);
      final f = UcTvFixture(credential: credential);
      await expectLater(
        f.connector.tv.ensureAuthorized(credential),
        throwsA(isA<UcTvAuthorizationRequired>()),
      );
      expect(f.credential.field('tv_status'), 'expired');
      expect(f.credential.updatedAt, credential.updatedAt);
      expect(f.calls('/ucdrive/token'), isEmpty);
    },
  );

  test(
    'Wrong file identity, invalid URLs and inconsistent API sizes never reach the CDN',
    () async {
      for (final changes in <Json>[
        {'fid': 'different'},
        {'fid': ''},
        {'size': -1},
        {'size': 123},
        {'size': 'invalid'},
        {'download_url': 'file:///C:/wrong'},
        {
          'download_url': Uri(
            scheme: 'https',
            host: 'media.example',
            userInfo: 'test:placeholder',
            path: '/wrong',
          ).toString(),
        },
      ]) {
        final f = UcTvFixture();
        f.respond = (r) => r.uri.path == '/file'
            ? ucTvOk({
                'data': {
                  'fid': ucTvVideo.id,
                  'size': 400,
                  'download_url': 'https://media.example/original.mp4',
                  ...changes,
                },
              })
            : null;
        await expectLater(
          f.repository.prepare(ucTvPersonal, ucTvVideo),
          throwsA(isA<AppException>()),
        );
        expect(
          f.http.calls.where((r) => r.uri.host == 'media.example'),
          isEmpty,
        );
      }
    },
  );

  test(
    'Original downloads reject replacement, malformed, encoded and failed range responses',
    () async {
      for (final response in [
        originalRange(123),
        const HttpResult(200, 'x', {
          'content-length': ['123'],
        }),
        const HttpResult(206, 'xx', {
          'content-range': ['bytes 1-2/400'],
        }),
        const HttpResult(206, 'xx', {
          'content-range': ['bytes 0-3/400'],
        }),
        const HttpResult(206, 'xx', {
          'content-range': ['bytes 0-1/400'],
          'content-length': ['3'],
        }),
        const HttpResult(206, 'xx', {
          'content-range': ['bytes 0-1/400'],
          'content-encoding': ['gzip'],
        }),
        const HttpResult(200, ''),
        const HttpResult(403, ''),
        const HttpResult(416, '', {
          'content-range': ['bytes */0'],
        }),
      ]) {
        final f = UcTvFixture();
        f.respond = (r) => r.uri.host == 'media.example' ? response : null;
        await expectLater(
          f.repository.prepare(ucTvPersonal, ucTvVideo),
          throwsA(isA<AppException>()),
        );
        expect(f.calls('/file'), hasLength(1));
        expect(f.calls('/1/clouddrive/file/download'), isEmpty);
      }
    },
  );

  test(
    'Empty, one-byte, and full-response original files retain their true size',
    () async {
      for (final size in [0, 1, 400]) {
        final f = UcTvFixture();
        f.respond = (r) {
          if (r.uri.path == '/file') return ucTvOriginal(size: size);
          if (r.uri.host != 'media.example') return null;
          return size == 0
              ? const HttpResult(416, '', {
                  'content-range': ['bytes */0'],
                })
              : size == 1
              ? originalRange(1)
              : const HttpResult(200, 'xx', {
                  'content-length': ['400'],
                });
        };
        final spec = await f.repository.prepare(
          ucTvPersonal,
          CloudFile(id: 'video-1', name: 'file', size: size),
        );
        expect(spec.expectedSize, size);
      }
    },
  );

  test(
    'Share downloads use exactly one transfer and validate its new personal fid',
    () async {
      final f = UcTvFixture();
      final spec = await f.repository.prepare(ucTvShare, ucTvVideo);
      expect(f.calls('/file').single.uri.queryParameters['method'], 'download');
      expect(f.calls('/file').single.uri.queryParameters['fid'], 'saved-video');
      expect(f.calls('/1/clouddrive/share/sharepage/save'), hasLength(1));
      expect(spec.cleanup!.body, f.staged.single.body);
      expect(spec.expectedSize, ucTvVideo.size);
      expect(spec.headers, isEmpty);
    },
  );

  test(
    'Failed or ambiguous shared downloads clean only their temporary transfer',
    () async {
      for (final ambiguous in [false, true]) {
        final f = UcTvFixture();
        f.respond = (r) {
          if (ambiguous && r.uri.path == '/1/clouddrive/task') {
            return jsonResponse({
              'status': 200,
              'code': 0,
              'data': {
                'status': 2,
                'save_as': {
                  'save_as_top_fids': ['one', 'two'],
                },
              },
            });
          }
          return r.uri.host == 'media.example' ? originalRange(123) : null;
        };
        await expectLater(
          f.repository.prepare(ucTvShare, ucTvVideo),
          throwsA(isA<AppException>()),
        );
        expect(f.calls('/1/clouddrive/file/delete').single.json['filelist'], [
          'temporary',
        ]);
        expect(f.calls('/1/clouddrive/share/sharepage/save'), hasLength(1));
        if (ambiguous) expect(f.calls('/file'), isEmpty);
      }
    },
  );

  test(
    'Cancellation or account removal during the probe never returns a source',
    () async {
      for (final removeAccount in [false, true]) {
        final f = UcTvFixture(), scope = RequestScope();
        f.respond = (r) {
          if (r.uri.host != 'media.example') return null;
          return () async {
            if (removeAccount) {
              await f.vault.removeCredential(CloudPlatform.uc);
            } else {
              scope.cancel();
            }
            return originalRange(400);
          }();
        };
        await expectLater(
          scope.run(() => f.repository.prepare(ucTvPersonal, ucTvVideo)),
          throwsA(isA<AppException>()),
        );
        expect(f.calls('/file'), hasLength(1));
        expect(f.calls('/ucdrive/token'), isEmpty);
        if (removeAccount) expect(f.vault.credential(CloudPlatform.uc), isNull);
      }
    },
  );
}
