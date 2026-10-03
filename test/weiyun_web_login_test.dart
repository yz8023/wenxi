import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/weiyun.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/weiyun_web_login.dart';
import 'native_login_support.dart';
import 'support.dart';
import 'token_cloud_support.dart';

const _cloud = CloudPlatform.weiyun;
const _captured = {
  'cookie': 'weiyun_qq_openid=qq-fixture',
  'tokenInfo': {
    'token_type': 3,
    'login_key_type': 1540,
    'qq_openid': 'qq-fixture',
    'env_id': 1,
  },
  'requestHeader': {
    'user_flag': 3,
    'uin': '12345',
    'qq_openid': 'qq-fixture',
    'env_id': 1,
    'appid': 30013,
    'version': 7,
  },
  'csrf': 'observed-csrf',
};
HttpResult _response(Json data) => jsonResponse({
  'ret': 0,
  'data': {
    'rsp_header': {'retcode': 0},
    'rsp_body': {'RspMsg_body': data},
  },
});
Json _requestToken(RecordedRequest r) => asJson(
  jsonDecode(r.json.str('req_body')),
).obj('ReqMsg_body').obj('ext_req_head').obj('token_info');

void main() {
  for (final variant in [
    'protobuf_defaults',
    'outer_default',
    'all_status_defaults',
    'json_strings',
    'result_envelope',
    'named_body',
  ]) {
    test('QQ web account accepts successful $variant responses', () async {
      final vault = Vault(StateStore.memory());
      final account = <String, dynamic>{
        'uin': 12345,
        'main_dir_key': 'root',
        'nick_name': 'fixture',
        'total_space': 500,
        'used_space': 10,
      };
      final envelope = <String, dynamic>{
        'rsp_header': {
          'cmd': 2201,
          'uin': 12345,
          if (variant == 'outer_default') 'retcode': 0,
        },
        'rsp_body': {
          'RspMsg_body': variant == 'named_body'
              ? {'.weiyun.DiskUserInfoGetMsgRsp_body': account}
              : account,
        },
      };
      if (variant == 'json_strings') {
        envelope['rsp_header'] = jsonEncode(envelope['rsp_header']);
        envelope['rsp_body'] = jsonEncode(envelope['rsp_body']);
      }
      final connector = WeiyunConnector(
        FakeHttp(
          (_) => jsonResponse({
            if (!{'outer_default', 'all_status_defaults'}.contains(variant))
              'ret': 0,
            variant == 'result_envelope' ? 'result' : 'data':
                variant == 'json_strings' ? jsonEncode(envelope) : envelope,
          }),
        ),
        vault,
        now: () => tokenClock,
      );
      final login = AccountLoginService(
        vault,
        (_, c) => connector.account(c),
        webAuthenticators: {_cloud: connector.authenticate},
      );
      await login.submitWeb(
        _cloud,
        LoginCredentials.fromBrowser(_cloud, storage: _captured),
      );
      expect(vault.credential(_cloud)!.field('rootId'), 'root');
      expect(vault.credential(_cloud)!.field('userId'), '12345');
    });
  }
  for (final invalid in <Json>[
    {'ret': 0},
    for (final status in [-1, 'invalid', null, false, 0.5])
      {
        'ret': status,
        'data': {
          'rsp_header': {'retcode': 0},
          'rsp_body': {
            'RspMsg_body': {'uin': 12345, 'main_dir_key': 'root'},
          },
        },
      },
    {
      'data': {
        'rsp_header': {'retcode': 0},
      },
    },
    {
      'ret': 0,
      'data': {
        'rsp_body': {
          'RspMsg_body': {'uin': 12345, 'main_dir_key': 'root'},
        },
      },
    },
    {
      'ret': 0,
      'data': {
        'rsp_header': {'retcode': 1001},
        'rsp_body': {
          'RspMsg_body': {'uin': 12345, 'main_dir_key': 'root'},
        },
      },
    },
    {
      'ret': 0,
      'data': {
        'rsp_header': {'retcode': 'invalid'},
        'rsp_body': {
          'RspMsg_body': {'uin': 12345, 'main_dir_key': 'root'},
        },
      },
    },
  ]) {
    test(
      'Malformed or rejected protocol responses cannot save an account: $invalid',
      () async {
        final vault = Vault(StateStore.memory());
        final connector = WeiyunConnector(
          FakeHttp((_) => jsonResponse(invalid)),
          vault,
          now: () => tokenClock,
        );
        final login = AccountLoginService(
          vault,
          (_, c) => connector.account(c),
          webAuthenticators: {_cloud: connector.authenticate},
        );
        await expectLater(
          login.submitWeb(
            _cloud,
            LoginCredentials.fromBrowser(_cloud, storage: _captured),
          ),
          throwsA(isA<AppException>()),
        );
        expect(vault.credential(_cloud), isNull);
      },
    );
  }
  test(
    'QQ OpenID can be detected before legacy marker or CSRF cookie exists',
    () {
      for (final raw in [
        'weiyun_qq_openid=qq-fixture',
        'weiyun_wx_openid=wx-fixture',
        'p_uin=o12345; p_skey=fixture-key',
      ]) {
        expect(LoginCredentials.plausible(_cloud, raw), isTrue);
      }
      expect(LoginCredentials.plausible(_cloud, 'tracking=unrelated'), isFalse);
      expect(WeiyunConnector.tokenInfo({'weiyun_qq_openid': 'qq-fixture'}), {
        'token_type': 3,
        'login_key_type': 1540,
        'qq_openid': 'qq-fixture',
      });
    },
  );

  test(
    'page and native HttpOnly credentials are merged without losing request parameters',
    () {
      final raw = LoginCredentials.fromBrowser(
        _cloud,
        storage: jsonEncode(_captured),
        cookies: ['qq_login_sid=fixture-http-only; wyctoken=native-csrf'],
      );
      final c = LoginCredentials.candidate(_cloud, raw, null);
      expect(c.primary, contains('qq_login_sid=fixture-http-only'));
      expect(c.primary, contains('weiyun_qq_openid=qq-fixture'));
      expect(c.field('weiyunCsrf'), 'observed-csrf');
      expect(
        WeiyunWebLogin.tokenInfo(c.field('weiyunTokenInfo')),
        _captured['tokenInfo'],
      );
      expect(c.primary, isNot(contains('tokenInfo')));
      expect(
        LoginCredentials.fromBrowser(_cloud, storage: {'cookie': 'tracking=x'}),
        isEmpty,
      );
    },
  );

  test(
    'captured file requests allow an otherwise unnamed session cookie to be validated',
    () async {
      final raw = LoginCredentials.fromBrowser(
        _cloud,
        storage: {..._captured, 'cookie': ''},
        cookies: ['qq_login_sid=fixture-http-only'],
      );
      expect(raw, isNotEmpty);
      final vault = Vault(StateStore.memory());
      final http = LoginHttp((r) {
        expect(r.method, 'POST');
        expect(r.uri.path, '/webapp/json/weiyunQdiskClient/DiskUserInfoGet');
        expect(r.uri.queryParameters['g_tk'], 'observed-csrf');
        expect(r.headers['Cookie'], 'qq_login_sid=fixture-http-only');
        expect(_requestToken(r), _captured['tokenInfo']);
        final header = asJson(jsonDecode(r.json.str('req_header')));
        expect(header['cmd'], 2201);
        expect(header['version'], 7);
        expect(header['uin'], '12345');
        return _response({
          'uin': 12345,
          'main_dir_key': 'main-root',
          'nick_name': 'fixture',
          'total_space': 500,
          'used_space': 10,
        });
      });
      final connector = WeiyunConnector(http, vault, now: () => tokenClock);
      final login = AccountLoginService(
        vault,
        (_, c) => connector.account(c),
        webAuthenticators: {_cloud: connector.authenticate},
      );
      await login.submitWeb(_cloud, raw);
      expect(http.calls, hasLength(1));
      expect(http.redirects, [false]);
      expect(vault.credential(_cloud)!.field('userId'), '12345');
      expect(vault.credential(_cloud)!.field('weiyunCsrf'), 'observed-csrf');
    },
  );

  test(
    'native CSRF takes priority and captured request commands are never replayed',
    () async {
      final raw = LoginCredentials.fromBrowser(
        _cloud,
        storage: {
          ..._captured,
          'csrf': '',
          'requestHeader': {
            ..._captured['requestHeader']! as Map,
            'cmd': 9999,
            'seq': 1,
            'Authorization': 'discard',
          },
        },
        cookies: ['wyctoken=current-csrf; qq_login_sid=fixture-http-only'],
      );
      final candidate = LoginCredentials.candidate(_cloud, raw, null);
      final http = FakeHttp((r) {
        expect(r.uri.queryParameters['g_tk'], 'current-csrf');
        final header = asJson(jsonDecode(r.json.str('req_header')));
        expect(header['cmd'], 2201);
        expect(header['seq'], tokenClock ~/ 1000);
        expect(header.containsKey('Authorization'), isFalse);
        return _response({'uin': 12345, 'main_dir_key': 'main-root'});
      });
      await WeiyunConnector(
        http,
        Vault(StateStore.memory()),
        now: () => tokenClock,
      ).authenticate(candidate);
    },
  );

  test('invalid account responses cannot save captured credentials', () async {
    final vault = Vault(StateStore.memory());
    final connector = WeiyunConnector(
      FakeHttp((_) => _response({})),
      vault,
      now: () => tokenClock,
    );
    final login = AccountLoginService(
      vault,
      (_, c) => connector.account(c),
      webAuthenticators: {_cloud: connector.authenticate},
    );
    await expectLater(
      login.submitWeb(
        _cloud,
        LoginCredentials.fromBrowser(_cloud, storage: _captured),
      ),
      throwsA(isA<AppException>()),
    );
    expect(vault.credential(_cloud), isNull);
  });

  test(
    'refresh replaces captured WeChat tokens even when the legacy marker is absent',
    () async {
      final raw = LoginCredentials.fromBrowser(
        _cloud,
        storage: {
          'cookie':
              'openid=wx-fixture; wy_appid=app; access_token=old-token; refresh_token=old-refresh; wyctoken=old-csrf',
          'tokenInfo': {
            'token_type': 1,
            'login_key_type': 192,
            'openid': 'wx-fixture',
            'access_token': 'old-token',
            'login_key_value': 'old-token',
          },
          'csrf': 'old-csrf',
        },
      );
      final candidate = LoginCredentials.candidate(_cloud, raw, null);
      var attempts = 0, touches = 0;
      final http = FakeHttp((r) {
        if (r.uri.host == 'api.weixin.qq.com') {
          expect(r.headers.containsKey('Cookie'), isFalse);
          return jsonResponse({
            'openid': 'wx-fixture',
            'access_token': 'new-token',
            'refresh_token': 'new-refresh',
          });
        }
        if (r.uri.path == '/disk') {
          touches++;
          return touches == 1
              ? const HttpResult(302, '')
              : const HttpResult(200, '', {
                  'set-cookie': [
                    'wyctoken=new-csrf; Domain=.weiyun.com; Path=/',
                  ],
                });
        }
        if (++attempts == 1) return const HttpResult(403, 'expired');
        expect(r.uri.queryParameters['g_tk'], 'new-csrf');
        expect(_requestToken(r)['access_token'], 'new-token');
        expect(_requestToken(r)['login_key_value'], 'new-token');
        return _response({'uin': 12345, 'main_dir_key': 'main-root'});
      });
      final login = await WeiyunConnector(
        http,
        Vault(StateStore.memory()),
        now: () => tokenClock,
      ).authenticate(candidate);
      expect(attempts, 2);
      expect(login.credential.primary, contains('refresh_token=new-refresh'));
      expect(login.credential.field('weiyunTokenInfo'), isEmpty);
    },
  );

  test('trusted page origins and captured fields have strict boundaries', () {
    expect(WeiyunWebLogin.trusted('https://www.weiyun.com/disk'), isTrue);
    for (final url in [
      'http://www.weiyun.com/disk',
      'https://www.weiyun.com:444/disk',
      'https://www.weiyun.com.attacker.invalid/',
      'https://user@www.weiyun.com/',
      'https://graph.qq.com/',
    ]) {
      expect(WeiyunWebLogin.trusted(url), isFalse);
    }
    expect(
      WeiyunWebLogin.tokenInfo({
        'token_type': 3,
        'login_key_type': -1,
        'access_token': 'bad\nvalue',
        'arbitrary': 'discard',
      }),
      {'token_type': 3},
    );
    expect(WeiyunWebLogin.csrf('bad&cmd=999'), isEmpty);
    expect(
      LoginCredentials.fromBrowser(
        _cloud,
        storage: {
          'tokenInfo': {'token_type': 3, 'login_key_type': 1540},
          'csrf': 'csrf',
        },
      ),
      isEmpty,
    );
  });
}
