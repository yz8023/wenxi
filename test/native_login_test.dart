import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/core/login_crypto.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/login_cookies.dart';
import 'package:asterlink/data/providers/pan123.dart';
import 'package:asterlink/data/providers/tianyi_captcha.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/redaction.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'native_login_support.dart';
import 'support.dart';

Matcher fails(String message) => throwsA(
  isA<AppException>().having((e) => e.message, 'message', contains(message)),
);

void main() {
  late LoginTestKey key;
  setUpAll(() => key = LoginTestKey());

  group('Login encryption', () {
    test(
      'Current SPKI and PKCS1 public keys use random PKCS1 padding and retain Unicode/password spaces',
      () {
        const plain = ' Password + 文 ';
        for (final public in [
          key.spki,
          key.pkcs1,
          '-----BEGIN PUBLIC KEY-----\n${key.spki}\n-----END PUBLIC KEY-----',
        ]) {
          final rsa = LoginRsa(public),
              first = rsa.encrypt(plain),
              second = rsa.encrypt(plain);
          expect(first, isNot(second));
          expect(base64Decode(first), hasLength(128));
          expect(key.decrypt(first), plain);
          expect(key.decrypt(second), plain);
        }
      },
    );
    test('Malformed keys and oversized multibyte credentials are rejected', () {
      expect(() => LoginRsa('not-a-public-key'), fails('加密公钥'));
      expect(() => LoginRsa(key.spki).encrypt('文' * 80), fails('过长'));
    });
    test(
      'Tianyi matches bytes decoded from the official public RSA bundle',
      () {
        // Independent reference: captch.min.js?v1.1, SHA-256
        // 5262a4404254691a558536eae1201fcef43f3bb008cd7c3ab6f7eed7188fb75e.
        // Generated ephemeral RSA keys decoded its output with PKCS1 v1.5.
        final rsa = LoginRsa(key.spki);
        for (final sample in {
          '13800000000': '3133383030303030303030',
          ' Test+password ': '20546573742b70617373776f726420',
          '测试密码': 'e6b58be8af95e5af86e7a081',
          'Test😀123': '54657374eda0bdedb880313233',
        }.entries) {
          final first = rsa.encryptTianyi(sample.key);
          expect(first, matches(RegExp(r'^(?:[0-9a-f]{2})+$')));
          expect(first.length, lessThanOrEqualTo(256));
          expect(first, isNot(rsa.encryptTianyi(sample.key)));
          expect(
            key
                .decryptTianyiBytes(first)
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join(),
            sample.value,
          );
        }
        expect(() => rsa.encryptTianyi('😀' * 20), fails('过长'));
      },
    );
  });

  group('Login cookie isolation', () {
    test(
      'Only domain- and path-matching cookies reach the cloud callback/API',
      () {
        final jar = LoginCookieJar({'cloud.189.cn', 'open.e.189.cn', '189.cn'});
        jar.absorb(
          Uri.parse(tianyiFixtureSso),
          const HttpResult(200, '', {
            'set-cookie': [
              'sso=private; Path=/; Secure',
              'foreign=bad; Domain=attacker.invalid; Path=/',
              'publicSuffix=bad; Domain=cn; Path=/',
              'family=shared; Domain=.189.cn; Path=/; Secure',
            ],
          }),
        );
        jar.absorb(
          Uri.parse(tianyiFixtureCallback),
          const HttpResult(200, '', {
            'set-cookie': [
              'COOKIE_LOGIN_USER=cloud; Path=/api; Secure; HttpOnly',
              'portal=only; Path=/api/portal; Secure',
              'deleted=gone; Max-Age=0; Path=/',
            ],
          }),
        );
        final api = jar.header(
          Uri.parse('https://cloud.189.cn/api/open/user/info'),
        );
        expect(api, contains('COOKIE_LOGIN_USER=cloud'));
        expect(api, contains('family=shared'));
        for (final absent in [
          'private',
          'foreign',
          'publicSuffix',
          'portal=',
          'deleted=',
        ]) {
          expect(api, isNot(contains(absent)));
        }
        expect(
          jar.header(Uri.parse('https://cloud.189.cn/apix')),
          isNot(contains('COOKIE_LOGIN_USER')),
        );
        expect(jar.header(Uri.parse('http://cloud.189.cn/api')), isEmpty);
        expect(jar.header(Uri.parse('https://attacker.invalid/api')), isEmpty);
        expect(jar.header(Uri.parse('https://cloud.189.cn')), 'family=shared');
      },
    );
    test(
      'Expiry, replacement and explicit deletion clear only the matching cookie',
      () {
        var now = DateTime.utc(2026, 1, 1);
        final jar = LoginCookieJar({'cloud.189.cn'}, clock: () => now),
            uri = Uri.parse('https://cloud.189.cn/api/callback');
        jar.absorb(
          uri,
          const HttpResult(200, '', {
            'Set-Cookie': [
              'a=old; Path=/; Max-Age=10',
              'b=keep; Path=/; Secure',
              'expired=no; Path=/; Expires=Wed, 01 Jan 2020 00:00:00 GMT',
            ],
          }),
        );
        jar.absorb(
          uri,
          const HttpResult(200, '', {
            'set-cookie': ['a=new; Path=/; Max-Age=5'],
          }),
        );
        expect(jar.header(uri), contains('a=new'));
        expect(jar.header(uri), isNot(contains('a=old')));
        now = now.add(const Duration(seconds: 6));
        expect(jar.header(uri), 'b=keep');
        jar.absorb(
          uri,
          const HttpResult(200, '', {
            'set-cookie': ['b=gone; Path=/; Max-Age=0'],
          }),
        );
        expect(jar.header(uri), isEmpty);
        jar.clear();
      },
    );
  });

  group('Tianyi native password flow', () {
    test(
      'Uses official fields/RSA, scopes redirects and remembers validated password credentials',
      () async {
        final fixture = TianyiLoginFixture(key);
        final result = await fixture.submit();
        final calls = fixture.http.calls;
        expect(fixture.http.redirects, everyElement(isFalse));
        final app = calls.singleWhere(
          (r) => r.uri.path.endsWith('/appConf.do'),
        );
        expect(loginForm(app), {'version': '2.0', 'appKey': 'cloud'});
        expect(app.headers['lt'], 'fixture-lt');
        expect(app.headers['reqId'], 'fixture-req');
        final login = calls.singleWhere(
          (r) => r.uri.path.endsWith('/loginSubmit.do'),
        );
        final fields = loginForm(login);
        expect(fields.str('version'), 'v2.0');
        expect(fields.str('dynamicCheck'), 'FALSE');
        expect(
          fields.str('returnUrl'),
          Uri.encodeComponent(tianyiFixtureReturn),
        );
        expect(fields.str('epd'), startsWith('{NRP}'));
        expect(key.decryptTianyi(fields.str('epd')), ' Password + 文 ');
        expect(key.decryptTianyi(fields.str('userName')), 'fixture-user');
        final preflight = loginForm(
          calls.singleWhere((r) => r.uri.path.endsWith('/needcaptcha.do')),
        );
        expect(key.decryptTianyi(preflight.str('userName')), 'fixture-user');
        expect(login.body, isNot(contains('Password')));
        final cloudCalls = calls.where((r) => r.uri.host == 'cloud.189.cn');
        for (final call in cloudCalls) {
          expect(call.headers['Cookie'] ?? '', isNot(contains('sso-only')));
          expect(call.headers.containsKey('lt'), isFalse);
          expect(call.headers.containsKey('reqId'), isFalse);
        }
        expect(result.account.nickname, '天翼测试用户');
        expect(result.account.used, 120);
        expect(
          result.credential.primary,
          contains('COOKIE_LOGIN_USER=cloud-login'),
        );
        expect(result.credential.primary, isNot(contains('sso-only')));
        expect(result.credential.secondary, isEmpty);
        expect(result.credential.field('authType'), 'passwordCookie');
        expect(result.credential.field('username'), 'fixture-user');
        expect(result.credential.field('password'), ' Password + 文 ');
        expect(result.credential.field('userId'), 'fixture-user-id');
        expect(result.credential.field('loginName'), 'fixture-user');
        expect(encoded(fixture.store.data), isNot(contains('{NRP}')));
      },
    );
    test(
      'Quota outages do not reject a separately verified identity',
      () async {
        final fixture = TianyiLoginFixture(key)
          ..override = (r) => r.uri.path.contains('getUserSizeInfo')
              ? const HttpResult(503, '{}')
              : null;
        expect((await fixture.submit()).account.nickname, '天翼测试用户');
      },
    );
    test('Missing identity never replaces an existing account', () async {
      final fixture = TianyiLoginFixture(key);
      final old = Credential('old', {
        'primary': 'COOKIE_LOGIN_USER=old',
      }, updatedAt: 1);
      await fixture.vault.putCredential(CloudPlatform.tianyi, old);
      fixture.override = (r) => r.uri.path.contains('getUserInfoForPortal')
          ? jsonResponse({'res_code': 0})
          : null;
      await expectLater(fixture.submit(), fails('账号信息'));
      expect(
        fixture.vault.credential(CloudPlatform.tianyi)!.sameAs(old),
        isTrue,
      );
    });
    test(
      'Password rejection is not retried and raw server text is never surfaced',
      () async {
        final fixture = TianyiLoginFixture(key)
          ..signIn = {'result': -16, 'msg': 'Password + 文'};
        await expectLater(fixture.submit(), fails('账号或密码错误'));
        expect(
          fixture.http.calls.where(
            (r) => r.uri.path.endsWith('/loginSubmit.do'),
          ),
          hasLength(1),
        );
        expect(fixture.vault.credential(CloudPlatform.tianyi), isNull);
      },
    );
    for (final url in [
      'https://attacker.invalid/grab',
      'https://cloud.189.cn.attacker.invalid/grab',
      'http://cloud.189.cn/api/portal/callbackUnify.action',
      'https://user:pass@cloud.189.cn/api/',
      'https://cloud.189.cn:444/api/',
    ]) {
      test(
        'Rejects unsafe credential callback: ${Uri.parse(url).authority}',
        () async {
          final fixture = TianyiLoginFixture(key)
            ..signIn = {'result': 0, 'toUrl': url};
          await expectLater(fixture.submit(), fails('登录跳转无效'));
          expect(fixture.http.calls.any((r) => r.url == url), isFalse);
          expect(fixture.vault.credential(CloudPlatform.tianyi), isNull);
        },
      );
    }
    test(
      'Redirect loops terminate without saving the SSO-only cookie',
      () async {
        final fixture = TianyiLoginFixture(key)
          ..override = (r) => r.uri.path.contains('callbackUnify')
              ? loginRedirect(tianyiFixtureCallback)
              : null;
        await expectLater(fixture.submit(), fails('登录跳转无效'));
        expect(fixture.vault.credential(CloudPlatform.tianyi), isNull);
      },
    );
    test(
      'No unencrypted password is sent if encryption configuration is incomplete',
      () async {
        final fixture = TianyiLoginFixture(key)
          ..override = (r) => r.uri.path.endsWith('/encryptConf.do')
              ? jsonResponse({
                  'result': 0,
                  'data': {'pre': '{NRP}'},
                })
              : null;
        await expectLater(fixture.submit(), fails('加密公钥'));
        expect(
          fixture.http.calls.any((r) => r.uri.path.endsWith('/loginSubmit.do')),
          isFalse,
        );
      },
    );
    test(
      'Captcha-required preflight waits for a human completion proof',
      () async {
        final fixture = TianyiLoginFixture(key)..needCaptcha = 1;
        final entered = Completer<void>(),
            answer = Completer<TianyiCaptchaProof?>();
        final pending = fixture.submit(
          captcha: (_) {
            entered.complete();
            return answer.future;
          },
        );
        await entered.future;
        expect(
          fixture.http.calls.any((r) => r.uri.path.endsWith('/loginSubmit.do')),
          isFalse,
        );
        answer.complete(
          const TianyiCaptchaProof(2, 'verified-token', 'verified-proof'),
        );
        await pending;
        final fields = loginForm(
          fixture.http.calls.singleWhere(
            (r) => r.uri.path.endsWith('/loginSubmit.do'),
          ),
        );
        expect(fields.str('captchaType'), '2');
        expect(fields.str('captchaToken'), 'verified-token');
        expect(fields.str('validateCode'), 'verified-proof');
        expect(fields.str('smsValidateCode'), 'verified-proof');
      },
    );
    test(
      'Server-requested captcha after sign-in is shown before resubmission',
      () async {
        final fixture = TianyiLoginFixture(key)..signIn = {'result': -2};
        var prompts = 0;
        await fixture.submit(
          captcha: (_) async {
            prompts++;
            fixture.signIn = {'result': 0, 'toUrl': tianyiFixtureCallback};
            return const TianyiCaptchaProof(1, 'verified', 'proof');
          },
        );
        expect(prompts, 1);
        expect(
          fixture.http.calls.where(
            (r) => r.uri.path.endsWith('/loginSubmit.do'),
          ),
          hasLength(2),
        );
      },
    );
    test(
      'Cancelling captcha preserves the old account and never submits the password',
      () async {
        final fixture = TianyiLoginFixture(key)..needCaptcha = 1;
        final old = Credential('old', {
          'primary': 'COOKIE_LOGIN_USER=old',
        }, updatedAt: 1);
        await fixture.vault.putCredential(CloudPlatform.tianyi, old);
        await expectLater(
          fixture.submit(
            captcha: (client) async {
              client.cancel();
              return null;
            },
          ),
          fails('取消'),
        );
        expect(
          fixture.vault.credential(CloudPlatform.tianyi)!.sameAs(old),
          isTrue,
        );
        expect(
          fixture.http.calls.any((r) => r.uri.path.endsWith('/loginSubmit.do')),
          isFalse,
        );
      },
    );
    test(
      'Logout while captcha is visible cannot resurrect the account',
      () async {
        final fixture = TianyiLoginFixture(key)..needCaptcha = 1;
        final entered = Completer<void>(),
            answer = Completer<TianyiCaptchaProof?>();
        final pending = fixture.submit(
          captcha: (_) {
            entered.complete();
            return answer.future;
          },
        );
        final assertion = expectLater(pending, fails('取消'));
        await entered.future;
        await fixture.login.remove(CloudPlatform.tianyi);
        answer.complete(const TianyiCaptchaProof(1, 'proof-token', 'proof'));
        await assertion;
        expect(fixture.vault.credential(CloudPlatform.tianyi), isNull);
        expect(
          fixture.http.calls.any((r) => r.uri.path.endsWith('/loginSubmit.do')),
          isFalse,
        );
      },
    );
    test(
      'A newer account is preserved if the old login finishes late',
      () async {
        final fixture = TianyiLoginFixture(key),
            entered = Completer<void>(),
            response = Completer<HttpResult>();
        fixture.override = (r) {
          if (!r.uri.path.contains('getUserInfoForPortal')) return null;
          entered.complete();
          return response.future;
        };
        final pending = fixture.submit(), assertion = expectLater;
        final completion = assertion(pending, fails('账号已发生变化'));
        await entered.future;
        final newer = Credential('new', {
          'primary': 'COOKIE_LOGIN_USER=newer',
        }, updatedAt: 8);
        await fixture.vault.putCredential(CloudPlatform.tianyi, newer);
        response.complete(
          jsonResponse({'res_code': 0, 'loginName': 'old-login-user'}),
        );
        await completion;
        expect(
          fixture.vault.credential(CloudPlatform.tianyi)!.sameAs(newer),
          isTrue,
        );
      },
    );
    test(
      'SMS second auth stays native, enforces send cooldown and encrypts the code',
      () async {
        final fixture = TianyiLoginFixture(key)
          ..signIn = {
            'result': -133,
            'mobile': 'opaque-bound-mobile',
            'showName': '138****0000',
          };
        await fixture.submit(
          sms: (challenge) async {
            expect(challenge.phoneHint, '138****0000');
            await challenge.sendCode();
            await expectLater(challenge.sendCode(), fails('稍后'));
            expect(challenge.resendSeconds, inInclusiveRange(59, 60));
            return challenge.verify('123456');
          },
        );
        final fields = loginForm(
          fixture.http.calls.singleWhere(
            (r) => r.uri.path.endsWith('/submitForSecondAuth.do'),
          ),
        );
        expect(key.decryptTianyi(fields.str('epd')), '123456');
        expect(fields.str('mobile'), 'opaque-bound-mobile');
        expect(key.decryptTianyi(fields.str('userName')), 'fixture-user');
        expect(
          fixture.http.calls.where(
            (r) => r.uri.path.endsWith('/sendSmsCodeForSecondAuth.do'),
          ),
          hasLength(1),
        );
      },
    );
    test(
      'An incorrect SMS code can be corrected without password reauthentication',
      () async {
        final fixture = TianyiLoginFixture(key)
          ..signIn = {'result': -133, 'mobile': 'bound'};
        var attempts = 0;
        fixture.override = (r) =>
            r.uri.path.endsWith('/submitForSecondAuth.do') && attempts++ == 0
            ? jsonResponse({'result': 51177})
            : null;
        await fixture.submit(
          sms: (challenge) async {
            await expectLater(challenge.verify('000000'), fails('验证码错误'));
            return challenge.verify('123456');
          },
        );
        expect(
          fixture.http.calls.where(
            (r) => r.uri.path.endsWith('/loginSubmit.do'),
          ),
          hasLength(1),
        );
      },
    );
  });

  group('123 native password flow', () {
    late StateStore store;
    late Vault vault;
    late LoginHttp http;
    late Pan123Connector connector;
    late AccountLoginService login;
    setUp(() {
      store = StateStore.memory();
      vault = Vault(store);
      http = LoginHttp(
        (r) => r.uri.path.endsWith('/sign_in')
            ? jsonResponse({
                'code': 200,
                'data': {'token': 'candidate-token'},
              })
            : jsonResponse({
                'code': 0,
                'data': {
                  'Nickname': '123测试用户',
                  'SpaceUsed': 12,
                  'SpacePermanent': 100,
                  'SpaceTemp': 0,
                },
              }),
      );
      connector = Pan123Connector(http, vault);
      login = AccountLoginService(vault, (_, c) => connector.account(c));
    });
    test(
      'Authenticates once, retains the exact password for renewal and reads quota using the token',
      () async {
        await vault.putSecret('pan123.access_token', 'old-cache');
        final result = await login.submit(
          CloudPlatform.pan123,
          (_) => connector.password(' fixture-phone ', ' Password + 文 '),
        );
        final request = http.calls.first;
        expect(request.json, {
          'passport': 'fixture-phone',
          'password': ' Password + 文 ',
          'remember': false,
        });
        expect(request.uri.host, 'user.123pan.cn');
        expect(http.redirects.first, isFalse);
        expect(request.headers['platform'], 'web');
        expect(request.headers['app-version'], '132');
        expect(request.headers['loginuuid'], isNotEmpty);
        expect(
          http.calls.last.headers['authorization'],
          'Bearer candidate-token',
        );
        expect(result.credential.field('accessToken'), 'candidate-token');
        expect(result.credential.primary, 'fixture-phone');
        expect(result.credential.field('secondary'), ' Password + 文 ');
        expect(result.credential.field('authType'), 'password');
        expect(vault.secret('pan123.access_token'), isNull);
        expect((await connector.account(result.credential)).used, 12);
        expect(
          http.calls.where((r) => r.uri.path.endsWith('/sign_in')),
          hasLength(1),
        );
      },
    );
    test(
      'Bad password does not clear old credentials or cached token and cannot echo the password',
      () async {
        final old = Credential('old', {
          'primary': 'old-user',
          'secondary': 'old-secret',
        }, updatedAt: 1);
        await vault.putCredential(CloudPlatform.pan123, old);
        await vault.putSecret('pan123.access_token', 'old-cache');
        final rejected = Pan123Connector(
          LoginHttp(
            (_) =>
                jsonResponse({'code': 401, 'message': 'rejected NewPassword!'}),
          ),
          vault,
        );
        await expectLater(
          login.submit(
            CloudPlatform.pan123,
            (_) => rejected.password('new-user', 'NewPassword!'),
          ),
          fails('检查账号和密码'),
        );
        expect(vault.credential(CloudPlatform.pan123)!.sameAs(old), isTrue);
        expect(vault.secret('pan123.access_token'), 'old-cache');
      },
    );
    test(
      'Mandatory verification and throttling give explicit errors without opening a browser',
      () async {
        for (final (code, message, expected) in [
          (401, '请完成安全验证', '网页登录'),
          (429, '', '频繁'),
        ]) {
          final denied = Pan123Connector(
            LoginHttp((_) => jsonResponse({'code': code, 'message': message})),
            vault,
          );
          await expectLater(
            denied.password('account', 'password'),
            fails(expected),
          );
        }
      },
    );
    test(
      'An unvalidated token and a redirect cannot become a saved login',
      () async {
        final bad = Pan123Connector(
          LoginHttp(
            (r) => r.uri.path.endsWith('/sign_in')
                ? jsonResponse({
                    'code': 200,
                    'data': {'token': 'invalid-token'},
                  })
                : jsonResponse({'code': 401}),
          ),
          vault,
        );
        await expectLater(
          login.submit(CloudPlatform.pan123, (_) => bad.password('u', 'p')),
          fails('登录已失效'),
        );
        expect(vault.credential(CloudPlatform.pan123), isNull);
        final redirect = LoginHttp(
          (_) => loginRedirect('https://attacker.invalid'),
        );
        await expectLater(
          Pan123Connector(redirect, vault).password('u', 'p'),
          fails('接口发生变化'),
        );
        expect(redirect.calls, hasLength(1));
        expect(redirect.redirects, [false]);
      },
    );
    test('Cancelling a slow sign-in cannot save its eventual token', () async {
      final entered = Completer<void>(), answer = Completer<HttpResult>();
      final slow = Pan123Connector(
        LoginHttp((_) {
          entered.complete();
          return answer.future;
        }),
        vault,
      );
      final pending = login.submit(
        CloudPlatform.pan123,
        (_) => slow.password('u', 'p'),
      );
      final result = expectLater(pending, fails('取消'));
      await entered.future;
      login.invalidate(CloudPlatform.pan123);
      answer.complete(
        jsonResponse({
          'code': 200,
          'data': {'token': 'late'},
        }),
      );
      await result;
      expect(vault.credential(CloudPlatform.pan123), isNull);
    });
  });

  group('Tianyi captcha protocol', () {
    late TianyiCaptchaClient client;
    late DateTime now;
    var requests = 0, type = 1, corruptProof = false;
    final payloads = <Json>[];
    setUp(() {
      requests = 0;
      type = 1;
      corruptProof = false;
      payloads.clear();
      now = DateTime.utc(2026, 1, 1);
      client = TianyiCaptchaClient(
        referer: tianyiFixtureSso,
        appId: 'cloud',
        checkpoint: () {},
        cancel: () {},
        encryption: LoginRsa(key.spki),
        clock: () => now,
        request: (uri) async {
          requests++;
          final args = uri.queryParameters,
              aes = base64Decode(key.decrypt(args['cp']!));
          final hex = args['pb']!;
          final body = [
            for (var i = 0; i < hex.length; i += 2)
              int.parse(hex.substring(i, i + 2), radix: 16),
          ];
          payloads.add(
            asJson(
              jsonDecode(utf8.decode(CryptoBox.aesCbc(false, body, aes, aes))),
            ),
          );
          expect(args['version'], '1.0.1');
          expect(args['appId'], 'cloud');
          Json result;
          if (uri.path.endsWith('/get.do')) {
            result = {
              'result': '0',
              'data': {
                'captchaType': type,
                'token': 'challenge-$requests',
                'bg': loginTestPng(310, 155),
                'front': type == 1 ? loginTestPng(47, 155) : '[山,水,月]',
              },
            };
          } else {
            final proof = {
              'captchaType': type,
              'token': 'verified-token',
              'validate': 'verified-proof',
            };
            final encrypted = CryptoBox.aesCbc(
              true,
              utf8.encode(encoded(proof)),
              aes,
              aes,
            );
            result = {
              'result': '0',
              'data': corruptProof
                  ? 'bad-data'
                  : encrypted
                        .map((b) => b.toRadixString(16).padLeft(2, '0'))
                        .join()
                        .toUpperCase(),
            };
          }
          return HttpResult(200, '${args['callback']}(${encoded(result)});');
        },
      );
    });
    for (final captchaType in [1, 2]) {
      test(
        'Type $captchaType encrypts actual gesture data and validates the returned proof',
        () async {
          type = captchaType;
          final challenge = await client.load();
          expect(challenge.background, isNotEmpty);
          if (type == 2) expect(challenge.instruction, '山、水、月');
          final gesture = TianyiCaptchaGesture(
            type == 1
                ? [
                    {'x': 125.5, 'y': 0},
                  ]
                : [
                    {'x': 10, 'y': 30},
                    {'x': 60, 'y': 80},
                    {'x': 100, 'y': 20},
                  ],
            type == 1
                ? [
                    {'pointDiff': 0, 'timeDiff': 0},
                    {'pointDiff': 125, 'timeDiff': 2300},
                  ]
                : [],
            2300,
          );
          final proof = await client.verify(challenge, gesture);
          expect(proof.type, type);
          expect(proof.token, 'verified-token');
          expect(proof.validate, 'verified-proof');
          expect(payloads.last['points'], gesture.points);
          expect(payloads.last['rates'], gesture.rates);
          expect(payloads.last['dragTime'], 2300);
          expect(payloads.first['finger'], payloads.last['finger']);
          expect(payloads.last['token'], challenge.token);
        },
      );
    }
    test(
      'Stale, expired, and already-submitted captcha images are rejected',
      () async {
        const gesture = TianyiCaptchaGesture(
          [
            {'x': 100, 'y': 0},
          ],
          [],
          2000,
        );
        final old = await client.load(), current = await client.load();
        await expectLater(client.verify(old, gesture), fails('已更新'));
        await client.verify(current, gesture);
        await expectLater(client.verify(current, gesture), fails('已更新'));
        final expired = await client.load();
        now = now.add(const Duration(minutes: 4));
        final previous = requests;
        await expectLater(client.verify(expired, gesture), fails('已过期'));
        expect(requests, previous);
      },
    );
    test(
      'Corrupt proofs and invalid positions cannot pass verification',
      () async {
        final challenge = await client.load();
        await expectLater(
          client.verify(
            challenge,
            const TianyiCaptchaGesture(
              [
                {'x': -5, 'y': 0},
              ],
              [],
              2000,
            ),
          ),
          fails('坐标无效'),
        );
        corruptProof = true;
        await expectLater(
          client.verify(
            challenge,
            const TianyiCaptchaGesture(
              [
                {'x': 100, 'y': 0},
              ],
              [],
              2000,
            ),
          ),
          fails('响应无效'),
        );
      },
    );
    test(
      'HTML/remote image URLs are not executed or fetched as captcha images',
      () async {
        final malformed = TianyiCaptchaClient(
          referer: tianyiFixtureSso,
          appId: 'cloud',
          checkpoint: () {},
          cancel: () {},
          request: (_) async => jsonResponse({
            'result': 0,
            'data': {
              'captchaType': 1,
              'token': 't',
              'bg': 'https://attacker.invalid/image',
              'front': 'x',
            },
          }),
        );
        await expectLater(malformed.load(), fails('图片格式已变化'));
      },
    );
  });

  test(
    'Password login diagnostics redact encrypted credentials, SSO tickets and verification data',
    () {
      final values = {
        'userName': '{NRP}c2VjcmV0',
        'epd': '{NRP}cGFzc3dvcmQ=',
        'passport': 'private-account',
        'lt': 'private-lt',
        'reqId': 'private-req',
        'paramId': 'private-param',
        'mobile': 'private-mobile',
        'captchaToken': 'private-token',
        'validateCode': 'private-proof',
        'cp': 'private-cp',
        'pb': 'private-pb',
      };
      for (final clean in [
        LogRedactor.json(values),
        LogRedactor.text(encoded(values)),
        LogRedactor.text('epd={NRP}cGFzc3dvcmQ= userName={NRP}c2VjcmV0'),
      ]) {
        expect(clean, isNot(contains('private-')));
        expect(clean, isNot(contains('cGFzc3dvcmQ')));
        expect(clean, isNot(contains('c2VjcmV0')));
      }
    },
  );
}
