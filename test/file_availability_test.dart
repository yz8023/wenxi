import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/completed_files.dart';
import 'package:asterlink/platform/file_access.dart';
import 'support.dart';

class _CheckingFiles extends FakeFiles {
  _CheckingFiles() : super(Directory('availability-fixture'));
  int active = 0, peak = 0, calls = 0;
  Completer<FileAvailability>? blocked;
  @override
  Future<FileAvailability> inspect(String? path) async {
    calls++;
    active++;
    if (active > peak) peak = active;
    try {
      if (blocked != null) return await blocked!.future;
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return super.inspect(path);
    } finally {
      active--;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Real saved files distinguish deletion, directories and invalid paths',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'asterlink-availability-',
      );
      final original = File('${root.path}/video.mp4');
      final renamed = File('${root.path}/renamed.mp4');
      final access = PlatformFileAccess(FakeNative(), root, android: false);
      await original.writeAsBytes([1, 2, 3]);
      expect(await access.inspect(original.path), FileAvailability.present);
      expect(
        await access.inspect(original.uri.toString()),
        FileAvailability.present,
      );
      await original.rename(renamed.path);
      expect(await access.inspect(original.path), FileAvailability.missing);
      expect(await access.inspect(renamed.path), FileAvailability.present);
      expect(await access.inspect(root.path), FileAvailability.inaccessible);
      expect(
        await access.inspect('relative.mp4'),
        FileAvailability.inaccessible,
      );
      expect(await access.inspect(null), FileAvailability.missing);
      await renamed.delete();
      expect(await access.inspect(renamed.path), FileAvailability.missing);
      await root.delete();
    },
  );
  test(
    'Android channel distinguishes missing content and a revoked permission',
    () async {
      const channel = MethodChannel('com.asterlink.app/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final access = PlatformFileAccess(
        FakeNative(),
        Directory('fixture'),
        android: true,
      );
      Object status = 'present';
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'fileAvailability');
        expect(call.arguments['path'], 'content://fixture/1');
        if (status is PlatformException) throw status;
        return status;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      for (final state in [
        FileAvailability.present,
        FileAvailability.missing,
        FileAvailability.inaccessible,
      ]) {
        status = state.name;
        expect(await access.inspect('content://fixture/1'), state);
      }
      status = PlatformException(code: 'permission');
      expect(
        await access.inspect('content://fixture/1'),
        FileAvailability.inaccessible,
      );
    },
  );

  Future<(AppServices, _CheckingFiles, CompletedFiles)> fixture({
    int count = 1,
  }) async {
    final files = _CheckingFiles();
    final services = AppServices(
      controlEnabled: false,
      store: StateStore.memory({
        'tasks': [
          for (var i = 0; i < count; i++)
            DownloadTask(
              id: 'completed-$i',
              spec: const DownloadSpec(
                url: 'https://example.com/video',
                fileName: 'video.mp4',
              ),
              createdAt: i,
              status: DownloadStatus.completed,
              savedPath: 'content://fixture/$i',
            ).toJson(),
        ],
      }),
      dataDirectory: Directory('availability-fixture'),
      cacheDirectory: Directory('availability-fixture/cache'),
      transport: FakeNative(),
      files: files,
      http: FakeHttp(),
      platformFeatures: false,
    );
    await services.downloads.initialize();
    final monitor = CompletedFiles(services.downloads);
    addTearDown(() async {
      monitor.dispose();
      await services.close();
    });
    return (services, files, monitor);
  }

  test(
    'Availability checks are bounded, cached and never rewrite completed tasks',
    () async {
      final (services, files, monitor) = await fixture(count: 7);
      files.availability['content://fixture/0'] = FileAvailability.missing;
      files.availability['content://fixture/1'] = FileAvailability.inaccessible;
      await monitor.refresh();
      expect(files.peak, 2);
      expect(
        monitor.state(services.downloads.task('completed-0')!),
        FileAvailability.missing,
      );
      expect(
        monitor.state(services.downloads.task('completed-1')!),
        FileAvailability.inaccessible,
      );
      expect(
        services.downloads.tasks.every(
          (t) => t.status == DownloadStatus.completed,
        ),
        isTrue,
      );
      expect(
        services.downloads.task('completed-0')!.savedPath,
        'content://fixture/0',
      );
      await monitor.refresh();
      expect(files.calls, 7);
      files.availability.clear();
      await monitor.refresh(force: true);
      expect(files.calls, 14);
      expect(
        monitor.state(services.downloads.task('completed-0')!),
        FileAvailability.present,
      );
    },
  );
  test(
    'A forced refresh queued during checking awaits the new inspection too',
    () async {
      final (services, files, monitor) = await fixture();
      final blocked = files.blocked = Completer<FileAvailability>();
      final first = monitor.refresh();
      final forced = monitor.refresh(force: true);
      files.blocked = null;
      files.availability['content://fixture/0'] = FileAvailability.missing;
      blocked.complete(FileAvailability.present);
      await Future.wait([first, forced]);
      expect(files.calls, 2);
      expect(
        monitor.state(services.downloads.tasks.single),
        FileAvailability.missing,
      );
    },
  );
  test('Late file checks cannot resurrect a removed download record', () async {
    final (services, files, monitor) = await fixture();
    final task = services.downloads.tasks.single;
    final blocked = files.blocked = Completer<FileAvailability>();
    final check = monitor.check(task);
    await services.downloads.delete(task.id);
    blocked.complete(FileAvailability.missing);
    await check;
    expect(services.downloads.tasks, isEmpty);
    expect(monitor.state(task), FileAvailability.unknown);
  });

  test(
    'An older successful check cannot hide a newer external deletion',
    () async {
      final (services, files, monitor) = await fixture();
      final task = services.downloads.tasks.single;
      final blocked = files.blocked = Completer<FileAvailability>();
      final oldCheck = monitor.check(task);
      files.blocked = null;
      files.availability[task.savedPath!] = FileAvailability.missing;
      expect(await monitor.check(task), FileAvailability.missing);
      blocked.complete(FileAvailability.present);
      expect(await oldCheck, FileAvailability.missing);
      expect(monitor.state(task), FileAvailability.missing);
    },
  );

  test(
    'An outdated check does not allow opening while a newer one is pending',
    () async {
      final (services, files, monitor) = await fixture();
      final task = services.downloads.tasks.single;
      await monitor.check(task);
      final firstResult = files.blocked = Completer<FileAvailability>();
      final first = monitor.check(task);
      final newerResult = files.blocked = Completer<FileAvailability>();
      final newer = monitor.check(task);
      firstResult.complete(FileAvailability.present);
      expect(await first, FileAvailability.unknown);
      newerResult.complete(FileAvailability.missing);
      expect(await newer, FileAvailability.missing);
      expect(monitor.state(task), FileAvailability.missing);
    },
  );
}
