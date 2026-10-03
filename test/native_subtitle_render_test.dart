import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/media_backend.dart';
import 'package:asterlink/playback/subtitle_fonts.dart';
import 'player_support.dart';
import 'support.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = [
    Platform.environment['ASTERLINK_MPV_LIBRARY'],
    '.local/player-test/libmpv/libmpv-2.dll',
  ].whereType<String>().where((path) => File(path).existsSync()).firstOrNull;

  for (final source in ['system', 'cache', 'late-download']) {
    test(
      'Native libass renders Chinese ASS from $source without implicit system fonts or a Flutter overlay',
      () async {
        MediaKit.ensureInitialized(libmpv: library);
        final directory = await Directory.systemTemp.createTemp(
          'asterlink-player-libass-',
        );
        addTearDown(() => removePlayerFixture(directory));
        final fontCache = Directory('${directory.path}/fonts');
        final releaseFont = Completer<void>();
        final urls = <Uri>[];
        if (source == 'cache') {
          final cached = File(
            '${fontCache.path}/${SubtitleFontStore.fontSha256}/NotoSansSC-Regular.otf',
          );
          await cached.parent.create(recursive: true);
          await File('assets/fonts/NotoSansSC-Regular.otf').copy(cached.path);
        } else if (source == 'late-download') {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          addTearDown(() {
            if (!releaseFont.isCompleted) releaseFont.complete();
          });
          server.listen((request) async {
            try {
              await releaseFont.future;
              request.response.contentLength = SubtitleFontStore.fontBytes;
              await request.response.addStream(
                File('assets/fonts/NotoSansSC-Regular.otf').openRead(),
              );
              await request.response.close();
            } on IOException {
              // The player may close before the shared download finishes.
            }
          });
          urls.add(Uri.parse('http://127.0.0.1:${server.port}/font'));
        }
        final fonts = SubtitleFontStore(
          directory: () async => fontCache,
          systemFiles: source == 'system' ? null : () async => [],
          clientFactory: () => _RealHttp().createHttpClient(null),
          downloadUrls: urls,
        );
        final subtitle = await File('${directory.path}/styled.ass')
            .writeAsString(r'''
[Script Info]
ScriptType: v4.00+
PlayResX: 320
PlayResY: 180
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Noto Sans SC,22,&H0000FF00,&H0000FF00,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:08.00,Default,,0,0,0,,{\an7\pos(16,20)}原生中文字幕
''');
        final player = Player(
          configuration: const PlayerConfiguration(libass: true, vo: 'null'),
        );
        final backend = MediaKitBackend(
          video: false,
          player: player,
          subtitleFonts: fonts,
        );
        addTearDown(backend.close);
        final native = player.platform as NativePlayer;
        await native.setProperty('ao', 'null');
        await native.setProperty('vid', 'auto');
        await native.setProperty('hwdec', 'no');
        // Model Android's libass build: no implicit DirectWrite/fontconfig fonts.
        await native.setProperty('sub-font-provider', 'none');
        await backend.open(
          DownloadSpec(
            url: File('test/fixtures/player-sample.mkv').absolute.path,
            fileName: 'sample.mkv',
          ),
          Duration.zero,
        );
        await backend.setSubtitleTrack(
          SubtitleTrack.uri(subtitle.uri.toString()),
        );
        await backend.setSubtitlePresentation(
          size: 22,
          height: 180,
          bottom: .25,
        );
        await backend.play();
        await until(
          () =>
              player.state.position.inMilliseconds >= 1100 &&
              (player.state.width ?? 0) > 1,
        );
        await backend.pause();
        if (source == 'late-download') {
          expect(backend.subtitleFontLoading, isTrue);
          expect(backend.failure, isNull);
          final position = player.state.position;
          releaseFont.complete();
          await until(() => !backend.subtitleFontLoading);
          expect(backend.subtitleFontMessage, isEmpty);
          expect(player.state.playing, isFalse);
          expect(player.state.position, position);
          expect(player.state.track.subtitle.uri, isTrue);
        }
        expect(
          backend.diagnosticFields['subtitleFontSource'],
          source == 'late-download' ? 'download' : source,
        );
        final clean = await player.screenshot(format: 'image/png');
        final styled = await player.screenshot(
          format: 'image/png',
          includeLibassSubtitles: true,
        );
        expect(clean, isNotNull);
        expect(styled, isNotNull);
        final cleanCodec = await ui.instantiateImageCodec(clean!);
        final styledCodec = await ui.instantiateImageCodec(styled!);
        final cleanFrame = (await cleanCodec.getNextFrame()).image;
        final styledFrame = (await styledCodec.getNextFrame()).image;
        final a = (await cleanFrame.toByteData())!.buffer.asUint8List();
        final b = (await styledFrame.toByteData())!.buffer.asUint8List();
        var green = 0, top = styledFrame.height, bottom = 0;
        for (var i = 0; i + 3 < b.length; i += 4) {
          if (a[i] == b[i] && a[i + 1] == b[i + 1] && a[i + 2] == b[i + 2]) {
            continue;
          }
          if (b[i + 1] > b[i] + 30 && b[i + 1] > b[i + 2] + 30) {
            green++;
            final y = (i ~/ 4) ~/ styledFrame.width;
            if (y < top) top = y;
            if (y > bottom) bottom = y;
          }
        }
        expect(green, greaterThan(40));
        expect(top, lessThan(45));
        expect(bottom, lessThan(90));
        expect(backend.rendersSubtitlesNatively, isTrue);
        cleanFrame.dispose();
        styledFrame.dispose();
        cleanCodec.dispose();
        styledCodec.dispose();
      },
      skip: library == null
          ? 'Requires the pinned Windows libmpv runtime.'
          : false,
    );
  }

  test(
    'Closing a player does not wait for its font download or attach a late result',
    () async {
      MediaKit.ensureInitialized(libmpv: library);
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-player-font-close-',
      );
      addTearDown(() => removePlayerFixture(directory));
      final release = Completer<void>(), started = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      server.listen((request) async {
        try {
          started.complete();
          await release.future;
          request.response.contentLength = SubtitleFontStore.fontBytes;
          await request.response.addStream(
            File('assets/fonts/NotoSansSC-Regular.otf').openRead(),
          );
          await request.response.close();
        } on IOException {
          // The test deliberately closes the native player first.
        }
      });
      final fonts = SubtitleFontStore(
        directory: () async => directory,
        systemFiles: () async => [],
        clientFactory: () => _RealHttp().createHttpClient(null),
        downloadUrls: [Uri.parse('http://127.0.0.1:${server.port}/font')],
      );
      final player = Player(
        configuration: const PlayerConfiguration(libass: true),
      );
      final backend = MediaKitBackend(
        video: false,
        player: player,
        subtitleFonts: fonts,
      );
      addTearDown(backend.close);
      await backend.initialize();
      await started.future;
      await backend.close().timeout(const Duration(seconds: 2));
      release.complete();
      final ready = await fonts.ensureAvailable();
      expect(await File(ready.path).exists(), isTrue);
      expect(backend.diagnosticFields['subtitleFontSource'], isNull);
    },
    skip: library == null
        ? 'Requires the pinned Windows libmpv runtime.'
        : false,
  );
}
