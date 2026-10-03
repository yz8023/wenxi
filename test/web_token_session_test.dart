import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/providers/aliyun.dart';
import 'package:asterlink/data/providers/guangya.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/web_tokens.dart';
import 'support.dart';
import 'token_cloud_support.dart';

CloudConnector tokenConnector(CloudPlatform p, JsonHttp http, Vault vault) =>
    p == CloudPlatform.aliyun
    ? AliyunConnector(http, vault, now: () => tokenClock)
    : GuangyaConnector(http, vault, now: () => tokenClock);

bool isRefresh(RecordedRequest r) => r.uri.path.endsWith('/token');

HttpResult tokenResponse(CloudPlatform p, RecordedRequest r) {
  if (isRefresh(r)) {
    return jsonResponse({
      'access_token': renewedAccess,
      'refresh_token': renewedRefresh,
      'expires_in': 7200,
      'user_id': 'user-1',
    });
  }
  if (r.uri.path.endsWith('/file/list')) return jsonResponse({'items': []});
  if (r.uri.path.endsWith('/get_file_list')) {
    return guangyaResponse({'list': [], 'total': 0});
  }
  if (r.uri.path == '/v1/user/me') {
    return jsonResponse({'sub': 'user-1', 'nickname': '光鸭账号'});
  }
  if (r.uri.path == '/assets/v1/get_assets') return guangyaAssetsResponse();
  return aliDefaultResponse(r);
}

