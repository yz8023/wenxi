class XunleiWebLogin {
  static const clientId = 'Xqp0kJBXWhwaTpB6';
  static const storageKey = 'credentials_$clientId';

  static const readScript = r'''(() => {
    try {
      const prefix = 'credentials_Xqp0kJBXWhwaTpB6';
      const sub = localStorage.getItem('current_sub');
      const raw = sub ? localStorage.getItem(prefix + '@' + sub) : localStorage.getItem(prefix);
      if (!raw) return '';
      const data = JSON.parse(raw);
      if (!data || typeof data !== 'object' || Array.isArray(data)) return '';
      if (sub && data.sub && String(data.sub) !== sub) return '';
      try {
        const captcha = JSON.parse(localStorage.getItem('captcha_Xqp0kJBXWhwaTpB6') || '{}');
        if (captcha && captcha.token && Date.parse(captcha.expires_at) > Date.now()) data.captcha_token = captcha.token;
      } catch (_) {}
      try {
        const cookie = document.cookie.split(';').map(s => s.trim()).find(s => s.startsWith('deviceid='));
        if (cookie) {
          const device = decodeURIComponent(cookie.slice(9));
          data.device_id = device.includes('.') && device.length > 32 ? device.split('.')[1].slice(0, 32) : device;
        }
      } catch (_) {}
      return JSON.stringify(data);
    } catch (_) { return ''; }
  })()''';

  static const clearScript = r'''(() => {
    const prefix = 'credentials_Xqp0kJBXWhwaTpB6';
    for (const key of Object.keys(localStorage)) {
      if (key === prefix || key.startsWith(prefix + '@') ||
          key === 'current_sub' || key === 'captcha_Xqp0kJBXWhwaTpB6') localStorage.removeItem(key);
    }
  })()''';
}
