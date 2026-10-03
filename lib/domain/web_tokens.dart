import 'dart:convert';
import '../core/json.dart';
import 'models.dart';
import 'xunlei_web_login.dart';

/// The public web clients store token objects, rather than login cookies.
class WebTokens {
  static bool supports(CloudPlatform platform) =>
      platform == CloudPlatform.aliyun ||
      platform == CloudPlatform.guangya ||
      platform == CloudPlatform.xunlei ||
      platform == CloudPlatform.wopan ||
      platform == CloudPlatform.ilanzou;

  static bool validToken(String value) =>
      value.length >= 16 &&
      value.length <= 16384 &&
      RegExp(r'^[A-Za-z0-9._~+/=-]+$').hasMatch(value) &&
      !{'null', 'undefined'}.contains(value);

  static Json decode(String raw) {
    Object? value;
    try {
      value = jsonDecode(raw);
      if (value is String && value.trimLeft().startsWith('{')) {
        value = jsonDecode(value);
      }
    } catch (_) {
      return {};
    }
    var result = asJson(value);
    for (var depth = 0; depth < 2; depth++) {
      if (result.containsKey('access_token') ||
          result.containsKey('accessToken') ||
          result.containsKey('refresh_token') ||
          result.containsKey('refreshToken')) {
        break;
      }
      final nested = result['credentials'] ?? result['token'] ?? result['data'];
      if (nested is! Map) break;
      result = asJson(nested);
    }
    return result;
  }

  static Map<String, String> fields(CloudPlatform platform, String raw) {
    if (platform == CloudPlatform.ilanzou) return _ilanzouFields(raw);
    var value = raw.trim();
    try {
      if (value.startsWith('"') && jsonDecode(value) is String) {
        value = (jsonDecode(value) as String).trim();
      }
    } catch (_) {
      return {};
    }
    final data = decode(value);
    for (final key in [
      'access_token',
      'accessToken',
      'refresh_token',
      'refreshToken',
    ]) {
      if (!data.containsKey(key)) continue;
      final token = data[key];
      if (token is! String || RegExp(r'[\x00-\x1f\x7f]').hasMatch(token)) {
        return {};
      }
    }
    String pick(List<String> keys) {
      for (final key in keys) {
        final item = data[key];
        if (item is! String && item is! num) continue;
        final text = '$item'.trim();
        if (text.isNotEmpty && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)) {
          return text;
        }
      }
      return '';
    }

    var access = pick(['access_token', 'accessToken']);
    var refresh = pick(['refresh_token', 'refreshToken']);
    if (data.isEmpty) {
      value = value.replaceFirst(
        RegExp(r'^Bearer\s+', caseSensitive: false),
        '',
      );
      if (platform == CloudPlatform.aliyun || platform == CloudPlatform.wopan) {
        refresh = value;
      } else {
        access = value;
      }
    }
    if (access.isNotEmpty && !validToken(access) ||
        refresh.isNotEmpty && !validToken(refresh) ||
        platform == CloudPlatform.aliyun && refresh.isEmpty ||
        access.isEmpty && refresh.isEmpty) {
      return {};
    }

    final expiry = pick([
      'expires_at',
      'expire_time',
      'expiresAt',
      'expireTime',
    ]);
    final expires = epochMilliseconds(expiry);
    return {
      'primary':
          platform == CloudPlatform.aliyun || platform == CloudPlatform.wopan
          ? refresh
          : access,
      'accessToken': access,
      'refreshToken': refresh,
      'authType': 'webToken',
      'userId': pick(['user_id', 'userId', 'sub']),
      'nickname': pick(['nick_name', 'nickname', 'name', 'user_name']),
      if (platform == CloudPlatform.guangya || platform == CloudPlatform.xunlei)
        'deviceId': pick(['device_id', 'deviceId']),
      if (platform == CloudPlatform.xunlei) ...{
        'clientId': XunleiWebLogin.clientId,
        if (validToken(pick(['captcha_token', 'captchaToken'])))
          'captchaToken': pick(['captcha_token', 'captchaToken']),
      },
      if (platform == CloudPlatform.guangya &&
          validToken(pick(['device_sign', 'deviceSign'])))
        'deviceSign': pick(['device_sign', 'deviceSign']),
      if (expires > 0) 'expiresAt': '$expires',
      'defaultDriveId': pick(['default_drive_id', 'defaultDriveId']),
      'resourceDriveId': pick(['resource_drive_id', 'resourceDriveId']),
      'backupDriveId': pick(['backup_drive_id', 'backupDriveId']),
    }..removeWhere((_, value) => value.isEmpty);
  }

  static bool validILanzouToken(String value) =>
      value.length >= 16 &&
      value.length <= 16384 &&
      RegExp(r'^[A-Za-z0-9._~+/=:!%&?\-]+$').hasMatch(value);

  static Map<String, String> _ilanzouFields(String raw) {
    var value = raw.trim();
    final data = decode(value);
    final token = data
        .str('appToken')
        .ifEmpty(data.str('accessToken'))
        .ifEmpty(data.isEmpty ? value : '');
    final uuid = data.str('uuid');
    if (!validILanzouToken(token) ||
        uuid.isNotEmpty && !RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(uuid)) {
      return {};
    }
    return {
      'primary': token,
      'accessToken': token,
      'authType': 'webToken',
      if (uuid.isNotEmpty) 'uuid': uuid,
    };
  }

  static int epochMilliseconds(String value) {
    final number = int.tryParse(value);
    if (number != null && number > 0) {
      return number < 100000000000 ? number * 1000 : number;
    }
    return DateTime.tryParse(value)?.millisecondsSinceEpoch ?? 0;
  }

  static int jwtExpiry(String token) {
    try {
      final part = token.split('.')[1];
      final body = asJson(
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(part)))),
      );
      return body.integer('exp') * 1000;
    } catch (_) {
      return 0;
    }
  }
}