void main() {
  for (final p in [CloudPlatform.aliyun, CloudPlatform.guangya]) {
    group(p.key, () {
      test('token JSON is minimized and supports official field aliases', () {
        final fields = WebTokens.fields(
          p,
          jsonEncode({
            'credentials': {
              'access_token': accessToken,
              'refresh_token': refreshToken,
              'sub': 'user-1',
              'expires_at': '1790203600',
              'unrelatedSecret': 'do-not-save',
            },
          }),
        );
        expect(fields['accessToken'], accessToken);
        expect(fields['refreshToken'], refreshToken);
        expect(fields['expiresAt'], '1790203600000');
        expect(fields.containsKey('unrelatedSecret'), isFalse);
        expect(
          WebTokens.fields(
            p,
            jsonEncode(
              jsonEncode({
                'accessToken': accessToken,
                'refreshToken': refreshToken,
              }),
            ),
          )['refreshToken'],
          refreshToken,
        );
      });

      test('malformed token objects cannot become saved credentials', () {
        for (final value in [
          true,
          1234567890123456,
          [],
          {},
          null,
          '$accessToken\r\nX-Injected: 1',
          '$accessToken\n',
        ]) {
          expect(
            WebTokens.fields(
              p,
              jsonEncode({
                'access_token': value,
                'refresh_token': refreshToken,
              }),
            ),
            isEmpty,
            reason: '$value',
          );
        }
        for (final raw in ['{}', '[]', '{invalid', 'short', 'null']) {
          expect(WebTokens.fields(p, raw), isEmpty);
        }
      });

      for (final expired in [true, false]) {
        test(
          '${expired ? 'expired tokens' : 'concurrent 401s'} rotate once',
          () async {
            final vault = await tokenVault(
              p,
              tokenCredential(p, expired: expired),
            );
            final release = Completer<void>();
            var rotations = 0;
            final http = FakeHttp((r) async {
              if (isRefresh(r)) {
                rotations++;
                expect(r.json['refresh_token'], refreshToken);
                expect(r.headers.containsKey('Authorization'), isFalse);
                await release.future;
                return tokenResponse(p, r);
              }
              if (!expired &&
                  r.headers['Authorization'] == 'Bearer $accessToken') {
                return const HttpResult(401, '<html>expired</html>');
              }
              expect(r.headers['Authorization'], 'Bearer $renewedAccess');
              return tokenResponse(p, r);
            });
            final connector = tokenConnector(p, http, vault),
                original = vault.credential(p)!;
            final pending = Future.wait(
              List.generate(
                8,
                (_) => connector.list(tokenPersonal(p), 'root', original),
              ),
            );
            await until(() => rotations == 1);
            release.complete();
            expect(await pending, hasLength(8));
            expect(rotations, 1);
            final current = vault.credential(p)!;
            expect(current.field('refreshToken'), renewedRefresh);
            expect(current.updatedAt, original.updatedAt);
            expect(
              LoginCredentials.sameWebTokenSession(original, current),
              isTrue,
            );
          },
        );
      }

      for (final change in ['removed', 'replaced', 'cancelled']) {
        test('late renewal cannot overwrite a $change login', () async {
          final vault = await tokenVault(p, tokenCredential(p, expired: true));
          final release = Completer<void>(), scope = RequestScope();
          var started = false;
          final http = FakeHttp((r) async {
            expect(isRefresh(r), isTrue);
            started = true;
            await release.future;
            return tokenResponse(p, r);
          });
          final connector = tokenConnector(p, http, vault);
          final result = expectLater(
            scope.run(
              () =>
                  connector.list(tokenPersonal(p), 'root', vault.credential(p)),
            ),
            throwsA(isA<AppException>()),
          );
          await until(() => started);
          if (change == 'removed') {
            await vault.removeCredential(p);
          } else if (change == 'replaced') {
            await vault.putCredential(p, tokenCredential(p, revision: 99));
          } else {
            scope.cancel();
          }
          release.complete();
          await result;
          // A cancelled gate may finish after its caller has been released.
          await Future<void>.delayed(Duration.zero);
          expect(
            vault.credential(p)?.field('refreshToken'),
            change == 'removed' ? isNull : refreshToken,
          );
          if (change == 'replaced') expect(vault.credential(p)!.updatedAt, 99);
          expect(http.calls, hasLength(1));
        });
      }

      test(
        'renewal stays with its original account after the active account switches',
        () async {
          final vault = await tokenVault(p, tokenCredential(p, expired: true));
          final first = vault.activeAccountId(p)!;
          final second = await vault.createAccount(p);
          await vault.withAccount(
            p,
            second,
            () => vault.putCredential(
              p,
              tokenCredential(p, revision: 99, fields: {'userId': 'user-2'}),
            ),
          );
          final release = Completer<void>();
          var rotating = false;
          final http = FakeHttp((r) async {
            if (isRefresh(r)) {
              rotating = true;
              await release.future;
            }
            return tokenResponse(p, r);
          });
          final connector = tokenConnector(p, http, vault);
          final result = vault.withAccount(
            p,
            first,
            () => connector.list(tokenPersonal(p), 'root', vault.credential(p)),
          );
          await until(() => rotating);
          await vault.activate(p, second);
          release.complete();
          await result;
          expect(vault.activeAccountId(p), second);
          expect(vault.credential(p)!.field('refreshToken'), refreshToken);
          expect(
            vault.credentialFor(p, first)!.field('refreshToken'),
            renewedRefresh,
          );
        },
      );

      test(
        'candidate validation keeps rotating tokens private until login commits',
        () async {
          final vault = await tokenVault(p), original = vault.credential(p)!;
          final http = FakeHttp((r) => tokenResponse(p, r));
          final connector = tokenConnector(p, http, vault);
          final candidate = tokenCredential(p, revision: 100, expired: true);
          final LoginResult result = switch (connector) {
            AliyunConnector c => await c.authenticate(candidate),
            GuangyaConnector c => await c.authenticate(candidate),
            _ => throw StateError('missing authenticator'),
          };
          expect(result.credential.field('refreshToken'), renewedRefresh);
          expect(vault.credential(p)!.sameAs(original), isTrue);
          final login = AccountLoginService(
            vault,
            (_, _) async => throw StateError('fallback'),
            webAuthenticators: {
              p: (credential) => switch (connector) {
                AliyunConnector c => c.authenticate(credential),
                GuangyaConnector c => c.authenticate(credential),
                _ => throw StateError('missing authenticator'),
              },
            },
          );
          await login.submitWeb(
            p,
            jsonEncode({
              'access_token': accessToken,
              'refresh_token': refreshToken,
              'expires_at': '${tokenClock - 1}',
            }),
          );
          expect(vault.credential(p)!.field('refreshToken'), renewedRefresh);
          expect(
            vault.credential(p)!.updatedAt,
            greaterThan(original.updatedAt),
          );
        },
      );

      test(
        'non-JSON refresh rejection asks for login without erasing credentials',
        () async {
          final vault = await tokenVault(p, tokenCredential(p, expired: true));
          final original = vault.credential(p)!;
          final http = FakeHttp((_) => const HttpResult(401, 'expired'));
          await expectLater(
            tokenConnector(
              p,
              http,
              vault,
            ).list(tokenPersonal(p), 'root', original),
            throwsA(isA<AccountLoginRequired>()),
          );
          expect(vault.credential(p)!.sameAs(original), isTrue);
          expect(http.calls, hasLength(1));
        },
      );

      test(
        'rotating refresh is not replayed by ordinary network retry',
        () async {
          final vault = await tokenVault(p, tokenCredential(p, expired: true));
          final http = FakeHttp((r) {
            expect(isRefresh(r), isTrue);
            throw const HttpRequestFailure(
              'connection lost',
              kind: 'connectionError',
              retryable: true,
            );
          });
          await expectLater(
            tokenConnector(
              p,
              RetryingJsonHttp(http),
              vault,
            ).list(tokenPersonal(p), 'root', vault.credential(p)),
            throwsA(isA<HttpRequestFailure>()),
          );
          expect(http.calls, hasLength(1));
        },
      );

      test('web storage is only readable on the official HTTPS origin', () {
        final target = WebLoginTarget.targets[p]!;
        expect(target.localStorageKey, isNotNull);
        expect(target.canReadLocalStorage(target.url), isTrue);
        for (final address in [
          target.url.replaceFirst('https:', 'http:'),
          '${target.url.split('/')[0]}//attacker.test',
          'https://${Uri.parse(target.url).host}.attacker.test/',
          'https://user:pass@${Uri.parse(target.url).host}/',
          'https://${Uri.parse(target.url).host}:8443/',
          'https://auth.aliyundrive.com/',
          'https://account.guangyapan.com/',
        ]) {
          expect(target.canReadLocalStorage(address), isFalse, reason: address);
        }
      });
    });
  }

  test(
    'plain Aliyun refresh token and Guangya bearer access token remain supported',
    () {
      expect(
        WebTokens.fields(CloudPlatform.aliyun, refreshToken)['refreshToken'],
        refreshToken,
      );
      expect(
        WebTokens.fields(
          CloudPlatform.guangya,
          'Bearer $accessToken',
        )['accessToken'],
        accessToken,
      );
      expect(
        WebTokens.fields(
          CloudPlatform.aliyun,
          jsonEncode({'access_token': accessToken}),
        ),
        isEmpty,
      );
    },
  );

  test(
    'Guangya initializes a single persistent device during concurrent first use',
    () async {
      const p = CloudPlatform.guangya;
      final vault = await tokenVault(
        p,
        tokenCredential(p, fields: {'deviceId': ''}),
      );
      final http = FakeHttp((r) => tokenResponse(p, r));
      final connector = tokenConnector(p, http, vault),
          original = vault.credential(p)!;
      await Future.wait(
        List.generate(
          8,
          (_) => connector.list(tokenPersonal(p), 'root', original),
        ),
      );
      final devices = http.calls.map((r) => r.headers['did']).toSet();
      expect(devices, hasLength(1));
      expect(devices.single, vault.credential(p)!.field('deviceId'));
      expect(devices.single, isNotEmpty);
    },
  );

  test(
    'Guangya preserves the official account device signature separately from the file API device',
    () async {
      const p = CloudPlatform.guangya;
      final sign = 'wdi10.${'a' * 32}${'b' * 32}';
      final parsed = WebTokens.fields(
        p,
        jsonEncode({
          'access_token': accessToken,
          'refresh_token': refreshToken,
          'device_id': 'file-api-device',
          'device_sign': sign,
        }),
      );
      expect(parsed['deviceSign'], sign);
      final vault = await tokenVault(p, tokenCredential(p, fields: parsed));
      final http = FakeHttp((r) {
        if (r.uri.path == '/v1/user/me') {
          expect(r.headers['X-Device-Sign'], sign);
          expect(r.headers['X-Device-Id'], 'a' * 32);
          return jsonResponse({'sub': 'user-1'});
        }
        expect(r.headers['did'], 'file-api-device');
        if (r.uri.path == '/assets/v1/get_assets') {
          return guangyaAssetsResponse();
        }
        return guangyaResponse({'list': []});
      });
      final connector = GuangyaConnector(http, vault, now: () => tokenClock),
          c = vault.credential(p)!;
      await connector.account(c);
      await connector.list(tokenPersonal(p), 'root', c);
      expect(vault.credential(p)!.field('deviceSign'), sign);
    },
  );
}
