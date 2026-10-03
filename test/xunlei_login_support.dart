import 'dart:async';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/xunlei.dart';
import 'package:asterlink/data/providers/xunlei_protocol.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

const xunleiTestPassword = ' SamplePassword + 文 ! ';
const xunleiTestUsername = 'fixture@example.com';
const xunleiTestPlatform = CloudPlatform.xunlei;

class XunleiLoginFixture {
  XunleiLoginFixture({StateStore? store})
    : store = store ?? StateStore.memory() {
    http = FakeHttp((r) async => await intercept?.call(r) ?? respond(r));
    repository = CloudRepository(http, vault, CleanupOutbox(this.store, http));
    login = AccountLoginService(
      vault,
      (_, credential) => connector.account(credential),
      webAuthenticators: {xunleiTestPlatform: connector.authenticate},
    );
  }

  final StateStore store;
  late final vault = Vault(store);
  late final FakeHttp http;
  late final CloudRepository repository;
  late final AccountLoginService login;
  FutureOr<HttpResult?> Function(RecordedRequest)? intercept;
  XunleiConnector get connector =>
      repository.connector(xunleiTestPlatform) as XunleiConnector;
  Credential get saved => vault.credential(xunleiTestPlatform)!;
  final initial = Credential('迅雷云盘', const {
    'primary': 'old-access',
    'accessToken': 'old-access',
    'secondary': 'old-refresh',
    'refreshToken': 'old-refresh',
    'clientId': XunleiProtocol.clientId,
    'clientSecret': 'fixture-client-secret',
    'clientVersion': XunleiProtocol.version,
    'deviceId': 'old-device',
    'captchaToken': 'old-captcha',
    'authType': 'passwordToken',
    'username': xunleiTestUsername,
    'password': xunleiTestPassword,
    'userId': 'user-1',
    'nickname': 'fixture-user',
  }, updatedAt: 42);
  final personal = const BrowseSession(
    platform: xunleiTestPlatform,
    mode: BrowseMode.personal,
    title: 'fixture',
    rootId: '',
  );
  final file = const CloudFile(id: 'file-1', name: 'fixture.bin', size: 4);
  Json signIn = {
    'errorCode': 0,
    'sessionID': 'fixture-session',
    'userID': 'user-1',
    'nickName': 'fixture-user',
  };
  HttpResult tokenRefresh = jsonResponse({'error': 'invalid_grant'}, 401);
  final acceptedTokens = {'signed-access', 'refreshed-access', 'newer-access'};

  int get passwordCalls => http.calls
      .where((r) => r.uri.path == '/xluser.core.login/v3/login')
      .length;
  int get refreshCalls =>
      http.calls.where((r) => r.uri.path == '/v1/auth/token').length;
  Future<void> seed([Credential? credential]) =>
      vault.putCredential(xunleiTestPlatform, credential ?? initial);
  Future<LoginResult> submit({bool remember = true}) => login.submit(
    xunleiTestPlatform,
    (_) => repository.xunleiLogin.password(
      xunleiTestUsername,
      xunleiTestPassword,
      rememberPassword: remember,
    ),
  );
  Future<List<CloudFile>> list([Credential? credential]) =>
      connector.list(personal, '', credential ?? initial);

  HttpResult respond(RecordedRequest r) {
    switch (r.uri.path) {
      case '/xluser.core.login/v3/login':
        return jsonResponse(signIn);
      case '/xluser.core.login/v3/smslogin':
        return jsonResponse(signIn);
      case '/v1/shield/captcha/init':
        return jsonResponse({'captcha_token': 'signed-captcha'});
      case '/v1/auth/signin/token':
        return jsonResponse({
          'access_token': 'signed-access',
          'refresh_token': 'signed-refresh',
        });
      case '/v1/auth/token':
        return tokenRefresh;
    }
    if (!acceptedTokens.any(
      (token) => r.headers['Authorization'] == 'Bearer $token',
    )) {
      return jsonResponse({'error': 'unauthenticated'}, 401);
    }
    return switch (r.uri.path) {
      '/drive/v1/about' => jsonResponse({
        'quota': {'usage': '4', 'limit': '1000'},
      }),
      '/drive/v1/files' => jsonResponse({
        'files': [
          {
            'id': file.id,
            'name': file.name,
            'size': '${file.size}',
            'kind': 'drive#file',
          },
        ],
      }),
      '/drive/v1/files/file-1' => jsonResponse({
        'id': file.id,
        'size': '${file.size}',
        'links': {
          'application/octet-stream': {'url': 'https://cdn.example/fixture'},
        },
      }),
      _ => throw StateError('Unexpected fixture path: ${r.uri.path}'),
    };
  }
}
