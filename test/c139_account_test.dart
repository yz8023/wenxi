import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/c139.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

void main() {
  const mb = 1024 * 1024;
  final authorization =
      'Basic ${base64Encode(utf8.encode('pc:13800000000:fixture-token'))}';
  final cookie =
      'authorization=${Uri.encodeComponent(authorization)}; '
      'skey=fixture%2Bkey%3D; ud_id=fixture%2Fdomain';
  Credential credential([String? value]) =>
      Credential('fixture', {'primary': value ?? cookie});

  test('Mobile cloud waits for cloud authorization, key and user domain', () {
    const mail = 'Os_SSo_Sid=fixture; RMKEY=fixture';
    expect(LoginCredentials.plausible(CloudPlatform.c139, mail), isTrue);
    expect(LoginCredentials.c139CloudReady(mail), isFalse);
    expect(
      LoginCredentials.c139CloudReady('$mail; authorization=$authorization'),
      isFalse,
    );
    expect(
      LoginCredentials.c139CloudReady(
        '$mail; authorization=$authorization; skey=fixture',
      ),
      isFalse,
    );
    expect(LoginCredentials.c139CloudReady(cookie), isTrue);
    final candidate = LoginCredentials.candidate(
      CloudPlatform.c139,
      cookie,
      null,
    );
    expect(candidate.field('authorization'), authorization);
    expect(candidate.field('userDomainId'), 'fixture/domain');
    expect(candidate.primary, cookie);
  });

  test(
    'Encoded cloud cookies and auth-token login normalize without losing plus signs',
    () {
      final tokenCookie =
          'AUTH_TOKEN=fixture%2Btoken%3D; '
          'ORCHES-I-ACCOUNT-ENCRYPT=${Uri.encodeComponent(base64Encode(utf8.encode('13800000000')))}; '
          'SKEY=key; UD_ID=domain';
      final candidate = LoginCredentials.candidate(
        CloudPlatform.c139,
        tokenCookie,
        null,
      );
      expect(
        candidate.field('authorization'),
        'Basic ${base64Encode(utf8.encode('pc:13800000000:fixture+token='))}',
      );
      expect(LoginCredentials.c139CloudReady(tokenCookie), isTrue);
      expect(LoginCredentials.c139Cookie('skey=a+b%3D', 'skey'), 'a+b=');
      expect(
        LoginCredentials.c139Cookie('skey=bad%0D%0AHeader', 'skey'),
        isEmpty,
      );
      expect(LoginCredentials.c139Cookie('skey=bad%zz', 'skey'), isEmpty);
      expect(
        LoginCredentials.c139Authorization(
          'auth_token=fixture; ORCHES-I-ACCOUNT-ENCRYPT=bad',
        ),
        isEmpty,
      );
    },
  );

  test(
    'Incomplete or expired mobile login never replaces a working account',
    () async {
      final vault = Vault(StateStore.memory());
      final old = credential();
      await vault.putCredential(CloudPlatform.c139, old);
      var requests = 0;
      final login = AccountLoginService(vault, (_, _) async {
        requests++;
        throw const AccountLoginRequired('expired');
      });
      await expectLater(
        login.submitWeb(CloudPlatform.c139, 'Os_SSo_Sid=early; RMKEY=early'),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(requests, 0);
      await expectLater(
        login.submitWeb(CloudPlatform.c139, cookie),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(requests, 1);
      expect(vault.credential(CloudPlatform.c139)!.sameAs(old), isTrue);
    },
  );

  test(
    'Temporary quota errors can retain complete manual login without inventing capacity',
    () async {
      final vault = Vault(StateStore.memory());
      final login = AccountLoginService(
        vault,
        (_, _) async => throw const AppException('temporary outage'),
      );
      final result = await login.submitWeb(CloudPlatform.c139, cookie);
      expect(result.account.nickname, '13800000000');
      expect(result.account.total, 0);
      expect(
        vault.credential(CloudPlatform.c139)!.field('authorization'),
        authorization,
      );
    },
  );

  test(
    'Quota request carries the real domain, decoded authorization and skey',
    () async {
      final http = FakeHttp(
        (_) => jsonResponse({
          'success': true,
          'code': '0000',
          'data': {'diskSize': '10240.5', 'freeDiskSize': '8192.25'},
        }),
      );
      final account = await C139Connector(http).account(credential());
      final request = http.calls.single;
      expect(request.uri.path, '/user/disk/quota/detail');
      expect(request.json, {'userDomainId': 'fixture/domain'});
      expect(request.headers['Authorization'], authorization);
      expect(request.headers['Cookie'], cookie);
      expect(request.headers['mcloud-skey'], 'fixture+key=');
      expect(request.headers['User-Agent'], C139Connector.ua);
      expect(request.headers['x-yun-app-channel'], '10000034');
      expect(request.headers['x-yun-channel-source'], '10000034');
      expect(request.headers['x-yun-module-type'], '100');
      expect(request.headers['mcloud-client'], '10701');
      expect(request.headers['Sec-Fetch-Site'], 'same-site');
      expect(request.headers['Sec-Fetch-Mode'], 'cors');
      expect(request.headers['Sec-Fetch-Dest'], 'empty');
      expect(request.headers['X-Requested-With'], 'mark.via');
      final signature = request.headers['mcloud-sign']!.split(',');
      expect(
        signature.last,
        C139Protocol.calculateSign(
          request.body as String,
          signature[0],
          signature[1],
        ),
      );
      expect(account.total, (10240.5 * mb).round());
      expect(account.used, (2048.25 * mb).round());
    },
  );

  test(
    'Stored authorization can read capacity without a local skey requirement',
    () async {
      final http = FakeHttp(
        (_) => jsonResponse({
          'code': '0000',
          'data': {'diskSize': 100, 'usedSize': 0.5},
        }),
      );
      final account = await C139Connector(http).account(
        Credential('imported', {
          'authorization': Uri.encodeComponent(authorization),
          'userDomainId': 'saved-domain',
        }),
      );
      expect(account.used, mb ~/ 2);
      expect(http.calls.single.json['userDomainId'], 'saved-domain');
      expect(http.calls.single.headers['Authorization'], authorization);
      expect(http.calls.single.headers.containsKey('mcloud-skey'), isFalse);
      expect(http.calls.single.headers.containsKey('Cookie'), isFalse);
    },
  );

  test(
    'Quota parser handles personal disk wrappers, total-free and every quota entry',
    () {
      final disk = C139Quota.parse({
        'diskInfo': {'diskSize': '100.25', 'freeDiskSize': '100.125'},
      }, 'fixture');
      expect(disk.total, (100.25 * mb).round());
      expect(disk.used, mb ~/ 8);
      final all = C139Quota.parse({
        'diskSize': 100,
        'quotaList': [
          {'usedSize': '1.25'},
          {'usedSize': 2.5},
        ],
      }, 'fixture');
      expect(all.used, (3.75 * mb).round());
      expect(
        C139Quota.parse({'diskSize': 100, 'freeDiskSize': 100}, 'fixture').used,
        0,
      );
      expect(
        C139Quota.parse({
          'diskSize': 100,
          'freeDiskSize': 50,
          'usedSize': 1,
        }, 'fixture').used,
        50 * mb,
      );
    },
  );

  test(
    'Missing or malformed capacity is an error rather than a zero-capacity success',
    () {
      for (final data in <Json>[
        {},
        {'diskSize': 100},
        {'diskSize': 'NaN', 'usedSize': 0},
        {'diskSize': 0, 'usedSize': 0},
        {'diskSize': 100, 'freeDiskSize': 101},
        {'diskSize': 100, 'usedSize': -1},
        {'diskSize': 100, 'quotaList': []},
        {
          'diskSize': 100,
          'quotaList': [
            {'usedSize': 1},
            {},
          ],
        },
        {
          'diskSize': 100,
          'quotaList': [
            {'usedSize': 1},
            'invalid',
          ],
        },
      ]) {
        expect(
          () => C139Quota.parse(data, 'fixture'),
          throwsA(isA<AppException>()),
        );
      }
    },
  );

  test(
    'Unavailable or incomplete quota detail falls back to official personal disk info',
    () async {
      for (final first in [
        jsonResponse({'code': '04000013'}, 503),
        jsonResponse({
          'success': true,
          'data': {'diskSize': 100},
        }),
      ]) {
        final http = FakeHttp(
          (request) => request.uri.path.endsWith('/quota/detail')
              ? first
              : jsonResponse({
                  'code': '0000',
                  'data': {'diskSize': 200, 'freeDiskSize': 50},
                }),
        );
        final result = await C139Connector(http).account(credential());
        expect(result.used, 150 * mb);
        expect(http.calls.map((call) => call.uri.path), [
          '/user/disk/quota/detail',
          '/user/disk/getPersonalDiskInfo',
        ]);
        expect(http.calls.last.json['userDomainId'], 'fixture/domain');
        expect(http.calls.last.headers['mcloud-skey'], 'fixture+key=');
      }
    },
  );

  test(
    'Expired authorization reports relogin and does not retry a second capacity endpoint',
    () async {
      for (final response in [
        const HttpResult(401, '<html>Login</html>'),
        const HttpResult(403, ''),
        jsonResponse({'code': '04000005'}),
        jsonResponse({'resultCode': '1010010002'}),
      ]) {
        final http = FakeHttp((_) => response);
        await expectLater(
          C139Connector(http).account(credential()),
          throwsA(isA<AccountLoginRequired>()),
        );
        expect(http.calls.length, 1);
      }
      final http = FakeHttp();
      await expectLater(
        C139Connector(
          http,
        ).account(credential('Os_SSo_Sid=early; RMKEY=early')),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(http.calls, isEmpty);
    },
  );
}
