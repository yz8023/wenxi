import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/providers/tianyi.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/tianyi_web_login.dart';
import 'support.dart';

const _id = '0123456789abcdef0123456789abcdef';
const _cloud = CloudPlatform.tianyi;
const _identity =
    'https://cloud.189.cn/api/open/user/getUserInfoForPortal.action';

void main() {
  test(
    'Tianyi keeps mobile login and post-login pages inside mobile origins',
    () {
      final target = WebLoginTarget.targets[_cloud]!;
      final login = Uri.parse(target.url);
      expect(login.host, 'm.cloud.189.cn');
      expect(login.path, '/udb/udb_login.jsp');
      expect(login.queryParameters['clientType'], 'wap');
      expect(login.queryParameters['pageKey'], 'normal');
      expect(
        login.queryParameters['redirectURL'],
        'https://cloud.189.cn/web/redirect.html',
      );
      expect(target.desktopMode, false);
      for (final page in [
        'https://m.cloud.189.cn/main.action?menu=true',
        'https://h5.cloud.189.cn/main.html',
      ]) {
        expect(TianyiWebLogin.trusted(page), true);
        expect(target.cookieUrls(page).first, _identity);
        expect(target.cookieUrls(page), contains(page.split('?').first));
      }
      expect(TianyiWebLogin.trusted('https://open.e.189.cn/'), false);
      expect(
        TianyiWebLogin.trusted('https://h5.cloud.189.cn.attacker.invalid/'),
        false,
      );
    },
  );

  test(
    'Tianyi completes before mobile home promotion, after the SSO callback',
    () {
      for (final url in [
        'https://cloud.189.cn/web/redirect.html',
        'https://cloud.189.cn/web/main/',
        'https://m.cloud.189.cn/main.action?menu=true',
        'https://h5.cloud.189.cn/',
        'https://h5.cloud.189.cn/home.html',
      ]) {
        expect(TianyiWebLogin.isCompletionLanding(url), true, reason: url);
      }
      for (final url in [
        TianyiWebLogin.loginUrl,
        'https://m.cloud.189.cn/callbackUnifyV2.action?ticket=fixture',
        'https://cloud.189.cn/api/portal/callbackUnify.action?ticket=fixture',
        'https://open.e.189.cn/api/logbox/separate/wap/index.html',
        'https://h5.cloud.189.cn/app/auth.js',
        'https://h5.cloud.189.cn.attacker.invalid/home.html',
        'https://cloud.189.cn:444/web/redirect.html',
        'http://cloud.189.cn/web/redirect.html',
      ]) {
        expect(TianyiWebLogin.isCompletionLanding(url), false, reason: url);
      }
    },
  );

  test(
    'Tianyi captures the login browser binding with the account API cookies',
    () {
      final target = WebLoginTarget.targets[_cloud]!;
      const page = 'https://cloud.189.cn/web/main/';
      final urls = target.cookieUrls(page);
      expect(urls.first, _identity);
      final raw = LoginCredentials.fromBrowser(
        _cloud,
        storage: jsonEncode({'browserId': _id, 'unrelated': 'discard'}),
        cookies: [
          for (final url in urls)
            url == _identity
                ? 'COOKIE_LOGIN_USER=api-session; JSESSIONID=api-transient'
                : 'COOKIE_LOGIN_USER=page-session',
        ],
      );
      final candidate = LoginCredentials.candidate(_cloud, raw, null);
      expect(
        candidate.primary,
        'COOKIE_LOGIN_USER=api-session; JSESSIONID=api-transient',
      );
      expect(candidate.field('browserId'), _id);
      expect(candidate.fields.containsKey('unrelated'), false);
    },
  );

  for (final id in [_id, '']) {
    test(
      'Tianyi authenticated operations preserve the original browser binding: bound=${id.isNotEmpty}',
      () async {
        final candidate = LoginCredentials.candidate(
          _cloud,
          TianyiWebLogin.encode('COOKIE_LOGIN_USER=cloud-session', id),
          null,
        );
        final http = FakeHttp((r) {
          expect(r.headers['Browser-Id'], id.isEmpty ? null : id);
          expect(r.headers['Cookie'], 'COOKIE_LOGIN_USER=cloud-session');
          expect(r.uri.queryParameters.containsKey('browserId'), false);
          if (r.uri.path.endsWith('/getUserInfoForPortal.action')) {
            return jsonResponse({
              'res_code': 0,
              'userId': 'fixture-user',
              'loginName': 'fixture-name',
            });
          }
          if (r.uri.path.endsWith('/getUserSizeInfo.action')) {
            return jsonResponse({
              'res_code': 0,
              'cloudCapacityInfo': {'totalSize': 100, 'usedSize': 30},
            });
          }
          if (r.uri.path.endsWith('/listFiles.action')) {
            return jsonResponse({
              'res_code': 0,
              'fileListAO': {'count': 0, 'fileList': [], 'folderList': []},
            });
          }
          if (r.uri.path.endsWith('/createFolder.action')) {
            return jsonResponse({
              'res_code': 0,
              'id': 'new-folder',
              'name': 'fixture-folder',
            });
          }
          throw StateError('Unexpected route');
        });
        final connector = TianyiConnector(http);
        final login = await connector.authenticate(candidate);
        expect(login.credential.field('browserId'), id);
        expect(login.account.total, 100);
        final session = await connector.openPersonal(login.credential);
        expect(
          await connector.list(session, session.rootId, login.credential),
          isEmpty,
        );
        expect(
          (await connector.createFolder(
            session,
            session.rootId,
            'fixture-folder',
            login.credential,
          )).id,
          'new-folder',
        );
      },
    );
  }

  test('Browser metadata never makes an incomplete Cookie a valid account', () {
    for (final value in ['', 'SSO_TOKEN=not-a-cloud-session']) {
      expect(
        LoginCredentials.plausible(_cloud, TianyiWebLogin.encode(value, _id)),
        false,
      );
    }
    expect(TianyiWebLogin.browserId('value\r\nInjected: true'), isEmpty);
    final previous = Credential('fixture', {
      'primary': 'COOKIE_LOGIN_USER=old',
      'browserId': _id,
    });
    final replacement = LoginCredentials.candidate(
      _cloud,
      'COOKIE_LOGIN_USER=new',
      previous,
    );
    expect(replacement.field('browserId'), isEmpty);
    for (final address in [
      'http://cloud.189.cn/',
      'https://cloud.189.cn.attacker.invalid/',
      'https://user@cloud.189.cn/',
      'https://cloud.189.cn:444/',
    ]) {
      expect(TianyiWebLogin.trusted(address), false);
    }
  });
}
