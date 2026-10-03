import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/wopan.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'support.dart';

const _now = 1700000000000,
    _part = 8 * 1024 * 1024,
    _size = 17 * 1024 * 1024 + 17;
const _session = BrowseSession(
  platform: CloudPlatform.wopan,
  mode: BrowseMode.personal,
  title: 'files',
  rootId: '0',
);
Future<(Vault, Credential)> _account() async {
  final vault = Vault(StateStore.memory());
  final c = Credential('fixture', {
    'primary': 'fixture-refresh-token',
    'accessToken': 'fixture-access-token-12345678',
    'refreshToken': 'fixture-refresh-token',
    'expiresAt': '${_now + 3600000}',
  }, updatedAt: 42);
  await vault.putCredential(CloudPlatform.wopan, c);
  return (vault, c);
}

HttpResult _reply(RecordedRequest r, Object data) => jsonResponse({
  'STATUS': '200',
  'RSP': {
    'RSP_CODE': '0000',
    'DATA': data is List
        ? data
        : WopanProtocol.encrypt(
            asJson(data),
            r.json.obj('header').str('channel'),
            r.headers['Accesstoken']!,
          ),
  },
});

void main() {
  test(
    'Wopan probes its advertised host before sending, then uploads exact part boundaries',
    () async {
      final (vault, c) = await _account();
      final ranges = <(int, int)>[], sizes = <int>[];
      var unique = '', written = 0;
      final http = FakeHttp((r) async {
        if (r.method == 'HEAD') {
          expect(r.uri.host, 'hyupload.pan.wo.cn');
          throw const HttpRequestFailure(
            'handshake',
            kind: 'tls',
            retryable: true,
            requestNotSent: true,
          );
        }
        if (r.body is HttpUpload) {
          expect(r.uri.host, 'tjupload.pan.wo.cn');
          expect(r.headers['Accesstoken'], isNull);
          final body = r.body as HttpUpload, fields = body.fields!;
          expect(fields['uniqueId'], matches(RegExp(r'^\d{13}$')));
          if (unique.isEmpty) unique = fields['uniqueId']!;
          expect(fields['uniqueId'], unique);
          expect(fields['totalPart'], '2');
          expect(fields['partIndex'], '${sizes.length + 1}');
          final info = WopanProtocol.decode(
            fields['fileInfo'],
            'wohome',
            fields['accessToken']!,
          );
          expect(info['directoryId'], '0');
          expect(info['spaceType'], '0');
          final bytes = await body.open().fold<int>(0, (n, b) => n + b.length);
          expect(bytes, int.parse(fields['partSize']!));
          sizes.add(bytes);
          written += bytes;
          return jsonResponse({
            'code': '0000',
            'data': {'fid': 'storage-fid'},
          });
        }
        final key = r.json.obj('header').str('key');
        return _reply(r, switch (key) {
          'GetZoneInfo' => {'url': 'https://hyupload.pan.wo.cn'},
          'ClassifyRule' => {'fileTypes': <String, dynamic>{}},
          'QueryAllFiles' => {
            'files': [
              {
                'id': 'listing-id',
                'fid': 'storage-fid',
                'type': 1,
                'name': 'sample.txt',
                'size': _size,
              },
            ],
          },
          _ => throw StateError('Unexpected operation'),
        });
      });
      final source = UploadFile(
        name: 'sample.txt',
        size: _size,
        read: (start, end) async* {
          ranges.add((start, end));
          for (var i = start; i < end; i += 65536) {
            yield Uint8List((end - i).clamp(0, 65536));
          }
        },
      );
      final file = await WopanConnector(
        http,
        vault,
        now: () => _now,
      ).upload(_session, '0', source, c);
      expect(ranges, [(0, _part), (_part, _size)]);
      expect(sizes, [_part, _size - _part]);
      expect(written, _size);
      expect(file.id, 'listing-id');
    },
  );
  test(
    'Wopan rejects a foreign upload host before disclosing its token or file',
    () async {
      final (vault, c) = await _account();
      final http = FakeHttp(
        (r) => _reply(r, {'url': 'https://pan.wo.cn.attacker.example'}),
      );
      await expectLater(
        WopanConnector(http, vault, now: () => _now).upload(
          _session,
          '0',
          UploadFile(
            name: 'sample.txt',
            size: 1,
            read: (a, b) => Stream.value([1]),
          ),
          c,
        ),
        throwsA(isA<AppException>()),
      );
      expect(http.calls, hasLength(1));
      expect(http.calls.single.uri.host, 'panservice.mail.wo.cn');
    },
  );
  test(
    'Unavailable Wopan download node obtains a fresh URL from the alternate API',
    () async {
      final (vault, c) = await _account();
      final http = FakeHttp((r) {
        if (r.method == 'GET') {
          expect(r.headers['Range'], 'bytes=0-0');
          expect(r.headers.containsKey('Accesstoken'), isFalse);
          if (r.uri.host == 'tjdownload.pan.wo.cn') {
            return const HttpResult(206, 'a', {
              'content-range': ['bytes 0-0/3'],
            });
          }
          return const HttpResult(503, '');
        }
        expect(r.headers['Accesstoken'], c.field('accessToken'));
        final key = r.json.obj('header').str('key');
        expect(key, isIn(['GetDownloadUrlV2', 'GetDownloadUrl']));
        final entry = {
          'fid': 'storage-fid',
          'downloadUrl': key == 'GetDownloadUrlV2'
              ? 'https://hydownload.pan.wo.cn/file?sign=fixture'
              : 'https://tjdownload.pan.wo.cn/file?sign=renewed%2b&k=1&k=2',
        };
        return _reply(
          r,
          key == 'GetDownloadUrlV2'
              ? {
                  'list': [entry],
                }
              : [entry],
        );
      });
      final file = CloudFile(
        id: 'file',
        name: 'sample.txt',
        size: 3,
        parentId: '0',
        token: jsonEncode({'fid': 'storage-fid'}),
      );
      final result = await WopanConnector(
        http,
        vault,
        now: () => _now,
      ).download(_session, file, c);
      expect(
        result.url,
        'https://tjdownload.pan.wo.cn/file?sign=renewed%2b&k=1&k=2',
      );
      expect(
        result.headers.values.join(),
        isNot(contains(c.field('accessToken'))),
      );
    },
  );
}
