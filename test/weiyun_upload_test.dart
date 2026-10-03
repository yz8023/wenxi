import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/weiyun.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'support.dart';

const _now = 1700000000000;
const _session = BrowseSession(
  platform: CloudPlatform.weiyun,
  mode: BrowseMode.personal,
  title: 'files',
  rootId: 'root',
);
HttpResult _reply(Json body, {String key = 'data', bool bare = false}) {
  final payload = {
    'rsp_header': <String, dynamic>{},
    'rsp_body': {'RspMsg_body': body},
  };
  return jsonResponse(bare ? payload : {'ret': 0, key: payload});
}

Future<(Vault, Credential)> _account() async {
  final vault = Vault(StateStore.memory());
  final c = Credential('fixture', {
    'primary': 'uin=o12345; p_skey=fixture-login; wyctoken=csrf',
    'csrfCheckedAt': '$_now',
    'rootId': 'root',
  }, updatedAt: 42);
  await vault.putCredential(CloudPlatform.weiyun, c);
  return (vault, c);
}

UploadFile _source([int size = 10]) => UploadFile(
  name: 'sample.txt',
  size: size,
  read: (start, end) =>
      Stream.value(List.generate(end - start, (i) => start + i)),
);
HttpResult _paths() => _reply({
  'items': [
    {'dir_key': 'root', 'pdir_key': 'upper'},
  ],
});
HttpResult _listed([int size = 10]) => _reply({
  'file_list': [
    {'file_id': 'file', 'filename': 'sample.txt', 'file_size': size},
  ],
  'finish_flag': true,
  'total_file_count': 2,
  'hide_file_count': 1,
  'pdir_key': 'upper',
});

