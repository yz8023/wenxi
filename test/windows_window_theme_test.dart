import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/platform/windows_window_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.asterlink.app/window_theme');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<bool> themes;

  setUp(() {
    themes = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'setTheme');
      themes.add((call.arguments as Map)['dark'] as bool);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Widget app(ValueNotifier<ThemeMode> mode, {bool enabled = true}) =>
      ValueListenableBuilder<ThemeMode>(
        valueListenable: mode,
        builder: (context, value, _) => MaterialApp(
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          themeMode: value,
          builder: (context, child) =>
              WindowsWindowTheme(enabled: enabled, child: child!),
          home: const Scaffold(body: Text('window content')),
        ),
      );

  testWidgets('Native caption follows explicit app theme changes', (
    tester,
  ) async {
    final mode = ValueNotifier(ThemeMode.light);
    addTearDown(mode.dispose);
    await tester.pumpWidget(app(mode));
    await tester.pumpAndSettle();
    expect(themes, [false]);

    await tester.pumpWidget(app(mode));
    await tester.pumpAndSettle();
    expect(themes, [false]);

    mode.value = ThemeMode.dark;
    await tester.pumpAndSettle();
    mode.value = ThemeMode.light;
    await tester.pumpAndSettle();
    expect(themes, [false, true, false]);
  }, skip: !Platform.isWindows);

  testWidgets(
    'System appearance cannot override an explicit light app theme',
    (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final mode = ValueNotifier(ThemeMode.light);
      addTearDown(mode.dispose);
      await tester.pumpWidget(app(mode));
      await tester.pumpAndSettle();

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(themes, [false]);

      mode.value = ThemeMode.system;
      await tester.pumpAndSettle();
      expect(themes, [false, true]);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(themes, [false, true, false]);
    },
    skip: !Platform.isWindows,
  );

  testWidgets('Disabled platform integration makes no native theme calls', (
    tester,
  ) async {
    final mode = ValueNotifier(ThemeMode.dark);
    addTearDown(mode.dispose);
    await tester.pumpWidget(app(mode, enabled: false));
    await tester.pumpAndSettle();
    expect(themes, isEmpty);
    expect(find.text('window content'), findsOneWidget);
  });

  testWidgets(
    'A native theme error leaves the app usable for the next change',
    (tester) async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'synthetic-error');
      });
      final mode = ValueNotifier(ThemeMode.light);
      addTearDown(mode.dispose);
      await tester.pumpWidget(app(mode));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('window content'), findsOneWidget);

      messenger.setMockMethodCallHandler(channel, (call) async {
        themes.add((call.arguments as Map)['dark'] as bool);
        return null;
      });
      mode.value = ThemeMode.dark;
      await tester.pumpAndSettle();
      expect(themes, [true]);
    },
    skip: !Platform.isWindows,
  );
}
