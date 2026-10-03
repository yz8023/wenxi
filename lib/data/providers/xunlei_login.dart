import 'dart:math';
import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../http.dart';
import 'xunlei_protocol.dart';

class SmsChallenge {
  const SmsChallenge(this.mobile, this.creditKey, this.token, this.deviceId);
  final String mobile, creditKey, token, deviceId;
}

class XunleiVerificationRequired implements Exception {
  const XunleiVerificationRequired(
    this.url,
    this.creditKey,
    this.token,
    this.message,
    this.deviceId,
  );
  final String url, creditKey, token, message, deviceId;
  @override
  String toString() => message;
}

class XunleiLoginService {
  XunleiLoginService(
    this.http,
    this.devices, {
    this.authBase = XunleiProtocol.authBase,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final JsonHttp http;
  final XunleiDevices devices;
  final String authBase;
  final int Function() now;
  static bool isMobile(String value) =>
      RegExp(r'^\+?[0-9]{7,15}$').hasMatch(value.trim());
  String message(Json j, String fallback) => j
      .str('errorDesc')
      .ifEmpty(j.str('error_description'))
      .ifEmpty(j.str('message'))
      .ifEmpty(fallback);
  Json base(
    XunleiDevice d,
    String version,
    String sdk, [
    String creditKey = '',
  ]) => {
    'protocolVersion': '301',
    'sequenceNo': '${10000000 + Random.secure().nextInt(89999999)}',
    'platformVersion': '10',
    'isCompressed': '0',
    'appid': '40',
    'clientVersion': version,
    'peerID': d.peer,
    'appName': 'ANDROID-${XunleiProtocol.packageName}',
    'sdkVersion': sdk,
    'devicesign': d.sign,
    'netWorkType': 'WIFI',
    'providerName': 'NONE',
    'deviceModel': 'M2004J7AC',
    'deviceName': 'Xiaomi_M2004j7ac',
    'OSVersion': '12',
    'creditkey': creditKey,
    'hl': 'zh-CN',
  };
  Future<Json> post(String path, Json body, String agent) async {
    RequestScope.checkpoint();
    final r = await http.postJson('$authBase$path', body, {
      'User-Agent': agent,
      'Content-Type': 'application/json',
    });
    RequestScope.checkpoint();
    checkAvailable(r);
    final j = r.json;
    require(
      r.successful ||
          j.str('errorCode').isNotEmpty ||
          j.str('error').isNotEmpty,
      '迅雷登录请求失败（HTTP ${r.status}）',
    );
    return j;
  }

  static void checkAvailable(HttpResult response) {
    if (response.status == 408 ||
        response.status == 429 ||
        response.status >= 500) {
      throw HttpRequestFailure(
        '迅雷登录服务暂不可用，请稍后重试',
        kind: 'status',
        status: response.status,
        retryable: true,
        retryAfter: response.header('retry-after'),
      );
    }
  }

  Future<LoginResult> password(
    String username,
    String password, {
    bool rememberPassword = false,
  }) async {
    final account = username.trim();
    require(account.isNotEmpty && password.isNotEmpty, '请输入账号和密码');
    require(account.length <= 254 && password.length <= 256, '账号或密码过长');
    final d = await devices.get();
    final login = await post(
      '/xluser.core.login/v3/login',
      {
        ...base(d, '25.0.5.25', '513006'),
        'userName': account,
        'passWord': password,
        'verifyKey': '',
        'verifyCode': '',
        'isMd5Pwd': '0',
      },
      'android-ok-http-client/xl-acc-sdk/version-5.1.3.513006',
    );
    final result = await finish(login, d, account);
    if (!rememberPassword) return result;
    return LoginResult(
      result.credential.withFields({
        'authType': 'passwordToken',
        'username': account,
        'password': password,
      }, preserveRevision: true),
      result.account,
    );
  }

  Future<SmsChallenge> sendSms(String mobile) async {
    require(isMobile(mobile), '请输入接收验证码的手机号');
    final d = await devices.get();
    final j = await post(
      '/xluser.core.login/v3/sendsms',
      {
        ...base(d, XunleiProtocol.version, '231500'),
        'mobile': mobile.trim(),
        'register': '0',
      },
      'android-ok-http-client/xl-acc-sdk/version-5.0.12.512000',
    );
    require(
      (j.str('errorCode').isEmpty || j.str('errorCode') == '0') &&
          (j.str('error').isEmpty || j.str('error') == 'success') &&
          j.str('creditkey').isNotEmpty,
      message(j, '短信发送失败，可重试或使用网页验证'),
    );
    return SmsChallenge(
      mobile.trim(),
      j.str('creditkey'),
      j.str('token'),
      d.id,
    );
  }

  Future<LoginResult> verifySms(SmsChallenge challenge, String code) async {
    require(RegExp(r'^[0-9]{4,8}$').hasMatch(code.trim()), '请输入正确的短信验证码');
    final d = await devices.get();
    require(
      d.id == challenge.deviceId && challenge.creditKey.isNotEmpty,
      '验证已失效，请重新发送验证码',
    );
    final j = await post(
      '/xluser.core.login/v3/smslogin',
      {
        ...base(d, XunleiProtocol.version, '231500', challenge.creditKey),
        'mobile': challenge.mobile,
        'smsCode': code.trim(),
        'token': challenge.token,
        'register': '0',
      },
      'android-ok-http-client/xl-acc-sdk/version-5.0.12.512000',
    );
    return finish(j, d, challenge.mobile);
  }

  Future<HttpResult> appPost(
    String path,
    Json body,
    XunleiDevice d, [
    String captcha = '',
  ]) async {
    RequestScope.checkpoint();
    final response = await http.postJson('$authBase$path', body, {
      'User-Agent': XunleiProtocol.appUa,
      'Accept': 'application/json;charset=UTF-8',
      'X-Client-Id': XunleiProtocol.clientId,
      'X-Device-Id': d.id,
      'X-Client-Version': XunleiProtocol.version,
      if (captcha.isNotEmpty) 'X-Captcha-Token': captcha,
    });
    RequestScope.checkpoint();
    checkAvailable(response);
    return response;
  }

  Future<LoginResult> finish(
    Json login,
    XunleiDevice device,
    String username,
  ) async {
    final code = login.str('errorCode'), error = login.str('error');
    if (!(code == '0' || error == 'success') ||
        login.str('sessionID').isEmpty) {
      if (error == 'review_panel' ||
          code == '1007' ||
          login.str('verifyType').isNotEmpty) {
        final url = XunleiProtocol.trustedPage(login.str('reviewurl'))
            ? login.str('reviewurl')
            : '';
        final uri = Uri.tryParse(url);
        throw XunleiVerificationRequired(
          url,
          uri?.queryParameters['creditkey'] ?? '',
          uri?.queryParameters['token'] ?? '',
          message(login, '请完成安全验证后继续登录'),
          device.id,
        );
      }
      throw AppException(message(login, '登录失败，请检查账号密码或验证码'));
    }
    final timestamp = '${now()}';
    final captchaResponse = await appPost('/v1/shield/captcha/init', {
      'action': 'POST:/auth/signin/token',
      'captcha_token': '',
      'client_id': XunleiProtocol.clientId,
      'device_id': device.id,
      'meta': {
        'username': username,
        'client_version': XunleiProtocol.version,
        'package_name': XunleiProtocol.packageName,
        'timestamp': timestamp,
        'captcha_sign': XunleiProtocol.captchaSign(device.id, timestamp),
        'user_id': login.str('userID'),
      },
      'redirect_uri': 'xlaccsdk01://xunlei.com/callback?state=harbor',
    }, device);
    final captcha = captchaResponse.json.str('captcha_token');
    require(
      captchaResponse.successful && captcha.isNotEmpty,
      message(captchaResponse.json, '安全验证初始化失败，请重试'),
    );
    final response = await appPost(
      '/v1/auth/signin/token',
      {
        'client_id': XunleiProtocol.clientId,
        'client_secret': XunleiProtocol.clientSecret,
        'provider': 'access_end_point_token',
        'signin_token': login.str('sessionID'),
      },
      device,
      captcha,
    );
    final j = response.json,
        access = response.json
            .str('access_token')
            .ifEmpty(response.json.str('accessToken'));
    require(
      response.successful && access.isNotEmpty,
      message(j, '登录凭证获取失败，请重新登录'),
    );
    final refresh = j.str('refresh_token').ifEmpty(j.str('refreshToken')),
        nickname = login.str('nickName').ifEmpty('迅雷用户');
    return LoginResult(
      Credential('迅雷云盘', {
        'primary': access,
        'secondary': refresh,
        'accessToken': access,
        'refreshToken': refresh,
        'captchaToken': captcha,
        'deviceId': device.id,
        'peerId': device.peer,
        'deviceSign': device.sign,
        'clientId': XunleiProtocol.clientId,
        'clientSecret': XunleiProtocol.clientSecret,
        'clientVersion': XunleiProtocol.version,
        'packageName': XunleiProtocol.packageName,
        'userId': login.str('userID'),
        'nickname': nickname,
      }),
      CloudAccount(nickname),
    );
  }
}
