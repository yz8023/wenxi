// Build with: flutter build windows --release --target tool/windows_web_login_smoke.dart
// Run the resulting EXE hidden, passing an isolated output directory as its only
// argument. Rebuild lib/main.dart before packaging the production application.
import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Cookie;
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:asterlink/ui/login_webview.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows || arguments.length != 1) exit(64);
  final output = Directory(arguments.single).absolute;
  await output.create(recursive: true);
  final report = File('${output.path}/webview-smoke.json');
  final checks = <String>[];
  final result = <String, Object?>{
    'passed': false,
    'checks': checks,
    'usesRealWebView2': true,
    'usesRealAccounts': false,
  };
  void save() => report.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(result)}\n',
    flush: true,
  );
  void check(String name, bool condition) {
    if (!condition) throw StateError(name);
    checks.add(name);
    save();
  }

  final watchdog = Timer(const Duration(seconds: 60), () {
    result['failure'] = 'Smoke test timed out';
    save();
    exit(2);
  });
  final views = <HeadlessInAppWebView>[];
  HttpServer? server;
  WebViewEnvironment? environment;
  try {
    final runtime = await WebViewEnvironment.getAvailableVersion();
    result['webView2Version'] = runtime;
    check('WebView2 runtime is installed', runtime?.isNotEmpty == true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      response.headers.contentType = ContentType.html;
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (request.uri.path == '/login') {
        response.headers.add(
          HttpHeaders.setCookieHeader,
          'login_session=fixture-private-session; Path=/; HttpOnly; SameSite=Lax',
        );
        for (final pair in {
          'UID': '12345_A1_fixture',
          'CID': 'fixture-cid',
          'SEID': 'fixture-seid',
        }.entries) {
          response.headers.add(
            HttpHeaders.setCookieHeader,
            '${pair.key}=${pair.value}; Path=/; HttpOnly; SameSite=Lax',
          );
        }
      } else if (request.uri.path == '/authorize') {
        response.headers.add(
          HttpHeaders.setCookieHeader,
          'authorization_result=fixture-popup-result; Path=/; HttpOnly; SameSite=Lax',
        );
      }
      response.write(
        '''<!doctype html><html><head><title>Cookie fixture</title></head>
<body>Local WebView2 login fixture<script>
localStorage.setItem('fixture_token', 'fixture-storage-token');
document.cookie = 'visible_cookie=fixture-visible; path=/';
</script></body></html>''',
      );
      await response.close();
    });
    final origin = 'http://127.0.0.1:${server.port}';
    final url = WebUri('$origin/');
    environment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder:
            '${output.path}/profile-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    final cookies = CookieManager.instance(webViewEnvironment: environment);
    await cookies.setCookie(
      url: url,
      name: 'ordinary_only',
      value: 'fixture-ordinary-profile',
      isHttpOnly: true,
    );

    Future<HeadlessInAppWebView> open(String path, {bool popup = false}) async {
      final loaded = Completer<void>();
      final settings = webSettings(isPopup: popup);
      final view = HeadlessInAppWebView(
        webViewEnvironment: environment,
        initialUrlRequest: URLRequest(url: WebUri('$origin$path')),
        initialSettings: settings,
        shouldOverrideUrlLoading: (_, _) async => NavigationActionPolicy.ALLOW,
        onLoadStop: (_, page) {
          if (page?.toString() == '$origin$path' && !loaded.isCompleted) {
            loaded.complete();
          }
        },
      );
      views.add(view);
      await view.run().timeout(const Duration(seconds: 10));
      await loaded.future.timeout(const Duration(seconds: 10));
      return view;
    }

    final main = await open('/login');
    final web = main.webViewController!;
    final ordinary = await cookies.getCookies(url: url);
    check(
      'Ordinary profile does not contain the private login cookie',
      ordinary.any((cookie) => cookie.name == 'ordinary_only') &&
          ordinary.every((cookie) => cookie.name != 'login_session'),
    );
    final captured = await cookies.getCookies(url: url, webViewController: web);
    check(
      'Current login window returns its HttpOnly session',
      captured.any(
        (cookie) =>
            cookie.name == 'login_session' &&
            cookie.value == 'fixture-private-session' &&
            cookie.isHttpOnly == true,
      ),
    );
    check(
      'Current login window excludes ordinary-profile credentials',
      captured.every((cookie) => cookie.name != 'ordinary_only'),
    );
    check(
      '115 HttpOnly credentials are captured from the current private window',
      LoginCredentials.plausible(
        CloudPlatform.pan115,
        captured.map((c) => '${c.name}=${c.value}').join('; '),
      ),
    );
    check(
      '115 credentials do not leak into the ordinary profile',
      !LoginCredentials.plausible(
        CloudPlatform.pan115,
        ordinary.map((c) => '${c.name}=${c.value}').join('; '),
      ),
    );
    final documentCookies = await web.evaluateJavascript(
      source: 'document.cookie',
    );
    check(
      'HttpOnly login cookie cannot be recovered through document.cookie',
      documentCookies is String &&
          documentCookies.contains('visible_cookie=') &&
          !documentCookies.contains('login_session='),
    );
    check(
      'Named cookie lookup uses the current login window',
      (await cookies.getCookie(
            url: url,
            name: 'login_session',
            webViewController: web,
          ))?.value ==
          'fixture-private-session',
    );
    check(
      'Windows JavaScript storage result is decoded as a string',
      await web.evaluateJavascript(
            source: "localStorage.getItem('fixture_token')",
          ) ==
          'fixture-storage-token',
    );
    final object = await web.evaluateJavascript(
      source: "({token: localStorage.getItem('fixture_token')})",
    );
    check(
      'Windows JavaScript object result preserves token fields',
      object is Map && object['token'] == 'fixture-storage-token',
    );

    for (final platform in [
      CloudPlatform.xunlei,
      CloudPlatform.aliyun,
      CloudPlatform.guangya,
      CloudPlatform.pan123,
      CloudPlatform.wopan,
    ]) {
      final target = WebLoginTarget.targets[platform]!;
      const access = 'fixture-access-token-0123456789';
      const refresh = 'fixture-refresh-token-0123456789';
      final value = platform == CloudPlatform.pan123
          ? access
          : jsonEncode({
              'access_token': access,
              'refresh_token': refresh,
              'sub': 'fixture-user',
            });
      final key = target.localStorageKey!;
      await web.evaluateJavascript(source: target.clearStorageScript);
      await web.evaluateJavascript(
        source:
            'localStorage.setItem(${jsonEncode(key)}, ${jsonEncode(value)});',
      );
      final raw = LoginCredentials.fromBrowser(
        platform,
        storage: await web.evaluateJavascript(source: target.readStorageScript),
      );
      check(
        '${platform.name} storage is captured by real WebView2',
        LoginCredentials.plausible(platform, raw) &&
            LoginCredentials.candidate(
                  platform,
                  raw,
                  null,
                ).field('accessToken') ==
                access,
      );
      await web.evaluateJavascript(source: target.clearStorageScript);
      check(
        '${platform.name} storage clears before another account login',
        LoginCredentials.fromBrowser(
          platform,
          storage: await web.evaluateJavascript(
            source: target.readStorageScript,
          ),
        ).isEmpty,
      );
    }

    final popup = await open('/authorize', popup: true);
    final popupCookies = await cookies.getCookies(
      url: url,
      webViewController: popup.webViewController!,
    );
    check(
      'Authorization window shares the private login profile',
      popupCookies.any((cookie) => cookie.name == 'login_session') &&
          popupCookies.any((cookie) => cookie.name == 'authorization_result') &&
          popupCookies.every((cookie) => cookie.name != 'ordinary_only'),
    );
    final returned = await cookies.getCookies(url: url, webViewController: web);
    check(
      'Main window receives authorization-window cookies',
      returned.any((cookie) => cookie.name == 'authorization_result'),
    );
    await popup.dispose();
    views.remove(popup);
    await main.dispose();
    views.remove(main);
    final fresh = await open('/fresh');
    final freshCookies = await cookies.getCookies(
      url: url,
      webViewController: fresh.webViewController!,
    );
    check(
      'Closing login windows clears the private session before the next login',
      freshCookies.every(
        (cookie) =>
            cookie.name != 'login_session' &&
            cookie.name != 'authorization_result' &&
            cookie.name != 'ordinary_only',
      ),
    );
    result['passed'] = true;
  } catch (error, stack) {
    result['failure'] = error.toString();
    result['stack'] = stack.toString();
  } finally {
    for (final view in views.reversed) {
      try {
        await view.dispose().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    try {
      await environment?.dispose().timeout(const Duration(seconds: 3));
    } catch (_) {}
    await server?.close(force: true);
    watchdog.cancel();
    save();
  }
  exit(result['passed'] == true ? 0 : 1);
}
