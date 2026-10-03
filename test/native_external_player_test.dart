import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/external_stream.dart';
import 'player_support.dart';
import 'support.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = [
    Platform.environment['ASTERLINK_MPV_LIBRARY'],
    '.local/player-test/libmpv/libmpv-2.dll',
    'build/windows/x64/runner/Release/libmpv-2.dll',
  ].whereType<String>().where((path) => File(path).existsSync()).firstOrNull;

  test(
    'A separate native decoder plays and seeks the authenticated stream while the app is backgrounded',
    () async {
      MediaKit.ensureInitialized(libmpv: library);
      final bytes = await File('test/fixtures/player-sample.mkv').readAsBytes();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final handlers = <Future<void>>[];
      final cookies = <String?>[];
      Future<void> serve(HttpRequest request) async {
        try {
          cookies.add(request.headers.value('cookie'));
          if (request.headers.value('cookie') != 'video=fixture') {
            request.response.statusCode = 403;
            return;
          }
          final range = RegExp(
            r'bytes=(\d+)-(\d*)',
          ).firstMatch(request.headers.value('range') ?? '');
          final start = int.tryParse(range?[1] ?? '') ?? 0;
          final end = math.min(
            bytes.length - 1,
            int.tryParse(range?[2] ?? '') ?? bytes.length - 1,
          );
          if (range != null) {
            request.response.statusCode = 206;
            request.response.headers.set(
              'Content-Range',
              'bytes $start-$end/${bytes.length}',
            );
          }
          request.response.headers.set('Content-Type', 'video/x-matroska');
          request.response.headers.set('Accept-Ranges', 'bytes');
          request.response.contentLength = end - start + 1;
          if (request.method != 'HEAD') {
            request.response.add(bytes.sublist(start, end + 1));
          }
        } catch (_) {
          // Native decoders cancel reads when seeking.
        } finally {
          try {
            await request.response.close();
          } catch (_) {}
        }
      }

      server.listen((request) => handlers.add(serve(request)));
      final fixture = PlaybackFixture(
        count: 1,
        externalStreamFactory: (_) => HttpOverrides.runWithHttpOverrides(
          () => ExternalPlaybackStream(
            DownloadSpec(
              url: 'http://127.0.0.1:${server.port}/movie.mkv',
              fileName: 'movie.mkv',
              headers: {'Cookie': 'video=fixture'},
            ),
          ),
          _RealHttp(),
        ),
      );
      final player = Player();
      addTearDown(() async {
        await player.dispose();
        await fixture.controller.close();
        await server.close(force: true);
        await Future.wait(handlers);
      });
      final native = player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      await native.setProperty('vo', 'null');
      await fixture.controller.start();
      await fixture.controller.openExternalPlayer((url, _, _) async {
        await player.open(Media(url));
        return true;
      });
      await fixture.controller.background(pictureInPicture: false);
      await until(
        () =>
            player.state.duration.inSeconds >= 8 &&
            player.state.position.inMilliseconds > 200,
      );
      expect(fixture.controller.state.playing, isFalse);
      expect(fixture.controller.playingExternally, isTrue);
      await player.seek(const Duration(seconds: 3));
      await until(() => player.state.position.inMilliseconds > 3200);
      expect(player.state.playing, isTrue);
      expect(cookies, isNotEmpty);
      expect(cookies, everyElement('video=fixture'));
    },
    skip: !Platform.isWindows || library == null
        ? 'Requires the local Windows libmpv test runtime.'
        : false,
  );
}
