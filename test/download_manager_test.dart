import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/legacy_import.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/platform/file_access.dart';
import 'support.dart';

class _ProbeHttp extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> h) async =>
      const Probe(RemoteIdentity(4, '"v1"', null), false);
}

class _BatchFiles extends FakeFiles {
  _BatchFiles(super.directory);
  final failPaths = <String>{};
  void Function()? afterDelete;
  @override
  Future<void> delete(String? path) async {
    if (failPaths.contains(path)) throw const AppException('文件正在使用');
    await super.delete(path);
    afterDelete?.call();
  }
}

class _RemovalNative extends FakeNative {
  final writers = <String>{};
  String? failingId;
  Completer<void>? blocked;
  bool entered = false;
  int? reportedActiveConnections, reportedTotalConnections;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    final id = args.str('id');
    if (method == 'begin') writers.add(id);
    if (method == 'remove' && args.str('id') == failingId) {
      entered = true;
      if (blocked != null) await blocked!.future;
      throw const AppException('下载组件清理失败');
    }
    if (method == 'remove') {
      calls.add(method);
      if (writers.contains(id)) removedWhileWriting = true;
      return null;
    }
    final result = await super.call(method, args);
    if (method == 'pause' || method == 'snapshot' && finish) writers.remove(id);
    if (method == 'snapshot' && reportedTotalConnections != null) {
      return {
        ...asJson(result),
        'activeConnections': reportedActiveConnections ?? 0,
        'totalConnections': reportedTotalConnections,
      };
    }
    return result;
  }
}

