import 'package:asterlink/platform/usage_metrics.dart';
import 'package:asterlink/ui/analytics_privacy_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const analytics = UsageMetrics(platform: TargetPlatform.android);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  bool? consent;
  bool initialized = false;
  bool restartRequired = false;
  bool failStatus = false;
  bool failSave = false;

  setUp(() {
    consent = null;
    initialized = false;
    restartRequired = false;
    failStatus = false;
    failSave = false;
    calls.clear();
    messenger.setMockMethodCallHandler(UsageMetrics.channel, (call) async {
      calls.add(call);
      if (call.method == 'status' && failStatus) {
        throw PlatformException(code: 'unavailable');
      }
      if (call.method == 'setConsent') {
        if (failSave) throw PlatformException(code: 'storage');
        consent = (call.arguments as Map)['granted'] as bool;
        initialized = consent == true && !restartRequired;
      }
      return {
        'consent': consent,
        'initialized': initialized,
        'restartRequired': restartRequired,
      };
    });
  });

  tearDown(
    () => messenger.setMockMethodCallHandler(UsageMetrics.channel, null),
  );

  Future<void> showGate(WidgetTester tester, {bool enabled = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AnalyticsConsentGate(
          enabled: enabled,
          analytics: analytics,
          child: const Scaffold(body: Text('应用内容')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('non-Android platforms do not invoke the native SDK bridge', () async {
    for (final platform in [TargetPlatform.windows, TargetPlatform.iOS]) {
      final client = UsageMetrics(platform: platform);
      expect((await client.status()).consent, isFalse);
      expect((await client.setConsent(true)).initialized, isFalse);
    }
    expect(calls, isEmpty);
  });

  testWidgets('first launch waits for an explicit choice', (tester) async {
    await showGate(tester);
    expect(find.text('使用统计与隐私'), findsOneWidget);
    expect(calls.map((call) => call.method), ['status']);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('使用统计与隐私'), findsOneWidget);
    expect(calls.map((call) => call.method), ['status']);
  });

  testWidgets('reading the disclosure does not grant consent', (tester) async {
    await showGate(tester);
    await tester.tap(find.text('查看统计与隐私说明'));
    await tester.pumpAndSettle();
    expect(find.text('隐私与使用统计'), findsOneWidget);
    expect(find.text('同意以上说明并开启统计'), findsNothing);
    expect(calls.map((call) => call.method), ['status']);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('使用统计与隐私'), findsOneWidget);
  });

  testWidgets('refusing leaves the app usable and is remembered', (
    tester,
  ) async {
    await showGate(tester);
    await tester.tap(find.text('不同意并继续'));
    await tester.pumpAndSettle();
    expect(consent, isFalse);
    expect(initialized, isFalse);
    expect(find.text('使用统计与隐私'), findsNothing);
    expect(find.text('应用内容'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await showGate(tester);
    expect(find.text('使用统计与隐私'), findsNothing);
    expect(calls.where((call) => call.method == 'setConsent'), hasLength(1));
  });

  testWidgets('accepting forwards only the explicit consent choice', (
    tester,
  ) async {
    await showGate(tester);
    await tester.tap(find.text('同意并开启'));
    await tester.pumpAndSettle();
    expect(consent, isTrue);
    expect(initialized, isTrue);
    expect(calls.last.arguments, {'granted': true});
    expect(find.text('使用统计与隐私'), findsNothing);
  });

  testWidgets('saved consent does not trigger another initialization request', (
    tester,
  ) async {
    consent = true;
    initialized = true;
    await showGate(tester);
    expect(calls.map((call) => call.method), ['status']);
    expect(find.text('使用统计与隐私'), findsNothing);
  });

  testWidgets('disabled platform features do not contact analytics', (
    tester,
  ) async {
    await showGate(tester, enabled: false);
    expect(calls, isEmpty);
    expect(find.text('应用内容'), findsOneWidget);
  });

  testWidgets('status failure never enables statistics or blocks the app', (
    tester,
  ) async {
    failStatus = true;
    await showGate(tester);
    expect(calls.map((call) => call.method), ['status']);
    expect(find.text('应用内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed consent persistence does not report analytics as enabled',
    (tester) async {
      failSave = true;
      await showGate(tester);
      await tester.tap(find.text('同意并开启'));
      await tester.pumpAndSettle();
      expect(consent, isNull);
      expect(initialized, isFalse);
      expect(find.text('无法读取或保存统计设置，可在“我的 → 隐私与使用统计”中重试'), findsOneWidget);
    },
  );

  testWidgets('privacy settings allow withdrawal and explain pending restart', (
    tester,
  ) async {
    consent = true;
    initialized = true;
    await tester.pumpWidget(
      const MaterialApp(home: AnalyticsPrivacyPage(analytics: analytics)),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('关闭使用统计'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    restartRequired = true;
    await tester.tap(find.text('关闭使用统计'));
    await tester.pumpAndSettle();
    expect(calls.last.arguments, {'granted': false});
    expect(find.textContaining('重启应用后完全停用统计组件'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('同意以上说明并开启统计'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('同意以上说明并开启统计'));
    await tester.pumpAndSettle();
    expect(find.text('选择已保存，下次启动应用时开启统计。'), findsOneWidget);
    expect(initialized, isFalse);
  });

  testWidgets('privacy settings show persistence errors and permit a retry', (
    tester,
  ) async {
    consent = false;
    failSave = true;
    await tester.pumpWidget(
      const MaterialApp(home: AnalyticsPrivacyPage(analytics: analytics)),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('同意以上说明并开启统计'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('同意以上说明并开启统计'));
    await tester.pumpAndSettle();
    expect(find.text('统计设置保存失败，请重试'), findsOneWidget);
    expect(consent, isFalse);
    failSave = false;
    await tester.tap(find.text('同意以上说明并开启统计'));
    await tester.pumpAndSettle();
    expect(consent, isTrue);
    expect(find.text('使用统计已开启。'), findsOneWidget);
  });
}
