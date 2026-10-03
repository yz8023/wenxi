import 'dart:convert';
import '../core/json.dart';

class WeiyunWebLogin {
  static const origins = {
    'https://www.weiyun.com',
    'https://weiyun.com',
    'https://user.weiyun.com',
  };

  static bool trusted(String? url) {
    final uri = Uri.tryParse(url ?? '');
    return uri != null &&
        uri.scheme == 'https' &&
        uri.hasAuthority &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        origins.contains(uri.origin);
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
    } catch (_) {
      return {};
    }
  }

  static String cookie(String raw) =>
      raw.trimLeft().startsWith('{') ? decode(raw).str('cookie') : raw;

  static Json tokenInfo(Object? raw) => _fields(
    decode(raw),
    {'token_type', 'login_key_type', 'env_id'},
    {'openid', 'qq_openid', 'open_appid', 'access_token', 'login_key_value'},
  );

  static Json requestHeader(Object? raw) => _fields(
    decode(raw),
    {
      'user_flag',
      'env_id',
      'appid',
      'type',
      'version',
      'major_version',
      'minor_version',
      'fix_version',
    },
    {'uin', 'qq_openid', 'wx_openid'},
  );

  static Json _fields(Json raw, Set<String> numbers, Set<String> strings) {
    final result = <String, dynamic>{};
    for (final name in numbers) {
      final number = int.tryParse(raw.str(name));
      if (number != null && number >= 0 && number <= 0x7fffffff) {
        result[name] = number;
      }
    }
    for (final name in strings) {
      final value = raw.str(name);
      if (value.isNotEmpty &&
          value.length <= 8192 &&
          !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value)) {
        result[name] = value;
      }
    }
    return result;
  }

  static String csrf(Object? value) {
    final raw = value is String ? value : '';
    return raw.length <= 512 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(raw)
        ? raw
        : '';
  }

  static String encode(String cookie, Json captured) {
    final info = tokenInfo(captured['tokenInfo']);
    final header = requestHeader(captured['requestHeader']);
    final token = csrf(captured['csrf']);
    if (info.isEmpty && header.isEmpty && token.isEmpty) return cookie;
    return jsonEncode({
      'cookie': cookie,
      if (info.isNotEmpty) 'tokenInfo': info,
      if (header.isNotEmpty) 'requestHeader': header,
      if (token.isNotEmpty) 'csrf': token,
    });
  }

  static Map<String, String> fields(String raw) {
    final captured = decode(raw);
    final info = tokenInfo(captured['tokenInfo']);
    final header = requestHeader(captured['requestHeader']);
    return {
      'primary': cookie(raw),
      if (info.isNotEmpty) 'weiyunTokenInfo': jsonEncode(info),
      if (header.isNotEmpty) 'weiyunRequestHeader': jsonEncode(header),
      if (csrf(captured['csrf']).isNotEmpty)
        'weiyunCsrf': csrf(captured['csrf']),
    };
  }

  // Read only Weiyun's file API parameters, in the same document that is
  // already displaying the user's files. Nothing is persisted in web storage.
  static const bootstrapScript = r'''(() => {
    if (window.top !== window || !['https://www.weiyun.com', 'https://weiyun.com', 'https://user.weiyun.com'].includes(location.origin)) return;
    if (window.__asterWeiyunLogin) return;
    let latest = {};
    const parse = value => {
      if (value && typeof value === 'object') return value;
      if (typeof value !== 'string' || value.length > 131072) return {};
      try { return JSON.parse(value); } catch (_) { return {}; }
    };
    const capture = (address, body) => {
      try {
        const url = new URL(address, location.href);
        if (url.origin !== 'https://www.weiyun.com' || !url.pathname.startsWith('/webapp/json/')) return;
        if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) body = body.toString();
        let data = parse(body);
        if (typeof FormData !== 'undefined' && body instanceof FormData) {
          data = {req_body: body.get('req_body'), req_header: body.get('req_header')};
        }
        if (!data.req_body && typeof body === 'string') {
          const form = new URLSearchParams(body);
          data = {req_body: form.get('req_body'), req_header: form.get('req_header')};
        }
        const request = parse(data.req_body);
        const header = parse(data.req_header);
        const info = request.ReqMsg_body?.ext_req_head?.token_info;
        if (!info || typeof info !== 'object' || info.token_type == null || info.login_key_type == null) return;
        latest = {tokenInfo: info, requestHeader: header, csrf: url.searchParams.get('g_tk') || ''};
      } catch (_) {}
    };
    window.__asterWeiyunLogin = {read: () => ({...latest, cookie: document.cookie || ''})};
    if (typeof XMLHttpRequest !== 'undefined') {
      const urls = new WeakMap();
      const open = XMLHttpRequest.prototype.open;
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) {
        urls.set(this, String(url));
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function(body) {
        capture(urls.get(this), body);
        return send.apply(this, arguments);
      };
    }
    if (typeof window.fetch === 'function') {
      const fetch = window.fetch;
      window.fetch = function(input, init) {
        const address = typeof input === 'string' || input instanceof URL ? String(input) : input?.url;
        if (init?.body != null) capture(address, init.body instanceof URLSearchParams ? init.body.toString() : init.body);
        else if (typeof Request !== 'undefined' && input instanceof Request) {
          try { input.clone().text().then(body => capture(address, body)).catch(() => {}); } catch (_) {}
        }
        return fetch.apply(this, arguments);
      };
    }
  })()''';

  static const readScript = r'''(() => {
    if (window.top !== window || !['https://www.weiyun.com', 'https://weiyun.com', 'https://user.weiyun.com'].includes(location.origin)) return '';
    return JSON.stringify(window.__asterWeiyunLogin?.read() || {cookie: document.cookie || ''});
  })()''';
}