class _CacheFailureEngine extends GopeedEngine {
  _CacheFailureEngine(
    super.transport,
    super.store,
    super.vault,
    super.storage,
    super.cache,
  );
  @override
  Directory taskDirectory(String id) {
    if (id == 'cache-blocked') throw const AppException('缓存路径发生变化，已停止删除');
    return super.taskDirectory(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late StateStore store;
  late _RemovalNative native;
  late _BatchFiles files;
  late GopeedEngine engine;
  late DownloadManager manager;
  late CleanupOutbox cleanups;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('aster-queue-');
    store = StateStore.memory();
    native = _RemovalNative();
    files = _BatchFiles(Directory(p.join(root.path, 'saved')));
    engine = GopeedEngine(
      native,
      store,
      Vault(store),
      Directory(p.join(root.path, 'native')),
      Directory(p.join(root.path, 'cache')),
    );
    cleanups = CleanupOutbox(store, FakeHttp());
    manager = DownloadManager(
      store: store,
      engine: engine,
      files: files,
      cleanups: cleanups,
      http: _ProbeHttp(),
      refreshSource: (_) async => throw const AppException('unused'),
    );
  });
  tearDown(() async {
    await manager.close();
    manager.dispose();
    await root.delete(recursive: true);
  });
  test('Cold deletion never initializes the native runtime', () async {
    await store.put('tasks', [
      DownloadTask(
        id: 'cold',
        spec: const DownloadSpec(
          url: 'https://example.com/a',
          fileName: 'a.zip',
        ),
        createdAt: 1,
        status: DownloadStatus.paused,
      ).toJson(),
    ]);
    await manager.initialize();
    await manager.delete('cold');
    expect(native.openCount, 0);
    expect(native.calls, isEmpty);
    expect(store.data['nativeRemovals'], contains('cold'));
    expect(manager.tasks, isEmpty);
  });
  test(
    'Bulk storage failure keeps live and durable records without cleanup markers',
    () async {
      final diskStore = await StateStore.open(
        Directory(p.join(root.path, 'state')),
        testKey: Uint8List(32),
      );
      final diskEngine = GopeedEngine(
        native,
        diskStore,
        Vault(diskStore),
        Directory(p.join(root.path, 'disk-native')),
        Directory(p.join(root.path, 'disk-cache')),
      );
      final diskManager = DownloadManager(
        store: diskStore,
        engine: diskEngine,
        files: files,
        cleanups: CleanupOutbox(diskStore, FakeHttp()),
        http: _ProbeHttp(),
        refreshSource: (_) async => throw const AppException('unused'),
      );
      await diskStore.put('tasks', [
        for (final id in ['one', 'two'])
          DownloadTask(
            id: id,
            spec: const DownloadSpec(
              url: 'https://example.com/a',
              fileName: 'a',
            ),
            status: DownloadStatus.paused,
            createdAt: 1,
          ).toJson(),
      ]);
      await diskManager.initialize();
      final blocked = Directory('${diskStore.file!.path}.tmp');
      await blocked.create();
      try {
        final result = await diskManager.batch([
          'one',
          'two',
        ], DownloadBatchAction.delete);
        expect(result.failed.keys, ['one', 'two']);
        expect(result.succeeded, isEmpty);
        expect(diskManager.tasks, hasLength(2));
        expect(diskStore.data.list('tasks'), hasLength(2));
        expect(diskStore.data['downloadRemovals'] ?? [], isEmpty);
      } finally {
        await blocked.delete();
        await diskManager.close();
        diskManager.dispose();
      }
    },
  );
  for (final cancelAfterFirstGroup in [false, true]) {
    test(
      'Bulk removal commits bounded groups; cancel=$cancelAfterFirstGroup',
      () async {
        const count = 130;
        final ids = List.generate(count, (i) => 'bulk-$i');
        await store.put('tasks', [
          for (final id in ids)
            DownloadTask(
              id: id,
              spec: const DownloadSpec(
                url: 'https://example.com/a',
                fileName: 'a',
              ),
              status: DownloadStatus.paused,
              createdAt: 1,
            ).toJson(),
        ]);
        await manager.initialize();
        await engine.begin({
          'id': 'runtime',
          'url': 'https://example.com/runtime',
        });
        await engine.pause('runtime');
        native.failingId = ids.first;
        final blocked = native.blocked = Completer<void>();
        final scope = RequestScope();
        var commits = 0;
        void changed() {
          commits++;
          if (cancelAfterFirstGroup) scope.cancel();
        }

        store.addListener(changed);
        try {
          final result = await scope
              .run(() => manager.batch(ids, DownloadBatchAction.delete))
              .timeout(const Duration(seconds: 2));
          expect(result.succeeded.length, cancelAfterFirstGroup ? 64 : count);
          expect(result.cancelled, cancelAfterFirstGroup);
          expect(commits, cancelAfterFirstGroup ? 1 : 3);
          expect(manager.tasks.length, cancelAfterFirstGroup ? count - 64 : 0);
          expect(store.data['downloadRemovals'], containsAll(result.succeeded));
        } finally {
          store.removeListener(changed);
          blocked.complete();
        }
      },
    );
  }

  test(
    'Atomic bulk removal retains remote cleanup protected by a preview',
    () async {
      const cleanup = DownloadCleanup(url: 'https://example.com/cleanup');
      cleanups.retain(cleanup);
      await cleanups.stage(cleanup);
      await store.put('tasks', [
        for (final id in ['one', 'two'])
          DownloadTask(
            id: id,
            spec: const DownloadSpec(
              url: 'https://example.com/a',
              fileName: 'a',
              cleanup: cleanup,
            ),
            status: DownloadStatus.paused,
            createdAt: 1,
          ).toJson(),
      ]);
      await manager.initialize();
      await manager.batch(['one', 'two'], DownloadBatchAction.delete);
      expect(
        store.data.obj('cleanups').obj(cleanupKey(cleanup)).boolean('ready'),
        isFalse,
      );
      expect(cleanups.pendingCount, 1);
    },
  );
  test(
    'Paused and failed batch records do not wait for blocked native cleanup',
    () async {
      await store.put('tasks', [
        for (final status in [DownloadStatus.paused, DownloadStatus.failed])
          DownloadTask(
            id: status.name,
            spec: const DownloadSpec(
              url: 'https://example.com/file',
              fileName: 'file.bin',
            ),
            createdAt: 1,
            status: status,
          ).toJson(),
      ]);
      await manager.initialize();
      await engine.begin({
        'id': 'runtime',
        'url': 'https://example.com/runtime',
      });
      await engine.pause('runtime');
      final cache = engine.taskDirectory('paused');
      await cache.create(recursive: true);
      await File(p.join(cache.path, 'part')).writeAsString('partial');
      native.failingId = 'paused';
      final blocked = native.blocked = Completer<void>();
      try {
        final result = await manager
            .batch(['paused', 'failed'], DownloadBatchAction.delete)
            .timeout(const Duration(seconds: 2));
        expect(result.succeeded, ['paused', 'failed']);
        expect(manager.tasks, isEmpty);
        expect(store.data.list('tasks'), isEmpty);
        expect(store.data['downloadRemovals'], contains('paused'));
        await until(() => native.entered);
        expect(await cache.exists(), isTrue);
        expect(native.removedWhileWriting, isFalse);
      } finally {
        blocked.complete();
      }
    },
  );

