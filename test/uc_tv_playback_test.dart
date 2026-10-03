import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/playback_sources.dart';
import 'package:asterlink/playback/recent_playback.dart';
import 'player_support.dart';
import 'support.dart';
import 'uc_tv_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppServices servicesFor(UcTvFixture f) {
    final services = AppServices(
      controlEnabled: false,
      store: f.store,
      dataDirectory: Directory('test-fixture'),
      cacheDirectory: Directory('test-fixture/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('test-fixture/saved')),
      http: f.http,
      platformFeatures: false,
    );
    services.cloud.connectors[CloudPlatform.uc] = f.connector;
    addTearDown(services.close);
    return services;
  }

  test(
    'Player retries after TV authorization without invalidating its original web account',
    () async {
      final f = UcTvFixture(credential: ucTvCredential(authorized: false));
      final services = servicesFor(f);
      final controller = cloudPlayback(
        services,
        ucTvPersonal,
        ucTvVideo,
        [ucTvVideo],
        backendFactory: (entry, _) => FakePlaybackBackend(entry.id, []),
      );
      addTearDown(controller.close);
      await controller.start();
      expect(controller.sourceError, isA<UcTvAuthorizationRequired>());
      expect(controller.ready, isFalse);
      final challenge = await f.connector.tv.beginAuthorization();
      f.scanned = true;
      await f.connector.tv.pollAuthorization(challenge);
      await controller.retry();
      expect(controller.ready, isTrue);
      expect(controller.sourceError, isNull);
      expect(f.credential.updatedAt, 7);
    },
  );

  test(
    'UC player download action resolves the original file instead of enqueueing a transcode',
    () async {
      final f = UcTvFixture(), services = servicesFor(f);
      final controller = cloudPlayback(
        services,
        ucTvPersonal,
        ucTvVideo,
        [ucTvVideo],
        backendFactory: (entry, _) => FakePlaybackBackend(entry.id, []),
      );
      addTearDown(controller.close);
      await controller.start();
      final played = (controller.backend as FakePlaybackBackend).openedSource!;
      expect(played.expectedSize, 123);
      final download = await controller.acquireForDownload();
      expect(download.url, 'https://media.example/original.mp4');
      expect(download.expectedSize, ucTvVideo.size);
      expect(download.headers, isEmpty);
      expect(played.headers, isEmpty);
      expect(f.calls('/file').map((r) => r.uri.queryParameters['method']), [
        'streaming',
        'download',
      ]);
      expect(f.calls('/1/clouddrive/file/download'), isEmpty);
    },
  );

  test(
    'Episode selection, address refresh and history reopen all use TV streaming',
    () async {
      final f = UcTvFixture(), services = servicesFor(f);
      const next = CloudFile(
        id: 'video-2',
        name: '第二集.mp4',
        size: 400,
        parentId: '0',
      );
      f.respond = (r) => r.uri.path == '/1/clouddrive/file/sort'
          ? jsonResponse({
              'status': 200,
              'code': 0,
              'data': {
                'list': [
                  for (final file in [ucTvVideo, next])
                    {
                      'fid': file.id,
                      'file_name': file.name,
                      'size': file.size,
                      'pdir_fid': '0',
                    },
                ],
              },
            })
          : null;
      FakePlaybackBackend backend(entry, _) =>
          FakePlaybackBackend(entry.id, []);
      final controller = cloudPlayback(services, ucTvPersonal, ucTvVideo, [
        ucTvVideo,
        next,
      ], backendFactory: backend);
      addTearDown(controller.close);
      await controller.start();
      expect(controller.ready, isTrue);
      await controller.next();
      expect(f.calls('/file').last.uri.queryParameters['fid'], next.id);
      await controller.retry();
      expect(f.calls('/file').last.uri.queryParameters['fid'], next.id);
      final player = controller.backend as FakePlaybackBackend;
      player.emit(player.state.copyWith(position: const Duration(seconds: 35)));
      await controller.saveProgress();
      final record = PlaybackStore(f.store).recent.first;
      final encodedHistory = jsonEncode(f.store.data['playbackHistory']);
      for (final secret in [
        'tv-access-private',
        'tv-refresh-private',
        'web-session',
        'sign=',
      ]) {
        expect(encodedHistory, isNot(contains(secret)));
      }
      await controller.close();
      final reopened = await restoreRecentPlayback(
        services,
        record,
        backendFactory: backend,
      );
      addTearDown(reopened.close);
      await reopened.start();
      expect(reopened.ready, isTrue);
      expect(reopened.resumedFrom, const Duration(seconds: 35));
      expect(f.calls('/file').last.uri.queryParameters['fid'], next.id);
      expect(f.calls('/1/clouddrive/file/download'), isEmpty);
    },
  );
}
