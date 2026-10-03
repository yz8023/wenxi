import 'dart:convert';
import 'models.dart';

/// A single, short-lived submission to Aliyun's official password form. The
/// frame scripts contain no credentials; only the ready, trusted frame chain
/// receives the values after the native form is submitted.
class AliyunWebPassword {
  AliyunWebPassword(String username, String password)
    : _username = username,
      _password = password,
      _rememberedUsername = username,
      _rememberedPassword = password;

  final id = newId();
  final _clock = Stopwatch()..start();
  String _username, _password;
  String _rememberedUsername, _rememberedPassword;
  Map<String, String> get rememberedLogin =>
      _rememberedUsername.isEmpty || _rememberedPassword.isEmpty
      ? {}
      : {
          'loginUsername': _rememberedUsername,
          'loginPassword': _rememberedPassword,
        };
  bool get pending => _username.isNotEmpty && _password.isNotEmpty;
  bool get expired => _clock.elapsed >= const Duration(minutes: 1);

  void clear() {
    _username = '';
    _password = '';
    _rememberedUsername = '';
    _rememberedPassword = '';
  }

  static const origins = {
    'https://www.alipan.com',
    'https://auth.alipan.com',
    'https://auth.aliyundrive.com',
    'https://passport.alipan.com',
    'https://passport.aliyundrive.com',
  };

  String get statusScript =>
      '''(() => {
    if (location.origin !== 'https://www.alipan.com') return 'unavailable';
    const bridge = window.__asterAliPassword;
    return bridge && bridge.id === ${jsonEncode(id)} ? bridge.status : 'waiting';
  })()''';

  String? takeSubmissionScript() {
    if (!pending || expired) {
      clear();
      return null;
    }
    final values = jsonEncode([_username, _password]);
    _username = '';
    _password = '';
    return '''(() => {
      if (location.origin !== 'https://www.alipan.com') return 'unavailable';
      const bridge = window.__asterAliPassword;
      if (!bridge || bridge.id !== ${jsonEncode(id)} || bridge.status !== 'ready') return 'unavailable';
      return bridge.submit(...$values);
    })()''';
  }

  String get bootstrapScript =>
      '''(() => {
    const id = ${jsonEncode(id)};
    const main = 'https://www.alipan.com';
    const auth = ['https://auth.alipan.com', 'https://auth.aliyundrive.com'];
    const passport = ['https://passport.alipan.com', 'https://passport.aliyundrive.com'];
    const origin = location.origin;
    if (![main, ...auth, ...passport].includes(origin) || window.__asterAliPasswordInstalled === id) return;
    window.__asterAliPasswordInstalled = id;
    const deadline = Date.now() + 60000;
    const valid = event => event.data && event.data.asterLogin === id && Date.now() < deadline;
    const child = (event, origins) => {
      if (!origins.includes(event.origin)) return null;
      return [...document.querySelectorAll('iframe')].find(frame => {
        try {
          return frame.contentWindow === event.source && new URL(frame.src, location.href).origin === event.origin;
        } catch (_) { return false; }
      });
    };
    const send = (target, targetOrigin, kind, extra = {}) => {
      target.postMessage({asterLogin: id, kind, ...extra}, targetOrigin);
    };
    if (origin === main && window === window.top) {
      let frame = null, frameOrigin = '';
      const bridge = window.__asterAliPassword = {
        id, status: 'waiting',
        submit: (username, password) => {
          if (Date.now() >= deadline || bridge.status !== 'ready' || !frame || !frame.isConnected ||
              new URL(frame.src, location.href).origin !== frameOrigin) return 'unavailable';
          try { localStorage.removeItem('token'); }
          catch (_) { return 'unavailable'; }
          bridge.status = 'sent';
          send(frame.contentWindow, frameOrigin, 'credentials', {username, password});
          return 'sent';
        }
      };
      window.addEventListener('message', event => {
        if (!valid(event)) return;
        const sender = child(event, auth);
        if (!sender) return;
        if (event.data.kind === 'ready' && bridge.status === 'waiting') {
          frame = sender; frameOrigin = event.origin; bridge.status = 'ready';
        } else if (sender === frame && ['submitted', 'unavailable'].includes(event.data.kind)) {
          bridge.status = event.data.kind;
        }
      });
      return;
    }
    if (auth.includes(origin) && window !== window.top) {
      let frame = null, frameOrigin = '', sent = false;
      window.addEventListener('message', event => {
        if (!valid(event)) return;
        const sender = child(event, passport);
        if (sender) {
          if (event.data.kind === 'ready' && !sent) {
            frame = sender; frameOrigin = event.origin;
            send(parent, main, 'ready');
          } else if (sender === frame && ['submitted', 'unavailable'].includes(event.data.kind)) {
            send(parent, main, event.data.kind);
          }
        } else if (!sent && event.source === parent && event.origin === main && event.data.kind === 'credentials') {
          sent = true;
          if (!frame || !frame.isConnected || new URL(frame.src, location.href).origin !== frameOrigin) {
            send(parent, main, 'unavailable'); return;
          }
          send(frame.contentWindow, frameOrigin, 'credentials', {
            username: event.data.username, password: event.data.password
          });
        }
      });
      return;
    }
    if (!passport.includes(origin) || window === window.top || location.pathname !== '/mini_login.htm') return;
    let accepted = false, switchCount = 0;
    const fields = () => {
      const username = document.getElementById('fm-login-id');
      const password = document.getElementById('fm-login-password');
      const form = password && password.closest('form');
      const button = form && form.querySelector('button[type="submit"], button.password-login');
      return username && password && password.getClientRects().length && button ? {username, password, button} : null;
    };
    const announce = () => {
      if (accepted || Date.now() >= deadline) { clearInterval(timer); return; }
      if (fields()) {
        for (const target of auth) send(parent, target, 'ready');
      } else if (switchCount < 3) {
        const tab = [...document.querySelectorAll('a')].find(link => link.textContent.trim() === '账号登录');
        if (tab) { switchCount++; tab.click(); }
      }
    };
    window.addEventListener('message', event => {
      if (!valid(event) || accepted || event.source !== parent || !auth.includes(event.origin) || event.data.kind !== 'credentials') return;
      accepted = true;
      clearInterval(timer);
      const form = fields();
      if (!form || typeof event.data.username !== 'string' || typeof event.data.password !== 'string') {
        send(parent, event.origin, 'unavailable'); return;
      }
      const set = (input, value) => {
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, value);
        input.dispatchEvent(new Event('input', {bubbles: true}));
        input.dispatchEvent(new Event('change', {bubbles: true}));
      };
      set(form.username, event.data.username);
      set(form.password, event.data.password);
      const replyOrigin = event.origin;
      setTimeout(() => {
        if (!form.button.isConnected || form.button.disabled) {
          send(parent, replyOrigin, 'unavailable'); return;
        }
        form.button.click();
        send(parent, replyOrigin, 'submitted');
      }, 80);
    });
    const timer = setInterval(announce, 200);
    announce();
  })();''';
}