  test(
    'Just-completed history can be removed while its run is still cleaning up',
    () async {
      native.finish = false;
      await manager.initialize();
      final id = await manager.enqueue(
        const DownloadSpec(
          url: 'https://example.com/completing',
          fileName: 'saved.bin',
          expectedSize: 4,
        ),
      );
      await until(() => native.writer);
      native.failingId = id;
      final blocked = native.blocked = Completer<void>();
      native.finish = true;
      try {
        await until(
          () =>
              native.entered &&
              manager.task(id)?.status == DownloadStatus.completed,
        );
        final path = manager.task(id)!.savedPath!;
        await manager.delete(id).timeout(const Duration(seconds: 2));
        expect(manager.task(id), isNull);
        expect(store.data.list('tasks'), isEmpty);
        expect(await File(path).readAsBytes(), native.content);
      } finally {
        blocked.complete();
      }
      await until(() => manager.activeCount == 0);
      expect(manager.lastError, isNull);
    },
  );
  test(
    'Retrying legacy import reloads the live queue before shutdown persists it',
    () async {
      await manager.initialize();
      await manager.importPausedQueue(() async {
        await LegacyImporter(store).import({
          'tasks': [
            {
              'id': 'imported-after-start',
              'url': 'https://example.com/legacy',
              'fileName': 'legacy.zip',
              'status': 'completed',
              'savedUri': 'content://fixture/legacy',
            },
          ],
        });
      });
      expect(
        manager.task('imported-after-start')!.savedPath,
        'content://fixture/legacy',
      );
      await manager.close();
      expect(store.data.list('tasks').single.str('id'), 'imported-after-start');
      expect(native.openCount, 0);
    },
  );
  test(
    'Deleting a saved file failure retains the completed row and URI',
    () async {
      final task = DownloadTask(
        id: 'saved',
        spec: const DownloadSpec(
          url: 'https://example.com/a',
          fileName: 'a.zip',
        ),
        createdAt: 1,
        status: DownloadStatus.completed,
        savedPath: p.join(root.path, 'keep.zip'),
      );
      await store.put('tasks', [task.toJson()]);
      await manager.initialize();
      files.failDelete = true;
      await expectLater(
        manager.delete('saved', deleteFile: true),
        throwsA(isA<AppException>()),
      );
      expect(manager.task('saved')!.status, DownloadStatus.completed);
      expect(manager.task('saved')!.savedPath, task.savedPath);
      expect(manager.task('saved')!.error, '文件正在使用');
      expect(native.openCount, 0);
    },
  );

