import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/platform/external_open.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/playback/external_playback.dart';
import 'package:asterlink/ui/downloads_page.dart';
import 'player_support.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(nativeChannel, null));

  ExternalOpenRequest request(Map<String, Object?> value) =>
      ExternalOpenRequest.fromPlatform({'id': 'external-1', ...value});

  test(
    'signed URLs and caller headers reach the player without cloud credentials',
    () async {
      const url =
          'https://cdn.example.test/film%2F01?token=opaque%2Bvalue&part=2';
      final value = request({
        'kind': 'play',
        'uri': url,
        'name': '电影.mp4',
        'headers': {
          'Cookie': 'caller-secret',
          'Referer': 'https://example.test/watch',
        },
      });
      final http = FakeHttp();
      final services = AppServices(
        store: StateStore.memory(),
        dataDirectory: Directory('test-fixture'),
        cacheDirectory: Directory('test-fixture/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('test-fixture/saved')),
        http: http,
        platformFeatures: false,
        controlEnabled: false,
      );
      final backend = FakePlaybackBackend('external', []);
      final controller = externalPlayback(
        services,
        value,
        backendFactory: (_, _) => backend,
      );
      try {
        await controller.start();
        expect(backend.openedSource!.url, url);
        expect(backend.openedSource!.headers, value.headers);
        expect(backend.openedSource!.platform, isNull);
        expect(controller.current.source, isNull);
        expect(http.calls, isEmpty);
        backend.emit(
          backend.state.copyWith(position: const Duration(seconds: 60)),
        );
        await controller.close();
        expect(backend.closed, isTrue);
        final recent = PlaybackStore(services.store).recent.single;
        expect(recent.bookmark.position, const Duration(seconds: 60));
        final stored = jsonEncode(services.store.data);
        expect(stored, isNot(contains('opaque')));
        expect(stored, isNot(contains('caller-secret')));
        expect(stored, isNot(contains('https://')));
      } finally {
        await controller.close();
        await services.close();
        services.store.dispose();
      }
    },
  );

  test('temporary document URLs are played directly with no HTTP headers', () {
    final value = request({
      'kind': 'play',
      'uri': 'content://camera.test/videos/17',
      'name': '拍摄.mp4',
      'headers': {'Cookie': 'not-for-files'},
    });
    expect(value.playbackSpec.url, 'content://camera.test/videos/17');
    expect(value.playbackSpec.headers, isEmpty);
    expect(value.fileName, '拍摄.mp4');
  });

  test(
    'plain downloads get a dialog while cloud shares and magnets keep the parser',
    () {
      final plain = request({
        'kind': 'share',
        'text': '下载地址 https://example.test/app.apk',
      });
      expect(plain.downloadUrl, 'https://example.test/app.apk');
      for (final input in [
        'https://pan.quark.cn/s/abc123 提取码: 1234',
        'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
        'https://example.test/a https://example.test/b',
      ]) {
        final value = request({'kind': 'share', 'text': input});
        expect(value.downloadUrl, isNull);
        expect(value.sharedText, input);
      }
      expect(
        request({
          'kind': 'download',
          'uri': 'https://pan.quark.cn/s/abc123',
        }).downloadUrl,
        isNull,
      );
      expect(
        request({
          'kind': 'download',
          'uri': 'https://example.test/a',
        }).downloadUrl,
        'https://example.test/a',
      );
    },
  );

  test('malformed platform requests and unsupported schemes cannot launch', () {
    for (final uri in [
      'javascript:alert(1)',
      'file:///data/file.apk',
      'https://user:secret@example.test/a',
      'https://example.test/a\n',
    ]) {
      expect(
        request({'kind': 'download', 'uri': uri}).kind,
        ExternalOpenKind.error,
      );
    }
    expect(request({'kind': 'share', 'text': ''}).kind, ExternalOpenKind.error);
    expect(
      request({'kind': 'play', 'uri': 'ftp://example.test/a.mp4'}).kind,
      ExternalOpenKind.error,
    );
    expect(request({'kind': 'unknown'}).kind, ExternalOpenKind.error);
  });

  test(
    'caller filenames are safe and injected or transport headers are removed',
    () {
      final value = request({
        'kind': 'download',
        'uri': 'https://example.test/app.apk',
        'name': '../unsafe/app.apk',
        'headers': {
          'Cookie': 'old',
          'cookie': 'new',
          'X-Allowed': 'yes',
          'Host': 'wrong.test',
          'Range': 'bytes=30-',
          'Content-Length': '1',
          'Bad Header': 'x',
          'X-Injection': 'ok\r\nSecret: value',
        },
      });
      expect(value.name, isNot(contains('/')));
      expect(value.headers, {'cookie': 'new', 'X-Allowed': 'yes'});
    },
  );

  test(
    'cold read and simultaneous availability events deliver each request once',
    () async {
      final first = Completer<List<Object?>>();
      var calls = 0;
      messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        expect(call.method, 'takeExternalOpens');
        calls++;
        if (calls == 1) return first.future;
        if (calls == 2) {
          return [
            {'id': 'two', 'kind': 'play', 'uri': 'https://example.test/2.mp4'},
            {'id': 'one', 'kind': 'play', 'uri': 'https://example.test/1.mp4'},
          ];
        }
        return [];
      });
      final inbox = ExternalOpenInbox();
      try {
        final initial = inbox.refresh();
        final event = inbox.refresh();
        first.complete([
          {'id': 'one', 'kind': 'play', 'uri': 'https://example.test/1.mp4'},
        ]);
        await Future.wait([initial, event]);
        expect(inbox.take()!.id, 'one');
        expect(inbox.take()!.id, 'two');
        expect(inbox.take(), isNull);
        await inbox.refresh();
        expect(inbox.hasPending, isFalse);
      } finally {
        inbox.dispose();
      }
    },
  );

  test(
    'an availability event from a drain listener schedules another read',
    () async {
      var reads = 0;
      messenger.setMockMethodCallHandler(nativeChannel, (_) async {
        reads++;
        return reads > 2
            ? []
            : [
                {
                  'id': '$reads',
                  'kind': 'share',
                  'text': 'https://example.test/$reads',
                },
              ];
      });
      final inbox = ExternalOpenInbox();
      inbox.addListener(() {
        if (reads == 1) unawaited(inbox.refresh());
      });
      await inbox.refresh();
      expect(inbox.take()!.id, '1');
      expect(inbox.take()!.id, '2');
      inbox.dispose();
    },
  );

  test(
    'failed platform read can retry and disposal ignores an in-flight response',
    () async {
      var failed = false;
      final response = Completer<List<Object?>>();
      messenger.setMockMethodCallHandler(nativeChannel, (_) async {
        if (!failed) {
          failed = true;
          throw PlatformException(code: 'temporary');
        }
        return response.future;
      });
      final inbox = ExternalOpenInbox();
      await expectLater(inbox.refresh(), throwsA(isA<PlatformException>()));
      final pending = inbox.refresh();
      inbox.dispose();
      response.complete([
        {'id': 'late', 'kind': 'play', 'uri': 'https://example.test/a'},
      ]);
      await pending;
      expect(inbox.hasPending, isFalse);
    },
  );

  test(
    'Android file opening forwards paths and keeps install-denied messages visible',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        calls.add(call);
        if (call.method == 'openFile') {
          throw PlatformException(
            code: 'install_permission',
            message: '尚未允许安装未知应用',
          );
        }
        return null;
      });
      await expectLater(
        nativeChannelOpen(
          '/storage/emulated/0/Download/app.apk',
          name: 'app.apk',
          share: false,
        ),
        throwsA(
          isA<AppException>().having((e) => e.message, 'message', '尚未允许安装未知应用'),
        ),
      );
      await nativeChannelOpen(
        'content://downloads.test/1',
        name: 'app.apk',
        share: true,
      );
      expect(calls.map((c) => c.method), ['openFile', 'shareFile']);
      expect(
        calls.first.arguments['path'],
        '/storage/emulated/0/Download/app.apk',
      );
    },
  );
}
