// Explicit, unauthenticated network preflight. Run with flutter test on this
// file; ordinary offline tests never call it or contact a cloud account.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/pan123.dart';
import 'package:asterlink/data/providers/tianyi.dart';
import 'package:asterlink/data/providers/tianyi_captcha.dart';
import 'package:asterlink/data/providers/tianyi_login.dart';
import 'package:asterlink/data/state_store.dart';

class _PreflightComplete implements Exception {}

class _TianyiPreflight extends JsonHttp {
  _TianyiPreflight(this.transport);
  final DioJsonHttp transport;
  final paths = <String>[];
  bool prepared = false;
  int imageType = 0, imageBytes = 0;

  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) async {
    final uri = Uri.parse(url);
    if (uri.path.endsWith('/needcaptcha.do')) {
      final form = Uri.splitQueryString(body! as String);
      expect(form['appKey'], 'cloud');
      expect(form['userName'], matches(RegExp(r'^\{NRP\}(?:[0-9a-f]{2})+$')));
      prepared = true;
      // Stop before any username/password or account-specific captcha check.
      // Request only a fresh anonymous image with the real Dart captcha client.
      final captcha = TianyiCaptchaClient(
        request: (uri) => transport.request(
          'GET',
          uri.toString(),
          headers: {
            'Referer': headers['Referer']!,
            'User-Agent': headers['User-Agent']!,
          },
          followRedirects: false,
        ),
        referer: headers['Referer']!,
        appId: 'cloud',
        checkpoint: () {},
        cancel: () {},
      );
      final image = await captcha.load();
      imageType = image.type;
      imageBytes = image.background.length;
      expect(imageType, isIn([1, 2]));
      expect(imageBytes, greaterThan(0));
      throw _PreflightComplete();
    }
    expect(uri.scheme, 'https');
    expect(uri.host, isIn(['cloud.189.cn', 'open.e.189.cn']));
    expect(uri.path, isNot(endsWith('/loginSubmit.do')));
    if (method == 'POST') {
      expect(
        uri.path,
        isIn([
          '/api/logbox/oauth2/appConf.do',
          '/api/logbox/config/encryptConf.do',
        ]),
      );
    }
    paths.add(uri.path);
    return transport.request(
      method,
      url,
      body: body,
      headers: headers,
      followRedirects: followRedirects,
      contentType: contentType,
    );
  }
}

void main() {
  test(
    'Official login configuration and anonymous captcha remain compatible',
    () async {
      final transport = DioJsonHttp(),
          tianyiTransport = _TianyiPreflight(DioJsonHttp());
      try {
        final tianyi = TianyiLoginService(
          tianyiTransport,
          TianyiConnector(tianyiTransport),
        );
        await expectLater(
          tianyi.password('local-preflight-only', 'local-preflight-only'),
          throwsA(isA<_PreflightComplete>()),
        );
        expect(tianyiTransport.prepared, isTrue);
        final pan123 = Pan123Connector(transport, Vault(StateStore.memory()));
        final response = await transport.request(
          'POST',
          'https://user.123pan.cn/api/user/sign_in',
          body: encoded({'passport': '', 'password': '', 'remember': false}),
          headers: {
            'platform': 'web',
            'app-version': '132',
            'loginuuid': await pan123.loginUuid(),
            'Origin': 'https://user.123pan.cn',
            'Referer': 'https://user.123pan.cn/',
            'User-Agent': Pan123Connector.webUa,
          },
          contentType: 'application/json; charset=utf-8',
          followRedirects: false,
        );
        expect(response.status, 200);
        expect(response.json.integer('code'), 1);
        final report = {
          'checkedUtc': DateTime.now().toUtc().toIso8601String(),
          'passed': true,
          'tianyi': {
            'officialSsoConfigurationLoaded': true,
            'officialRsaConfigurationUsed': true,
            'rsaCiphertextIsHexadecimal': true,
            'anonymousCaptchaDecodedByDart': true,
            'captchaType': tianyiTransport.imageType,
            'captchaBackgroundBytes': tianyiTransport.imageBytes,
            'configurationPaths': tianyiTransport.paths,
            'stoppedBeforeUsernameOrPasswordSubmission': true,
            'captchaSolvedOrSubmitted': false,
          },
          'pan123': {
            'emptyFormHttpStatus': response.status,
            'emptyFormCode': response.json.integer('code'),
          },
          'realAccountCredentialsUsed': false,
          'authenticatedLoginVerified': false,
          'webViewDeviceVerified': false,
        };
        await File('docs/PUBLIC-LOGIN-PREFLIGHT.json').writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n',
        );
      } finally {
        transport.dio.close(force: true);
        tianyiTransport.transport.dio.close(force: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 55)),
  );
}
