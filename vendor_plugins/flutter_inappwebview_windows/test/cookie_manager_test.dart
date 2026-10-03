import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends PlatformInAppWebViewController {
  _Controller(this.response)
      : super.implementation(
            const PlatformInAppWebViewControllerCreationParams(id: 41));
  dynamic response;
  bool closed = false;
  final calls = <Map<String, dynamic>>[];

  @override
  Future<dynamic> callDevToolsProtocolMethod(
      {required String methodName, Map<String, dynamic>? parameters}) async {
    calls.add({'method': methodName, 'parameters': parameters});
    if (closed) throw PlatformException(code: 'WEBVIEW_CLOSED');
    return response;
  }
}

Map<String, dynamic> _cookie(String value, {bool session = true}) => {
      'name': 'login_session',
      'value': value,
      'domain': '.cloud.example.test',
      'path': '/disk',
      'expires': session ? -1 : 1790320441.125,
      'httpOnly': true,
      'secure': true,
      'session': session,
      'sameSite': 'Lax',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_cookiemanager');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final ordinaryCalls = <MethodCall>[];
  late WindowsCookieManager manager;
  final url = WebUri('https://cloud.example.test/disk');

  setUp(() {
    manager = WindowsCookieManager(const WindowsCookieManagerCreationParams());
    messenger.setMockMethodCallHandler(channel, (call) async {
      ordinaryCalls.add(call);
      return [
        {'name': 'login_session', 'value': 'ordinary-profile'}
      ];
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    ordinaryCalls.clear();
  });

  test('InPrivate reads use the supplied view and preserve HttpOnly cookies',
      () async {
    final web = _Controller({
      'cookies': [_cookie('private-profile')]
    });
    final cookies = await manager.getCookies(url: url, webViewController: web);
    expect(cookies.single.value, 'private-profile');
    expect(cookies.single.domain, '.cloud.example.test');
    expect(cookies.single.path, '/disk');
    expect(cookies.single.isHttpOnly, isTrue);
    expect(cookies.single.isSecure, isTrue);
    expect(cookies.single.isSessionOnly, isTrue);
    expect(cookies.single.expiresDate, isNull);
    expect(cookies.single.sameSite, HTTPCookieSameSitePolicy.LAX);
    expect(web.calls.single, {
      'method': 'Network.getCookies',
      'parameters': {
        'urls': [url.toString()]
      }
    });
    expect(ordinaryCalls, isEmpty);
  });

  test('An empty login window cannot reuse ordinary-profile credentials',
      () async {
    final web = _Controller({'cookies': []});
    expect(await manager.getCookies(url: url, webViewController: web), isEmpty);
    expect(ordinaryCalls, isEmpty);
  });

  test('Closed views report failure without reading another profile', () async {
    final web = _Controller({'cookies': []})..closed = true;
    await expectLater(manager.getCookies(url: url, webViewController: web),
        throwsA(isA<PlatformException>()));
    expect(ordinaryCalls, isEmpty);
  });

  test('Malformed browser responses are failures, not empty successful reads',
      () async {
    for (final response in [
      null,
      <String, dynamic>{},
      {'cookies': 'invalid'},
      {
        'cookies': [42]
      },
      {
        'cookies': [
          {'name': 'login_session'}
        ]
      },
    ]) {
      await expectLater(
          manager.getCookies(
              url: url, webViewController: _Controller(response)),
          throwsFormatException);
    }
    expect(ordinaryCalls, isEmpty);
  });

  test('Persistent cookie expiry uses milliseconds, including fractions',
      () async {
    final web = _Controller({
      'cookies': [_cookie('persistent-profile', session: false)]
    });
    final cookies = await manager.getCookies(url: url, webViewController: web);
    expect(cookies.single.expiresDate, 1790320441125);
    expect(cookies.single.isSessionOnly, isFalse);
  });

  test('Named cookie reads also use the supplied view', () async {
    final web = _Controller({
      'cookies': [_cookie('private-profile')]
    });
    final cookie = await manager.getCookie(
        url: url, name: 'login_session', webViewController: web);
    expect(cookie!.value, 'private-profile');
    expect(
        await manager.getCookie(
            url: url, name: 'missing', webViewController: web),
        isNull);
    expect(ordinaryCalls, isEmpty);
  });

  test('Main and authorization windows are read through their own controller',
      () async {
    for (final value in ['main-window', 'authorization-window']) {
      final web = _Controller({
        'cookies': [_cookie(value)]
      });
      final result = await manager.getCookies(url: url, webViewController: web);
      expect(result.single.value, value);
      expect(web.calls, hasLength(1));
    }
    expect(ordinaryCalls, isEmpty);
  });

  test('Calls without a controller retain the environment cookie API',
      () async {
    expect(
        (await manager.getCookies(url: url)).single.value, 'ordinary-profile');
    expect((await manager.getCookie(url: url, name: 'login_session'))!.value,
        'ordinary-profile');
    expect(ordinaryCalls, hasLength(2));
    expect(ordinaryCalls.every((call) => call.method == 'getCookies'), isTrue);
    expect(ordinaryCalls.first.arguments,
        {'url': url.toString(), 'webViewEnvironmentId': null});
  });
}
