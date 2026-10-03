import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/providers/wopan.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

const _now = 1700000000000;
const _session = BrowseSession(
  platform: CloudPlatform.wopan,
  mode: BrowseMode.personal,
  title: 'files',
  rootId: '0',
);
const _original = 'https://hydownload.pan.wo.cn/file?sign=old';
const _fresh = 'https://hydownload.pan.wo.cn/file?sign=fresh%2b&k=1&k=2';
const _alternate = 'https://tjdownload.pan.wo.cn/file?sign=alternate';

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

HttpResult _downloadResponse(RecordedRequest request, String alternate) {
  final key = request.json.obj('header').str('key');
  expect(key, isIn(['GetDownloadUrlV2', 'GetDownloadUrl']));
  final param = WopanProtocol.decode(
    request.json.obj('body')['param'],
    'wohome',
    request.headers['Accesstoken']!,
  );
  expect(param['fidList'], ['storage-fid']);
  final entries = [
    {
      'fid': 'storage-fid',
      'downloadUrl': key == 'GetDownloadUrlV2' ? _original : alternate,
    },
  ];
  return jsonResponse({
    'STATUS': '200',
    'RSP': {
      'RSP_CODE': '0000',
      'DATA': key == 'GetDownloadUrlV2' ? {'list': entries} : entries,
    },
  });
}

CloudFile _file([int size = 3]) => CloudFile(
  id: 'list-file-id',
  name: 'sample.txt',
  size: size,
  parentId: '0',
  token: jsonEncode({'fid': 'storage-fid'}),
);

void _checkProbe(RecordedRequest request) {
  expect(request.method, 'GET');
  expect(request.headers['Range'], 'bytes=0-0');
  expect(
    request.headers.keys.map((key) => key.toLowerCase()),
    isNot(anyElement(isIn(['accesstoken', 'cookie', 'authorization']))),
  );
}

HttpResult _range([int size = 3]) => HttpResult(206, 'a', {
  'content-range': ['bytes 0-0/$size'],
  'content-length': ['1'],
});

