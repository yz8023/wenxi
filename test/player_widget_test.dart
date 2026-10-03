import 'dart:async';
import 'dart:io';
import 'package:media_kit/media_kit.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/core/operation_progress.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/player_page.dart';
import 'package:asterlink/ui/loading_indicator.dart';
import 'package:asterlink/ui/player_theme.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/playback/external_stream.dart';
import 'player_support.dart';

class _FixtureExternalStream extends ExternalPlaybackStream {
  _FixtureExternalStream(super.source);
  @override
  Future<void> start() async {}
  @override
  String get url => 'http://127.0.0.1:12345/fixture/video';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var systemFont = false;
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

  Future<
    ({PlaybackFixture fixture, FakePlaybackDevice device, Directory directory})
  >
  render(
    WidgetTester tester, {
    Size size = const Size(393, 864),
    double scale = 1,
    bool dark = false,
    Future<XFile?> Function()? chooseSubtitle,
    PlaybackFixture? suppliedFixture,
    FakePlaybackDevice? suppliedDevice,
    bool downloadAvailable = false,
    bool settle = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final fixture =
            suppliedFixture ??
            PlaybackFixture(externalStreamFactory: _FixtureExternalStream.new),
        device =
            suppliedDevice ??
            (FakePlaybackDevice()..supportsExternalPlayer = size.width < 1000);
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('asterlink-player-widget-'),
    ))!;
    // The test binding unmounts the player and drains its fake clock before tearDown.
    // Real filesystem cleanup runs here, outside that fake clock.
    addTearDown(() => removePlayerFixture(directory));
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('player-capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(
            dark ? Brightness.dark : Brightness.light,
            fontFamily: systemFont ? 'FixtureUI' : null,
          ),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          initialRoute: '/player',
          routes: {
            '/': (_) => const Scaffold(body: Center(child: Text('播放器已关闭'))),
            '/player': (_) => PlayerPage(
              fixture.controller,
              subtitleDirectory: directory,
              device: device,
              chooseSubtitle: chooseSubtitle,
              onDownload: downloadAvailable ? (_) async {} : null,
            ),
          },
        ),
      ),
    );
    if (!settle) {
      await tester.pump();
      return (fixture: fixture, device: device, directory: directory);
    }
    await tester.pumpAndSettle();
    expect(fixture.controller.ready, isTrue);
    fixture.current.emit(
      fixture.current.state.copyWith(
        position: const Duration(seconds: 120),
        buffer: const Duration(seconds: 180),
        subtitle: ['每一段旅途，都值得被记住。', 'Every journey is worth remembering.'],
      ),
    );
    await tester.pump();
    return (fixture: fixture, device: device, directory: directory);
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> openSetting(WidgetTester tester, String label) async {
    if (label == '选集') {
      await tap(tester, find.byKey(const Key('player-playlist')));
      return;
    }
    await tap(tester, find.byTooltip('播放设置'));
    await tester.ensureVisible(find.text(label));
    await tap(tester, find.text(label));
  }

  Future<void> doubleTap(WidgetTester tester, Offset position) async {
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 70));
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets(
    'Phone exposes the external player button and cancellation restores playback',
    (tester) async {
      final device = FakePlaybackDevice()..supportsExternalPlayer = true;
      final page = await render(
        tester,
        suppliedDevice: device,
        downloadAvailable: true,
      );
      device.externalPlayer = (url, title, position) async {
        expect(url, 'http://127.0.0.1:12345/fixture/video');
        expect(title, page.fixture.controller.current.name);
        expect(position, const Duration(seconds: 120));
        expect(page.fixture.current.state.playing, isFalse);
        return false;
      };
      expect(
        find.byKey(const Key('player-external-player')).hitTestable(),
        findsOneWidget,
      );
      await tap(tester, find.byTooltip('第三方播放器'));
      expect(device.calls, contains('externalPlayer'));
      expect(page.fixture.current.state.playing, isTrue);
      expect(page.fixture.leases.values.single, 1);
    },
  );

  testWidgets(
    'External player failure is visible and leaves internal playback usable',
    (tester) async {
      final device = FakePlaybackDevice()..supportsExternalPlayer = true;
      final page = await render(tester, suppliedDevice: device);
      device.externalPlayer = (_, _, _) async =>
          throw const AppException('未找到可播放此视频的第三方播放器');
      await tap(tester, find.byTooltip('第三方播放器'));
      expect(find.text('未找到可播放此视频的第三方播放器'), findsOneWidget);
      expect(page.fixture.current.state.playing, isTrue);
    },
  );

  testWidgets(
    'External player is also reachable by name in playback settings',
    (tester) async {
      final device = FakePlaybackDevice()..supportsExternalPlayer = true;
      final page = await render(tester, suppliedDevice: device);
      device.externalPlayer = (_, _, _) async => true;
      await tap(tester, find.byTooltip('播放设置'));
      await tester.ensureVisible(find.text('第三方播放器'));
      await tap(tester, find.text('第三方播放器'));
      expect(find.byKey(const Key('player-panel')), findsNothing);
      expect(page.fixture.controller.playingExternally, isTrue);
      expect(page.fixture.current.state.playing, isFalse);
    },
  );

  testWidgets('A narrow desktop window does not expose the phone-only action', (
    tester,
  ) async {
    await render(
      tester,
      size: const Size(320, 700),
      suppliedDevice: FakePlaybackDevice(),
    );
    expect(find.byTooltip('第三方播放器'), findsNothing);
    await tap(tester, find.byTooltip('播放设置'));
    expect(find.text('第三方播放器'), findsNothing);
  });

  for (final size in [const Size(393, 864), const Size(700, 320)]) {
    testWidgets('Player shows only a centered loading icon at $size', (
      tester,
    ) async {
      final fixture = PlaybackFixture();
      final pending = Completer<void>();
      fixture.prepareBarrier = (_, _) async {
        await OperationProgress.step(
          OperationStage.createTemporary,
          () async {},
        );
        await OperationProgress.step(OperationStage.transfer, () async {});
        await OperationProgress.step(
          OperationStage.playbackLink,
          () => pending.future,
        );
      };
      try {
        await render(
          tester,
          suppliedFixture: fixture,
          size: size,
          scale: 1.8,
          settle: false,
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(AppLoadingIndicator), findsOneWidget);
        expect(
          tester.getCenter(find.byType(AppLoadingIndicator)),
          Offset(size.width / 2, size.height / 2),
        );
        expect(find.text('正在准备播放…'), findsNothing);
        expect(find.text('正在获取播放链接…'), findsNothing);
        expect(fixture.controller.ready, isFalse);
        expect(tester.takeException(), isNull);
        pending.complete();
        await tester.pumpAndSettle();
        expect(fixture.controller.ready, isTrue);
        expect(find.byType(AppLoadingIndicator), findsNothing);
        expect(find.text('正在获取播放链接…'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        if (!pending.isCompleted) pending.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets(
    'Windows PiP controls play, seek, drag and restore without reopening media',
    (tester) async {
      final device = FakePlaybackDevice()..supportsDesktopPip = true;
      final result = await render(
        tester,
        size: const Size(1100, 780),
        suppliedDevice: device,
      );
      final backend = result.fixture.current;
      await tap(tester, find.byTooltip('画中画'));
      tester.view.physicalSize = const Size(480, 270);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-desktop-pip')), findsOneWidget);
      expect(find.byTooltip('播放设置'), findsNothing);
      await tap(tester, find.byKey(const Key('player-pip-toggle')));
      expect(result.fixture.current.state.playing, isFalse);
      final slider = tester.widget<Slider>(
        find.byKey(const Key('player-pip-seek')),
      );
      slider.onChanged!(180000);
      slider.onChangeEnd!(180000);
      await tester.pumpAndSettle();
      expect(result.fixture.current.state.position, const Duration(minutes: 3));
      await tester.drag(
        find.byKey(const Key('player-pip-drag')),
        const Offset(30, 20),
      );
      await tester.pumpAndSettle();
      expect(device.calls, contains('dragPip'));
      await tester.drag(
        find.byKey(const Key('pip-resize-bottomRight')),
        const Offset(40, 30),
      );
      await tester.pumpAndSettle();
      expect(device.calls, contains('resizePip:bottomRight'));
      await expectLater(
        find.byKey(const Key('player-capture')),
        matchesGoldenFile('goldens/player-windows-pip.png'),
      );
      await tap(tester, find.byTooltip('还原窗口'));
      tester.view.physicalSize = const Size(1100, 780);
      await tester.pumpAndSettle();
      expect(device.inPip, isFalse);
      expect(identical(backend, result.fixture.current), isTrue);
      expect(result.fixture.current.state.position, const Duration(minutes: 3));
      expect(find.byTooltip('播放设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Windows PiP close stops playback and returns to the previous page',
    (tester) async {
      final device = FakePlaybackDevice()..supportsDesktopPip = true;
      final result = await render(tester, suppliedDevice: device);
      await tap(tester, find.byTooltip('画中画'));
      tester.view.physicalSize = const Size(270, 480);
      await tester.pumpAndSettle();
      await tap(tester, find.byTooltip('关闭画中画'));
      expect(
        result.fixture.current.state.playing,
        isFalse,
        reason: 'Close first pauses the media',
      );
      expect(
        device.inPip,
        isFalse,
        reason: 'Closing restores the window first',
      );
      expect(result.fixture.current.state.playing, isFalse);
      expect(find.text('播放器已关闭'), findsOneWidget);
      expect(result.fixture.current.closed, isTrue);
      expect(device.inPip, isFalse);
      expect(device.finished, isTrue);
    },
  );

  for (final (name, size, scale, dark) in [
    ('player-phone', const Size(393, 864), 1.0, false),
    ('player-landscape', const Size(844, 390), 1.0, false),
    ('player-desktop', const Size(1100, 780), 1.0, false),
    ('player-large-text', const Size(320, 700), 1.8, false),
    ('player-dark', const Size(393, 864), 1.0, true),
  ]) {
    testWidgets('$name controls remain reachable without overflow', (
      tester,
    ) async {
      await render(tester, size: size, scale: scale, dark: dark);
      expect(
        find.byKey(const Key('player-lock')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('player-play-pause')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const Key('player-capture')),
        matchesGoldenFile('goldens/$name.png'),
      );
    });
  }

  for (final dark in [false, true]) {
    testWidgets(
      'Player controls stay legible in the ${dark ? 'dark' : 'light'} application theme',
      (tester) async {
        await render(tester, dark: dark);
        final slider = tester.widget<Slider>(
          find.byKey(const Key('player-seek')),
        );
        expect(slider.activeColor, playerAccent);
        await tap(tester, find.byTooltip('播放设置'));
        final panel = tester.widget<Material>(
          find.byKey(const Key('player-panel')),
        );
        expect(panel.color, playerPanelColor);
        expect(
          Theme.of(tester.element(find.text('自动适配视频方向'))).brightness,
          Brightness.dark,
        );
        expect(find.text('自动适配视频方向'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byKey(const Key('player-capture')),
          matchesGoldenFile(
            'goldens/player-settings-${dark ? 'dark' : 'light'}.png',
          ),
        );
      },
    );
  }

  testWidgets(
    'A right-side settings panel adapts to portrait without restarting playback',
    (tester) async {
      final page = await render(tester, size: const Size(844, 390));
      final backend = page.fixture.current;
      await tap(tester, find.byTooltip('播放设置'));
      final side = tester.getRect(find.byKey(const Key('player-panel')));
      expect(side.right, 844);
      expect(side.width, lessThan(422));
      expect(side.top, 0);
      expect(side.height, 390);
      await expectLater(
        find.byKey(const Key('player-capture')),
        matchesGoldenFile('goldens/player-settings-landscape.png'),
      );
      await tester.ensureVisible(find.text('记住播放进度'));
      await tester.pumpAndSettle();
      await tap(tester, find.text('记住播放进度'));
      expect(page.fixture.history.preferences.resume, isFalse);
      tester.view.physicalSize = const Size(393, 864);
      await tester.pumpAndSettle();
      final bottom = tester.getRect(find.byKey(const Key('player-panel')));
      expect(bottom.left, 0);
      expect(bottom.width, 393);
      expect(bottom.top, greaterThan(0));
      expect(bottom.bottom, 864);
      expect(page.fixture.current, same(backend));
      expect(backend.state.playing, isTrue);
      expect(page.fixture.history.preferences.resume, isFalse);
      await tester.scrollUntilVisible(
        find.text('字幕'),
        -180,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('player-panel')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tap(tester, find.text('字幕'));
      expect(find.text('关闭字幕'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'PiP dismisses panels and a selected submenu cannot reappear over it',
    (tester) async {
      final page = await render(tester);
      await tap(tester, find.byTooltip('播放设置'));
      await page.device.enterPip();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-panel')), findsNothing);
      expect(page.fixture.current.state.playing, isTrue);
      page.device.leavePip();
      await tester.pumpAndSettle();
      await tap(tester, find.byTooltip('播放设置'));
      await tester.tap(find.text('字幕'));
      await page.device.enterPip();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-panel')), findsNothing);
      expect(find.text('关闭字幕'), findsNothing);
      expect(page.fixture.current.state.playing, isTrue);
      page.device.leavePip();
      await tester.pumpAndSettle();
      await openSetting(tester, '音轨');
      expect(find.text('音轨与同步'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Progress updates do not prevent controls and system bars from hiding',
    (tester) async {
      final page = await render(tester);
      final backend = page.fixture.current;
      for (var i = 1; i <= 5; i++) {
        backend.emit(
          backend.state.copyWith(position: Duration(seconds: 120 + i)),
        );
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-seek')), findsNothing);
      expect(find.byKey(const Key('player-collapsed-progress')), findsNothing);
      expect(find.byKey(const Key('player-bottom-controls')), findsNothing);
      expect(page.device.barsVisible, isFalse);
      final seeks = backend.seeks.length;
      await tester.tapAt(const Offset(196, 432));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('player-seek')).hitTestable(),
        findsOneWidget,
      );
      expect(find.byKey(const Key('player-collapsed-progress')), findsNothing);
      expect(page.device.barsVisible, isTrue);
      expect(backend.seeks.length, seeks);
      expect(backend.state.position, const Duration(seconds: 125));
      expect(backend.state.playing, isTrue);
    },
  );

  testWidgets(
    'Speed controls and all toolbar actions fit large text and safe areas',
    (tester) async {
      final page = await render(
        tester,
        size: const Size(320, 700),
        scale: 2,
        downloadAvailable: true,
      );
      for (final label in ['返回', '下载文件', '画中画', '播放设置']) {
        expect(find.byTooltip(label).hitTestable(), findsOneWidget);
      }
      await tap(tester, find.byKey(const Key('player-speed')));
      await tester.ensureVisible(find.byKey(const ValueKey('player-rate-3.0')));
      await tap(tester, find.byKey(const ValueKey('player-rate-3.0')));
      expect(page.fixture.current.state.rate, 3);
      expect(page.fixture.history.preferences.rate, 3);
      tester.view.physicalSize = const Size(640, 320);
      tester.view.padding = FakeViewPadding(left: 44, right: 24, bottom: 20);
      addTearDown(tester.view.resetPadding);
      await tester.pumpAndSettle();
      final lock = tester.getRect(find.byKey(const Key('player-lock')));
      expect(lock.left, greaterThanOrEqualTo(44));
      final fullscreen = tester.getRect(
        find.byKey(const Key('player-fullscreen')),
      );
      expect(fullscreen.right, lessThanOrEqualTo(616));
      expect(fullscreen.bottom, lessThanOrEqualTo(300));
      await tap(tester, find.byKey(const Key('player-playlist')));
      await tester.ensureVisible(find.byKey(const Key('episode-1')));
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const Key('episode-1')));
      expect(page.fixture.controller.index, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Single-tap fade starts next frame and retains controls through system-inset changes',
    (tester) async {
      tester.view.padding = FakeViewPadding(top: 24, bottom: 20);
      tester.view.viewPadding = FakeViewPadding(top: 24, bottom: 20);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      final page = await render(tester);
      final top = find.byKey(
        const Key('player-top-controls'),
        skipOffstage: false,
      );
      final element = tester.element(top), topRect = tester.getRect(top);
      final caption = find.byKey(const Key('player-captions'));
      final initialCaption = tester.getRect(caption);
      await tester.tapAt(const Offset(196, 300));
      await tester.pump();
      expect(page.device.barsVisible, isFalse);
      expect(
        find.byKey(const Key('player-play-pause')).hitTestable(),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 16));
      double opacity() => tester
          .widget<FadeTransition>(
            find.byKey(const Key('player-controls-fade'), skipOffstage: false),
          )
          .opacity
          .value;
      expect(opacity(), allOf(greaterThan(0), lessThan(1)));
      expect(tester.element(top), same(element));
      expect(tester.getRect(caption).top, greaterThan(initialCaption.top));
      tester.view.padding = FakeViewPadding();
      tester.view.viewPadding = FakeViewPadding();
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getRect(top), topRect);
      await tester.pump(const Duration(milliseconds: 180));
      expect(opacity(), 0);
      expect(tester.element(top), same(element));
      expect(find.byKey(const Key('player-top-controls')), findsNothing);
      expect(tester.getRect(caption).top, greaterThan(initialCaption.top));
    },
  );

  testWidgets(
    'Quickly reversing visibility continues from the current opacity',
    (tester) async {
      final page = await render(tester);
      double opacity() => tester
          .widget<FadeTransition>(
            find.byKey(const Key('player-controls-fade'), skipOffstage: false),
          )
          .opacity
          .value;
      await tester.tapAt(const Offset(196, 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      final fading = opacity();
      expect(fading, allOf(greaterThan(0), lessThan(1)));
      // A separate tap location is not a double-tap seek/pause gesture.
      await tester.tapAt(const Offset(196, 520));
      await tester.pump();
      expect(opacity(), closeTo(fading, .01));
      await tester.pump(const Duration(milliseconds: 32));
      expect(opacity(), greaterThan(fading));
      expect(page.fixture.current.state.playing, isTrue);
      await tester.pumpAndSettle();
      expect(opacity(), 1);
    },
  );

  testWidgets(
    'Progress events rebuild the seek bar without rebuilding top controls or syncing system bars',
    (tester) async {
      final page = await render(tester);
      final top = tester.widget(find.byKey(const Key('player-top-controls')));
      final deviceUpdates = page.device.updates;
      for (var i = 0; i < 12; i++) {
        page.fixture.current.emit(
          page.fixture.current.state.copyWith(
            position: Duration(seconds: 130 + i),
            buffer: Duration(seconds: 190 + i),
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        tester.widget(find.byKey(const Key('player-top-controls'))),
        same(top),
      );
      expect(page.device.updates, deviceUpdates);
      expect(
        tester.widget<Slider>(find.byKey(const Key('player-seek'))).value,
        141000,
      );
    },
  );

  testWidgets(
    'Reduced-motion preferences hide controls without leaving an animated overlay',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final page = await render(tester);
      await tester.tapAt(const Offset(196, 300));
      await tester.pump();
      expect(find.byKey(const Key('player-top-controls')), findsNothing);
      expect(page.device.barsVisible, isFalse);
      final fade = tester.widget<FadeTransition>(
        find.byKey(const Key('player-controls-fade'), skipOffstage: false),
      );
      expect(fade.opacity.value, 0);
    },
  );

  testWidgets(
    'Video switches, screen locking and automatic direction setting reach the device',
    (tester) async {
      final page = await render(tester);
      expect(page.device.orientation, PlaybackOrientation.landscape);
      await tap(tester, find.byKey(const Key('player-lock')));
      expect(page.device.orientationLocked, isTrue);
      await tap(tester, find.byKey(const Key('player-unlock')));
      expect(page.device.orientationLocked, isFalse);
      page.fixture.configureBackend = (backend) =>
          backend.emit(backend.state.copyWith(width: 1080, height: 1920));
      await openSetting(tester, '选集');
      await tap(tester, find.byKey(const Key('episode-1')));
      expect(page.device.orientation, PlaybackOrientation.portrait);
      expect(page.fixture.controller.index, 1);
      await tap(tester, find.byTooltip('播放设置'));
      await tap(tester, find.text('自动适配视频方向'));
      expect(page.device.orientation, PlaybackOrientation.system);
      expect(page.fixture.history.preferences.autoRotate, isFalse);
      await tap(tester, find.text('自动适配视频方向'));
      expect(page.device.orientation, PlaybackOrientation.portrait);
      expect(page.fixture.history.preferences.autoRotate, isTrue);
      await tap(tester, find.byTooltip('关闭面板'));
    },
  );

  testWidgets(
    'Playback connections update immediately and persist across episodes',
    (tester) async {
      final page = await render(tester);
      expect(page.fixture.current.connections, 8);
      await tap(tester, find.byTooltip('播放设置'));
      final choice = find.byKey(const Key('player-connections-16'));
      await tester.ensureVisible(choice);
      await tap(tester, choice);
      expect(page.fixture.current.connections, 16);
      expect(page.fixture.history.preferences.connections, 16);
      await tap(tester, find.byTooltip('关闭面板'));
      await openSetting(tester, '选集');
      await tap(tester, find.byKey(const Key('episode-1')));
      expect(page.fixture.current.connections, 16);
      expect(page.fixture.controller.index, 1);
    },
  );

  testWidgets(
    'Secondary controls live in settings and landscape overlays leave the center clear',
    (tester) async {
      await render(tester, size: const Size(844, 390));
      for (final label in ['音轨', '字幕', '画面']) {
        expect(find.text(label), findsNothing);
      }
      final top = tester.getRect(find.byKey(const Key('player-top-controls')));
      final bottom = tester.getRect(
        find.byKey(const Key('player-bottom-controls')),
      );
      expect(top.bottom, lessThan(150));
      expect(bottom.top, greaterThan(240));
      expect(bottom.height, lessThan(140));
      expect(
        find.byKey(const Key('player-playlist')).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester.getCenter(find.byKey(const Key('player-playlist'))).dy,
        greaterThan(bottom.top),
      );
      await openSetting(tester, '画面');
      expect(find.text('适应画面'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Track headers rotate before autoplay and the cover waits for stable layout',
    (tester) async {
      final fixture = PlaybackFixture(),
          device = FakePlaybackDevice()..supportsOrientation = true;
      fixture.configureBackend = (backend) => backend.emit(
        const PlayerState(
          tracks: Tracks(
            video: [VideoTrack('1', null, null, w: 1920, h: 1080)],
          ),
        ),
      );
      await render(
        tester,
        suppliedFixture: fixture,
        suppliedDevice: device,
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(device.orientation, PlaybackOrientation.landscape);
      expect(fixture.current.state.width, isNull);
      expect(fixture.current.plays, 0);
      expect(find.byKey(const Key('player-layout-cover')), findsOneWidget);
      tester.view.physicalSize = const Size(864, 393);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();
      expect(fixture.current.plays, 1);
      expect(find.byKey(const Key('player-layout-cover')), findsNothing);
      expect(tester.takeException(), isNull);
      fixture.current.emit(
        const PlayerState(
          playing: true,
          videoParams: VideoParams(dw: 1920, dh: 1080, rotate: 90),
        ),
      );
      await tester.pump();
      expect(device.orientation, PlaybackOrientation.portrait);
      expect(find.byKey(const Key('player-layout-cover')), findsOneWidget);
      tester.view.physicalSize = const Size(393, 864);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();
      expect(find.byKey(const Key('player-layout-cover')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'A platform refusing rotation cannot hold playback behind a permanent cover',
    (tester) async {
      final device = FakePlaybackDevice()..supportsOrientation = true;
      final page = await render(tester, suppliedDevice: device, settle: false);
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump();
      expect(page.fixture.current.plays, 1);
      expect(find.byKey(const Key('player-layout-cover')), findsNothing);
      page.fixture.current.emit(
        page.fixture.current.state.copyWith(
          position: const Duration(seconds: 3),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('player-layout-cover')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Closing while Android is rotating cancels pending presentation work',
    (tester) async {
      final device = FakePlaybackDevice()..supportsOrientation = true;
      final page = await render(tester, suppliedDevice: device, settle: false);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(page.fixture.controller.closed, isTrue);
      expect(device.finished, isTrue);
      expect(page.fixture.current.plays, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Single taps only toggle controls; double taps skip or pause', (
    tester,
  ) async {
    final page = await render(tester), backend = page.fixture.current;
    final initialVolumeWrites = backend.volumes.length;
    await tester.tapAt(const Offset(196, 300));
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.byKey(const Key('player-play-pause')).hitTestable(),
      findsNothing,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-play-pause')), findsNothing);
    expect(backend.volumes.length, initialVolumeWrites);
    expect(backend.state.volume, 100);
    await doubleTap(tester, const Offset(320, 300));
    expect(backend.state.position, const Duration(seconds: 135));
    await doubleTap(tester, const Offset(90, 300));
    expect(backend.state.position, const Duration(seconds: 120));
    await doubleTap(tester, const Offset(196, 300));
    expect(backend.state.playing, isFalse);
    expect(find.byKey(const Key('player-play-pause')), findsOneWidget);
    expect(backend.volumes.length, initialVolumeWrites);
  });

  testWidgets(
    'Progress, brightness and volume gestures act on the intended control',
    (tester) async {
      final page = await render(tester), backend = page.fixture.current;
      await tester.dragFrom(const Offset(160, 300), const Offset(110, 0));
      await tester.pumpAndSettle();
      expect(backend.state.position.inSeconds, greaterThan(120));
      expect(backend.state.position.inSeconds, lessThan(160));
      final oldVolume = backend.state.volume;
      await tester.dragFrom(const Offset(90, 400), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(page.device.brightness, greaterThan(.5));
      expect(backend.state.volume, oldVolume);
      await tester.dragFrom(const Offset(310, 350), const Offset(0, 160));
      await tester.pumpAndSettle();
      expect(backend.state.volume, lessThan(oldVolume));
      expect(page.fixture.history.preferences.volume, backend.state.volume);
    },
  );

  testWidgets(
    'Long press restores the chosen speed and locking prevents gesture actions',
    (tester) async {
      final page = await render(tester), backend = page.fixture.current;
      await tap(tester, find.byKey(const Key('player-speed')));
      await tap(tester, find.byKey(const ValueKey('player-rate-1.5')));
      expect(backend.state.rate, 1.5);
      final gesture = await tester.startGesture(const Offset(196, 300));
      await tester.pump(const Duration(milliseconds: 700));
      expect(backend.state.rate, 2);
      await gesture.up();
      await tester.pump();
      expect(backend.state.rate, 1.5);
      await tap(tester, find.byKey(const Key('player-lock')));
      expect(find.byKey(const Key('player-play-pause')), findsNothing);
      final position = backend.state.position;
      await doubleTap(tester, const Offset(320, 300));
      await tester.dragFrom(const Offset(160, 300), const Offset(110, 0));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(backend.state.position, position);
      expect(backend.state.playing, isTrue);
      await tap(tester, find.byKey(const Key('player-unlock')));
      expect(find.byKey(const Key('player-play-pause')), findsOneWidget);
    },
  );

  testWidgets('Custom fractional rate is validated, applied and remembered', (
    tester,
  ) async {
    final page = await render(tester);
    await tap(tester, find.byKey(const Key('player-speed')));
    final input = find.byKey(const Key('player-custom-rate'));
    await expectLater(
      find.byKey(const Key('player-capture')),
      matchesGoldenFile('goldens/player-custom-rate.png'),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.ensureVisible(input);
    await tester.enterText(input, '0');
    await tester.ensureVisible(
      find.byKey(const Key('player-apply-custom-rate')),
    );
    await tap(tester, find.byKey(const Key('player-apply-custom-rate')));
    expect(find.text('请输入 0.25 至 4 之间的倍速'), findsOneWidget);
    expect(page.fixture.current.state.rate, 1);
    await tester.enterText(input, '2.37');
    await tester.ensureVisible(
      find.byKey(const Key('player-apply-custom-rate')),
    );
    await tap(tester, find.byKey(const Key('player-apply-custom-rate')));
    expect(page.fixture.current.state.rate, 2.37);
    expect(page.fixture.history.preferences.rate, 2.37);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const Key('player-speed')));
    expect(tester.widget<TextField>(input).controller!.text, '2.37');
    await tap(tester, find.byTooltip('关闭面板'));
  });

  testWidgets('Locked screen tap briefly reveals the icon without a text HUD', (
    tester,
  ) async {
    final page = await render(tester);
    await tap(tester, find.byKey(const Key('player-lock')));
    await tester.pump(const Duration(milliseconds: 2200));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-unlock')).hitTestable(), findsNothing);
    await tester.tapAt(const Offset(196, 300));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('player-unlock')).hitTestable(),
      findsOneWidget,
    );
    expect(find.textContaining('解锁'), findsNothing);
    expect(find.textContaining('解除屏幕锁定'), findsNothing);
    expect(page.fixture.current.state.playing, isTrue);
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.tapAt(const Offset(196, 300));
    await tester.pump(const Duration(milliseconds: 900));
    expect(
      find.byKey(const Key('player-unlock')).hitTestable(),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-unlock')).hitTestable(), findsNothing);
  });

  testWidgets('Holding boost keeps the speed without persistent text', (
    tester,
  ) async {
    final page = await render(tester);
    final gesture = await tester.startGesture(const Offset(196, 300));
    await tester.pump(const Duration(milliseconds: 700));
    expect(page.fixture.current.state.rate, 2);
    expect(find.textContaining('倍速播放中'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(page.fixture.current.state.rate, 2);
    expect(find.textContaining('倍速播放中'), findsNothing);
    expect(find.textContaining('松手恢复'), findsNothing);
    await gesture.up();
    await tester.pump();
    expect(page.fixture.current.state.rate, 1);
  });

  testWidgets(
    'A missing subtitle font can be retried without interrupting playback',
    (tester) async {
      final page = await render(tester);
      page.fixture.current.subtitleFontMessage = '中文字幕字体未就绪，请在字幕设置中重试';
      page.fixture.current.emit(page.fixture.current.state);
      await tester.pump();
      expect(page.fixture.controller.ready, isTrue);
      expect(page.fixture.current.state.playing, isTrue);
      await openSetting(tester, '字幕');
      await tester.ensureVisible(find.text('点此重试下载中文字幕字体'));
      await tap(tester, find.text('点此重试下载中文字幕字体'));
      expect(page.fixture.current.subtitleFontRetries, 1);
      expect(page.fixture.current.subtitleFontMessage, isEmpty);
      expect(page.fixture.controller.error, isEmpty);
      expect(page.fixture.current.state.playing, isTrue);
    },
  );

  testWidgets('Track, caption and episode panels use the selected ids', (
    tester,
  ) async {
    final page = await render(tester);
    await openSetting(tester, '音轨');
    await tap(tester, find.text('English · 英语'));
    expect(page.fixture.current.state.track.audio.id, '2');
    await tap(tester, find.text('延后 0.5 秒'));
    expect(page.fixture.current.audioDelay, .5);
    await tap(tester, find.byTooltip('关闭面板'));
    await openSetting(tester, '字幕');
    await tap(tester, find.text('关闭字幕'));
    expect(page.fixture.current.state.track.subtitle.id, 'no');
    await tap(tester, find.text('简体中文 · 中文'));
    expect(page.fixture.current.state.track.subtitle.id, '1');
    await tap(tester, find.byTooltip('关闭面板'));
    await openSetting(tester, '选集');
    await tap(tester, find.byKey(const Key('episode-2')));
    expect(page.fixture.controller.index, 2);
    expect(page.fixture.backends.first.closed, isTrue);
    expect(page.fixture.leases.values.where((n) => n == 0).length, 1);
  });

  testWidgets(
    'Subtitle import reads a private copy and exit preserves the original',
    (tester) async {
      final original = File('test/fixtures/player-external.srt').absolute;
      final page = await render(
        tester,
        chooseSubtitle: () async => XFile(original.path),
      );
      // File I/O uses the real clock; the serialized subtitle commands and
      // widget frames also need the test clock to drain their microtasks.
      Future<void> drainFileWork(bool Function() complete) async {
        for (var attempt = 0; attempt < 100 && !complete(); attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(complete(), isTrue);
      }

      await openSetting(tester, '字幕');
      await tester.tap(find.text('加载字幕文件'));
      await drainFileWork(() => page.fixture.current.state.track.subtitle.uri);
      await tester.pumpAndSettle();
      final staged = File.fromUri(
        Uri.parse(page.fixture.current.state.track.subtitle.id),
      );
      expect(staged.parent.path, page.directory.path);
      await tester.runAsync(() async {
        expect(await staged.readAsBytes(), await original.readAsBytes());
      });
      await tap(tester, find.byTooltip('返回'));
      var closed = false;
      unawaited(page.fixture.controller.close().then((_) => closed = true));
      await drainFileWork(() => closed);
      await tester.pumpAndSettle();
      expect(find.text('播放器已关闭'), findsOneWidget);
      expect(page.device.finished, isTrue);
      expect(await tester.runAsync(staged.exists), isFalse);
      expect(await tester.runAsync(original.exists), isTrue);
    },
  );

  testWidgets(
    'PiP hides Flutter controls, forwards actions and pauses when hidden',
    (tester) async {
      final page = await render(tester), backend = page.fixture.current;
      await tap(tester, find.byTooltip('画中画'));
      expect(find.byKey(const Key('player-gesture-surface')), findsNothing);
      expect(find.byKey(const Key('player-play-pause')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(backend.state.playing, isTrue);
      page.device.events.add('forward');
      await tester.pump();
      expect(backend.state.position, const Duration(seconds: 135));
      page.device.events.add('toggle');
      await tester.pump();
      expect(backend.state.playing, isFalse);
      page.device.events.add('toggle');
      await tester.pump();
      expect(backend.state.playing, isTrue);
      page.device.events.add('hidden');
      await tester.pump();
      expect(backend.state.playing, isFalse);
      page.device.leavePip();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-play-pause')), findsOneWidget);
    },
  );

  testWidgets(
    'Escape restores fullscreen before leaving and closes the native session',
    (tester) async {
      final page = await render(tester);
      await tap(tester, find.byKey(const Key('player-fullscreen')));
      expect(page.device.full, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(page.device.full, isFalse);
      expect(find.byType(PlayerPage), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.runAsync(page.fixture.controller.close);
      expect(find.text('播放器已关闭'), findsOneWidget);
      expect(
        page.device.calls,
        containsAllInOrder(['fullscreen:true', 'fullscreen:false']),
      );
      expect(page.device.finished, isTrue);
      expect(page.fixture.leases.values, everyElement(0));
    },
  );

  testWidgets(
    'Narrow large-text panels and short landscape errors remain usable',
    (tester) async {
      final page = await render(tester, size: const Size(320, 640), scale: 1.8);
      for (final panel in ['音轨', '字幕', '选集', '画面']) {
        await openSetting(tester, panel);
        final scrolling = find
            .descendant(
              of: find.byKey(const Key('player-panel')),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.drag(scrolling, const Offset(0, -450));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tap(tester, find.byTooltip('关闭面板'));
      }
      await tap(tester, find.byTooltip('播放设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tap(tester, find.byTooltip('关闭面板'));
      tester.view.physicalSize = const Size(640, 320);
      page.fixture.current.fail();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('刷新重试'));
      expect(find.text('刷新重试').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tap(tester, find.text('刷新重试'));
      expect(page.fixture.preparations, 2);
      expect(page.fixture.controller.error, isEmpty);
    },
  );
}
