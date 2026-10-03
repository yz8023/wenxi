import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/remote_control_service.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/ui/remote_control_dialogs.dart';
import 'remote_control_support.dart';

void main() {
  RemoteControlService create(
    FakeControlFetcher fetcher, {
    DateTime Function()? clock,
  }) => RemoteControlService(
    StateStore.memory(),
    enabled: true,
    platform: 'android',
    currentBuild: 44,
    configUrl: controlEndpoint,
    fetcher: fetcher,
    clock: clock ?? () => controlNow,
  );

  Future<void> updateHome(WidgetTester tester, RemoteControlService control) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => checkForAppUpdate(context, control),
                child: const Text('检查更新'),
              ),
            ),
          ),
        ),
      );

  testWidgets(
    'A broken Windows block does not suppress a verified Android update',
    (tester) async {
      final json = controlJson(androidBuild: 50);
      json['updates']['windows'] = {'enabled': true, 'build': 'bad'};
      final control = create(FakeControlFetcher(json));
      try {
        await updateHome(tester, control);
        await tester.tap(find.text('检查更新'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('control-update-dialog')),
          findsOneWidget,
        );
        expect(find.textContaining('格式有误'), findsNothing);
        expect(find.text('当前已是最新版本'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        control.close();
      }
    },
  );

  testWidgets(
    'A broken Android block cannot be mistaken for the latest installed version',
    (tester) async {
      final json = controlJson(androidBuild: 44, windowsBuild: 50);
      json['updates']['android']['downloadUrl'] = 'http://invalid';
      final control = create(FakeControlFetcher(json));
      try {
        await updateHome(tester, control);
        await tester.tap(find.text('检查更新'));
        await tester.pumpAndSettle();
        expect(find.textContaining('这项在线信息格式有误'), findsOneWidget);
        expect(find.text('当前已是最新版本'), findsNothing);
        expect(
          find.byKey(const ValueKey('control-update-dialog')),
          findsNothing,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        control.close();
      }
    },
  );

  testWidgets(
    'Foreground expiry turns a forced update into a dismissible ordinary update without fetching again',
    (tester) async {
      var now = controlNow;
      final json = controlJson(androidBuild: 50, force: true);
      json['updates']['android']['expiresAt'] = now
          .add(const Duration(minutes: 1))
          .toUtc()
          .toIso8601String();
      final fetcher = FakeControlFetcher(json);
      final control = create(fetcher, clock: () => now);
      try {
        control.setForeground(true);
        await tester.pump();
        await updateHome(tester, control);
        await tester.tap(find.text('检查更新'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('control-update-later')),
          findsNothing,
        );
        final calls = fetcher.calls.length;
        now = now.add(const Duration(minutes: 1));
        await tester.pump(const Duration(minutes: 1));
        await tester.pumpAndSettle();
        expect(control.requiredUpdate, isNull);
        expect(
          find.byKey(const ValueKey('control-update-later')),
          findsOneWidget,
        );
        expect(fetcher.calls.length, calls);
        await tester.tap(find.byKey(const ValueKey('control-update-later')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('control-update-dialog')),
          findsNothing,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        control.close();
      }
    },
  );

  testWidgets(
    'Healthy announcements do not display an unrelated update validation error',
    (tester) async {
      final json = controlJson(noticeId: 'a');
      json['updates']['windows'] = {'enabled': true};
      final control = create(FakeControlFetcher(json));
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => openLatestAnnouncement(context, control),
                  child: const Text('软件公告'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('软件公告'));
        await tester.pumpAndSettle();
        expect(find.text('维护公告'), findsOneWidget);
        expect(find.textContaining('格式有误'), findsNothing);
        expect(find.text('当前显示上次成功获取的公告。'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        control.close();
      }
    },
  );
}
