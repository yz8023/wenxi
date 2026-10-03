import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/guangya.dart';
import 'package:asterlink/data/providers/guangya_login.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'native_login_support.dart';
import 'support.dart';
import 'token_cloud_support.dart';

const _captcha = 'fixture-captcha-token-0123456789';
const _verified = 'verified-captcha-token-0123456789';

HttpResult _tokens() => jsonResponse({
  'access_token': renewedAccess,
  'refresh_token': renewedRefresh,
  'expires_in': 3600,
});

void main() {
  test(
    'password login uses the web client captcha, preserves the password and retains only tokens',
    () async {
      final http = LoginHttp((r) {
        expect(r.uri.origin, GuangyaLoginProtocol.origin);
        expect(r.method, 'POST');
        expect(r.headers['User-Agent'], WebLoginTarget.desktopUserAgent);
        expect(r.headers.containsKey('Authorization'), isFalse);
        expect(r.json['client_id'], GuangyaLoginProtocol.clientId);
        if (r.uri.path == '/v1/shield/captcha/init') {
          expect(r.json['action'], 'POST:/v1/auth/signin');
          expect(r.json.obj('meta'), {'phone_number': '+86 13800000000'});
          expect(r.json['device_id'], r.headers['X-Device-Id']);
          return jsonResponse({'captcha_token': _captcha, 'expires_in': 300});
        }
        expect(r.uri.path, '/v1/auth/signin');
        expect(r.json['username'], '+86 13800000000');
        expect(r.json['password'], ' SamplePassword! ');
        expect(r.headers['X-Captcha-Token'], _captcha);
        return _tokens();
      });
      final credential = await GuangyaPasswordLogin(
        http,
        now: () => tokenClock,
      ).password(' 13800000000 ', ' SamplePassword! ');
      expect(http.calls, hasLength(2));
      expect(http.redirects, everyElement(isFalse));
      expect(credential.field('accessToken'), renewedAccess);
      expect(credential.field('refreshToken'), renewedRefresh);
      expect(credential.field('expiresAt'), '${tokenClock + 3600000}');
      expect(credential.field('username'), '13800000000');
      expect(credential.field('authType'), 'webToken');
      expect(credential.fields.keys, isNot(contains('password')));
      expect(credential.fields.values, isNot(contains(' SamplePassword! ')));
      expect(credential.field('deviceSign'), startsWith('wdi10.'));
      expect(credential.field('deviceId'), hasLength(32));
    },
  );

  test(
    'a verified callback token is required before sending a password',
    () async {
      final http = LoginHttp(
        (r) => r.uri.path.endsWith('/init')
            ? jsonResponse({
                'captcha_token': _captcha,
                'url':
                    'https://captcha.guangyapan.com/verify?challenge=fixture',
              })
            : _tokens(),
      );
      final proof = Completer<String?>();
      final pending = GuangyaPasswordLogin(http).password(
        'fixture@example.invalid',
        'fixture-password',
        verifyCaptcha: (challenge) {
          expect(
            challenge.url.queryParameters['redirect_uri'],
            GuangyaCaptchaChallenge.callback,
          );
          expect(challenge.url.queryParameters['state'], challenge.state);
          return proof.future;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(http.calls, hasLength(1));
      proof.complete(_verified);
      await pending;
      expect(http.calls.last.headers['X-Captcha-Token'], _verified);
    },
  );

  test('cancelling verification never submits the password', () async {
    final http = LoginHttp(
      (_) => jsonResponse({'url': 'https://captcha.guangyapan.com/verify'}),
    );
    await expectLater(
      GuangyaPasswordLogin(
        http,
      ).password('fixture', 'private', verifyCaptcha: (_) async => null),
      throwsA(isA<AppException>()),
    );
    expect(http.calls, hasLength(1));
  });

  test(
    'request cancellation during verification cannot send a late password',
    () async {
      final http = LoginHttp(
        (_) => jsonResponse({'url': 'https://captcha.guangyapan.com/verify'}),
      );
      final proof = Completer<String?>();
      final scope = RequestScope();
      final pending = scope.run(
        () => GuangyaPasswordLogin(
          http,
        ).password('fixture', 'private', verifyCaptcha: (_) => proof.future),
      );
      final failure = expectLater(pending, throwsA(isA<AppException>()));
      await Future<void>.delayed(Duration.zero);
      scope.cancel();
      await failure;
      proof.complete(_verified);
      await Future<void>.delayed(Duration.zero);
      expect(http.calls, hasLength(1));
    },
  );

  test(
    'only captcha rejection retries; incorrect passwords are sent once',
    () async {
      var signs = 0;
      final http = LoginHttp((r) {
        if (r.uri.path.endsWith('/init')) {
          return jsonResponse({'captcha_token': _captcha});
        }
        signs++;
        return jsonResponse({
          'error': signs == 1
              ? 'captcha_invalid'
              : 'invalid_account_or_password',
          'error_description': 'do not echo private password',
        }, 400);
      });
      await expectLater(
        GuangyaPasswordLogin(http).password('fixture', 'private password'),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'safe error',
            '光鸭账号或密码不正确，请检查后重试',
          ),
        ),
      );
      expect(signs, 2);
      expect(http.calls, hasLength(4));
    },
  );

  test(
    'verification callback rejects untrusted hosts, wrong state and subframe-like paths',
    () {
      final challenge = GuangyaCaptchaChallenge(
        'https://captcha.guangyapan.com/verify',
      );
      final callback = Uri.parse(GuangyaCaptchaChallenge.callback).replace(
        queryParameters: {
          'asterlink_captcha': '1',
          'state': challenge.state,
          'captcha_token': _verified,
        },
      );
      expect(challenge.tokenFromCallback(callback.toString()), _verified);
      for (final uri in [
        callback.replace(scheme: 'http'),
        callback.replace(host: 'www.guangyapan.com.evil.invalid'),
        callback.replace(userInfo: 'someone'),
        callback.replace(port: 444),
        callback.replace(path: '/unexpected'),
        callback.replace(
          queryParameters: {
            ...callback.queryParameters,
            'state': 'another-attempt',
          },
        ),
        callback.replace(
          queryParameters: {
            ...callback.queryParameters,
            'captcha_token': 'short',
          },
        ),
      ]) {
        expect(challenge.tokenFromCallback(uri.toString()), isNull);
      }
      for (final url in [
        'https://guangyapan.com.evil.invalid/verify',
        'http://captcha.guangyapan.com/',
        'https://user@captcha.guangyapan.com/',
      ]) {
        expect(
          () => GuangyaCaptchaChallenge(url),
          throwsA(isA<AppException>()),
        );
      }
    },
  );

  test(
    'login validates the new account before replacing an existing session',
    () async {
      final vault = await tokenVault(CloudPlatform.guangya);
      final old = vault.credential(CloudPlatform.guangya)!;
      final http = LoginHttp((r) {
        if (r.uri.path.endsWith('/init')) {
          return jsonResponse({'captcha_token': _captcha});
        }
        if (r.uri.path.endsWith('/signin')) return _tokens();
        if (r.uri.path == '/assets/v1/get_assets') {
          return guangyaAssetsResponse();
        }
        expect(r.uri.path, '/v1/user/me');
        expect(r.method, 'GET');
        expect(r.body, isNull);
        expect(r.headers['Authorization'], 'Bearer $renewedAccess');
        return jsonResponse({'sub': 'new-user', 'nickname': '新账号'});
      });
      final connector = GuangyaConnector(http, vault, now: () => tokenClock);
      final login = AccountLoginService(vault, (_, c) => connector.account(c));
      await login.submit(
        CloudPlatform.guangya,
        (_) => connector.password('new-user', 'new-password'),
      );
      final saved = vault.credential(CloudPlatform.guangya)!;
      expect(saved.field('userId'), 'new-user');
      expect(saved.field('accessToken'), renewedAccess);
      expect(saved.field('deviceId'), isNot(old.field('deviceId')));
      expect(saved.field('password'), 'new-password');
    },
  );

  test(
    'invalid account response preserves the old session and a partial token is rejected',
    () async {
      final vault = await tokenVault(CloudPlatform.guangya);
      final old = vault.credential(CloudPlatform.guangya)!;
      final http = LoginHttp((r) {
        if (r.uri.path.endsWith('/init')) {
          return jsonResponse({'captcha_token': _captcha});
        }
        if (r.uri.path.endsWith('/signin')) return _tokens();
        return jsonResponse({'nickname': 'incomplete'});
      });
      final connector = GuangyaConnector(http, vault, now: () => tokenClock);
      final login = AccountLoginService(vault, (_, c) => connector.account(c));
      await expectLater(
        login.submit(
          CloudPlatform.guangya,
          (_) => connector.password('new-user', 'new-password'),
        ),
        throwsA(isA<AppException>()),
      );
      expect(vault.credential(CloudPlatform.guangya)!.toJson(), old.toJson());
      final partial = LoginHttp(
        (r) => r.uri.path.endsWith('/init')
            ? jsonResponse({'captcha_token': _captcha})
            : jsonResponse({'access_token': renewedAccess}),
      );
      await expectLater(
        GuangyaPasswordLogin(partial).password('fixture', 'private'),
        throwsA(isA<AppException>()),
      );
    },
  );
}
