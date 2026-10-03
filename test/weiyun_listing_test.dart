import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/providers/weiyun.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

void main() {
  const session = BrowseSession(
    platform: CloudPlatform.weiyun,
    mode: BrowseMode.personal,
    title: 'fixture',
    rootId: 'root',
  );

  for (final hiddenOnly in [false, true]) {
    test(
      'Weiyun excludes hidden items from completed listing counts: hiddenOnly=$hiddenOnly',
      () async {
        final credential = Credential('fixture', {
          'primary': 'weiyun_qq_openid=fixture; wyctoken=csrf',
          'csrfCheckedAt': '1700000000000',
        });
        final vault = Vault(StateStore.memory());
        await vault.putCredential(CloudPlatform.weiyun, credential);
        final http = FakeHttp((r) {
          expect(r.uri.path, endsWith('/DiskDirList'));
          return jsonResponse({
            'data': {
              'rsp_header': {'retcode': 0},
              'rsp_body': {
                'RspMsg_body': {
                  'total_dir_count': 2,
                  'total_file_count': 7,
                  'hide_dir_count': hiddenOnly ? 2 : 0,
                  'hide_file_count': hiddenOnly ? 7 : 1,
                  'finish_flag': true,
                  if (!hiddenOnly)
                    'dir_list': [
                      for (var i = 0; i < 2; i++)
                        {'dir_key': 'directory-$i', 'dir_name': 'folder-$i'},
                    ],
                  if (!hiddenOnly)
                    'file_list': [
                      for (var i = 0; i < 6; i++)
                        {
                          'file_id': 'file-$i',
                          'filename': 'sample-$i.txt',
                          'file_size': i + 1,
                        },
                    ],
                },
              },
            },
          });
        });
        final connector = WeiyunConnector(
          http,
          vault,
          now: () => 1700000000000,
        );
        for (var refresh = 0; refresh < 3; refresh++) {
          final files = await connector.list(session, 'root', credential);
          expect(files.length, hiddenOnly ? 0 : 8);
        }
        expect(http.calls.length, 3);
      },
    );
  }

  for (final hidden in [0, -1, 3]) {
    test(
      'Weiyun rejects missing visible items or invalid hidden counts: $hidden',
      () async {
        final credential = Credential('fixture', {
          'primary': 'weiyun_qq_openid=fixture; wyctoken=csrf',
          'csrfCheckedAt': '1700000000000',
        });
        final vault = Vault(StateStore.memory());
        await vault.putCredential(CloudPlatform.weiyun, credential);
        final http = FakeHttp(
          (r) => jsonResponse({
            'data': {
              'rsp_header': {'retcode': 0},
              'rsp_body': {
                'RspMsg_body': {
                  'total_file_count': 2,
                  'hide_file_count': hidden,
                  'finish_flag': true,
                  'file_list': [
                    {'file_id': 'file', 'filename': 'sample.txt'},
                  ],
                },
              },
            },
          }),
        );
        await expectLater(
          WeiyunConnector(
            http,
            vault,
            now: () => 1700000000000,
          ).list(session, 'root', credential),
          throwsA(isA<AppException>()),
        );
      },
    );
  }
}
