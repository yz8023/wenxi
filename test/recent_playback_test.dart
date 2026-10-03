import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/providers/quark.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/playback_source.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/playback/playback_controller.dart';
import 'package:asterlink/playback/playback_sources.dart';
import 'package:asterlink/playback/recent_playback.dart';
import 'package:asterlink/playback/torrent_playback.dart';
import 'player_support.dart';
import 'support.dart';
import 'torrent_test.dart' show testTorrent;

class _Quark extends QuarkConnector {
  _Quark() : super(FakeHttp());
  int opens = 0, lists = 0, downloads = 0, size = 4000;
  bool missing = false;
  String hash = 'fixture-hash';
  Future<void>? listBarrier;
  ParsedLink? lastLink;
  BrowseSession? downloadedSession;
  CloudFile? downloadedFile;
  final parents = <String>[];
  BrowseSession _open(BrowseMode mode, Credential? credential) {
    opens++;
    return BrowseSession(
      platform: platform,
      mode: mode,
      title: '分享视频',
      rootId: 'root-$opens',
      metadata: {
        'stoken': 'share-token-$opens',
        'cookie': credential?.primary ?? '',
      },
    );
  }

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    lastLink = link;
    return _open(BrowseMode.share, credential);
  }

  @override
  Future<BrowseSession> openPersonal(Credential credential) async =>
      _open(BrowseMode.personal, credential);
  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async {
    lists++;
    parents.add(parentId);
    await listBarrier;
    return [
      if (!missing)
        CloudFile(
          id: 'first',
          name: '第一集.mp4',
          parentId: parentId,
          size: size,
          token: 'file-token-$opens',
          hashType: 'md5',
          hashValue: hash,
        ),
      CloudFile(
        id: 'second',
        name: '第二集.mp4',
        parentId: parentId,
        size: 4000,
        token: 'file-token-$opens',
      ),
      CloudFile(id: 'notes', name: '介绍.txt', parentId: parentId),
    ];
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) => throw StateError('Cloud playback must use the playback source route');

  @override
  Future<DownloadSpec> playback(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    downloads++;
    downloadedSession = session;
    downloadedFile = file;
    return DownloadSpec(
      url: 'https://example.invalid/${file.id}?token=fresh-$opens-$downloads',
      fileName: file.name,
      expectedSize: file.size,
      headers: {
        'Cookie': credential!.primary,
        'Referer': 'https://pan.quark.cn/',
      },
    );
  }
}

