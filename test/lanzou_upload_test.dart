import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/lanzou.dart';
import 'package:asterlink/data/providers/lanzou_protocol.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'support.dart';
import 'lanzou_support.dart';

const _page = r"""<html><script>var uploadVei='fixture-vei';
$.ajax({url:'/doupload.php?uid=12345',data:{'vei':uploadVei}});</script></html>""";
Credential _credential() => Credential('fixture', {
  'primary': 'ylogin=fixture; phpdisk_info=personal-cookie',
}, updatedAt: 42);
const _session = BrowseSession(
  platform: CloudPlatform.lanzou,
  mode: BrowseMode.personal,
  title: 'files',
  rootId: '-1',
);

void main() {
  test(
    'Lanzou personal login and account parameters preserve anonymous sharing',
    () {
      expect(LanzouPage(_page).accountParameters, {
        'uid': '12345',
        'vei': 'fixture-vei',
      });
      expect(
        LoginCredentials.plausible(CloudPlatform.lanzou, _credential().primary),
        true,
      );
      expect(
        LoginCredentials.plausible(CloudPlatform.lanzou, 'ylogin=only'),
        false,
      );
      expect(
        WebLoginTarget.targets[CloudPlatform.lanzou]!.userAgent,
        contains('Windows NT'),
      );
      expect(CloudPlatform.lanzou.shareRequiresAccount, false);
    },
  );
  test(
    'Lanzou creates a folder, streams the selected bytes and confirms its file ID',
    () async {
      var uploaded = false;
      final received = <int>[];
      final http = FakeHttp((r) async {
        expect(r.uri.host, 'pc.woozooo.com');
        expect(r.headers['Cookie'], contains('phpdisk_info=personal-cookie'));
        if (r.uri.path == '/mydisk.php') return const HttpResult(200, _page);
        if (r.uri.path == '/html5wup.php') fail('Unexpected upload endpoint');
        if (r.uri.path == '/html5up.php') {
          final body = r.body as HttpUpload;
          expect(body.fieldName, 'upload_file');
          expect(body.fields!['folder_id_bb_n'], '7');
          expect(body.fields!['name'], 'sample.txt');
          received.addAll(await body.open().expand((c) => c).toList());
          uploaded = true;
          return jsonResponse({
            'zt': 1,
            'text': [
              {'id': '42', 'name_all': 'sample.txt', 'size': '0.1 K'},
            ],
          });
        }
        expect(r.uri.queryParameters, {'uid': '12345', 'vei': 'fixture-vei'});
        final fields = Uri.splitQueryString(r.body as String);
        switch (fields['task']) {
          case '2':
            expect(fields['parent_id'], '-1');
            expect(fields['folder_name'], 'new folder');
            return jsonResponse({'zt': 1, 'text': '7'});
          case '47':
            return jsonResponse({'zt': 1, 'text': []});
          case '5':
            return jsonResponse({
              'zt': fields['pg'] == '1' ? 1 : 2,
              'text': uploaded && fields['pg'] == '1'
                  ? [
                      {'id': '42', 'name_all': 'sample.txt', 'size': '0.1 K'},
                    ]
                  : [],
            });
          default:
            throw StateError('Unexpected task');
        }
      });
      final connector = LanzouConnector(http), c = _credential();
      final folder = await connector.createFolder(
        _session,
        '-1',
        'new folder',
        c,
      );
      expect(folder.id, 'd:7');
      final file = await connector.upload(
        _session,
        folder.id,
        UploadFile(
          name: 'sample.txt',
          size: 3,
          read: (start, end) => Stream.value([1, 2, 3].sublist(start, end)),
        ),
        c,
      );
      expect(file.id, 'f:42');
      expect(file.parentId, 'd:7');
      expect(received, [1, 2, 3]);
    },
  );
  test(
    'Lanzou personal download uses the returned share domain without leaking account cookies',
    () async {
      final public = LanzouFixture()..exactSize = 3;
      final http = FakeHttp((r) async {
        if (r.uri.host == 'pc.woozooo.com') {
          if (r.uri.path == '/mydisk.php') return const HttpResult(200, _page);
          expect(Uri.splitQueryString(r.body as String)['task'], '22');
          return jsonResponse({
            'zt': 1,
            'info': {
              'f_id': 'iExample123',
              'is_newd': 'https://author.lanzouu.com',
              'pwd': '',
            },
          });
        }
        expect(r.headers['Cookie'] ?? '', isNot(contains('personal-cookie')));
        return public.respond(r);
      });
      final spec = await LanzouConnector(http).download(
        _session,
        const CloudFile(
          id: 'f:42',
          name: 'sample.txt',
          size: 103,
          parentId: 'd:7',
        ),
        _credential(),
      );
      expect(spec.url, lanzouTestFinal);
      expect(spec.expectedSize, 3);
      expect(spec.headers.values.join(), isNot(contains('personal-cookie')));
    },
  );
  test(
    'Lanzou login expiry and upload rejection never report success',
    () async {
      for (final status in [401, 200]) {
        final http = FakeHttp(
          (r) => r.uri.path == '/mydisk.php'
              ? const HttpResult(200, _page)
              : status == 401
              ? const HttpResult(401, '<html>login</html>')
              : jsonResponse({'zt': 0, 'info': 'unsupported'}),
        );
        await expectLater(
          LanzouConnector(http).upload(
            _session,
            '-1',
            UploadFile(
              name: 'sample.txt',
              size: 1,
              read: (start, end) => Stream.value([1]),
            ),
            _credential(),
          ),
          throwsA(isA<AppException>()),
        );
        expect(http.calls.any((r) => r.uri.path == '/doupload.php'), false);
      }
    },
  );
}
