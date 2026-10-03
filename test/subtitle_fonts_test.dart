import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/playback/font_metadata.dart';
import 'package:asterlink/playback/subtitle_fonts.dart';
import 'player_support.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final font = File('assets/fonts/NotoSansSC-Regular.otf').absolute;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'asterlink-player-fonts-',
    );
  });
  tearDown(() => removePlayerFixture(directory));

  Future<HttpServer> serve(Future<void> Function(HttpRequest) handle) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      try {
        await handle(request);
        await request.response.close();
      } on IOException {
        // Truncation, timeout and size-limit cases deliberately abort sockets.
      }
    });
    return server;
  }

  Uri endpoint(HttpServer server, [String path = '/font']) =>
      Uri.parse('http://127.0.0.1:${server.port}$path');
  SubtitleFontStore store({
    List<String> systemFiles = const [],
    List<Uri> urls = const [],
    Duration deadline = const Duration(seconds: 10),
    Duration idle = const Duration(seconds: 3),
    HttpClient Function()? client,
  }) => SubtitleFontStore(
    systemFiles: () async => systemFiles,
    directory: () async => directory,
    downloadUrls: urls,
    clientFactory: client ?? () => _RealHttp().createHttpClient(null),
    downloadTimeout: deadline,
    idleTimeout: idle,
  );
  Future<void> sendFont(HttpRequest request) async {
    request.response.contentLength = SubtitleFontStore.fontBytes;
    await request.response.addStream(font.openRead());
  }

  File cachedFont() => File(
    p.join(
      directory.path,
      SubtitleFontStore.fontSha256,
      'NotoSansSC-Regular.otf',
    ),
  );
  Future<void> expectNoPartial() async {
    final partial = Directory(p.join(directory.path, 'partial'));
    if (await partial.exists()) expect(await partial.list().toList(), isEmpty);
  }

  test(
    'Reads the real CJK font family and rejects a misleading file name',
    () async {
      final metadata = inspectSubtitleFont(font.path);
      expect(metadata?.family, 'Noto Sans SC');
      final fake = await File(
        p.join(directory.path, 'NotoSansCJK-Regular.ttc'),
      ).writeAsString('<html>download unavailable</html>');
      expect(inspectSubtitleFont(fake.path), isNull);
      expect(findChineseSubtitleFont([fake.path, font.path])?.path, font.path);
    },
  );

  test(
    'Rejects a font without Chinese glyphs and malformed table offsets',
    () async {
      final bytes = await font.readAsBytes();
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < data.getUint16(4); i++) {
        final at = 12 + i * 16;
        if (data.getUint32(at) != 0x636d6170) continue;
        final offset = data.getUint32(at + 8), length = data.getUint32(at + 12);
        bytes.fillRange(offset, offset + length, 0);
        final empty = await File(
          p.join(directory.path, 'empty.otf'),
        ).writeAsBytes(bytes);
        expect(inspectSubtitleFont(empty.path), isNull);
        data.setUint32(at + 8, 0x7fffffff);
        final corrupt = await File(
          p.join(directory.path, 'corrupt.otf'),
        ).writeAsBytes(bytes);
        expect(inspectSubtitleFont(corrupt.path), isNull);
        return;
      }
      fail('Fixture has no cmap table');
    },
  );

  test(
    'Reads a real Windows TTC and rejects an oversized TTC face count',
    () async {
      final collection = File(r'C:\Windows\Fonts\msyh.ttc');
      if (await collection.exists()) {
        expect(inspectSubtitleFont(collection.path)?.family, contains('YaHei'));
      }
      final header = ByteData(12)
        ..setUint32(0, 0x74746366)
        ..setUint32(4, 0x00010000)
        ..setUint32(8, 0x7fffffff);
      final invalid = await File(
        p.join(directory.path, 'invalid.ttc'),
      ).writeAsBytes(header.buffer.asUint8List());
      expect(inspectSubtitleFont(invalid.path), isNull);
    },
  );

  test(
    'System font wins without networking and exposes only one file to libass',
    () async {
      final fonts = store(
        systemFiles: [font.path],
        client: () =>
            throw StateError('System fonts must not cause network access'),
      );
      final ready = await fonts.ensureAvailable();
      expect(ready.origin, SubtitleFontOrigin.system);
      expect(ready.family, 'Noto Sans SC');
      expect(await File(ready.path).length(), SubtitleFontStore.fontBytes);
      expect(await Directory(ready.directory).list().length, 1);
      expect((await fonts.local())?.path, ready.path);
    },
  );

  test('Missing local fonts do not implicitly start a download', () async {
    final fonts = store(
      client: () => throw StateError('Unexpected network access'),
    );
    expect(await fonts.local(), isNull);
    expect(await cachedFont().exists(), isFalse);
  });

  test(
    'Concurrent players share a verified download and a new process can reuse it offline',
    () async {
      var requests = 0;
      final server = await serve((request) async {
        requests++;
        await sendFont(request);
      });
      final fonts = store(urls: [endpoint(server)]);
      final results = await Future.wait(
        List.generate(8, (_) => fonts.ensureAvailable()),
      );
      expect(requests, 1);
      expect(results.map((font) => font.path).toSet(), hasLength(1));
      expect(results.first.origin, SubtitleFontOrigin.download);
      expect(
        (await sha256.bind(cachedFont().openRead()).first).toString(),
        SubtitleFontStore.fontSha256,
      );
      final offline = store(
        client: () => throw StateError('Cache must work offline'),
      );
      expect(
        (await offline.ensureAvailable()).origin,
        SubtitleFontOrigin.cache,
      );
      await expectNoPartial();
    },
  );

  test(
    'An incomplete download is never exposed as the available font',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      final server = await serve((request) async {
        request.response.contentLength = SubtitleFontStore.fontBytes;
        request.response.add(await font.openRead(0, 1024).first);
        await request.response.flush();
        started.complete();
        await release.future;
        await request.response.addStream(font.openRead(1024));
      });
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final fonts = store(urls: [endpoint(server)]);
      final task = fonts.ensureAvailable();
      await started.future;
      expect(await fonts.local(), isNull);
      expect(await cachedFont().exists(), isFalse);
      release.complete();
      expect((await task).origin, SubtitleFontOrigin.download);
      await expectNoPartial();
    },
  );

  test(
    'A corrupt mirror is rejected by SHA-256 and the next source succeeds',
    () async {
      final requests = <String>[];
      final server = await serve((request) async {
        requests.add(request.uri.path);
        if (request.uri.path == '/bad') {
          final bytes = await font.readAsBytes();
          bytes[bytes.length - 1] ^= 1;
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
        } else {
          await sendFont(request);
        }
      });
      final fonts = store(urls: [endpoint(server, '/bad'), endpoint(server)]);
      expect((await fonts.ensureAvailable()).family, 'Noto Sans SC');
      expect(requests, ['/bad', '/font']);
      await expectNoPartial();
    },
  );

  for (final fault in ['404', 'truncated', 'oversized', 'redirect-loop']) {
    test(
      'A $fault response leaves no usable file and a later attempt can retry',
      () async {
        var broken = true;
        final server = await serve((request) async {
          if (!broken) return sendFont(request);
          switch (fault) {
            case '404':
              request.response.statusCode = 404;
            case 'truncated':
              request.response.add([0, 1, 2, 3]);
            case 'oversized':
              // Chunked responses must also obey the size limit.
              await request.response.addStream(font.openRead());
              request.response.add([1]);
            case 'redirect-loop':
              request.response.statusCode = 302;
              request.response.headers.set('location', '/font');
          }
        });
        final fonts = store(urls: [endpoint(server)]);
        await expectLater(
          fonts.ensureAvailable(),
          throwsA(isA<FileSystemException>()),
        );
        expect(await cachedFont().exists(), isFalse);
        await expectNoPartial();
        broken = false;
        expect(
          (await fonts.ensureAvailable()).origin,
          SubtitleFontOrigin.download,
        );
      },
    );
  }

  test(
    'A stalled transfer times out, closes its partial file and can retry',
    () async {
      var stall = true;
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final server = await serve((request) async {
        if (!stall) return sendFont(request);
        request.response.add([1, 2, 3]);
        await request.response.flush();
        await release.future;
      });
      final fonts = store(
        urls: [endpoint(server)],
        deadline: const Duration(seconds: 3),
        idle: const Duration(milliseconds: 350),
      );
      final watch = Stopwatch()..start();
      await expectLater(
        fonts.ensureAvailable(),
        throwsA(isA<FileSystemException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      await expectNoPartial();
      stall = false;
      release.complete();
      expect(
        (await fonts.ensureAvailable()).origin,
        SubtitleFontOrigin.download,
      );
    },
  );

  test('A slow trickle cannot evade the total deadline', () async {
    final server = await serve((request) async {
      for (var i = 0; i < 20; i++) {
        request.response.add([i]);
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    });
    final fonts = store(
      urls: [endpoint(server)],
      deadline: const Duration(milliseconds: 300),
      idle: const Duration(milliseconds: 200),
    );
    await expectLater(
      fonts.ensureAvailable(),
      throwsA(isA<FileSystemException>()),
    );
    expect(await cachedFont().exists(), isFalse);
    await expectNoPartial();
  });

  test('A corrupted persistent cache is discarded and reacquired', () async {
    final cached = cachedFont();
    await cached.parent.create(recursive: true);
    final bytes = await font.readAsBytes();
    bytes[bytes.length - 1] ^= 1;
    await cached.writeAsBytes(bytes);
    var requests = 0;
    final server = await serve((request) async {
      requests++;
      await sendFont(request);
    });
    final fonts = store(urls: [endpoint(server)]);
    expect(await fonts.local(), isNull);
    expect(await cached.exists(), isFalse);
    expect((await fonts.ensureAvailable()).origin, SubtitleFontOrigin.download);
    expect(requests, 1);
  });

  test(
    'Removing a resolved cache file does not leave a permanent stale hit',
    () async {
      final server = await serve(sendFont);
      final fonts = store(urls: [endpoint(server)]);
      final ready = await fonts.ensureAvailable();
      await File(ready.path).delete();
      expect(await fonts.local(), isNull);
      expect((await fonts.ensureAvailable()).path, ready.path);
    },
  );
}
