import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/uc_tv.dart';
import 'package:asterlink/data/providers/uc_tv_protocol.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';
import 'uc_tv_support.dart';

Matcher tvRequired = throwsA(isA<UcTvAuthorizationRequired>());
Matcher failedWith(String part) => throwsA(
  isA<AppException>().having((e) => e.message, 'message', contains(part)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'QR login is isolated from web Cookies and commits only after confirmed token validation',
    () async {
      final f = UcTvFixture(credential: ucTvCredential(authorized: false));
      final old = f.credential, tv = f.connector.tv;
      final challenge = await tv.beginAuthorization();
      expect(challenge.qr.image.take(4), [137, 80, 78, 71]);
      expect(await tv.pollAuthorization(challenge), isFalse);
      expect(f.credential.sameAs(old), isTrue);
      expect(f.calls('/ucdrive/token'), isEmpty);
      f.scanned = true;
      expect(await tv.pollAuthorization(challenge), isTrue);
      expect(UcTvService.authorized(f.credential), isTrue);
      expect(f.credential.updatedAt, old.updatedAt);
      expect(f.credential.primary, old.primary);
      expect(f.credential.field('tv_access_token'), 'new-tv-access');
      expect(f.credential.field('tv_refresh_token'), 'new-tv-refresh');
      expect(
        f.credential.field('tv_access_token_expires_at'),
        '${ucTvNow + 3600000}',
      );
      final token = f.calls('/ucdrive/token').single;
      expect(token.uri.scheme, 'https');
      expect(token.json['code'], 'one-time-private-code');
      expect(token.json.containsKey('refresh_token'), isFalse);
      expect(token.headers['User-Agent'], UcTvProtocol.userAgent);
      expect(f.http.redirectPolicies, everyElement(isFalse));
      for (final call in f.http.calls) {
        expect(
          call.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('cookie')),
        );
        expect(
          jsonEncode([call.url, call.body, call.headers]),
          isNot(contains('__pus')),
        );
      }
      expect(jsonEncode(f.store.data), isNot(contains('qr-poll-private')));
      expect(
        jsonEncode(f.store.data),
        isNot(contains('one-time-private-code')),
      );
    },
  );

  test(
    'Cancel or replacing a QR cannot commit a late authorization code',
    () async {
      final f = UcTvFixture(credential: ucTvCredential(authorized: false));
      final challenge = await f.connector.tv.beginAuthorization();
      final pending = Completer<HttpResult>();
      f.respond = (r) => r.uri.path == '/oauth/code' ? pending.future : null;
      final poll = f.connector.tv.pollAuthorization(challenge);
      final assertion = expectLater(poll, failedWith('取消'));
      f.connector.tv.cancelAuthorization();
      pending.complete(ucTvOk({'code': 'late-code'}));
      await assertion;
      expect(f.calls('/ucdrive/token'), isEmpty);
      expect(UcTvService.authorized(f.credential), isFalse);
    },
  );

  test(
    'Expired QR and denied QR responses never reach token exchange',
    () async {
      final f = UcTvFixture(credential: ucTvCredential(authorized: false));
      final challenge = await f.connector.tv.beginAuthorization();
      f.now = challenge.qr.expiresAt;
      await expectLater(
        f.connector.tv.pollAuthorization(challenge),
        failedWith('超时'),
      );
      expect(f.calls('/oauth/code'), isEmpty);
      f.now = ucTvNow;
      final next = await f.connector.tv.beginAuthorization();
      f.respond = (r) => r.uri.path == '/oauth/code' ? ucTvError(11002) : null;
      await expectLater(
        f.connector.tv.pollAuthorization(next),
        failedWith('失效'),
      );
      expect(f.calls('/ucdrive/token'), isEmpty);
    },
  );

  test(
    'Malformed QR and outer success with an inner token failure are rejected',
    () async {
      final f = UcTvFixture(credential: ucTvCredential(authorized: false));
      f.respond = (r) => r.uri.path == '/oauth/authorize'
          ? ucTvOk({
              'query_token': 'query',
              'qr_data': 'data:image/svg+xml;base64,eA==',
            })
          : null;
      await expectLater(
        f.connector.tv.beginAuthorization(),
        failedWith('格式无效'),
      );
      f.respond = null;
      final challenge = await f.connector.tv.beginAuthorization();
      f.scanned = true;
      f.respond = (r) => r.uri.path == '/ucdrive/token'
          ? jsonResponse({
              'code': 200,
              'data': {'status': -1, 'errno': 11004, 'access_token': 'bad'},
            })
          : null;
      await expectLater(
        f.connector.tv.pollAuthorization(challenge),
        failedWith('交换失败'),
      );
      expect(UcTvService.authorized(f.credential), isFalse);
      expect(f.calls('/user'), isEmpty);
    },
  );

  test(
    'Web Cookie rotation during token exchange is merged without replacing the account',
    () async {
      final f = UcTvFixture(credential: ucTvCredential(authorized: false));
      final challenge = await f.connector.tv.beginAuthorization();
      f.scanned = true;
      f.respond = (r) {
        if (r.uri.path != '/ucdrive/token') return null;
        return () async {
          await f.vault.putCredential(
            CloudPlatform.uc,
            f.credential.withFields({
              'primary': '__pus=web-owner; __puus=rotated',
            }, preserveRevision: true),
          );
          return ucTvToken();
        }();
      };
      expect(await f.connector.tv.pollAuthorization(challenge), isTrue);
      expect(f.credential.primary, contains('__puus=rotated'));
      expect(f.credential.updatedAt, 7);
      expect(UcTvService.authorized(f.credential), isTrue);
    },
  );

  test(
    'Replacing or removing the web account during token exchange cannot restore it',
    () async {
      for (final remove in [false, true]) {
        final f = UcTvFixture(credential: ucTvCredential(authorized: false));
        final challenge = await f.connector.tv.beginAuthorization();
        f.scanned = true;
        f.respond = (r) {
          if (r.uri.path != '/ucdrive/token') return null;
          return () async {
            if (remove) {
              await f.vault.removeCredential(CloudPlatform.uc);
            } else {
              await f.vault.putCredential(
                CloudPlatform.uc,
                ucTvCredential(authorized: false, revision: 8),
              );
            }
            return ucTvToken();
          }();
        };
        await expectLater(
          f.connector.tv.pollAuthorization(challenge),
          failedWith('账号已变化'),
        );
        final current = f.vault.credential(CloudPlatform.uc);
        expect(UcTvService.authorized(current), isFalse);
        expect(current?.updatedAt, remove ? null : 8);
        expect(f.calls('/user'), isEmpty);
      }
    },
  );

  test(
    'A cancelled in-flight validation leaves the previous TV grant intact',
    () async {
      final f = UcTvFixture(), old = <String, String>{};
      old.addAll(f.credential.fields);
      final scope = RequestScope();
      final challenge = await scope.run(f.connector.tv.beginAuthorization);
      f.scanned = true;
      f.respond = (r) {
        if (r.uri.path == '/user') {
          scope.cancel();
          return ucTvOk({'data': {}});
        }
        return null;
      };
      await expectLater(
        scope.run(() => f.connector.tv.pollAuthorization(challenge)),
        failedWith('取消'),
      );
      expect(f.credential.fields, old);
    },
  );

  test(
    'Concurrent playbacks share one refresh and preserve account revision',
    () async {
      final f = UcTvFixture(credential: ucTvCredential(expiresAt: ucTvNow));
      final owner = f.credential;
      final results = await Future.wait(
        List.generate(
          4,
          (_) => f.connector.playback(ucTvPersonal, ucTvVideo, owner),
        ),
      );
      expect(results, hasLength(4));
      expect(f.calls('/ucdrive/token'), hasLength(1));
      expect(
        f.calls('/ucdrive/token').single.json['refresh_token'],
        'tv-refresh-private',
      );
      expect(f.calls('/file'), hasLength(4));
      expect(
        f.calls('/file').map((r) => r.uri.queryParameters['access_token']),
        everyElement('new-tv-access'),
      );
      expect(f.credential.updatedAt, 7);
      expect(f.credential.primary, owner.primary);
    },
  );

  test(
    'An API token rejection refreshes once, retries once, then requires reauthorization',
    () async {
      final f = UcTvFixture();
      f.respond = (r) => r.uri.path == '/file' ? ucTvError(10001) : null;
      await expectLater(
        f.connector.playback(ucTvPersonal, ucTvVideo, f.credential),
        tvRequired,
      );
      expect(f.calls('/file'), hasLength(2));
      expect(f.calls('/ucdrive/token'), hasLength(1));
      expect(f.credential.field('tv_status'), 'expired');
      expect(f.credential.primary, contains('web-session'));
    },
  );

  test(
    'Live-observed refresh errno 11000 becomes reauthorization without looping',
    () async {
      final f = UcTvFixture(credential: ucTvCredential(expiresAt: ucTvNow));
      f.respond = (r) => r.uri.path == '/ucdrive/token'
          ? jsonResponse({
              'code': 200,
              'data': {'status': -1, 'errno': 11000},
            })
          : null;
      await expectLater(
        f.connector.playback(ucTvPersonal, ucTvVideo, f.credential),
        tvRequired,
      );
      expect(f.calls('/ucdrive/token'), hasLength(1));
      expect(f.calls('/file'), isEmpty);
      expect(UcTvService.authorized(f.credential), isFalse);
    },
  );

  test(
    'Temporary exchange failure does not discard a refresh token or invalidate the web account',
    () async {
      final f = UcTvFixture(credential: ucTvCredential(expiresAt: ucTvNow));
      final previous = f.credential;
      f.respond = (r) =>
          r.uri.path == '/ucdrive/token' ? const HttpResult(503, '{}') : null;
      await expectLater(
        f.connector.playback(ucTvPersonal, ucTvVideo, previous),
        failedWith('续期失败'),
      );
      expect(f.credential.sameAs(previous), isTrue);
      expect(f.calls('/file'), isEmpty);
    },
  );

  test(
    'Removing a TV grant while refresh is pending prevents late resurrection',
    () async {
      final f = UcTvFixture(credential: ucTvCredential(expiresAt: ucTvNow));
      f.respond = (r) {
        if (r.uri.path != '/ucdrive/token') return null;
        return () async {
          await f.connector.tv.removeAuthorization();
          return ucTvToken();
        }();
      };
      await expectLater(
        f.connector.playback(ucTvPersonal, ucTvVideo, f.credential),
        tvRequired,
      );
      expect(f.credential.field('tv_access_token'), isEmpty);
      expect(f.credential.field('tv_refresh_token'), isEmpty);
      expect(f.credential.updatedAt, 7);
      expect(f.credential.primary, contains('web-session'));
    },
  );

  test(
    'New web login candidates never inherit a TV grant from the previous account',
    () {
      final candidate = LoginCredentials.candidate(
        CloudPlatform.uc,
        '__pus=other; __puus=other-session',
        ucTvCredential(),
      );
      expect(UcTvService.authorized(candidate), isFalse);
      expect(
        candidate.fields.keys.any((key) => key.startsWith('tv_')),
        isFalse,
      );
    },
  );

  test(
    'An explicit web login can replace an account whose TV token renewed during validation',
    () async {
      final f = UcTvFixture();
      final login = AccountLoginService(
        f.vault,
        (_, _) async => const CloudAccount('新的 UC 账号'),
      );
      final result = await login.submit(CloudPlatform.uc, (_) async {
        await f.vault.putCredential(
          CloudPlatform.uc,
          f.credential.withFields({
            'tv_access_token': 'background-renewed',
            'tv_refresh_token': 'background-refresh',
          }, preserveRevision: true),
        );
        return LoginResult(
          Credential('UC', {'primary': '__pus=other; __puus=other-session'}),
          const CloudAccount('新的 UC 账号'),
        );
      });
      expect(result.credential.updatedAt, greaterThan(7));
      expect(f.credential.primary, contains('__pus=other'));
      expect(UcTvService.authorized(f.credential), isFalse);
    },
  );

  test(
    'Streaming picks highest accessible quality and uses its own size and headers',
    () async {
      final f = UcTvFixture();
      final result = await f.repository.preparePlayback(
        ucTvPersonal,
        const CloudFile(
          id: 'video-1',
          name: '视频.mp4',
          size: 400,
          hashType: 'md5',
          hashValue: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
      );
      expect(result.url, 'https://media.example/video.mp4?sign=a%2Bb%2Fc&n=1');
      expect(result.expectedSize, 123);
      expect(result.checksumValue, isNull);
      expect(result.checksumType, isNull);
      expect(result.headers, isEmpty);
      expect(result.source!['accountRevision'], 7);
      expect(f.calls('/1/clouddrive/file/download'), isEmpty);
      final request = f.calls('/file').single;
      expect(request.uri.queryParameters['method'], 'streaming');
      expect(
        request.uri.queryParameters['resolution'],
        'low,normal,high,super,2k,4k',
      );
      expect(request.headers['x-pan-tm'], '$ucTvNow');
      expect(request.headers['x-pan-client-id'], UcTvProtocol.clientId);
      expect(request.headers.containsKey('Cookie'), isFalse);
    },
  );

  test(
    'Inaccessible, malformed and wrong-file streams fail without falling back to original download',
    () async {
      for (final data in [
        {'fid': 'wrong', 'video_info': []},
        {
          'video_info': [
            {'url': 'https://media.example/denied', 'accessable': 0},
          ],
        },
        {
          'video_info': [
            {'url': 'https://user:password@media.example/clip'},
          ],
        },
        {
          'video_info': [
            {'url': 'file:///C:/video.mp4'},
          ],
        },
        {
          'video_info': [
            {'url': 'https://media.example/other', 'fid': 'wrong'},
          ],
        },
      ]) {
        final f = UcTvFixture();
        f.respond = (r) =>
            r.uri.path == '/file' ? ucTvOk({'data': data}) : null;
        await expectLater(
          f.connector.playback(ucTvPersonal, ucTvVideo, f.credential),
          throwsA(isA<AppException>()),
        );
        expect(f.calls('/1/clouddrive/file/download'), isEmpty);
        expect(f.calls('/ucdrive/token'), isEmpty);
      }
    },
  );

  test(
    'Missing TV grant stops before any personal or shared-file request',
    () async {
      final f = UcTvFixture(credential: ucTvCredential(authorized: false));
      for (final session in [ucTvPersonal, ucTvShare]) {
        await expectLater(
          f.connector.playback(session, ucTvVideo, f.credential),
          tvRequired,
        );
      }
      expect(f.http.calls, isEmpty);
      expect(f.staged, isEmpty);
    },
  );

  test(
    'Shared video uses the saved personal fid and stages cleanup before transferring',
    () async {
      final f = UcTvFixture();
      f.respond = (r) {
        if (r.uri.path == '/1/clouddrive/share/sharepage/save') {
          expect(f.staged, hasLength(1));
          expect(r.json['fid_list'], ['video-1']);
          expect(r.json['fid_token_list'], ['share-file-token']);
          expect(r.headers['Cookie'], contains('__pus='));
        }
        return null;
      };
      final result = await f.connector.playback(
        ucTvShare,
        ucTvVideo,
        f.credential,
      );
      expect(f.calls('/file').single.uri.queryParameters['fid'], 'saved-video');
      expect(f.calls('/file').single.headers.containsKey('Cookie'), isFalse);
      expect(result.cleanup, same(f.staged.single));
      expect(result.expectedSize, 123);
      expect(jsonDecode(result.cleanup!.body!)['filelist'], ['temporary']);
      expect(f.calls('/1/clouddrive/file/download'), isEmpty);
    },
  );

  test(
    'Failed stream lookup cleans only its newly created share-transfer directory',
    () async {
      final f = UcTvFixture();
      f.respond = (r) => r.uri.path == '/file'
          ? ucTvOk({
              'data': {'video_info': []},
            })
          : null;
      await expectLater(
        f.connector.playback(ucTvShare, ucTvVideo, f.credential),
        failedWith('暂无可播放'),
      );
      expect(f.calls('/1/clouddrive/file/delete'), hasLength(1));
      expect(f.calls('/1/clouddrive/file/delete').single.json['filelist'], [
        'temporary',
      ]);
      expect(f.calls('/1/clouddrive/file/download'), isEmpty);
    },
  );

  test(
    'Original video downloads and audio playback continue through the web connector',
    () async {
      final f = UcTvFixture(credential: ucTvCredential(authorized: false));
      final original = await f.connector.download(
        ucTvPersonal,
        ucTvVideo,
        f.credential,
      );
      final audio = await f.connector.playback(
        ucTvPersonal,
        const CloudFile(id: 'video-1', name: '音频.mp3', size: 400),
        f.credential,
      );
      expect(original.expectedSize, 400);
      expect(audio.expectedSize, 400);
      expect(original.headers['Cookie'], contains('web-session'));
      expect(f.calls('/1/clouddrive/file/download'), hasLength(2));
      expect(f.calls('/file'), isEmpty);
      expect(f.calls('/ucdrive/token'), isEmpty);
    },
  );
}