  test(
    'Externally deleted history is committed before a blocked native cleanup and survives restart',
    () async {
      await manager.initialize();
      final id = await manager.enqueue(
        const DownloadSpec(
          url: 'https://example.com/completed',
          fileName: 'completed.bin',
          expectedSize: 4,
        ),
      );
      await until(
        () =>
            manager.task(id)?.status == DownloadStatus.completed &&
            manager.activeCount == 0,
      );
      final path = manager.task(id)!.savedPath!;
      await File(path).delete();
      files.availability[path] = FileAvailability.inaccessible;
      files.failDelete = true;
      final cache = engine.taskDirectory(id);
      await cache.create(recursive: true);
      await File(p.join(cache.path, 'leftover')).writeAsString('retry');
      native.failingId = id;
      final blocked = native.blocked = Completer<void>();
      try {
        await manager.delete(id).timeout(const Duration(seconds: 2));
        expect(manager.task(id), isNull);
        expect(store.data.list('tasks'), isEmpty);
        expect(store.data['downloadRemovals'], contains(id));
        expect(store.data['nativeRemovals'], contains(id));
        await until(() => native.entered);
        expect(await cache.exists(), isTrue);
      } finally {
        blocked.complete();
      }
      await manager.close();
      manager.dispose();
      // Reuse the committed store and cache, as an app restart does.
      native = _RemovalNative();
      engine = GopeedEngine(
        native,
        store,
        Vault(store),
        Directory(p.join(root.path, 'native')),
        Directory(p.join(root.path, 'cache')),
      );
      manager = DownloadManager(
        store: store,
        engine: engine,
        files: files,
        cleanups: cleanups,
        http: _ProbeHttp(),
        refreshSource: (_) async => throw const AppException('unused'),
      );
      await manager.initialize();
      expect(manager.tasks, isEmpty);
      await until(() => (store.data['downloadRemovals'] as List).isEmpty);
      expect(await cache.exists(), isFalse);
      expect(native.openCount, 0);
      expect(store.data['nativeRemovals'], contains(id));
    },
  );

  test(
    'A cache path that cannot be cleaned does not restore completed history',
    () async {
      final task = DownloadTask(
        id: 'cache-blocked',
        spec: const DownloadSpec(
          url: 'https://example.com/gone',
          fileName: 'gone.bin',
        ),
        createdAt: 1,
        status: DownloadStatus.completed,
        savedPath: 'content://fixture/unrecognised',
      );
      await store.put('tasks', [task.toJson()]);
      manager.dispose();
      engine = _CacheFailureEngine(
        native,
        store,
        Vault(store),
        engine.storage,
        engine.cache,
      );
      manager = DownloadManager(
        store: store,
        engine: engine,
        files: files,
        cleanups: cleanups,
        http: _ProbeHttp(),
        refreshSource: (_) async => throw const AppException('unused'),
      );
      await manager.initialize();
      files.failDelete = true;
      await manager.delete(task.id);
      await manager.close();
      expect(manager.task(task.id), isNull);
      expect(store.data.list('tasks'), isEmpty);
      expect(store.data['downloadRemovals'], contains(task.id));
      expect(native.openCount, 0);
    },
  );

