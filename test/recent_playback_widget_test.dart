import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/playback_source.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/ui/player_page.dart';
import 'package:asterlink/ui/recent_playback_page.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppServices services;
  late FakeFiles files;
  Future<void> prepare() async {
    files = FakeFiles(Directory('recent-widget-fixture/saved'));
    services = AppServices(
      controlEnabled: false,
      store: StateStore.memory(),
      dataDirectory: Directory('recent-widget-fixture'),
      cacheDirectory: Directory('recent-widget-fixture/cache'),
      transport: FakeNative(),
      files: files,
      http: FakeHttp(),
      platformFeatures: false,
    );
    await PlaybackStore(services.store).save(
      'video',
      const PlaybackBookmark(
        name: '旅行视频.mp4',
        source: PlaybackSource.local(path: 'fixture.mp4'),
        position: Duration(seconds: 60),
        duration: Duration(minutes: 10),
        updatedAt: 1,
      ),
    );
  }

  void scenario(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        services.close().then((_) => closed = true);
        for (var i = 0; i < 20 && !closed; i++) {
          await tester.pump();
        }
        expect(closed, isTrue);
      }
    });
  }

  scenario(
    'A recent row opens its record once while a previous click is pending',
    (tester) async {
      await prepare();
      final opened = <PlaybackRecord>[], gate = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: RecentPlaybackPage(
            services,
            onOpen: (record) async {
              opened.add(record);
              await gate.future;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(const Key('recent-play-video'));
      await tester.tap(row);
      await tester.pump();
      await tester.tap(row);
      expect(opened, hasLength(1));
      expect(opened.single.key, 'video');
      expect(
        opened.single.bookmark.resumePosition,
        const Duration(seconds: 60),
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  scenario(
    'A missing file is visibly marked and its history can still be removed',
    (tester) async {
      await prepare();
      files
        ..failDelete = true
        ..availability['fixture.mp4'] = FileAvailability.missing;
      await tester.pumpWidget(MaterialApp(home: RecentPlaybackPage(services)));
      await tester.pumpAndSettle();
      expect(find.text(FileAvailability.missing.label), findsOneWidget);
      await tester.tap(find.byTooltip('管理播放记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移除记录'));
      await tester.pumpAndSettle();
      expect(PlaybackStore(services.store).recent, isEmpty);
      expect(find.text('暂无播放记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  scenario(
    'The home resume button restores directly and reports missing files without opening a player',
    (tester) async {
      await prepare();
      files.availability['fixture.mp4'] = FileAvailability.missing;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RecentPlaybackSummary(services, desktop: false)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('parse-recent-resume')));
      await tester.pumpAndSettle();
      expect(find.textContaining('本地文件不存在'), findsOneWidget);
      expect(find.byType(PlayerPage), findsNothing);
      expect(find.byType(RecentPlaybackPage), findsNothing);
      await tester.tap(find.byKey(const Key('parse-recent')));
      await tester.pumpAndSettle();
      expect(find.byType(RecentPlaybackPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
