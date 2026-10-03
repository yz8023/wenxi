import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/github_update_service.dart';
import 'package:asterlink/data/remote_control_http.dart';
import 'package:asterlink/data/remote_control_service.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/ui/remote_control_dialogs.dart';
import 'github_update_support.dart';
import 'remote_control_support.dart';

void main() {
  late FakeControlFetcher primary, github;
  late StateStore store;
  late RemoteControlService control;
  late List<Uri> opened;

  void initialize() {
    primary = FakeControlFetcher()
      ..respond = (_) => throw TimeoutException('Primary unavailable');
    github = FakeControlFetcher(githubRelease());
    store = StateStore.memory();
    opened = [];
    control = RemoteControlService(
      store,
      enabled: true,
      platform: 'android',
      currentBuild: 53,
      currentVersion: '0.5.0+53',
      configUrl: controlEndpoint,
      fetcher: primary,
      clock: () => controlNow,
      githubUpdates: GitHubUpdateService(
        repository: githubRepository,

        platform: 'android',
        architecture: 'arm64',
        fetcher: github,
        clock: () => controlNow,
      ),
    );
  }

  void scenario(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      initialize();
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        control.close();
        await control.flushCache();
        await tester.pump();
        store.dispose();
      }
    });
  }

  Future<bool> launch(Uri url) async {
    opened.add(url);
    return true;
  }

  Future<void> render(
    WidgetTester tester, {
    bool automaticPrompts = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                if (automaticPrompts)
                  RemoteControlPrompts(control, launcher: launch),
                TextButton(
                  key: const ValueKey('check-update'),
                  onPressed: () =>
                      checkForAppUpdate(context, control, launcher: launch),
                  child: const Text('检查更新'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> check(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.pumpAndSettle();
  }

  final dialog = find.byKey(const ValueKey('control-update-dialog'));
  final download = find.byKey(const ValueKey('control-download-update'));

  scenario(
    'Manual check waits for primary failure and opens the compatible GitHub asset',
    (tester) async {
      final pending = Completer<String>();
      primary.respond = (_) => pending.future;
      await render(tester);
      await check(tester);
      expect(primary.calls, hasLength(1));
      expect(github.calls, isEmpty);
      expect(dialog, findsNothing);

      pending.completeError(TimeoutException('Primary unavailable'));
      await tester.pumpAndSettle();
      expect(github.calls, hasLength(1));
      expect(dialog, findsOneWidget);
      expect(find.text('发现新版本 0.6.0'), findsOneWidget);
      expect(find.text('更新说明\n修复已知问题'), findsOneWidget);

      await tester.tap(download);
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(opened, hasLength(1));
      expect(opened.single.host, 'github.com');
      expect(opened.single.pathSegments, [
        'z7786',
        'wenxi',
        'releases',
        'download',
        'v0.6.0+54',
        'asterlink-0.6.0+54-android-arm64.apk',
      ]);
      expect(control.unreadUpdate, isNull);
    },
  );

  scenario('Foreground failure automatically prompts once and respects Later', (
    tester,
  ) async {
    await render(tester, automaticPrompts: true);
    expect(primary.calls, isEmpty);
    expect(github.calls, isEmpty);
    control.setForeground(true);
    await tester.pumpAndSettle();
    expect(dialog, findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('control-update-later')));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    control.setForeground(false);
    control.setForeground(true);
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(github.calls, hasLength(1));
  });

  scenario('Primary recovery removes an already visible GitHub prompt', (
    tester,
  ) async {
    await render(tester, automaticPrompts: true);
    control.setForeground(true);
    await tester.pumpAndSettle();
    expect(dialog, findsOneWidget);

    primary
      ..respond = null
      ..text = '{"updates":{"android":{"enabled":false}}}';
    await control.refresh(force: true);
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(control.usingGithubUpdates, isFalse);
    expect(github.calls, hasLength(1));
    expect(opened, isEmpty);
  });

  scenario('Two failed sources report failure instead of the latest version', (
    tester,
  ) async {
    github.respond = (_) =>
        throw const ControlAccessException('Rate limited', statusCode: 403);
    await render(tester);
    await check(tester);
    expect(control.errorForSection('updates.android'), isNotNull);
    expect(
      find.text(control.errorForSection('updates.android')!),
      findsOneWidget,
    );
    expect(find.text('当前已是最新版本'), findsNothing);
    expect(find.text('暂时没有可用的更新'), findsNothing);
    expect(dialog, findsNothing);
    expect(opened, isEmpty);
  });

  scenario('A matching current release reports the app is up to date', (
    tester,
  ) async {
    github.text = jsonEncode(
      githubRelease(
        tag: 'v0.5.0+53',
        files: ['asterlink-0.5.0+53-android-arm64.apk'],
      ),
    );
    await render(tester);
    await check(tester);
    expect(find.text('当前已是最新版本'), findsOneWidget);
    expect(dialog, findsNothing);
  });

  scenario('A release without an Android asset reports no available update', (
    tester,
  ) async {
    github.text = jsonEncode(
      githubRelease(files: ['asterlink-0.6.0+54-windows-x64-setup.exe']),
    );
    await render(tester);
    await check(tester);
    expect(find.text('暂时没有可用的更新'), findsOneWidget);
    expect(find.text('当前已是最新版本'), findsNothing);
    expect(dialog, findsNothing);
  });

  scenario(
    'Ignoring an unnumbered release still allows the following release',
    (tester) async {
      github.text = jsonEncode(
        githubRelease(tag: 'v0.6.0', files: ['asterlink-android-arm64.apk']),
      );
      await render(tester, automaticPrompts: true);
      control.setForeground(true);
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('control-ignore-update')));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);

      github.text = jsonEncode(
        githubRelease(tag: 'v0.7.0', files: ['asterlink-android-arm64.apk']),
      );
      await control.refresh(force: true);
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 0.7.0'), findsOneWidget);
      expect(dialog, findsOneWidget);
    },
  );

  scenario('A changed release rejects the old download button callback', (
    tester,
  ) async {
    github.text = jsonEncode(
      githubRelease(tag: 'v0.6.0', files: ['asterlink-android-arm64.apk']),
    );
    await render(tester);
    await check(tester);
    final oldDownload = tester.widget<FilledButton>(download).onPressed!;
    github.text = jsonEncode(
      githubRelease(tag: 'v0.7.0', files: ['asterlink-android-arm64.apk']),
    );
    await control.refresh(force: true);
    await tester.pumpAndSettle();
    oldDownload();
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(dialog, findsOneWidget);
    expect(find.text('发现新版本 0.7.0'), findsOneWidget);

    await tester.tap(download);
    await tester.pumpAndSettle();
    expect(opened.single.pathSegments[4], 'v0.7.0');
    expect(dialog, findsNothing);
  });
}