void main() {
  test(
    'Weiyun creates a directory using its parent path and without overwriting',
    () async {
      final (vault, c) = await _account();
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('/LibDirPathGet')) return _paths();
        expect(r.uri.path, endsWith('/DiskDirCreate'));
        final body = asJson(
          jsonDecode(r.json.str('req_body')),
        ).obj('ReqMsg_body').obj('.weiyun.DiskDirCreateMsgReq_body');
        expect(body['ppdir_key'], 'upper');
        expect(body['pdir_key'], 'root');
        expect(body['file_exist_option'], 2);
        return _reply({'dir_key': 'folder', 'dir_name': 'new folder'});
      });
      final created = await WeiyunConnector(
        http,
        vault,
        now: () => _now,
      ).createFolder(_session, 'root', 'new folder', c);
      expect(created.id, 'folder');
      expect(created.isDirectory, true);
    },
  );
  test(
    'Weiyun follows server piece offsets, response envelopes and final confirmation',
    () async {
      final (vault, c) = await _account();
      final received = <int>[];
      var pieces = 0;
      final http = FakeHttp((r) async {
        if (r.uri.path.endsWith('/LibDirPathGet')) return _paths();
        if (r.uri.path.endsWith('/DiskDirList')) return _listed();
        expect(r.uri.queryParameters['g_tk'], 'csrf');
        if (r.uri.path == '/api/v3/ftn_pre_upload') {
          expect(r.json['req_header'], isA<Map>());
          final body = r.json
              .obj('req_body')
              .obj('ReqMsg_body')
              .obj('weiyun.PreUploadMsgReq_body');
          expect(
            body.obj('common_upload_req'),
            containsPair('file_exist_option', 2),
          );
          expect(body.obj('common_upload_req')['file_size'], 10);
          expect(body.list('block_info_list').single['size'], 10);
          return _reply({
            'weiyunPreUploadMsgRsp_body': {
              'file_exist': false,
              'common_upload_rsp': {'file_id': 'file'},
              'upload_key': 'upload-only-key',
              'ex': 'first',
              'channel_list': [
                {'id': 0, 'offset': 0, 'len': 4},
              ],
            },
          }, key: 'result');
        }
        expect(r.uri.host, 'upload.weiyun.com');
        expect(r.uri.path, '/ftnup_v2/weiyun');
        final upload = r.body as HttpUpload;
        expect(upload.fileName, 'blob');
        expect(upload.fieldName, 'upload');
        final body = asJson(jsonDecode(upload.fields!['json']!))
            .obj('req_body')
            .obj('ReqMsg_body')
            .obj('weiyun.UploadPieceMsgReq_body');
        expect(body['ex'], pieces == 0 ? 'first' : 'next-$pieces');
        expect(body.obj('channel')['offset'], received.length);
        expect(upload.length, pieces == 2 ? 2 : 4);
        expect(body.obj('channel')['len'], upload.length);
        received.addAll(await upload.open().expand((b) => b).toList());
        pieces++;
        return _reply({
          'weiyun.UploadPieceMsgRsp_body': {
            'ex': 'next-$pieces',
            'upload_state': pieces == 3 ? 2 : 1,
            'channel': {'id': 0, 'offset': received.length},
          },
        }, bare: true);
      });
      final file = await WeiyunConnector(
        http,
        vault,
        now: () => _now,
      ).upload(_session, 'root', _source(), c);
      expect(received, List.generate(10, (i) => i));
      expect(pieces, 3);
      expect(file.id, 'file');
    },
  );
  test(
    'Weiyun refuses repeated ranges, incomplete channels and cancellation',
    () async {
      for (final behavior in ['repeat', 'incomplete', 'cancel']) {
        final (vault, c) = await _account();
        final scope = RequestScope();
        var pieces = 0;
        final http = FakeHttp((r) async {
          if (r.uri.path.endsWith('/LibDirPathGet')) return _paths();
          if (r.uri.path == '/api/v3/ftn_pre_upload') {
            return _reply({
              'weiyunPreUploadMsgRsp_body': {
                'upload_key': 'key',
                'channel_list': [
                  {'id': 0, 'offset': 0, 'len': 4},
                ],
              },
            }, key: 'result');
          }
          expect(r.body, isA<HttpUpload>());
          await (r.body as HttpUpload).open().drain<void>();
          pieces++;
          if (behavior == 'cancel') scope.cancel();
          return _reply({
            'weiyun.UploadPieceMsgRsp_body': {
              'upload_state': behavior == 'incomplete' ? 3 : 1,
              'channel': {'id': 0, 'offset': 0, 'len': 4},
            },
          }, bare: true);
        });
        await expectLater(
          scope.run(
            () => WeiyunConnector(
              http,
              vault,
              now: () => _now,
            ).upload(_session, 'root', _source(), c),
          ),
          throwsA(isA<AppException>()),
        );
        expect(pieces, 1);
        expect(
          http.calls.any((r) => r.uri.path.endsWith('/DiskDirList')),
          false,
        );
      }
    },
  );
  test(
    'Weiyun rejects invalid channel starts and capacities before sending',
    () async {
      for (final channel in [
        {'id': 0, 'offset': -1, 'len': 4},
        {'id': 0, 'offset': 10, 'len': 4},
        {'id': 0, 'offset': 11, 'len': 4},
        {'id': 0, 'offset': 0, 'len': 0},
        {'id': 0, 'offset': 0, 'len': -1},
      ]) {
        final (vault, c) = await _account();
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('/LibDirPathGet')) return _paths();
          expect(r.uri.path, '/api/v3/ftn_pre_upload');
          return _reply({
            'weiyunPreUploadMsgRsp_body': {
              'upload_key': 'key',
              'channel_list': [channel],
            },
          }, key: 'result');
        });
        await expectLater(
          WeiyunConnector(
            http,
            vault,
            now: () => _now,
          ).upload(_session, 'root', _source(), c),
          throwsA(isA<AppException>()),
        );
        expect(http.calls.where((r) => r.body is HttpUpload), isEmpty);
      }
    },
  );
  test(
    'Weiyun instant and empty uploads still confirm the resulting file',
    () async {
      for (final size in [0, 10]) {
        final (vault, c) = await _account();
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('/LibDirPathGet')) return _paths();
          if (r.uri.path.endsWith('/DiskDirList')) return _listed(size);
          expect(r.body, isNot(isA<HttpUpload>()));
          return _reply({
            'weiyunPreUploadMsgRsp_body': {
              'file_exist': true,
              'common_upload_rsp': {'file_id': 'file'},
            },
          }, key: 'result');
        });
        expect(
          (await WeiyunConnector(
            http,
            vault,
            now: () => _now,
          ).upload(_session, 'root', _source(size), c)).size,
          size,
        );
      }
    },
  );
}
