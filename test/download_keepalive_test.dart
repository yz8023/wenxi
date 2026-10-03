import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_activity.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

class _Probe extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(4, '"fixture"', null), false);
}

class _Native extends FakeNative {
  final done = <String>{};
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'snapshot') finish = done.contains(args.str('id'));
    final value = await super.call(method, args);
    if (method == 'snapshot' && !finish) {
      return {...asJson(value), 'speed': 1024 * 1024};
    }
    return value;
  }
}

class _Files extends FakeFiles {
  _Files(super.directory);
  Completer<void>? saveGate;
  bool saving = false;
  @override
  Future<String> save({
    required String id,
    required File source,
    required String name,
    required String relativePath,
    String? destination,
    required void Function() checkpoint,
    void Function(int copied, int total)? onProgress,
  }) async {
    saving = true;
    await saveGate?.future;
    return super.save(
      id: id,
      source: source,
      name: name,
      relativePath: relativePath,
      destination: destination,
      checkpoint: checkpoint,
      onProgress: onProgress,
    );
  }
}

const _spec = DownloadSpec(
  url: 'https://example.invalid/file',
  fileName: 'file.bin',
  expectedSize: 4,
);

class _InterruptedRecoveryManager extends DownloadManager {
  _InterruptedRecoveryManager({
    required super.store,
    required super.engine,
    required super.files,
    required super.cleanups,
    required super.http,
    required super.refreshSource,
    super.foreground,
  });
  int resumed = 0;
  @override
  Future<void> resume(String id) async {
    if (resumed++ == 1) {
      throw const AppException('simulated recovery interruption');
    }
    await super.resume(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late StateStore store;
  late _Native native;
  late _Files files;
  late DownloadManager manager;
  final activity = <DownloadActivity>[];
  Future<void> Function(DownloadActivity)? publish;

  DownloadManager create({bool interruptRecovery = false}) =>
      (interruptRecovery
      ? _InterruptedRecoveryManager.new
      : DownloadManager.new)(
        store: store,
        engine: GopeedEngine(
          native,
          store,
          Vault(store),
          Directory(p.join(root.path, 'native')),
          Directory(p.join(root.path, 'cache')),
        ),
        files: files,
        cleanups: CleanupOutbox(store, FakeHttp()),
        http: _Probe(),
        refreshSource: (spec) async => spec,
        foreground: (state) async {
          activity.add(state);
          await publish?.call(state);
        },
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aster-keepalive-');
    store = StateStore.memory({
      'settings': {'concurrent': 1},
    });
    native = _Native();
    files = _Files(Directory(p.join(root.path, 'saved')));
    activity.clear();
    publish = null;
    manager = create();
  });
  tearDown(() async {
    if (files.saveGate?.isCompleted == false) files.saveGate!.complete();
    await manager.close();
    manager.dispose();
    await root.delete(recursive: true);
  });

  test(
    'service stays active between sequential files, then releases after export',
    () async {
      await manager.initialize();
      final first = await manager.enqueue(_spec);
      final second = await manager.enqueue(_spec);
      await until(() => native.begins.length == 1);
      native.done.add(first);
      await until(() => native.begins.length == 2);
      await until(
        () => manager.task(first)!.status == DownloadStatus.completed,
      );
      expect(manager.task(first)!.status, DownloadStatus.completed);
      expect(activity.every((state) => state.active > 0), isTrue);
      native.done.add(second);
      await until(() => manager.activeCount == 0 && activity.last.active == 0);
      expect(manager.task(second)!.status, DownloadStatus.completed);
      expect(activity.where((state) => state.active == 0).length, 1);
    },
  );

  test(
    'CPU protection and updates cover saving and stop after all tasks pause',
    () async {
      files.saveGate = Completer<void>();
      await manager.initialize();
      final id = await manager.enqueue(_spec);
      native.done.add(id);
      await until(() => files.saving);
      await until(() => activity.any((state) => state.text == '保存文件'));
      expect(manager.activeCount, 1);
      expect(activity.last.active, 1);
      final pausing = manager.pauseAll();
      files.saveGate!.complete();
      await pausing;
      expect(activity.last.active, 0);
      expect(manager.task(id)!.status, DownloadStatus.paused);
      expect(files.savedCount, 0);
    },
  );

  for (final bulk in [false, true]) {
    test(
      'user ${bulk ? 'pause-all' : 'pause'} is durable while export cancellation is still blocked',
      () async {
        files.saveGate = Completer<void>();
        await manager.initialize();
        final id = await manager.enqueue(_spec);
        native.done.add(id);
        await until(() => files.saving);
        final pausing = bulk ? manager.pauseAll() : manager.pause(id);
        await until(
          () => store.data.list('tasks').single.str('status') == 'paused',
        );
        expect(manager.activeCount, 1); // Writer is still draining.
        final crashSnapshot = StateStore.memory(store.data);
        files.saveGate!.complete();
        await pausing;
        await manager.close();
        manager.dispose();
        store = crashSnapshot;
        manager = create();
        await manager.initialize();
        final previousBegins = native.begins.length;
        await manager.recoverInterrupted();
        expect(native.begins.length, previousBegins);
        expect(manager.task(id)!.status, DownloadStatus.paused);
      },
    );
  }

  test(
    'periodic notification reflects actual speed and unknown totals stay indeterminate',
    () async {
      await manager.initialize();
      await manager.enqueue(_spec);
      await until(() => activity.any((state) => state.text.contains('MB/s')));
      expect(activity.last.text, contains('1.0 MB/s'));
      final unknown = DownloadActivity.fromTasks([
        const DownloadTask(id: 'unknown', spec: _spec, createdAt: 0),
      ]);
      expect(unknown.progress, -1);
    },
  );

  test(
    'native start failure prevents payload download and remains retryable',
    () async {
      publish = (state) async {
        if (state.active > 0) throw const AppException('系统不允许启动后台服务');
      };
      await manager.initialize();
      final id = await manager.enqueue(_spec);
      await until(
        () =>
            manager.task(id)!.status == DownloadStatus.failed &&
            manager.activeCount == 0,
      );
      expect(native.begins, isEmpty);
      expect(manager.task(id)!.error, contains('后台服务'));
      publish = null;
      await manager.resume(id);
      await until(() => native.begins.length == 1);
    },
  );

  test(
    'regular startup is paused; sticky recovery resumes only interrupted tasks',
    () async {
      await store.put('tasks', [
        for (final status in DownloadStatus.values)
          DownloadTask(
            id: status.name,
            spec: _spec,
            createdAt: 0,
            status: status,
          ).toJson(),
      ]);
      await manager.initialize();
      expect(native.begins, isEmpty);
      expect(manager.tasks.every((task) => !task.active), isTrue);
      await manager.recoverInterrupted();
      await until(() => native.begins.isNotEmpty);
      expect(
        manager.tasks
            .where((task) => task.active)
            .map((task) => task.id)
            .toSet(),
        {'pending', 'running'},
      );
      expect(manager.task('paused')!.status, DownloadStatus.paused);
      expect(manager.task('failed')!.status, DownloadStatus.failed);
      expect(manager.task('completed')!.status, DownloadStatus.completed);
      await manager.recoverInterrupted();
      expect(native.begins.length, 1);
    },
  );

  test(
    'recovery markers survive another process loss during initialization',
    () async {
      await store.put('tasks', [
        const DownloadTask(
          id: 'interrupted',
          spec: _spec,
          createdAt: 0,
          status: DownloadStatus.running,
        ).toJson(),
      ]);
      await manager.initialize();
      expect(store.data['downloadRecovery'], ['interrupted']);
      manager
          .dispose(); // Simulate process loss, without the orderly close/pause.
      manager = create();
      await manager.initialize();
      await manager.recoverInterrupted();
      await until(() => native.begins.isNotEmpty);
      expect(native.begins.single.str('id'), 'interrupted');
    },
  );

  test(
    'a second process loss midway through recovery retains the remaining queue',
    () async {
      manager.dispose();
      manager = create(interruptRecovery: true);
      await store.put('tasks', [
        for (var i = 0; i < 3; i++)
          DownloadTask(
            id: 'recover-$i',
            spec: _spec,
            createdAt: i,
            status: DownloadStatus.running,
          ).toJson(),
      ]);
      await manager.initialize();
      await expectLater(
        manager.recoverInterrupted(),
        throwsA(isA<AppException>()),
      );
      expect(store.data['downloadRecovery'], ['recover-1', 'recover-2']);
      final crashSnapshot = StateStore.memory(store.data);
      await manager.close();
      manager.dispose();
      store = crashSnapshot;
      manager = create();
      await manager.initialize();
      await manager.recoverInterrupted();
      expect(
        manager.tasks
            .where((task) => task.active)
            .map((task) => task.id)
            .toSet(),
        {'recover-0', 'recover-1', 'recover-2'},
      );
    },
  );

  test(
    'manual pause wins over a late restart signal and timeout reason is visible',
    () async {
      await store.put('tasks', [
        const DownloadTask(
          id: 'old',
          spec: _spec,
          createdAt: 0,
          status: DownloadStatus.running,
        ).toJson(),
      ]);
      await manager.initialize();
      await manager.pause('old');
      await manager.recoverInterrupted();
      expect(native.begins, isEmpty);
      expect(activity.last.active, 0);
      final current = await manager.enqueue(_spec);
      await until(() => native.begins.isNotEmpty);
      await manager.pauseAll(reason: '系统已暂停长时间后台下载，返回应用后可继续');
      expect(manager.task(current)!.phase, contains('返回应用'));
      expect(manager.task(current)!.status, DownloadStatus.paused);
    },
  );

  test(
    'ordinary launch discards candidates before a later unrelated service restart',
    () async {
      await store.put('tasks', [
        const DownloadTask(
          id: 'old',
          spec: _spec,
          createdAt: 0,
          status: DownloadStatus.running,
        ).toJson(),
      ]);
      await manager.initialize();
      await manager.discardInterrupted();
      await manager.recoverInterrupted();
      expect(native.begins, isEmpty);
      expect(manager.task('old')!.status, DownloadStatus.paused);
      expect(store.data['downloadRecovery'], isEmpty);
    },
  );

  test(
    'delayed start acknowledgement cannot start a paused task or overtake idle',
    () async {
      final gate = Completer<void>();
      var inFlight = 0, maxInFlight = 0;
      publish = (state) async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        if (state.active > 0) await gate.future;
        inFlight--;
      };
      await manager.initialize();
      final id = await manager.enqueue(_spec);
      await until(() => inFlight == 1);
      final pause = manager.pauseAll();
      gate.complete();
      await pause;
      expect(native.begins, isEmpty);
      expect(manager.task(id)!.status, DownloadStatus.paused);
      expect(activity.last.active, 0);
      expect(maxInFlight, 1);
    },
  );
}
