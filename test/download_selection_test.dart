import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/platform/file_access.dart';
import 'support.dart';

class _SelectionHttp extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(4, '"selection-fixture"', null), false);
}

class _SelectionFiles extends FakeFiles {
  _SelectionFiles(super.directory);
  final failPaths = <String>{};
  Completer<FileAvailability>? blocked;
  int deletes = 0, inspections = 0, checked = 0;
  @override
  Future<FileAvailability> inspect(String? path) async {
    inspections++;
    try {
      if (blocked != null) return await blocked!.future;
      if (path != null && availability.containsKey(path)) {
        return availability[path]!;
      }
      // The widget fixture observes real external deletion without leaving
      // host file handles open in Flutter's simulated clock. PlatformFileAccess
      // itself is exercised by file_availability_test and file_deletion_test.
      return path != null && File(path).existsSync()
          ? FileAvailability.present
          : FileAvailability.missing;
    } finally {
      checked++;
    }
  }

  @override
  Future<void> delete(String? path) async {
    deletes++;
    if (failPaths.contains(path)) throw const AppException('文件正在使用');
    await super.delete(path);
  }
}

void main() {
  final openVideoLabel = Platform.isWindows ? '播放视频' : '打开文件';
  bool systemFont = false;
  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    final clock = Stopwatch()..start();
    bool settled() =>
        ready() && find.byType(CircularProgressIndicator).evaluate().isEmpty;
    do {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    } while (!settled() && clock.elapsed < const Duration(seconds: 12));
    expect(
      settled(),
      isTrue,
      reason: 'The asynchronous selection action did not finish',
    );
    await tester.pumpAndSettle();
  }

  setUpAll(() async {
    for (final (family, asset) in [
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      (
        'packages/cupertino_icons/CupertinoIcons',
        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      ),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (await font.exists()) {
      await (FontLoader('FixtureUI')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
      systemFont = true;
    }
  });

  Future<(AppServices, FakeNative, _SelectionFiles)> render(
    WidgetTester tester, {
    Size size = const Size(393, 864),
    bool dark = false,
    double scale = 1,
    bool missingFiles = false,
    bool blockedInspection = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    late Directory root;
    late AppServices services;
    final native = FakeNative()..finish = false;
    late _SelectionFiles files;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('aster-download-selection-');
      files = _SelectionFiles(Directory(p.join(root.path, 'saved')));
      final tasks = <Json>[];
      for (final (id, name, status, createdAt) in [
        ('completed-a', '旅行回忆 第一集.mp4', DownloadStatus.completed, 4),
        ('completed-b', '旅行回忆 第二集.mp4', DownloadStatus.completed, 3),
        ('paused', '待续传的资料.zip', DownloadStatus.paused, 2),
        ('failed', '等待重试的文件.zip', DownloadStatus.failed, 1),
      ]) {
        String? savedPath;
        if (status == DownloadStatus.completed) {
          savedPath = p.join(root.path, '$id.mp4');
          await File(savedPath).writeAsBytes([1, 2, 3, 4]);
          if (missingFiles) {
            await File(savedPath).delete();
            files.availability[savedPath] = FileAvailability.missing;
            files.failPaths.add(savedPath);
          }
        }
        tasks.add(
          DownloadTask(
            id: id,
            spec: DownloadSpec(
              url: 'https://example.com/$id',
              fileName: name,
              source: {'platform': 'Quark'},
              expectedSize: 4,
            ),
            createdAt: createdAt,
            status: status,
            total: 4,
            downloaded: status == DownloadStatus.completed ? 4 : 0,
            savedPath: savedPath,
            connections: 512,
            error: status == DownloadStatus.failed ? '网络连接中断' : '',
          ).toJson(),
        );
      }
      services = AppServices(
        controlEnabled: false,
        store: StateStore.memory({
          'settings': {'theme': dark ? 'Dark' : 'Light', 'concurrent': 1},
          'tasks': tasks,
        }),
        dataDirectory: root,
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        transport: native,
        files: files,
        http: FakeHttp(),
        transferHttp: _SelectionHttp(),
        platformFeatures: false,
        clock: () => DateTime(2026, 9, 14, 20),
      );
      await services.downloads.initialize();
    });
    if (blockedInspection) files.blocked = Completer<FileAvailability>();
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('selection-capture'),
        child: AsterLinkApp(
          services,
          initialTab: 2,
          fontFamily: systemFont ? 'FixtureUI' : null,
        ),
      ),
    );
    if (!blockedInspection) await waitFor(tester, () => files.checked >= 2);
    await tester.runAsync(() async {
      final context = tester.element(find.byType(MainShell));
      for (final file in Directory(
        'assets/icons',
      ).listSync().whereType<File>()) {
        if (file.path.endsWith('.png') || file.path.endsWith('.webp')) {
          await precacheImage(
            AssetImage(file.path.replaceAll('\\', '/')),
            context,
          );
        }
      }
    });
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      if (files.blocked?.isCompleted == false) {
        files.blocked!.complete(FileAvailability.inaccessible);
        await tester.pump();
      }
      await waitFor(tester, () => files.checked == files.inspections);
      var closed = false;
      final close = services.close().whenComplete(() => closed = true);
      await waitFor(tester, () => closed);
      await close;
      await tester.runAsync(() async {
        expect(
          p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path),
          isTrue,
        );
        await root.delete(recursive: true);
      });
    });
    return (services, native, files);
  }

  Finder row(String id) => find.byKey(ValueKey('download-row-$id'));
  Checkbox checkbox(WidgetTester tester, String id) =>
      tester.widget<Checkbox>(find.byKey(ValueKey('download-select-$id')));
  Finder action(String name) => find.byKey(Key('downloads-batch-$name'));
  Finder getCount() => find.byKey(const Key('downloads-selected-count'));
  Future<void> select(WidgetTester tester, String id) async {
    await tester.longPress(row(id));
    await tester.pumpAndSettle();
  }

  void background(WidgetTester tester) {
    for (final state in [
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  void foreground(WidgetTester tester) {
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  testWidgets(
    'A missing file can be removed from its details without file access',
    (tester) async {
      final (services, _, _) = await render(tester, missingFiles: true);
      await tester.tap(row('completed-a'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-remove-record')));
      await tester.pumpAndSettle();
      expect(find.text('移除下载记录'), findsOneWidget);
      expect(find.text('同时删除已下载的文件'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(services.downloads.task('completed-a'), isNotNull);
      await tester.tap(row('completed-a'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-remove-record')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('downloads-confirm-single-delete')),
      );
      await waitFor(
        tester,
        () => services.downloads.task('completed-a') == null,
      );
      expect(services.downloads.task('completed-b'), isNotNull);
    },
  );

  testWidgets(
    'Missing file filter supports selecting and removing all records',
    (tester) async {
      final (services, _, _) = await render(tester, missingFiles: true);
      await tester.tap(find.text('文件异常 2'));
      await tester.pumpAndSettle();
      await select(tester, 'completed-a');
      await tester.tap(find.byKey(const Key('downloads-select-all')));
      await tester.pumpAndSettle();
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      expect(find.text('其中 2 个文件已不存在，将移除对应的下载记录。'), findsOneWidget);
      expect(find.text('同时删除已下载的文件'), findsNothing);
      await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      await waitFor(tester, () => services.downloads.tasks.length == 2);
      expect(services.downloads.task('completed-a'), isNull);
      expect(services.downloads.task('completed-b'), isNull);
      expect(services.downloads.task('paused'), isNotNull);
      expect(services.downloads.task('failed'), isNotNull);
      expect(find.byKey(const Key('downloads-selection-bar')), findsNothing);
    },
  );

  testWidgets(
    'Opening details rechecks a file deleted externally after list inspection',
    (tester) async {
      final (services, _, files) = await render(tester);
      final path = services.downloads.task('completed-a')!.savedPath!;
      expect(find.text('文件不存在'), findsNothing);
      await tester.runAsync(() => File(path).delete());
      files.failPaths.add(path);
      await tester.tap(row('completed-a'));
      await waitFor(
        tester,
        () => find.textContaining('文件已被移动或删除，下载记录仍保留').evaluate().isNotEmpty,
      );
      expect(find.text(openVideoLabel), findsNothing);
      expect(find.text('移除下载记录'), findsOneWidget);
      await tester.tap(find.byKey(const Key('downloads-remove-record')));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNothing);
      await tester.tap(
        find.byKey(const Key('downloads-confirm-single-delete')),
      );
      await waitFor(
        tester,
        () => services.downloads.task('completed-a') == null,
      );
      expect(files.deletes, 0);
      expect(
        services.store.data
            .list('tasks')
            .any((task) => task.str('id') == 'completed-a'),
        isFalse,
      );
    },
  );

  testWidgets(
    'Returning from an external file manager refreshes an open details sheet',
    (tester) async {
      final (services, _, files) = await render(tester);
      await tester.tap(row('completed-a'));
      await waitFor(tester, () => files.checked == files.inspections);
      expect(find.text(openVideoLabel), findsOneWidget);
      background(tester);
      final path = services.downloads.task('completed-a')!.savedPath!;
      await tester.runAsync(() => File(path).delete());
      foreground(tester);
      await waitFor(
        tester,
        () => find.textContaining('文件已被移动或删除，下载记录仍保留').evaluate().isNotEmpty,
      );
      expect(find.text(openVideoLabel), findsNothing);
      expect(find.text('移除下载记录'), findsOneWidget);
      expect(
        services.downloads.task('completed-a')!.status,
        DownloadStatus.completed,
      );
      await Navigator.of(tester.element(find.text('移除下载记录'))).maybePop();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'A failed open exposes record removal even when the provider cannot identify the file',
    (tester) async {
      final (services, _, files) = await render(tester);
      final path = services.downloads.task('completed-a')!.savedPath!;
      await tester.runAsync(() => File(path).delete());
      files.availability[path] = FileAvailability.inaccessible;
      files.failPaths.add(path);
      final open = find.descendant(
        of: row('completed-a'),
        matching: find.byType(IconButton),
      );
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(find.text('移除下载记录'), findsOneWidget);
      expect(find.text(openVideoLabel), findsNothing);
      await tester.tap(find.byKey(const Key('downloads-remove-record')));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前无法访问原文件，仍可直接移除'), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      await tester.tap(
        find.byKey(const Key('downloads-confirm-single-delete')),
      );
      await waitFor(
        tester,
        () => services.downloads.task('completed-a') == null,
      );
      expect(files.deletes, 0);
    },
  );

  testWidgets(
    'A blocked file inspection cannot block single or batch history removal',
    (tester) async {
      final (services, _, files) = await render(
        tester,
        blockedInspection: true,
      );
      await tester.tap(row('completed-a'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-remove-record')));
      await tester.pumpAndSettle();
      expect(find.textContaining('文件状态尚未确认，仍可直接移除'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('downloads-confirm-single-delete')),
      );
      await waitFor(
        tester,
        () => services.downloads.task('completed-a') == null,
      );
      await select(tester, 'completed-b');
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      expect(find.text('移除 1 条下载记录'), findsOneWidget);
      await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      await waitFor(
        tester,
        () => services.downloads.task('completed-b') == null,
      );
      files.blocked!.complete(FileAvailability.present);
      await tester.pumpAndSettle();
      expect(services.downloads.tasks.map((task) => task.id), [
        'paused',
        'failed',
      ]);
      expect(files.deletes, 0);
    },
  );

  testWidgets(
    'Returning to the download tab discovers an external deletion and permits batch removal',
    (tester) async {
      final (services, _, files) = await render(tester);
      await tester.tap(find.text('网盘').last);
      await tester.pumpAndSettle();
      final path = services.downloads.task('completed-a')!.savedPath!;
      await tester.runAsync(() => File(path).delete());
      files.failPaths.add(path);
      await tester.tap(find.text('下载').last);
      await waitFor(tester, () => find.text('文件不存在').evaluate().isNotEmpty);
      await tester.tap(find.text('文件异常 1'));
      await tester.pumpAndSettle();
      await select(tester, 'completed-a');
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      await waitFor(
        tester,
        () => services.downloads.task('completed-a') == null,
      );
      expect(files.deletes, 0);
      expect(services.downloads.task('completed-b'), isNotNull);
    },
  );

  testWidgets(
    'An inaccessible history record can be removed in a batch without deleting its file',
    (tester) async {
      final (services, _, files) = await render(tester);
      final path = services.downloads.task('completed-a')!.savedPath!;
      await tester.runAsync(() => File(path).delete());
      files.availability[path] = FileAvailability.inaccessible;
      files.failPaths.add(path);
      background(tester);
      foreground(tester);
      await waitFor(tester, () => find.text('无法访问文件').evaluate().isNotEmpty);
      await tester.tap(find.text('文件异常 1'));
      await tester.pumpAndSettle();
      await select(tester, 'completed-a');
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      await waitFor(
        tester,
        () => services.downloads.task('completed-a') == null,
      );
      expect(files.deletes, 0);
    },
  );

  testWidgets(
    'Long press selects, taps toggle, back and tab change exit selection',
    (tester) async {
      await render(tester);
      await select(tester, 'completed-a');
      expect(checkbox(tester, 'completed-a').value, isTrue);
      expect(tester.widget<Text>(getCount()).data, '已选 1 项');
      expect(tester.widget<TextButton>(action('pause')).onPressed, isNull);
      expect(tester.widget<TextButton>(action('resume')).onPressed, isNull);
      await tester.tap(row('completed-b'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(getCount()).data, '已选 2 项');
      await tester.tap(row('completed-a'));
      await tester.pumpAndSettle();
      expect(checkbox(tester, 'completed-a').value, isFalse);
      expect(find.text('复制下载链接'), findsNothing);
      await Navigator.of(tester.element(row('completed-b'))).maybePop();
      await tester.pumpAndSettle();
      expect(getCount(), findsNothing);
      await tester.tap(row('completed-b'));
      await tester.pumpAndSettle();
      expect(find.text('复制下载链接'), findsOneWidget);
      Navigator.of(tester.element(find.text('复制下载链接'))).pop();
      await tester.pumpAndSettle();
      await select(tester, 'completed-a');
      await tester.tap(find.text('网盘').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载').last);
      await tester.pumpAndSettle();
      expect(getCount(), findsNothing);
    },
  );

  testWidgets(
    'Select all stays within the filter and vanished rows leave selection',
    (tester) async {
      final (services, _, _) = await render(tester);
      await tester.tap(find.text('已完成 2'));
      await tester.pumpAndSettle();
      await select(tester, 'completed-a');
      await tester.tap(find.byKey(const Key('downloads-select-all')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(getCount()).data, '已选 2 项');
      expect(find.byType(Checkbox), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('downloads-select-all')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(getCount()).data, '已选 0 项');
      expect(tester.widget<TextButton>(action('delete')).onPressed, isNull);
      await tester.tap(find.text('失败 1'));
      await tester.pumpAndSettle();
      expect(getCount(), findsNothing);
      await select(tester, 'failed');
      await tester.runAsync(() => services.downloads.delete('failed'));
      await tester.pumpAndSettle();
      expect(getCount(), findsNothing);
      expect(services.downloads.task('completed-a'), isNotNull);
    },
  );

  testWidgets(
    'Batch delete can be cancelled and preserves downloaded files by default',
    (tester) async {
      final (services, _, _) = await render(tester);
      final paths = [
        'completed-a',
        'completed-b',
      ].map((id) => services.downloads.task(id)!.savedPath!).toList();
      await select(tester, 'completed-a');
      await tester.tap(row('completed-b'));
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      expect(find.text('移除 2 条下载记录'), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(services.downloads.tasks.length, 4);
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      await waitFor(tester, () => services.downloads.tasks.length == 2);
      expect(getCount(), findsNothing);
      await tester.runAsync(() async {
        for (final path in paths) {
          expect(await File(path).exists(), isTrue);
        }
      });
      expect(services.downloads.task('paused'), isNotNull);
      expect(services.downloads.task('failed'), isNotNull);
    },
  );

  testWidgets(
    'Opting into file deletion retains a failed file and selects it for retry',
    (tester) async {
      final (services, _, files) = await render(tester);
      final keep = services.downloads.task('completed-a')!.savedPath!;
      final removed = services.downloads.task('completed-b')!.savedPath!;
      files.failPaths.add(keep);
      await select(tester, 'completed-a');
      await tester.tap(row('completed-b'));
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      await waitFor(
        tester,
        () => services.downloads.task('completed-b') == null,
      );
      expect(tester.widget<Text>(getCount()).data, '已选 1 项');
      expect(checkbox(tester, 'completed-a').value, isTrue);
      expect(services.downloads.task('completed-a')!.error, '文件正在使用');
      expect(services.downloads.tasks.length, 3);
      await tester.runAsync(() async {
        expect(await File(keep).exists(), isTrue);
        expect(await File(removed).exists(), isFalse);
      });
      expect(
        find.byKey(const Key('downloads-selection-notice')),
        findsOneWidget,
      );
      files.failPaths.clear();
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      expect(find.text('移除 1 条下载记录'), findsOneWidget);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      await waitFor(
        tester,
        () => services.downloads.task('completed-a') == null,
      );
      await tester.runAsync(() async {
        expect(await File(keep).exists(), isFalse);
      });
    },
  );

  testWidgets(
    'Selected paused and failed downloads resume and pause without touching completed files',
    (tester) async {
      final (services, native, _) = await render(tester);
      await select(tester, 'paused');
      await tester.tap(row('failed'));
      await tester.pumpAndSettle();
      await tester.tap(action('resume'));
      await waitFor(
        tester,
        () => native.writer && services.downloads.task('failed')!.active,
      );
      expect(getCount(), findsNothing);
      await select(tester, 'paused');
      await tester.tap(row('failed'));
      await tester.pumpAndSettle();
      await tester.tap(action('pause'));
      await waitFor(
        tester,
        () =>
            services.downloads.activeCount == 0 &&
            services.downloads.task('failed')!.status == DownloadStatus.paused,
      );
      expect(native.begins.length, 1);
      expect(services.downloads.task('paused')!.status, DownloadStatus.paused);
      expect(
        services.downloads.task('completed-a')!.status,
        DownloadStatus.completed,
      );
      expect(
        services.downloads.task('completed-b')!.status,
        DownloadStatus.completed,
      );
    },
  );

  testWidgets(
    'New task and progress reordering do not move the selection to another file',
    (tester) async {
      final (services, native, _) = await render(tester);
      await select(tester, 'completed-a');
      native.finish = true;
      late String id;
      id = (await tester.runAsync(
        () => services.downloads.enqueue(
          const DownloadSpec(
            url: 'https://example.com/new',
            fileName: '新下载的资料.zip',
            expectedSize: 4,
          ),
        ),
      ))!;
      await waitFor(
        tester,
        () =>
            services.downloads.task(id)!.status == DownloadStatus.completed &&
            services.downloads.activeCount == 0,
      );
      expect(tester.widget<Text>(getCount()).data, '已选 1 项');
      expect(checkbox(tester, 'completed-a').value, isTrue);
      expect(checkbox(tester, id).value, isFalse);
    },
  );

  for (final (name, size, dark, scale) in [
    ('phone-downloads-selection', const Size(393, 864), false, 1.0),
    ('phone-downloads-selection-dark', const Size(393, 864), true, 1.0),
    (
      'landscape-downloads-selection-large-text',
      const Size(900, 430),
      false,
      1.5,
    ),
  ]) {
    testWidgets('$name selection layout', (tester) async {
      await render(tester, size: size, dark: dark, scale: scale);
      await select(tester, 'paused');
      await tester.tap(find.byKey(const Key('downloads-select-all')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.widget<Text>(getCount()).data, '已选 4 项');
      await expectLater(
        find.byKey(const Key('selection-capture')),
        matchesGoldenFile('goldens/$name.png'),
      );
    });
  }
}