  test(
    'Deferred history cleanup retries without blocking unrelated downloads',
    () async {
      await store.put('nativeRemovals', ['old-history']);
      native.failingId = 'old-history';
      await engine.begin({'id': 'new-task', 'url': 'https://example.com/new'});
      expect(native.begins.single.str('id'), 'new-task');
      expect(store.data['nativeRemovals'], contains('old-history'));
      await expectLater(
        engine.begin({'id': 'old-history', 'url': 'https://example.com/old'}),
        throwsA(isA<AppException>()),
      );
      expect(native.begins.length, 1);
      await engine.pause('new-task');
      native.failingId = null;
      await engine.remove('old-history');
      expect(store.data['nativeRemovals'], isEmpty);
    },
  );
  test(
    'Queue captures thread settings, verifies output and completes only after export',
    () async {
      await store.put('settings', {
        'threads': 7,
        'retries': 2,
        'speedLimit': 2048,
      });
      await manager.initialize();
      final id = await manager.enqueue(
        const DownloadSpec(
          url: 'https://example.com/a',
          fileName: 'a.zip',
          expectedSize: 4,
          checksumType: 'md5',
          checksumValue: '08d6c05a21512a79a1dfeb9d2a8f262f',
        ),
      );
      await until(
        () =>
            manager.task(id)?.status == DownloadStatus.completed &&
            manager.activeCount == 0,
      );
      expect(native.begins.single['connections'], 7);
      expect(native.begins.single['headers'], containsPair('If-Range', '"v1"'));
      expect(files.savedCount, 1);
      expect(await File(manager.task(id)!.savedPath!).readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
      expect(native.removedWhileWriting, isFalse);
    },
  );
  test(
    'The native connection profile follows the download source route',
    () async {
      await manager.initialize();
      for (final (platform, route, expectedProfile, connections) in [
        (CloudPlatform.quark, null, 'quark_route_1', 512),
        (CloudPlatform.quark, 'quark_route_2', 'quark_route_2', 64),
        (CloudPlatform.uc, null, 'uc', 512),
        (null, null, null, 64),
      ]) {
        final id = await manager.enqueue(
          DownloadSpec(
            url: 'https://example.com/profile',
            fileName: 'profile.bin',
            expectedSize: 4,
            source: {if (platform != null) 'platform': platform.key},
            profile: route,
          ),
        );
        await until(
          () =>
              manager.task(id)?.status == DownloadStatus.completed &&
              manager.activeCount == 0,
        );
        expect(native.begins.last['connectionProfile'], expectedProfile);
        expect(native.begins.last['connections'], connections);
      }
    },
  );
  test(
    'Live connection counts are transient and clear on pause and completion',
    () async {
      native
        ..finish = false
        ..reportedActiveConnections = 3
        ..reportedTotalConnections = 8;
      await manager.initialize();
      final id = await manager.enqueue(
        const DownloadSpec(
          url: 'https://example.com/counts',
          fileName: 'counts.bin',
          expectedSize: 4,
          source: {'platform': 'Quark'},
        ),
      );
      await until(() => manager.httpConnections(id) != null);
      expect(manager.httpConnections(id), (active: 3, total: 8));
      expect(manager.task(id)!.connections, 512);
      expect(manager.task(id)!.toJson(), isNot(contains('activeConnections')));
      await manager.pause(id);
      expect(manager.httpConnections(id), isNull);
      native.reportedActiveConnections = 0;
      await manager.resume(id);
      await until(() => manager.httpConnections(id) != null);
      expect(manager.httpConnections(id), (active: 0, total: 8));
      native.finish = true;
      await until(
        () =>
            manager.task(id)?.status == DownloadStatus.completed &&
            manager.activeCount == 0,
      );
      expect(manager.httpConnections(id), isNull);
    },
  );
  test(
    'Export failure keeps a verified payload so retry needs no network transfer',
    () async {
      files.failSave = true;
      await manager.initialize();
      final id = await manager.enqueue(
        const DownloadSpec(
          url: 'https://example.com/a',
          fileName: 'a',
          expectedSize: 4,
        ),
      );
      await until(
        () =>
            manager.task(id)?.status == DownloadStatus.failed &&
            manager.activeCount == 0,
      );
      expect(manager.task(id)!.payloadReady, isTrue);
      files.failSave = false;
      await manager.resume(id);
      await until(
        () =>
            manager.task(id)?.status == DownloadStatus.completed &&
            manager.activeCount == 0,
      );
      expect(native.begins.length, 1);
      expect(files.savedCount, 1);
    },
  );
  test(
    'Active deletion waits for native writers before removing checkpoints',
    () async {
      native.finish = false;
      await manager.initialize();
      final id = await manager.enqueue(
        const DownloadSpec(
          url: 'https://example.com/a',
          fileName: 'a',
          expectedSize: 4,
        ),
      );
      await until(() => native.writer);
      await manager.delete(id);
      expect(native.removedWhileWriting, isFalse);
      expect(native.writer, isFalse);
      expect(manager.task(id), isNull);
    },
  );
  test('Pause-all removes queued work before freeing running slots', () async {
    native.finish = false;
    await store.put('settings', {'concurrent': 1});
    await manager.initialize();
    for (var i = 0; i < 4; i++) {
      await manager.enqueue(
        DownloadSpec(url: 'https://example.com/$i', fileName: '$i'),
      );
    }
    await until(() => native.writer);
    await manager.pauseAll();
    expect(
      manager.tasks.every((t) => t.status == DownloadStatus.paused),
      isTrue,
    );
    expect(native.begins.length, 1);
    expect(manager.activeCount, 0);
  });

  for (final action in [
    DownloadBatchAction.pause,
    DownloadBatchAction.delete,
  ]) {
    test(
      'Batch ${action.name} holds selected queued work and preserves others',
      () async {
        native.finish = false;
        await store.put('settings', {'concurrent': 1});
        await manager.initialize();
        final ids = <String>[];
        for (var i = 0; i < 3; i++) {
          ids.add(
            await manager.enqueue(
              DownloadSpec(url: 'https://example.com/$i', fileName: '$i.zip'),
            ),
          );
        }
        await until(() => native.writer);
        final result = await manager.batch([
          ids[0],
          ids[1],
          ids[1],
          'missing',
        ], action);
        await until(() => native.begins.length == 2);
        expect(result.succeeded, [ids[0], ids[1]]);
        expect(result.skipped, ['missing']);
        expect(result.failed, isEmpty);
        expect(native.begins.map((value) => value.str('id')), [ids[0], ids[2]]);
        expect(native.removedWhileWriting, isFalse);
        for (final id in ids.take(2)) {
          if (action == DownloadBatchAction.delete) {
            expect(manager.task(id), isNull);
          } else {
            expect(manager.task(id)!.status, DownloadStatus.paused);
          }
        }
        expect(manager.task(ids[2])!.active, isTrue);
      },
    );
  }

  test(
    'Batch resume respects eligible tasks and captured connection settings',
    () async {
      native.finish = false;
      await store.put('settings', {'concurrent': 1, 'threads': 1});
      await store.put('tasks', [
        for (final (id, status) in [
          ('selected-paused', DownloadStatus.paused),
          ('selected-failed', DownloadStatus.failed),
          ('complete', DownloadStatus.completed),
          ('untouched', DownloadStatus.paused),
        ])
          DownloadTask(
            id: id,
            spec: DownloadSpec(
              url: 'https://example.com/$id',
              fileName: '$id.zip',
            ),
            createdAt: 1,
            status: status,
            connections: 512,
            speedLimit: 2048,
          ).toJson(),
      ]);
      await manager.initialize();
      final result = await manager.batch([
        'selected-paused',
        'selected-failed',
        'complete',
        'missing',
      ], DownloadBatchAction.resume);
      await until(() => native.writer);
      expect(result.succeeded, ['selected-paused', 'selected-failed']);
      expect(result.skipped, ['complete', 'missing']);
      expect(result.failed, isEmpty);
      expect(native.begins.single['connections'], 512);
      expect(native.begins.single['speedLimit'], 2048);
      expect(manager.task('selected-failed')!.status, DownloadStatus.pending);
      expect(manager.task('untouched')!.status, DownloadStatus.paused);
    },
  );

  Future<List<String>> savedBatch() async {
    final paths = <String>[];
    final tasks = <Json>[];
    for (var i = 0; i < 3; i++) {
      final file = File(p.join(root.path, 'saved-$i.bin'));
      await file.writeAsBytes([i]);
      paths.add(file.path);
      tasks.add(
        DownloadTask(
          id: 'saved-$i',
          spec: DownloadSpec(url: 'https://example.com/$i', fileName: '$i.bin'),
          createdAt: i,
          status: DownloadStatus.completed,
          savedPath: file.path,
        ).toJson(),
      );
    }
    await store.put('tasks', tasks);
    await manager.initialize();
    return paths;
  }

  test(
    'Batch record deletion retains exported files and unselected records',
    () async {
      final paths = await savedBatch();
      final result = await manager.batch([
        'saved-0',
        'saved-1',
      ], DownloadBatchAction.delete);
      expect(result.succeeded, ['saved-0', 'saved-1']);
      expect(manager.tasks.single.id, 'saved-2');
      for (final path in paths) {
        expect(await File(path).exists(), isTrue);
      }
      expect(native.openCount, 0);
    },
  );

  test(
    'Batch file deletion continues after a failure and retains failed records',
    () async {
      final paths = await savedBatch();
      files.failPaths.add(paths[0]);
      final result = await manager.batch(
        ['saved-0', 'saved-1'],
        DownloadBatchAction.delete,
        deleteFiles: true,
      );
      expect(result.succeeded, ['saved-1']);
      expect(result.failed.keys, ['saved-0']);
      expect(manager.task('saved-0')!.savedPath, paths[0]);
      expect(manager.task('saved-0')!.error, '文件正在使用');
      expect(await File(paths[0]).exists(), isTrue);
      expect(await File(paths[1]).exists(), isFalse);
      expect(await File(paths[2]).exists(), isTrue);
      expect(manager.task('saved-2'), isNotNull);
    },
  );

  test(
    'Cancelling a batch finishes the current deletion and leaves later files',
    () async {
      final paths = await savedBatch();
      final scope = RequestScope();
      files.afterDelete = scope.cancel;
      final result = await scope.run(
        () => manager.batch(
          ['saved-0', 'saved-1', 'saved-2'],
          DownloadBatchAction.delete,
          deleteFiles: true,
        ),
      );
      expect(result.cancelled, isTrue);
      expect(result.succeeded, ['saved-0']);
      expect(result.failed, isEmpty);
      expect(await File(paths[0]).exists(), isFalse);
      expect(await File(paths[1]).exists(), isTrue);
      expect(await File(paths[2]).exists(), isTrue);
      expect(manager.tasks.map((task) => task.id), ['saved-2', 'saved-1']);
    },
  );
  test('Wrong checksums never become completed exports', () async {
    await manager.initialize();
    final id = await manager.enqueue(
      const DownloadSpec(
        url: 'https://example.com/a',
        fileName: 'a',
        checksumType: 'sha256',
        checksumValue: '00000000',
      ),
    );
    await until(
      () =>
          manager.task(id)?.status == DownloadStatus.failed &&
          manager.activeCount == 0,
    );
    expect(files.savedCount, 0);
    expect(manager.task(id)!.savedPath, isNull);
    expect(manager.task(id)!.error, contains('校验失败'));
  });
  test(
    'Temporary remote cleanups are protected by task and preview leases',
    () async {
      const cleanup = DownloadCleanup(
        url: 'https://example.com/remove',
        body: '{"ids":["temporary"]}',
      );
      await cleanups.stage(cleanup);
      cleanups.retain(cleanup);
      await cleanups.reconcile(recoverOrphans: true);
      await cleanups.drain();
      expect(cleanups.pendingCount, 1);
      await cleanups.release(cleanup);
      await cleanups.ready(cleanup);
      await cleanups.drain();
      expect(cleanups.pendingCount, 0);
    },
  );
  test(
    'Desktop exports reserve unique filenames and stay in the selected directory',
    () async {
      final source = File(p.join(root.path, 'source'))
        ..writeAsBytesSync([5, 6, 7]);
      final exports = Directory(p.join(root.path, 'exports'));
      final adapter = PlatformFileAccess(native, exports);
      final outputs = await Future.wait(
        List.generate(
          3,
          (i) => adapter.save(
            id: '$i',
            source: source,
            name: 'same.zip',
            relativePath: '../nested',
            checkpoint: () {},
          ),
        ),
      );
      expect(outputs.toSet().length, 3);
      final resolvedExports = await exports.resolveSymbolicLinks();
      for (final path in outputs) {
        expect(p.isWithin(resolvedExports, path), isTrue);
        expect(await File(path).readAsBytes(), [5, 6, 7]);
      }
    },
  );
}
