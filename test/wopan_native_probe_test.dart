import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

class _RejectDartProbe extends TransferHttp {
  int calls = 0;
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async {
    calls++;
    throw const DownloadNetworkException('dart-tls');
  }
}

class _ProbeNative extends FakeNative {
  _ProbeNative(this.result);
  final Json Function(int starts) result;
  int starts = 0, stops = 0;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'httpProbeStart') {
      starts++;
      return null;
    }
    if (method == 'httpProbeStatus') return result(starts);
    if (method == 'httpProbeStop') {
      stops++;
      return null;
    }
    return super.call(method, args);
  }
}

const _valid = {
  'status': 'done',
  'code': 206,
  'headers': {'content-range': 'bytes 0-0/4', 'etag': '"fixture"'},
};
const _source = DownloadSpec(
  url: 'https://hydownload.pan.wo.cn/local-fixture',
  fileName: 'sample.bin',
  profile: 'wopan',
  expectedSize: 4,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late StateStore store;
  late _RejectDartProbe http;
  DownloadManager? manager;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('aster-wopan-probe-');
    store = StateStore.memory();
    http = _RejectDartProbe();
  });
  tearDown(() async {
    await manager?.close();
    manager?.dispose();
    manager = null;
    http.dio.close(force: true);
    await root.delete(recursive: true);
  });
  DownloadManager makeManager(NativeTransport transport) {
    final engine = GopeedEngine(
      transport,
      store,
      Vault(store),
      Directory(p.join(root.path, 'native')),
      Directory(p.join(root.path, 'cache')),
    );
    return manager = DownloadManager(
      store: store,
      engine: engine,
      files: FakeFiles(Directory(p.join(root.path, 'saved'))),
      cleanups: CleanupOutbox(store, FakeHttp()),
      http: http,
      refreshSource: (source) async => source,
    );
  }

  test(
    'Wopan uses the actual native probe and downloader when Dart TLS is unavailable',
    () async {
      final payload = Uint8List.fromList(
        List.generate(512 * 1024, (i) => i % 251),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var probes = 0;
      server.listen((request) async {
        final response = request.response;
        try {
          final range = request.headers.value('range');
          final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range ?? '');
          final first = match == null ? 0 : int.parse(match.group(1)!);
          final last = match == null
              ? payload.length - 1
              : int.parse(match.group(2)!);
          if (first == 0 && last == 0) probes++;
          response.headers.set('etag', '"local-file"');
          if (match != null) {
            response.statusCode = 206;
            response.headers.set(
              'content-range',
              'bytes $first-$last/${payload.length}',
            );
          }
          response.contentLength = last - first + 1;
          response.add(payload.sublist(first, last + 1));
          await response.close();
        } on IOException {
          // A completed probe closes its stream immediately.
        }
      });
      final current = makeManager(
        DesktopGopeedTransport(
          executable: File('native/bin/asterlink_gopeed.exe').absolute.path,
        ),
      );
      await current.initialize();
      final id = await current.enqueue(
        DownloadSpec(
          url: 'http://127.0.0.1:${server.port}/sample.bin',
          fileName: 'sample.bin',
          profile: 'wopan',
          expectedSize: payload.length,
        ),
      );
      await until(() => !current.task(id)!.active && current.activeCount == 0);
      expect(current.task(id)!.status, DownloadStatus.completed);
      expect(await File(current.task(id)!.savedPath!).readAsBytes(), payload);
      expect(current.task(id)!.identity.strongEtag, '"local-file"');
      expect(probes, greaterThanOrEqualTo(2));
      expect(http.calls, 0);
    },
  );

  for (final (kind, retries, recover) in [
    ('network', 1, true),
    ('network', 0, false),
    ('certificate', 3, false),
    ('bad-range', 3, false),
    ('changed-size', 3, false),
  ]) {
    test('Wopan native probe: $kind with $retries retries', () async {
      await store.put('settings', {'retries': retries});
      final native = _ProbeNative((starts) {
        if (starts > 1) return _valid;
        if (kind == 'bad-range' || kind == 'changed-size') {
          return {
            ..._valid,
            'headers': {
              'content-range': kind == 'bad-range'
                  ? 'bytes 1-1/4'
                  : 'bytes 0-0/40',
            },
          };
        }
        return {
          'status': 'error',
          'errorKind': kind,
          'retryable': kind == 'network',
        };
      });
      final current = makeManager(native);
      await current.initialize();
      final id = await current.enqueue(_source);
      await until(() => !current.task(id)!.active && current.activeCount == 0);
      expect(
        current.task(id)!.status,
        recover ? DownloadStatus.completed : DownloadStatus.failed,
      );
      expect(native.starts, recover ? 2 : 1);
      expect(native.stops, native.starts);
      expect(native.begins.length, recover ? 1 : 0);
      expect(http.calls, 0);
    });
  }

  test(
    'Pausing Wopan during native probing cancels before downloading',
    () async {
      final native = _ProbeNative((_) => {'status': 'running'});
      final current = makeManager(native);
      await current.initialize();
      final id = await current.enqueue(_source);
      await until(() => native.starts == 1);
      await current.pause(id).timeout(const Duration(seconds: 2));
      expect(current.task(id)!.status, DownloadStatus.paused);
      expect(native.stops, 1);
      expect(native.begins, isEmpty);
      expect(http.calls, 0);
    },
  );
}
