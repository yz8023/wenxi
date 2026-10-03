import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';
import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/tianyi.dart';
import 'package:asterlink/data/providers/tianyi_login.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

/// Generated in memory for each test process; never a real account/signing key.
class LoginTestKey {
  LoginTestKey() {
    final generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), 1024, 32),
          FortunaRandom()..seed(KeyParameter(CryptoBox.random(32))),
        ),
      );
    final pair = generator.generateKeyPair();
    public = pair.publicKey;
    private = pair.privateKey;
    final inner = ASN1Sequence()
      ..add(ASN1Integer(public.modulus!))
      ..add(ASN1Integer(public.exponent!));
    pkcs1 = base64Encode(inner.encode());
    final algorithm = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromIdentifierString('1.2.840.113549.1.1.1'))
      ..add(ASN1Null());
    final outer = ASN1Sequence()
      ..add(algorithm)
      ..add(ASN1BitString(stringValues: inner.encode()));
    spki = base64Encode(outer.encode());
  }
  late final RSAPublicKey public;
  late final RSAPrivateKey private;
  late final String pkcs1, spki;
  String decrypt(String ciphertext) {
    final cipher = PKCS1Encoding(RSAEngine())
      ..init(false, PrivateKeyParameter<RSAPrivateKey>(private));
    return utf8.decode(cipher.process(base64Decode(ciphertext)));
  }

  List<int> decryptTianyiBytes(String ciphertext) {
    final hex = ciphertext.replaceFirst('{NRP}', '');
    if (!RegExp(r'^(?:[0-9a-f]{2})+$').hasMatch(hex)) {
      throw const FormatException('Tianyi requires hexadecimal RSA ciphertext');
    }
    final cipher = PKCS1Encoding(RSAEngine())
      ..init(false, PrivateKeyParameter<RSAPrivateKey>(private));
    return cipher.process(
      Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]),
    );
  }

  String decryptTianyi(String ciphertext) =>
      utf8.decode(decryptTianyiBytes(ciphertext));
}

class LoginHttp extends FakeHttp {
  LoginHttp(super.respond);
  final redirects = <bool>[];
  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) {
    redirects.add(followRedirects);
    return super.request(
      method,
      url,
      body: body,
      headers: headers,
      followRedirects: followRedirects,
      contentType: contentType,
    );
  }
}

Json loginForm(RecordedRequest r) => r.method == 'GET'
    ? r.uri.queryParameters
    : Uri.splitQueryString(r.body as String);
HttpResult loginRedirect(String url, [List<String> cookies = const []]) =>
    HttpResult(302, '', {
      'location': [url],
      'set-cookie': cookies,
    });
const tianyiFixtureSso =
    'https://open.e.189.cn/api/logbox/separate/web/index.html?appId=cloud&lt=fixture-lt&reqId=fixture-req';
const tianyiFixtureReturn =
    'https://cloud.189.cn/api/portal/callbackUnify.action?redirectURL=https%3A%2F%2Fcloud.189.cn%2Fweb%2Fredirect.html';
const tianyiFixtureCallback =
    'https://cloud.189.cn/api/portal/callbackUnify.action?ticket=fixture-ticket';

