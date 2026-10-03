import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';

import 'webview_environment/webview_environment.dart';

/// Object specifying creation parameters for creating a [WindowsCookieManager].
///
/// When adding additional fields make sure they can be null or have a default
/// value to avoid breaking changes. See [PlatformCookieManagerCreationParams] for
/// more information.
@immutable
class WindowsCookieManagerCreationParams
    extends PlatformCookieManagerCreationParams {
  /// Creates a new [WindowsCookieManagerCreationParams] instance.
  const WindowsCookieManagerCreationParams({this.webViewEnvironment});

  /// Creates a [WindowsCookieManagerCreationParams] instance based on [PlatformCookieManagerCreationParams].
  factory WindowsCookieManagerCreationParams.fromPlatformCookieManagerCreationParams(
      // Recommended placeholder to prevent being broken by platform interface.
      // ignore: avoid_unused_constructor_parameters
      PlatformCookieManagerCreationParams params) {
    return WindowsCookieManagerCreationParams(
        webViewEnvironment:
            params.webViewEnvironment as WindowsWebViewEnvironment?);
  }

  @override
  final WindowsWebViewEnvironment? webViewEnvironment;
}

///{@macro flutter_inappwebview_platform_interface.PlatformCookieManager}
class WindowsCookieManager extends PlatformCookieManager
    with ChannelController {
  /// Creates a new [WindowsCookieManager].
  WindowsCookieManager(PlatformCookieManagerCreationParams params)
      : super.implementation(
          params is WindowsCookieManagerCreationParams
              ? params
              : WindowsCookieManagerCreationParams
                  .fromPlatformCookieManagerCreationParams(params),
        ) {
    channel = const MethodChannel(
        'com.pichillilorenzo/flutter_inappwebview_cookiemanager');
    handler = handleMethod;
    initMethodCallHandler();
  }

  static WindowsCookieManager? _instance;

  ///Gets the [WindowsCookieManager] shared instance.
  static WindowsCookieManager instance(
      {WindowsWebViewEnvironment? webViewEnvironment}) {
    if (webViewEnvironment == null) {
      if (_instance == null) {
        _instance = _init();
      }
      return _instance!;
    } else {
      return WindowsCookieManager(WindowsCookieManagerCreationParams(
          webViewEnvironment: webViewEnvironment));
    }
  }

  static WindowsCookieManager _init() {
    _instance = WindowsCookieManager(WindowsCookieManagerCreationParams());
    return _instance!;
  }

  Future<dynamic> _handleMethod(MethodCall call) async {}

  @override
  Future<bool> setCookie(
      {required WebUri url,
      required String name,
      required String value,
      String path = "/",
      String? domain,
      int? expiresDate,
      int? maxAge,
      bool? isSecure,
      bool? isHttpOnly,
      HTTPCookieSameSitePolicy? sameSite,
      @Deprecated("Use webViewController instead")
      PlatformInAppWebViewController? iosBelow11WebViewController,
      PlatformInAppWebViewController? webViewController}) async {
    assert(url.toString().isNotEmpty);
    assert(name.isNotEmpty);
    assert(value.isNotEmpty);
    assert(path.isNotEmpty);

    Map<String, dynamic> args = <String, dynamic>{};
    args.putIfAbsent('url', () => url.toString());
    args.putIfAbsent('name', () => name);
    args.putIfAbsent('value', () => value);
    args.putIfAbsent('domain', () => domain);
    args.putIfAbsent('path', () => path);
    args.putIfAbsent('expiresDate', () => expiresDate);
    args.putIfAbsent('maxAge', () => maxAge);
    args.putIfAbsent('isSecure', () => isSecure);
    args.putIfAbsent('isHttpOnly', () => isHttpOnly);
    args.putIfAbsent('sameSite', () => sameSite?.toNativeValue());
    args.putIfAbsent(
        'webViewEnvironmentId', () => params.webViewEnvironment?.id);

    return await channel?.invokeMethod<bool>('setCookie', args) ?? false;
  }

  @override
  Future<List<Cookie>> getCookies(
      {required WebUri url,
      @Deprecated("Use webViewController instead")
      PlatformInAppWebViewController? iosBelow11WebViewController,
      PlatformInAppWebViewController? webViewController}) async {
    assert(url.toString().isNotEmpty);

    if (webViewController != null) {
      // The environment's hidden WebView uses its ordinary profile. Read the
      // supplied WebView instead so InPrivate and authorization windows keep
      // their own cookie store, including HttpOnly cookies.
      final response = await webViewController.callDevToolsProtocolMethod(
          methodName: 'Network.getCookies',
          parameters: {
            'urls': [url.toString()]
          });
      if (response is! Map || response['cookies'] is! List) {
        throw const FormatException('Invalid WebView cookie response');
      }
      return (response['cookies'] as List).map((entry) {
        if (entry is! Map ||
            entry['name'] is! String ||
            entry['value'] is! String) {
          throw const FormatException('Invalid WebView cookie entry');
        }
        final expires = entry['expires'];
        return Cookie(
            name: entry['name'],
            value: entry['value'],
            domain: entry['domain'],
            path: entry['path'],
            expiresDate:
                entry['session'] != true && expires is num && expires > 0
                    ? (expires * 1000).round()
                    : null,
            isSessionOnly: entry['session'],
            isHttpOnly: entry['httpOnly'],
            isSecure: entry['secure'],
            sameSite:
                HTTPCookieSameSitePolicy.fromNativeValue(entry['sameSite']));
      }).toList();
    }

    List<Cookie> cookies = [];

    Map<String, dynamic> args = <String, dynamic>{};
    args.putIfAbsent('url', () => url.toString());
    args.putIfAbsent(
        'webViewEnvironmentId', () => params.webViewEnvironment?.id);
    List<dynamic> cookieListMap =
        await channel?.invokeMethod<List>('getCookies', args) ?? [];
    cookieListMap = cookieListMap.cast<Map<dynamic, dynamic>>();

    cookieListMap.forEach((cookieMap) {
      cookies.add(Cookie(
          name: cookieMap["name"],
          value: cookieMap["value"],
          expiresDate: cookieMap["expiresDate"],
          isSessionOnly: cookieMap["isSessionOnly"],
          domain: cookieMap["domain"],
          sameSite:
              HTTPCookieSameSitePolicy.fromNativeValue(cookieMap["sameSite"]),
          isSecure: cookieMap["isSecure"],
          isHttpOnly: cookieMap["isHttpOnly"],
          path: cookieMap["path"]));
    });
    return cookies;
  }

  @override
  Future<Cookie?> getCookie(
      {required WebUri url,
      required String name,
      @Deprecated("Use webViewController instead")
      PlatformInAppWebViewController? iosBelow11WebViewController,
      PlatformInAppWebViewController? webViewController}) async {
    assert(url.toString().isNotEmpty);
    assert(name.isNotEmpty);

    final cookies = await getCookies(
        url: url,
        webViewController: webViewController,
        iosBelow11WebViewController: iosBelow11WebViewController);
    for (final cookie in cookies) {
      if (cookie.name == name) return cookie;
    }
    return null;
  }

  @override
  Future<bool> deleteCookie(
      {required WebUri url,
      required String name,
      String path = "/",
      String? domain,
      @Deprecated("Use webViewController instead")
      PlatformInAppWebViewController? iosBelow11WebViewController,
      PlatformInAppWebViewController? webViewController}) async {
    assert(url.toString().isNotEmpty);
    assert(name.isNotEmpty);

    Map<String, dynamic> args = <String, dynamic>{};
    args.putIfAbsent('url', () => url.toString());
    args.putIfAbsent('name', () => name);
    args.putIfAbsent('domain', () => domain);
    args.putIfAbsent('path', () => path);
    args.putIfAbsent(
        'webViewEnvironmentId', () => params.webViewEnvironment?.id);
    return await channel?.invokeMethod<bool>('deleteCookie', args) ?? false;
  }

  @override
  Future<bool> deleteCookies(
      {required WebUri url,
      String path = "/",
      String? domain,
      @Deprecated("Use webViewController instead")
      PlatformInAppWebViewController? iosBelow11WebViewController,
      PlatformInAppWebViewController? webViewController}) async {
    assert(url.toString().isNotEmpty);

    Map<String, dynamic> args = <String, dynamic>{};
    args.putIfAbsent('url', () => url.toString());
    args.putIfAbsent('domain', () => domain);
    args.putIfAbsent('path', () => path);
    args.putIfAbsent(
        'webViewEnvironmentId', () => params.webViewEnvironment?.id);
    return await channel?.invokeMethod<bool>('deleteCookies', args) ?? false;
  }

  @override
  Future<bool> deleteAllCookies() async {
    Map<String, dynamic> args = <String, dynamic>{};
    args.putIfAbsent(
        'webViewEnvironmentId', () => params.webViewEnvironment?.id);
    return await channel?.invokeMethod<bool>('deleteAllCookies', args) ?? false;
  }

  @override
  void dispose() {
    // empty
  }
}

extension InternalCookieManager on WindowsCookieManager {
  get handleMethod => _handleMethod;
}