void main() {
  test(
    'Wopan checks GET before accepting a node whose HEAD succeeds',
    () async {
      final (vault, credential) = await _account();
      final http = FakeHttp((request) {
        if (request.method == 'POST') {
          return _downloadResponse(request, _alternate);
        }
        if (request.method == 'HEAD') return const HttpResult(200, '');
        _checkProbe(request);
        return request.url == _original ? const HttpResult(503, '') : _range();
      });
      final result = await WopanConnector(
        http,
        vault,
        now: () => _now,
      ).download(_session, _file(), credential);
      expect(result.url, _alternate);
      expect(http.calls.where((request) => request.method == 'HEAD'), isEmpty);
    },
  );

  test(
    'Wopan verifies a fresh URL on the original node before changing hosts',
    () async {
      final (vault, credential) = await _account();
      final http = FakeHttp((request) {
        if (request.method == 'POST') return _downloadResponse(request, _fresh);
        _checkProbe(request);
        if (request.url == _original) return const HttpResult(503, '');
        return request.uri.host == 'hydownload.pan.wo.cn'
            ? _range()
            : const HttpResult(302, '', {
                'location': [_fresh],
              });
      });
      final result = await WopanConnector(
        http,
        vault,
        now: () => _now,
      ).download(_session, _file(), credential);
      expect(result.url, _fresh);
      expect(
        http.calls.where(
          (request) => request.uri.host == 'tjdownload.pan.wo.cn',
        ),
        isEmpty,
      );
    },
  );

  for (final kind in ['tls', 'connectionTimeout', 'connectionError']) {
    for (final retries in [0, 3]) {
      test(
        'Wopan leaves an inconclusive $kind probe to the transfer with $retries retries',
        () async {
          final (vault, credential) = await _account();
          final waits = <Duration>[];
          final fake = FakeHttp((request) {
            if (request.method == 'POST') {
              return _downloadResponse(request, _alternate);
            }
            _checkProbe(request);
            throw HttpRequestFailure(
              'temporary connection failure',
              kind: kind,
              retryable: true,
            );
          });
          final result =
              await ReadRetryScope(
                retries: retries,
                checkpoint: RequestScope.checkpoint,
                wait: (delay) async => waits.add(delay),
              ).run(
                () => WopanConnector(
                  RetryingJsonHttp(fake),
                  vault,
                  now: () => _now,
                ).download(_session, _file(), credential),
              );
          expect(result.url, _original);
          expect(result.expectedSize, 3);
          expect(fake.calls.where((r) => r.method == 'POST'), hasLength(1));
          expect(fake.calls.where((r) => r.method == 'GET'), hasLength(1));
          expect(waits, isEmpty);
        },
      );
    }
  }

  test('Wopan preserves a fresh link when its probe is inconclusive', () async {
    final (vault, credential) = await _account();
    final waits = <Duration>[];
    final fake = FakeHttp((request) {
      if (request.method == 'POST') return _downloadResponse(request, _fresh);
      _checkProbe(request);
      if (request.url == _original) return const HttpResult(503, '');
      throw const HttpRequestFailure(
        'handshake interrupted',
        kind: 'tls',
        retryable: true,
      );
    });
    final result =
        await ReadRetryScope(
          retries: 3,
          checkpoint: RequestScope.checkpoint,
          wait: (delay) async => waits.add(delay),
        ).run(
          () => WopanConnector(
            RetryingJsonHttp(fake),
            vault,
            now: () => _now,
          ).download(_session, _file(), credential),
        );
    expect(result.url, _fresh);
    expect(fake.calls.where((r) => r.method == 'POST'), hasLength(2));
    expect(fake.calls.where((r) => r.method == 'GET'), hasLength(2));
    expect(waits, isEmpty);
    expect(
      fake.calls.any((r) => r.uri.host == 'tjdownload.pan.wo.cn'),
      isFalse,
    );
  });

  test('Wopan still stops if a probe is cancelled', () async {
    final (vault, credential) = await _account();
    final scope = RequestScope();
    final http = FakeHttp((request) {
      if (request.method == 'POST') {
        return _downloadResponse(request, _alternate);
      }
      _checkProbe(request);
      scope.cancel();
      throw const HttpRequestFailure(
        'connection interrupted',
        kind: 'tls',
        retryable: true,
      );
    });
    await expectLater(
      scope.run(
        () => WopanConnector(
          http,
          vault,
          now: () => _now,
        ).download(_session, _file(), credential),
      ),
      throwsA(isA<AppException>().having((e) => e.message, 'message', '请求已取消')),
    );
    expect(http.calls.where((r) => r.method == 'POST'), hasLength(1));
  });

  test('Wopan refuses a node returning a different file size', () async {
    final (vault, credential) = await _account();
    final http = FakeHttp((request) {
      if (request.method == 'POST') {
        return _downloadResponse(request, _alternate);
      }
      if (request.method == 'HEAD') return const HttpResult(200, '');
      _checkProbe(request);
      return _range(99);
    });
    await expectLater(
      WopanConnector(
        http,
        vault,
        now: () => _now,
      ).download(_session, _file(), credential),
      throwsA(isA<AppException>()),
    );
  });

  test(
    'Wopan does not bypass a certificate rejection when probing a node',
    () async {
      final (vault, credential) = await _account();
      final http = FakeHttp((request) {
        if (request.method == 'POST') {
          return _downloadResponse(request, _alternate);
        }
        if (request.method == 'HEAD') return const HttpResult(200, '');
        _checkProbe(request);
        throw const HttpRequestFailure(
          'certificate rejected',
          kind: 'badCertificate',
          retryable: false,
        );
      });
      await expectLater(
        WopanConnector(
          http,
          vault,
          now: () => _now,
        ).download(_session, _file(), credential),
        throwsA(
          isA<HttpRequestFailure>().having(
            (error) => error.retryable,
            'retryable',
            isFalse,
          ),
        ),
      );
      expect(
        http.calls.where((request) => request.method == 'POST'),
        hasLength(1),
      );
    },
  );

  for (final size in [0, 3]) {
    test(
      'Wopan accepts a valid ${size == 0 ? 'empty' : 'non-range'} file response',
      () async {
        final (vault, credential) = await _account();
        final http = FakeHttp((request) {
          if (request.method == 'POST') {
            return _downloadResponse(request, _alternate);
          }
          _checkProbe(request);
          return size == 0
              ? const HttpResult(416, '', {
                  'content-range': ['bytes */0'],
                })
              : const HttpResult(200, 'a', {
                  'content-length': ['3'],
                });
        });
        final result = await WopanConnector(
          http,
          vault,
          now: () => _now,
        ).download(_session, _file(size), credential);
        expect(result.url, _original);
        expect(
          http.calls.where((request) => request.method == 'POST'),
          hasLength(1),
        );
      },
    );
  }
}