class TianyiLoginFixture {
  TianyiLoginFixture(this.key, {StateStore? store})
    : store = store ?? StateStore.memory() {
    http = LoginHttp(respond);
    connector = TianyiConnector(
      http,
      store: vault,
      passwordLogin: (username, password) =>
          service.password(username, password),
    );
    service = TianyiLoginService(http, connector);
    login = AccountLoginService(
      vault,
      (_, c) => connector.account(c),
      webAuthenticators: {CloudPlatform.tianyi: connector.authenticate},
    );
  }
  final LoginTestKey key;
  final StateStore store;
  late final vault = Vault(store);
  late final LoginHttp http;
  late final TianyiConnector connector;
  late final TianyiLoginService service;
  late final AccountLoginService login;
  int needCaptcha = 0;
  Json signIn = {'result': 0, 'toUrl': tianyiFixtureCallback};
  FutureOr<HttpResult?> Function(RecordedRequest)? override;
  Future<HttpResult> respond(RecordedRequest request) async {
    final response = await override?.call(request);
    if (response != null) return response;
    switch (request.uri.path) {
      case '/api/portal/loginUrl.action':
        return loginRedirect(tianyiFixtureSso, [
          'bootstrap=cloud; Path=/; Secure',
        ]);
      case '/api/logbox/separate/web/index.html':
        return const HttpResult(200, '<html>official login fixture</html>', {
          'set-cookie': [
            'COOKIE_LOGIN_USER=sso-only; Domain=open.e.189.cn; Path=/; Secure',
            'JSESSIONID=sso-session; Path=/; HttpOnly',
          ],
        });
      case '/api/logbox/oauth2/appConf.do':
        return jsonResponse({
          'result': 0,
          'data': {
            'appKey': 'cloud',
            'pageKey': 'normal',
            'accountType': '01',
            'clientType': 1,
            'isOauth2': true,
            'returnUrl': tianyiFixtureReturn,
            'paramId': 'fixture-param',
            'mailSuffix': '@189.cn',
          },
        });
      case '/api/logbox/config/encryptConf.do':
        return jsonResponse({
          'result': 0,
          'data': {'pre': '{NRP}', 'pubKey': key.spki},
        });
      case '/api/logbox/oauth2/needcaptcha.do':
        return HttpResult(200, '$needCaptcha');
      case '/api/logbox/oauth2/loginSubmit.do':
        return jsonResponse(signIn);
      case '/api/portal/callbackUnify.action':
        return loginRedirect('/web/redirect.html', [
          'COOKIE_LOGIN_USER=cloud-login; Domain=cloud.189.cn; Path=/; HttpOnly; Secure',
        ]);
      case '/web/redirect.html':
        return const HttpResult(200, '<html>cloud redirect fixture</html>');
      case '/api/open/user/getUserInfoForPortal.action':
        return jsonResponse({
          'res_code': 0,
          'loginName': 'fixture-user',
          'userId': 'fixture-user-id',
          'userExtResp': {'nickName': '天翼测试用户'},
        });
      case '/api/portal/getUserSizeInfo.action':
        return jsonResponse({
          'res_code': 0,
          'cloudCapacityInfo': {'totalSize': '1000', 'usedSize': '120'},
        });
      case '/api/logbox/oauth2/sendSmsCodeForSecondAuth.do':
        return jsonResponse({'result': 0});
      case '/api/logbox/oauth2/submitForSecondAuth.do':
        return jsonResponse({'result': 0, 'toUrl': tianyiFixtureCallback});
      default:
        throw StateError('Unexpected login fixture path: ${request.uri.path}');
    }
  }

  Future<LoginResult> submit({
    TianyiCaptchaPrompt? captcha,
    TianyiSmsPrompt? sms,
  }) => login.submit(
    CloudPlatform.tianyi,
    (_) => service.password(
      'fixture-user',
      ' Password + 文 ',
      verifyCaptcha: captcha,
      verifySms: sms,
    ),
  );
}

/// Flat, generated PNGs: contain no captured or solved provider challenges.
String loginTestPng(int width, int height) {
  List<int> word(int value) =>
      (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
  List<int> chunk(String name, List<int> content) {
    final bytes = [...ascii.encode(name), ...content];
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = crc.isOdd ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    return [
      ...word(content.length),
      ...bytes,
      ...word((crc ^ 0xffffffff) & 0xffffffff),
    ];
  }

  final pixels = <int>[
    for (var y = 0; y < height; y++) ...[
      0,
      for (var x = 0; x < width; x++) ...[100, 160, 220, 255],
    ],
  ];
  return 'data:image/png;base64,${base64Encode([
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    ...chunk('IHDR', [...word(width), ...word(height), 8, 6, 0, 0, 0]),
    ...chunk('IDAT', ZLibEncoder().convert(pixels)),
    ...chunk('IEND', []),
  ])}';
}
