import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/platform/file_access.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.asterlink.app/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('aster-file-delete-');
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    expect(
      p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path),
      isTrue,
    );
    await root.delete(recursive: true);
  });

  test('Local paths can be deleted again after the file has gone', () async {
    final file = File(p.join(root.path, 'file.bin'));
    final access = PlatformFileAccess(FakeNative(), root, android: false);
    await file.writeAsBytes([1, 2, 3]);
    await access.delete(file.path);
    expect(await file.exists(), isFalse);
    await access.delete(file.path);
    expect(await access.inspect(file.path), FileAvailability.missing);
  });

  test(
    'File URIs use the same path for inspection and repeated deletion',
    () async {
      final file = File(p.join(root.path, '视频 #1.mp4'));
      final access = PlatformFileAccess(FakeNative(), root, android: false);
      await file.writeAsBytes([1, 2, 3]);
      final uri = file.uri.toString();
      expect(await access.inspect(uri), FileAvailability.present);
      await access.delete(uri);
      expect(await file.exists(), isFalse);
      await access.delete(uri);
      expect(await access.inspect(uri), FileAvailability.missing);
    },
  );

  test(
    'A directory in place of a file and relative paths are never deleted',
    () async {
      final directory = await Directory(p.join(root.path, 'keep')).create();
      final access = PlatformFileAccess(FakeNative(), root, android: false);
      await expectLater(
        access.delete(directory.path),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        access.delete('relative.bin'),
        throwsA(isA<AppException>()),
      );
      expect(await directory.exists(), isTrue);
    },
  );

  test(
    'Android deletion uses the native channel and tolerates empty saved paths',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final access = PlatformFileAccess(FakeNative(), root, android: true);
      await access.delete(null);
      await access.delete('');
      expect(calls, isEmpty);
      await access.delete('content://fixture/missing');
      expect(calls.single.method, 'deleteFile');
      expect(calls.single.arguments, {'path': 'content://fixture/missing'});
    },
  );

  test('Android permission failures are retained as deletion errors', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'permission', message: '目录权限已失效');
    });
    final access = PlatformFileAccess(FakeNative(), root, android: true);
    await expectLater(
      access.delete('content://fixture/protected'),
      throwsA(
        isA<AppException>().having((e) => e.message, 'message', '目录权限已失效'),
      ),
    );
  });

  test(
    'Batch deletion removes absent records and keeps inaccessible files',
    () async {
      final deletedPaths = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'deleteFile');
        final path = call.arguments['path'] as String;
        deletedPaths.add(path);
        if (path.endsWith('/protected')) {
          throw PlatformException(code: 'permission', message: '目录权限已失效');
        }
        return null;
      });
      final native = FakeNative();
      final store = StateStore.memory({
        'tasks': [
          for (final id in ['missing', 'protected', 'present'])
            DownloadTask(
              id: id,
              spec: DownloadSpec(
                url: 'https://example.com/$id',
                fileName: '$id.bin',
              ),
              status: DownloadStatus.completed,
              createdAt: 1,
              savedPath: 'content://fixture/$id',
            ).toJson(),
        ],
      });
      final services = AppServices(
        controlEnabled: false,
        store: store,
        dataDirectory: root,
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        transport: native,
        files: PlatformFileAccess(native, root, android: true),
        http: FakeHttp(),
        platformFeatures: false,
      );
      try {
        await services.downloads.initialize();
        final result = await services.downloads.batch(
          ['missing', 'protected', 'present'],
          DownloadBatchAction.delete,
          deleteFiles: true,
        );
        expect(result.succeeded, ['missing', 'present']);
        expect(result.failed.keys, ['protected']);
        expect(services.downloads.tasks.single.id, 'protected');
        expect(
          services.downloads.tasks.single.savedPath,
          'content://fixture/protected',
        );
        expect(store.data.list('tasks').single.str('id'), 'protected');
        expect(native.openCount, 0);
        // A user may always choose record-only removal after a file access error.
        await services.downloads.delete('protected');
        expect(deletedPaths, [
          'content://fixture/missing',
          'content://fixture/protected',
          'content://fixture/present',
        ]);
        expect(services.downloads.tasks, isEmpty);
      } finally {
        await services.close();
      }
    },
  );
}
