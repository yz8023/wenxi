import 'dart:io';
import 'http.dart';

/// An in-memory cookie jar for a single login attempt, separate from WebViews
/// and the saved account. Only explicitly allowed cookie domains are accepted.
class LoginCookieJar {
  LoginCookieJar(this.allowedDomains, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final Set<String> allowedDomains;
  final DateTime Function() clock;
  final _cookies = <_LoginCookie>[];

  void absorb(Uri source, HttpResult response) {
    final now = clock();
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() != 'set-cookie') continue;
      for (final raw in entry.value) {
        if (raw.length > 8192 || RegExp(r'[\r\n\x00]').hasMatch(raw)) continue;
        try {
          final cookie = Cookie.fromSetCookieValue(raw);
          final hostOnly = cookie.domain == null || cookie.domain!.isEmpty;
          final domain = hostOnly
              ? source.host
              : cookie.domain!.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
          if (!allowedDomains.contains(domain) ||
              source.host != domain && !source.host.endsWith('.$domain')) {
            continue;
          }
          final path = cookie.path?.startsWith('/') == true
              ? cookie.path!
              : source.path.lastIndexOf('/') <= 0
              ? '/'
              : source.path.substring(0, source.path.lastIndexOf('/'));
          _cookies.removeWhere(
            (c) =>
                c.name == cookie.name && c.domain == domain && c.path == path,
          );
          final expires = cookie.maxAge != null
              ? now.add(Duration(seconds: cookie.maxAge!.clamp(-1, 31536000)))
              : cookie.expires;
          if (cookie.value.isEmpty ||
              expires != null && !expires.isAfter(now)) {
            continue;
          }
          if (_cookies.length >= 64) continue;
          _cookies.add(
            _LoginCookie(
              cookie.name,
              cookie.value,
              domain,
              path,
              hostOnly,
              cookie.secure,
              expires,
            ),
          );
        } on FormatException {
          // A malformed optional cookie must not corrupt this login attempt.
        } on ArgumentError {
          // Ignore invalid attributes without logging cookie contents.
        }
      }
    }
  }

  String header(Uri target) {
    final now = clock();
    final path = target.path.isEmpty ? '/' : target.path;
    _cookies.removeWhere((c) => c.expires != null && !c.expires!.isAfter(now));
    final matches =
        _cookies
            .where(
              (c) =>
                  (target.host == c.domain ||
                      !c.hostOnly && target.host.endsWith('.${c.domain}')) &&
                  (!c.secure || target.scheme == 'https') &&
                  (path == c.path ||
                      path.startsWith(
                        c.path.endsWith('/') ? c.path : '${c.path}/',
                      )),
            )
            .toList()
          ..sort((a, b) => b.path.length.compareTo(a.path.length));
    return matches.map((c) => '${c.name}=${c.value}').join('; ');
  }

  void clear() => _cookies.clear();
}

class _LoginCookie {
  const _LoginCookie(
    this.name,
    this.value,
    this.domain,
    this.path,
    this.hostOnly,
    this.secure,
    this.expires,
  );
  final String name, value, domain, path;
  final bool hostOnly, secure;
  final DateTime? expires;
}
