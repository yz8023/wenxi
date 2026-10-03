import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/domain/torrent.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/torrent_page.dart';
import 'support.dart';
import 'torrent_test.dart' show TorrentTestHttp, testTorrent, testTorrentJson;

class _MetadataEngine extends GopeedEngine {
  _MetadataEngine(AppServices s)
    : super(FakeNative(), s.store, s.vault, s.dataDirectory, s.cacheDirectory);
  @override
  Future<Json> torrentCall(String method, Json args) async =>
      method == 'torrentMetadata'
      ? {'status': 'ready', 'info': testTorrentJson}
      : {};
  @override
  Future<void> close() async {}
}

class _SelectionQueue extends DownloadManager {
  _SelectionQueue(AppServices s)
    : super(
        store: s.store,
        engine: s.engine,
        files: s.files,
        cleanups: s.cleanups,
        http: s.transfer,
        refreshSource: (_) async =>
            throw StateError('No cloud request in a BT selection test'),
      );
  List<int> selection = [];
  @override
  Future<List<String>> enqueueTorrent(
    TorrentInfo info,
    List<int> selected,
  ) async {
    selection = selected;
    return ['selected'];
  }
}

class _UiServices extends Fake implements AppServices {
  _UiServices(this.dataDirectory);
  @override
  final Directory dataDirectory;
  @override
  late final cacheDirectory = Directory(p.join(dataDirectory.path, 'cache'));
  @override
  final store = StateStore.memory();
  @override
  late final vault = Vault(store);
  @override
  late final files = FakeFiles(Directory(p.join(dataDirectory.path, 'saved')));
  @override
  final transfer = TorrentTestHttp();
  @override
  late final cleanups = CleanupOutbox(store, FakeHttp());
  @override
  late final engine = _MetadataEngine(this);
  @override
  late final downloads = _SelectionQueue(this);
  @override
  Future<void> close() async {
    downloads.dispose();
    await engine.close();
  }
}

void main() {
  bool systemFont = false;
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
    final file = File('C:/Windows/Fonts/msyh.ttc');
    if (await file.exists()) {
      await (FontLoader('FixtureUI')..addFont(
            Future.value(ByteData.sublistView(await file.readAsBytes())),
          ))
          .load();
      systemFont = true;
    }
  });
  for (final (name, size, dark, scale) in [
    ('phone-bt', const Size(430, 960), false, 1.0),
    ('phone-bt-dark', const Size(430, 960), true, 1.0),
    ('landscape-bt-large-text', const Size(900, 430), false, 1.3),
  ]) {
    testWidgets('$name file selection works without layout overflow', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      late Directory root;
      late AppServices services;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('aster-bt-ui-');
        services = _UiServices(root);
      });
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(
              dark ? Brightness.dark : Brightness.light,
              fontFamily: systemFont ? 'FixtureUI' : null,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<bool>(
                      builder: (_) => RepaintBoundary(
                        key: const Key('capture'),
                        child: TorrentPage(services, testTorrent.magnet),
                      ),
                    ),
                  ),
                  child: const Text('打开种子'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开种子'));
        await tester.pump();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('下载选中 2 个文件'), findsOneWidget);
        if (systemFont) {
          await expectLater(
            find.byKey(const Key('capture')),
            matchesGoldenFile('goldens/$name.png'),
          );
        }
        await tester.tap(find.text('清空选择'));
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('torrent-download')))
              .onPressed,
          isNull,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('torrent-file-1')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('torrent-file-1')));
        await tester.pump();
        expect(find.text('下载选中 1 个文件'), findsOneWidget);
        await tester.tap(find.byKey(const Key('torrent-download')));
        await tester.pumpAndSettle();
        expect((services.downloads as _SelectionQueue).selection, [1]);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        services.close().then((_) => closed = true);
        for (var i = 0; i < 30 && !closed; i++) {
          await tester.pump();
        }
        expect(closed, isTrue);
        await tester.runAsync(() => root.delete(recursive: true));
      }
    });
  }
}
