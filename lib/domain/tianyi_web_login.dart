import 'dart:convert';
import '../core/json.dart';

class TianyiWebLogin {
  static const loginUrl =
      'https://m.cloud.189.cn/udb/udb_login.jsp?pageId=1&pageKey=normal&clientType=wap&redirectURL=https%3A%2F%2Fcloud.189.cn%2Fweb%2Fredirect.html';

  static const origins = {
    'https://cloud.189.cn',
    'https://m.cloud.189.cn',
    'https://h5.cloud.189.cn',
  };

  static bool trusted(String? address) {
    final uri = Uri.tryParse(address ?? '');
    return uri != null &&
        uri.scheme == 'https' &&
        uri.hasAuthority &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        origins.contains(uri.origin);
  }

  static bool isCompletionLanding(String? address) {
    if (!trusted(address)) return false;
    final uri = Uri.parse(address!);
    return switch (uri.host) {
      'cloud.189.cn' => {
        '/web/redirect.html',
        '/web/main',
        '/web/main/',
      }.contains(uri.path),
      'm.cloud.189.cn' => uri.path == '/main.action',
      'h5.cloud.189.cn' => {'/', '/home.html'}.contains(uri.path),
      _ => false,
    };
  }

  static Json decode(Object? value) {
    if (value is Map) return asJson(value);
    if (value is! String ||
        value.length > 131072 ||
        !value.trimLeft().startsWith('{')) {
      return {};
    }
    try {
      return asJson(jsonDecode(value));
    } on FormatException {
      return {};
    }
  }

  static String cookie(String raw) =>
      raw.trimLeft().startsWith('{') ? decode(raw).str('cookie') : raw;

  static String browserId(Object? value) =>
      value is String && RegExp(r'^[A-Za-z0-9_-]{8,256}$').hasMatch(value)
      ? value
      : '';

  static String encode(String cookie, Object? browser) {
    final id = browserId(browser);
    return id.isEmpty
        ? cookie
        : jsonEncode({'cookie': cookie, 'browserId': id});
  }

  static Map<String, String> fields(String raw) => {
    'primary': cookie(raw),
    if (browserId(decode(raw)['browserId']).isNotEmpty)
      'browserId': browserId(decode(raw)['browserId']),
  };

  static const mobileFormScript = r'''(() => {
    if (window.top !== window || location.origin !== 'https://open.e.189.cn' ||
        location.pathname !== '/api/logbox/separate/wap/index.html' || window.__asterTianyiForm) return;
    window.__asterTianyiForm = true;
    let observer;
    const select = () => {
      const button = [...document.querySelectorAll('a,button,[role="button"]')].find(el =>
        ['其它方式登录', '其他方式登录'].includes(el.textContent?.trim()) && el.getClientRects().length && !el.disabled);
      if (!button) return;
      observer?.disconnect();
      button.click();
    };
    observer = new MutationObserver(select);
    observer.observe(document, {childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'style', 'hidden']});
    select();
    setTimeout(() => observer.disconnect(), 15000);
  })()''';

  // The official login iframe and account API share a browser fingerprint.
  // Observe the value already used by that page; do not generate a replacement.
  static const bootstrapScript = r'''(() => {
    if (window.top !== window || !['https://cloud.189.cn', 'https://m.cloud.189.cn', 'https://h5.cloud.189.cn'].includes(location.origin)) return;
    if (window.__asterTianyiLogin) return;
    let latest = '';
    const identifier = value => typeof value === 'string' && /^[A-Za-z0-9_-]{8,256}$/.test(value) ? value : '';
    const api = address => {
      try {
        const url = new URL(address, location.href);
        return url.origin === 'https://cloud.189.cn' && !url.username && !url.password && url.pathname.startsWith('/api/') ? url : null;
      } catch (_) { return null; }
    };
    const remember = (address, value) => {
      const id = identifier(value);
      if (id && api(address)) latest = id;
    };
    window.__asterTianyiLogin = {read: () => {
      const frame = document.getElementById('udb_login');
      const url = frame?.src ? api(frame.src) : null;
      if (url?.pathname === '/api/portal/loginUrl.action') remember(url.href, url.searchParams.get('browserId'));
      return {browserId: latest};
    }};
    if (typeof XMLHttpRequest !== 'undefined') {
      const requests = new WeakMap();
      const open = XMLHttpRequest.prototype.open;
      const setHeader = XMLHttpRequest.prototype.setRequestHeader;
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, address) {
        requests.set(this, {address: String(address), id: ''});
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
        const request = requests.get(this);
        if (request && String(name).toLowerCase() === 'browser-id') request.id = identifier(value);
        return setHeader.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        const request = requests.get(this);
        if (request) remember(request.address, request.id);
        return send.apply(this, arguments);
      };
    }
    if (typeof window.fetch === 'function') {
      const fetch = window.fetch;
      window.fetch = function(input, init) {
        try {
          const address = typeof input === 'string' || input instanceof URL ? String(input) : input?.url;
          const headers = new Headers(init?.headers ?? input?.headers);
          remember(address, headers.get('Browser-Id'));
        } catch (_) {}
        return fetch.apply(this, arguments);
      };
    }
  })()''';

  static const readScript = r'''(() => {
    if (window.top !== window || !['https://cloud.189.cn', 'https://m.cloud.189.cn', 'https://h5.cloud.189.cn'].includes(location.origin)) return '';
    return JSON.stringify(window.__asterTianyiLogin?.read() || {});
  })()''';
}
