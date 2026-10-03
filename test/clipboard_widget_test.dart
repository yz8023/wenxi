import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/clipboard_link_banner.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppServices services;
  late FakeHttp http;
  String? clipboard;
  int reads = 0;

  setUp(() {
    clipboard = null;
    reads = 0;
  });

  void scenario(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        services.close().then((_) => closed = true);
        for (var i = 0; i < 30 && !closed; i++) {
          await tester.pump();
        }
        expect(closed, isTrue);
        services.store.dispose();
      }
    });
  }

  Future<void> render(
    WidgetTester tester, {
    int tab = 0,
    bool dark = false,
  }) async {
    http = FakeHttp();
    services = AppServices(
      controlEnabled: false,
      store: StateStore.memory({
        'settings': {'theme': dark ? 'Dark' : 'Light'},
      }),
      dataDirectory: Directory('test-fixture'),
      cacheDirectory: Directory('test-fixture/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('test-fixture/saved')),
      http: http,
      platformFeatures: false,
      clipboardReader: () async {
        reads++;
        return clipboard;
      },
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(AsterLinkApp(services, initialTab: tab));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  scenario(
    'startup discovers links without overwriting a draft or fetching the cloud',
    (tester) async {
      await render(tester);
      final parse = tester.state<ParsePageState>(find.byType(ParsePage));
      parse.input.text = 'unfinished draft';
      clipboard = 'https://drive.uc.cn/s/abc123 提取码：a123';
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byType(ClipboardLinkBanner), findsOneWidget);
      expect(parse.input.text, 'unfinished draft');
      expect(http.calls, isEmpty);
      await tester.tap(find.text('填入解析'));
      await tester.pumpAndSettle();
      expect(parse.current!.passcode, 'a123');
      expect(parse.input.text, contains('https://drive.uc.cn/s/abc123'));
      expect(find.byType(ClipboardLinkBanner), findsNothing);
      expect(http.calls, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  scenario(
    'Mobile phone share and 123 domain alias reach the parser unchanged from a clipboard banner',
    (tester) async {
      clipboard =
          'https://caiyun.139.com/m/i?Mobile123&pass=m123\n\n'
          'https://www.123684.com/s/Pan_123 提取码：p123';
      await render(tester, tab: 2);
      expect(find.byType(ClipboardLinkBanner), findsOneWidget);
      await tester.tap(find.text('填入解析'));
      await tester.pumpAndSettle();
      final parse = tester.state<ParsePageState>(find.byType(ParsePage));
      expect(parse.links.map((link) => link.shareId), ['Mobile123', 'Pan_123']);
      expect(parse.links.map((link) => link.passcode), ['m123', 'p123']);
      expect(parse.current!.shareId, 'Mobile123');
      expect(http.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'incoming clipboard links work from another tab and ignored links stay quiet',
    (tester) async {
      clipboard = 'https://pan.quark.cn/s/abc123';
      await render(tester, tab: 2);
      await tester.tap(find.byTooltip('忽略此链接'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byType(ClipboardLinkBanner), findsNothing);
      clipboard = 'https://drive.uc.cn/s/newlink';
      services.clipboard.setForeground(true);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('填入解析'));
      await tester.pumpAndSettle();
      expect(find.byType(ParsePage), findsOneWidget);
      expect(
        tester.state<ParsePageState>(find.byType(ParsePage)).current!.shareId,
        'newlink',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  scenario('recognition switch stops clipboard access and is persisted', (
    tester,
  ) async {
    await render(tester, tab: 3);
    await tester.scrollUntilVisible(find.text('自动识别剪贴板链接'), 150);
    await tester.tap(find.text('自动识别剪贴板链接'));
    await tester.pumpAndSettle();
    expect(services.settings.clipboardRecognition, isFalse);
    final previous = reads;
    clipboard = 'https://drive.uc.cn/s/abc123';
    services.clipboard.setForeground(false);
    services.clipboard.setForeground(true);
    await tester.pump(const Duration(milliseconds: 500));
    expect(reads, previous);
    expect(find.byType(ClipboardLinkBanner), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  scenario('banner fits a narrow dark window with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    clipboard = 'https://drive.uc.cn/s/abc123\nhttps://pan.quark.cn/s/abc456';
    await render(tester, dark: true);
    expect(find.byType(ClipboardLinkBanner), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('忽略此链接'));
    await tester.pumpWidget(const SizedBox());
  });
}