class _StreamingNative extends FakeNative {
  final starts = <Json>[], stops = <String>[];
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'torrentStreamStart') {
      starts.add(args);
      return {
        'url': 'http://127.0.0.1:9988/${args.str('id')}/media.mp4',
        'size': 4,
      };
    }
    if (method == 'torrentStreamStop') {
      stops.add(args.str('id'));
      return {};
    }
    return super.call(method, args);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppServices services;
  late _Quark quark;
  late FakeFiles files;
  late _StreamingNative native;
  final instances = <AppServices>[], controllers = <PlaybackController>[];
  final backends = <FakePlaybackBackend>[];
  FakePlaybackBackend backend(PlaybackEntry entry, bool hardware) {
    final value = FakePlaybackBackend(entry.id, []);
    backends.add(value);
    return value;
  }

  void create([Json? persisted]) {
    native = _StreamingNative();
    files = FakeFiles(Directory('${root.path}/saved'));
    services = AppServices(
      controlEnabled: false,
      store: StateStore.memory(
        persisted ??
            {
              'credentials': {
                'Quark': Credential('fixture', {
                  'primary': '__pus=fixture; __puus=old-cookie',
                }, updatedAt: 42).toJson(),
              },
            },
      ),
      dataDirectory: root,
      cacheDirectory: Directory('${root.path}/cache'),
      transport: native,
      files: files,
      http: FakeHttp(),
      platformFeatures: false,
    );
    instances.add(services);
    quark = _Quark();
    services.cloud.connectors[CloudPlatform.quark] = quark;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('asterlink-player-recent-');
    create();
  });
  tearDown(() async {
    for (final controller in controllers.reversed) {
      await controller.close();
    }
    for (final instance in instances.reversed) {
      await instance.close();
    }
    controllers.clear();
    instances.clear();
    backends.clear();
    await removePlayerFixture(root);
  });
  Future<PlaybackRecord> cloudRecord(BrowseMode mode) async {
    final session = mode == BrowseMode.personal
        ? await services.cloud.personal(CloudPlatform.quark)
        : await services.cloud.share(
            ParsedLink(
              source: 'https://pan.quark.cn/s/fixture 提取码：abcd',
              url: 'https://pan.quark.cn/s/fixture',
              kind: LinkKind.cloudShare,
              platform: CloudPlatform.quark,
              shareId: 'fixture',
              passcode: 'abcd',
            ),
          );
    final siblings = await services.cloud.list(session, session.rootId);
    final controller = cloudPlayback(
      services,
      session,
      siblings.first,
      siblings,
      backendFactory: backend,
    );
    controllers.add(controller);
    await controller.start();
    // Merely opening a media already makes it restorable, before any progress tick.
    expect(PlaybackStore(services.store).recent.single.source, isNotNull);
    await controller.seek(const Duration(seconds: 92));
    await controller.close();
    return PlaybackStore(services.store).recent.single;
  }

  for (final mode in BrowseMode.values) {
    test(
      '${mode.name} history survives restart, reacquires credentials and preserves the playlist',
      () async {
        final old = await cloudRecord(mode);
        final raw = jsonEncode(services.store.data);
        final historyJson = jsonEncode(services.store.data['playbackHistory']);
        for (final secret in [
          'old-cookie',
          'share-token-',
          'file-token-',
          'token=fresh-',
          'cleanup',
        ]) {
          expect(historyJson, isNot(contains(secret)));
        }
        await services.close();
        create(asJson(jsonDecode(raw)));
        quark.opens = 10;
        await services.vault.putCredential(
          CloudPlatform.quark,
          Credential('fixture', {
            'primary': '__pus=fixture; __puus=new-cookie',
          }, updatedAt: 42),
        );
        final record = PlaybackStore(services.store).recent.single;
        final controller = await restoreRecentPlayback(
          services,
          record,
          backendFactory: backend,
        );
        controllers.add(controller);
        expect(quark.opens, 11);
        expect(quark.lists, 1);
        expect(quark.downloads, 0);
        expect(quark.parents.single, 'root-11');
        expect(controller.entries.map((entry) => entry.name), [
          '第一集.mp4',
          '第二集.mp4',
        ]);
        expect(controller.current.key, old.key);
        await controller.start();
        expect(controller.error, isEmpty);
        expect(quark.downloads, 1);
        expect(quark.downloadedSession!.meta('stoken'), 'share-token-11');
        expect(quark.downloadedFile!.token, 'file-token-11');
        expect(
          backends.last.openedSource!.headers['Cookie'],
          contains('new-cookie'),
        );
        expect(backends.last.openedStart, const Duration(seconds: 92));
        expect(PlaybackStore(services.store).recent, hasLength(1));
        if (mode == BrowseMode.share) expect(quark.lastLink!.passcode, 'abcd');
        await controller.next();
        expect(controller.current.name, '第二集.mp4');
        expect(quark.downloads, 2);
      },
    );
  }

  for (final logout in [false, true]) {
    test(
      'History cannot replay after ${logout ? 'logout' : 'switching accounts'}',
      () async {
        final record = await cloudRecord(BrowseMode.share);
        if (logout) {
          await services.vault.removeCredential(CloudPlatform.quark);
        } else {
          await services.vault.putCredential(
            CloudPlatform.quark,
            Credential('other', {'primary': '__pus=other'}, updatedAt: 43),
          );
        }
        await expectLater(
          restoreRecentPlayback(services, record, backendFactory: backend),
          throwsA(logout ? isA<AccountLoginRequired>() : isA<AppException>()),
        );
        expect(quark.opens, 1);
        expect(quark.downloads, 1);
      },
    );
  }

  test(
    'Cancelling directory restoration never starts a transfer or backend',
    () async {
      final record = await cloudRecord(BrowseMode.share);
      final scope = RequestScope(), gate = Completer<void>();
      quark.listBarrier = gate.future;
      final result = scope.run(
        () => restoreRecentPlayback(services, record, backendFactory: backend),
      );
      final checked = expectLater(
        result,
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('取消'),
          ),
        ),
      );
      await until(() => quark.lists == 2);
      scope.cancel();
      gate.complete();
      await checked;
      expect(quark.downloads, 1);
      expect(backends, hasLength(1));
    },
  );

  for (final changed in ['deleted', 'size', 'hash']) {
    test(
      'Restoration rejects a $changed source file before requesting a stream',
      () async {
        final record = await cloudRecord(BrowseMode.personal);
        if (changed == 'deleted') quark.missing = true;
        if (changed == 'size') quark.size++;
        if (changed == 'hash') quark.hash = 'replacement-hash';
        await expectLater(
          restoreRecentPlayback(services, record, backendFactory: backend),
          throwsA(isA<AppException>()),
        );
        expect(quark.downloads, 1);
      },
    );
  }

  test(
    'Local history can replay after its download task is removed; deleting history leaves the file',
    () async {
      final file = await File(
        '${root.path}/local.mp4',
      ).writeAsBytes([1, 2, 3, 4]);
      final history = PlaybackStore(services.store);
      await history.save(
        'local-key',
        PlaybackBookmark(
          name: '本地视频.mp4',
          source: PlaybackSource.local(
            path: file.path,
            downloadId: 'removed-task',
            size: 4,
          ),
          position: const Duration(seconds: 60),
          duration: const Duration(minutes: 10),
          updatedAt: 1,
        ),
      );
      expect(services.downloads.tasks, isEmpty);
      final controller = await restoreRecentPlayback(
        services,
        history.recent.single,
        backendFactory: backend,
      );
      controllers.add(controller);
      await controller.start();
      expect(backends.single.openedSource!.url, file.path);
      expect(backends.single.openedStart, const Duration(seconds: 60));
      await controller.close();
      await history.remove('local-key');
      expect(history.recent, isEmpty);
      expect(await file.exists(), isTrue);
    },
  );

  test(
    'Missing local files remain individually removable alongside malformed legacy sources',
    () async {
      final history = PlaybackStore(services.store);
      await history.opened(
        'missing',
        '失效.mp4',
        const PlaybackSource.local(path: 'missing.mp4'),
      );
      files.availability['missing.mp4'] = FileAvailability.missing;
      await services.store.change((draft) {
        final entries = draft.obj('playbackHistory');
        entries['legacy'] = {
          'name': '旧记录.mp4',
          'source': {'version': 99, 'kind': 'cloud'},
        };
        draft['playbackHistory'] = entries;
      });
      final record = history.recent.firstWhere(
        (record) => record.key == 'missing',
      );
      await expectLater(
        restoreRecentPlayback(services, record, backendFactory: backend),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('不存在'),
          ),
        ),
      );
      await history.remove(record.key);
      expect(history.recent.single.source, isNull);
      await expectLater(
        restoreRecentPlayback(services, history.recent.single),
        throwsA(isA<AppException>()),
      );
      await history.clearHistory();
      expect(history.recent, isEmpty);
    },
  );

  test(
    'BT history deduplicates metadata and resumes the correct file after download persistence and restart',
    () async {
      final controller = torrentPlayback(
        services,
        testTorrent,
        testTorrent.files.first,
        backendFactory: backend,
      );
      controllers.add(controller);
      await controller.start();
      await controller.seek(const Duration(seconds: 42));
      await controller.next();
      await controller.seek(const Duration(seconds: 86));
      final selectedKey = controller.current.key;
      await controller.close();
      final history = PlaybackStore(services.store);
      expect(history.recent, hasLength(2));
      expect(services.store.data.obj('playbackTorrents'), hasLength(1));
      await services.downloads.initialize();
      await services.close();
      final persisted = asJson(jsonDecode(jsonEncode(services.store.data)));
      expect(
        jsonEncode(persisted.obj('playbackHistory')),
        isNot(contains(testTorrent.data)),
      );
      expect(persisted.obj('playbackTorrents'), hasLength(1));
      create(persisted);
      final freshHistory = PlaybackStore(services.store);
      final record = freshHistory.recent.firstWhere(
        (record) => record.key == selectedKey,
      );
      final restored = await restoreRecentPlayback(
        services,
        record,
        backendFactory: backend,
      );
      controllers.add(restored);
      expect(restored.entries, hasLength(2));
      await restored.start();
      expect(restored.error, isEmpty);
      expect(native.starts.single.integer('torrentIndex'), 1);
      expect(backends.last.openedStart, const Duration(seconds: 86));
      await restored.close();
      await freshHistory.remove(selectedKey);
      expect(services.store.data.obj('playbackTorrents'), hasLength(1));
      await freshHistory.clearHistory();
      expect(services.store.data.obj('playbackTorrents'), isEmpty);
      expect(native.stops, hasLength(1));
    },
  );
}
