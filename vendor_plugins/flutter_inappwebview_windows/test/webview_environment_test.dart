import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const manager =
      MethodChannel('com.pichillilorenzo/flutter_webview_environment');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channels = <MethodChannel>[];
  final disposed = <String>[];

  setUp(() {
    // The native manager registers an instance channel for the ID supplied
    // during create. A factory/static ID has no native environment behind it.
    messenger.setMockMethodCallHandler(manager, (call) async {
      expect(call.method, 'create');
      final id = (call.arguments as Map)['id'] as String;
      final channel =
          MethodChannel('com.pichillilorenzo/flutter_webview_environment_$id');
      channels.add(channel);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'dispose');
        disposed.add(id);
        return null;
      });
      return true;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(manager, null);
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    channels.clear();
    disposed.clear();
  });

  test('created environment can release its native resources', () async {
    final environment = await WindowsWebViewEnvironment.static().create();

    await environment.dispose();

    expect(disposed, [environment.id]);
  });

  test('multiple environments release their own resources independently',
      () async {
    final factory = WindowsWebViewEnvironment.static();
    final first = await factory.create();
    final second = await factory.create();

    await second.dispose();
    await first.dispose();

    expect(first.id, isNot(second.id));
    expect(disposed, [second.id, first.id]);
  });
}
