import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/image_preview_loader.dart';
import 'package:asterlink/download/transfer_http.dart';

const _mib = 1024 * 1024;
const _etag = '"image-v1"';
const _modified = 'Wed, 23 Sep 2026 01:00:00 GMT';

class _LocalIo extends HttpOverrides {}

typedef _Handler = Future<void> Function(HttpRequest, _ImageServer);

class _ImageServer {
  _ImageServer(this.server, this.bytes);
  final HttpServer server;
  final Uint8List bytes;
  final closed = Completer<void>();
  final requests = <Map<String, String?>>[];
  final http = TransferHttp();
  ImagePreviewLoader get loader => ImagePreviewLoader(http);

  DownloadSpec source({int? size, Map<String, String> headers = const {}}) =>
      DownloadSpec(
        url: 'http://127.0.0.1:${server.port}/photo.jpg',
        fileName: 'photo.jpg',
        expectedSize: size ?? bytes.length,
        headers: headers,
      );

  Future<void> reply(
    HttpRequest request, {
    bool ignoreRange = false,
    String? etag = _etag,
    String? modified,
    bool chunked = false,
    int? total,
    int missing = 0,
  }) async {
    final range = ignoreRange ? null : _requestedRange(request);
    final first = range?.$1 ?? 0, last = range?.$2 ?? bytes.length - 1;
    final response = request.response;
    response.statusCode = range == null ? 200 : 206;
    response.headers.contentType = ContentType.binary;
    if (etag != null) response.headers.set('ETag', etag);
    if (modified != null) response.headers.set('Last-Modified', modified);
    if (range != null) {
      response.headers.set(
        'Content-Range',
        'bytes $first-$last/${total ?? bytes.length}',
      );
    }
    if (!chunked) response.contentLength = last - first + 1;
    response.add(Uint8List.sublistView(bytes, first, last + 1 - missing));
    await response.close();
  }
}

(int, int)? _requestedRange(HttpRequest request) {
  final value = request.headers.value('range');
  if (value == null) return null;
  final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(value)!;
  return (int.parse(match[1]!), int.parse(match[2]!));
}

bool _isProbe(HttpRequest request) => _requestedRange(request) == (0, 0);

Future<void> _withServer(
  Future<void> Function(_ImageServer) body, {
  _Handler? handler,
  int size = 2 * _mib + 17,
}) => HttpOverrides.runWithHttpOverrides(() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final fixture = _ImageServer(
    server,
    Uint8List.fromList(List.generate(size, (i) => (i * 31 + (i >> 16)) & 255)),
  );
  final pending = <Future<void>>[];
  server.listen((request) {
    fixture.requests.add({
      for (final key in ['range', 'if-range', 'cookie', 'accept-encoding'])
        key: request.headers.value(key),
    });
    pending.add(() async {
      try {
        await (handler == null
            ? fixture.reply(request)
            : handler(request, fixture));
      } on HttpException {
        // A canceled or deliberately truncated response may fail at the server.
      } on SocketException {
        // The client is allowed to close a rejected response without draining it.
      }
    }());
  });
  try {
    await body(fixture);
  } finally {
    fixture.closed.complete();
    fixture.http.dio.close(force: true);
    await server.close(force: true);
    await Future.wait(pending);
  }
}, _LocalIo());

void _sameBytes(Uint8List actual, Uint8List expected) {
  expect(actual.length, expected.length);
  expect(sha256.convert(actual), sha256.convert(expected));
}

void main() {
  test(
    'large images overlap requests and assemble out-of-order ranges',
    () async {
      final together = Completer<void>();
      final completionOrder = <int>[];
      var active = 0, peak = 0;
      await _withServer(
        (server) async {
          final result = await server.loader
              .load(
                server.source(
                  headers: {
                    'Cookie': 'test-session=local',
                    'range': 'bytes=99-100',
                    'if-range': 'stale',
                    'accept-encoding': 'gzip',
                  },
                ),
                connections: 4,
              )
              .timeout(const Duration(seconds: 5));
          _sameBytes(result, server.bytes);
          expect(peak, 4);
          expect(completionOrder.first, greaterThan(0));
          expect(server.requests, hasLength(5));
          expect(server.requests.first['range'], 'bytes=0-0');
          expect(server.requests.first['if-range'], isNull);
          for (final request in server.requests) {
            expect(request['cookie'], 'test-session=local');
            expect(request['accept-encoding'], 'identity');
          }
          expect(
            server.requests.skip(1).map((r) => r['if-range']),
            everyElement(_etag),
          );
        },
        handler: (request, server) async {
          if (_isProbe(request)) return server.reply(request);
          final first = _requestedRange(request)!.$1;
          peak = math.max(peak, ++active);
          if (active == 4) together.complete();
          await together.future.timeout(const Duration(seconds: 3));
          // Keep the first range pending until another range has completed.
          if (first == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 80));
          }
          await server.reply(request);
          completionOrder.add(first);
          active--;
        },
      );
    },
  );

  for (final connections in [1, 3, 8, 64, 512]) {
    test(
      'honors connection budget $connections with an eight-connection cap',
      () => _withServer((server) async {
        _sameBytes(
          await server.loader.load(server.source(), connections: connections),
          server.bytes,
        );
        final count = math.min(connections, 8);
        expect(server.requests, hasLength(count == 1 ? 1 : count + 1));
        if (count == 1) expect(server.requests.single['range'], isNull);
      }, size: 4 * _mib + 13),
    );
  }

  test(
    'known small image needs only one ordinary request',
    () => _withServer((server) async {
      _sameBytes(await server.loader.load(server.source()), server.bytes);
      expect(server.requests.single['range'], isNull);
    }, size: _mib),
  );

  test(
    'unknown image size is discovered before parallel reads',
    () => _withServer((server) async {
      _sameBytes(
        await server.loader.load(server.source(size: 0)),
        server.bytes,
      );
      expect(server.requests, hasLength(5));
    }),
  );

  test(
    'server ignoring the probe reuses its full response',
    () => _withServer((server) async {
      _sameBytes(await server.loader.load(server.source()), server.bytes);
      expect(server.requests, hasLength(1));
    }, handler: (request, server) => server.reply(request, ignoreRange: true)),
  );

  for (final code in [400, 405, 416, 501]) {
    test(
      'probe rejection $code falls back to one ordinary request',
      () => _withServer(
        (server) async {
          _sameBytes(
            await server.loader.load(server.source(size: 0)),
            server.bytes,
          );
          expect(server.requests, hasLength(2));
          expect(server.requests.last['range'], isNull);
        },
        size: 128,
        handler: (request, server) async {
          if (_isProbe(request)) {
            request.response.statusCode = code;
            await request.response.close();
          } else {
            await server.reply(request);
          }
        },
      ),
    );
  }

  for (final etag in [null, 'W/"weak-image"']) {
    test(
      'missing strong validator ($etag) uses one complete representation',
      () => _withServer((server) async {
        _sameBytes(await server.loader.load(server.source()), server.bytes);
        expect(server.requests, hasLength(2));
        expect(server.requests.last['range'], isNull);
      }, handler: (request, server) => server.reply(request, etag: etag)),
    );
  }

  test(
    'Last-Modified protects ranges when the ETag is weak',
    () => _withServer(
      (server) async {
        _sameBytes(await server.loader.load(server.source()), server.bytes);
        expect(server.requests, hasLength(5));
        expect(
          server.requests.skip(1).map((r) => r['if-range']),
          everyElement(_modified),
        );
      },
      handler: (request, server) =>
          server.reply(request, etag: 'W/"weak-image"', modified: _modified),
    ),
  );

  for (final code in [200, 416]) {
    test('segment response $code cancels ranges before full fallback', () async {
      final allStarted = Completer<void>();
      var started = 0;
      await _withServer(
        (server) async {
          _sameBytes(
            await server.loader
                .load(server.source(), connections: 4)
                .timeout(const Duration(seconds: 5)),
            server.bytes,
          );
          expect(started, 4);
          expect(
            server.requests.where((r) => r['range'] == null),
            hasLength(1),
          );
          expect(server.requests, hasLength(6));
        },
        handler: (request, server) async {
          if (_isProbe(request) || _requestedRange(request) == null) {
            return server.reply(request);
          }
          if (++started == 4) allStarted.complete();
          await allStarted.future;
          if (_requestedRange(request)!.$1 == 0) {
            request.response.statusCode = code;
            await request.response.close();
          } else {
            // The loader must cancel these requests without waiting for headers.
            await server.closed.future;
          }
        },
      );
    });
  }

  for (final fault in [
    'changed etag',
    'missing etag',
    'changed total',
    'wrong range',
    'encoded segment',
    'wrong length',
    'overflow',
  ]) {
    test(
      'rejects $fault instead of returning mixed or incomplete image bytes',
      () => _withServer(
        (server) async {
          await expectLater(
            server.loader.load(server.source()),
            throwsA(isA<AppException>()),
          );
          expect(server.requests.where((r) => r['range'] == null), isEmpty);
        },
        handler: (request, server) async {
          if (_isProbe(request)) return server.reply(request);
          if (fault == 'changed etag' || fault == 'missing etag') {
            return server.reply(
              request,
              etag: fault == 'missing etag' ? null : '"image-v2"',
            );
          }
          if (fault == 'changed total') {
            return server.reply(request, total: server.bytes.length + 1);
          }
          final (first, last) = _requestedRange(request)!;
          final response = request.response;
          response.statusCode = 206;
          response.headers.set('ETag', _etag);
          response.headers.set(
            'Content-Range',
            'bytes ${fault == 'wrong range' ? first + 1 : first}-$last/${server.bytes.length}',
          );
          if (fault == 'encoded segment') {
            response.headers.set('Content-Encoding', 'br');
          }
          if (fault == 'wrong length') {
            response.contentLength = last - first;
          }
          response.add(
            Uint8List.sublistView(
              server.bytes,
              first,
              fault == 'wrong length' ? last : last + 1,
            ),
          );
          if (fault == 'overflow') response.add([0]);
          await response.close();
        },
      ),
    );
  }

  test(
    'malformed probe is rejected before starting any segment',
    () => _withServer(
      (server) async {
        await expectLater(
          server.loader.load(server.source()),
          throwsA(isA<AppException>()),
        );
        expect(server.requests, hasLength(1));
      },
      handler: (request, server) async {
        request.response.statusCode = 206;
        request.response.headers.set('Content-Range', 'bytes 0-2/2097152');
        request.response.add([1, 2, 3]);
        await request.response.close();
      },
    ),
  );

  test(
    'retries only a truncated segment, preserving the other finished ranges',
    () async {
      final attempts = <String, int>{};
      await _withServer(
        (server) async {
          _sameBytes(await server.loader.load(server.source()), server.bytes);
          expect(attempts.values.where((n) => n == 2), hasLength(1));
          expect(server.requests, hasLength(6));
        },
        handler: (request, server) async {
          final range = request.headers.value('range')!;
          final attempt = attempts.update(
            range,
            (n) => n + 1,
            ifAbsent: () => 1,
          );
          await server.reply(
            request,
            chunked: true,
            missing:
                !_isProbe(request) &&
                    _requestedRange(request)!.$1 == 0 &&
                    attempt == 1
                ? 1
                : 0,
          );
        },
      );
    },
  );

  test('transient server failure retries the affected segment once', () async {
    var failed = false;
    await _withServer(
      (server) async {
        _sameBytes(await server.loader.load(server.source()), server.bytes);
        expect(server.requests, hasLength(6));
      },
      handler: (request, server) async {
        if (!_isProbe(request) && !failed) {
          failed = true;
          request.response.statusCode = 503;
          await request.response.close();
        } else {
          await server.reply(request);
        }
      },
    );
  });

  test('Retry-After is respected without an unbounded retry loop', () async {
    final arrivals = <DateTime>[];
    await _withServer(
      (server) async {
        await expectLater(
          server.loader.load(server.source()),
          throwsA(
            isA<DownloadHttpException>().having((e) => e.status, 'status', 429),
          ),
        );
        expect(arrivals, hasLength(2));
        expect(
          arrivals.last.difference(arrivals.first),
          greaterThanOrEqualTo(const Duration(seconds: 3)),
        );
      },
      size: 128,
      handler: (request, server) async {
        arrivals.add(DateTime.now());
        request.response.statusCode = 429;
        request.response.headers.set('Retry-After', '3');
        await request.response.close();
      },
    );
  });

  test(
    'unknown chunked full body stays bounded and returns exact bytes',
    () => _withServer(
      (server) async {
        _sameBytes(
          await server.loader.load(server.source(size: 0)),
          server.bytes,
        );
        expect(server.requests, hasLength(1));
      },
      size: 129,
      handler: (request, server) =>
          server.reply(request, ignoreRange: true, chunked: true),
    ),
  );

  test(
    'metadata above the image limit starts no network request',
    () => _withServer((server) async {
      await expectLater(
        server.loader.load(server.source(size: 65 * _mib)),
        throwsA(isA<AppException>()),
      );
      expect(server.requests, isEmpty);
    }, size: 128),
  );

  for (final chunked in [false, true]) {
    test(
      'full body enforces the size limit (chunked: $chunked)',
      () => _withServer(
        (server) async {
          await expectLater(
            server.loader.load(server.source(size: 0), limit: 128),
            throwsA(isA<AppException>()),
          );
          expect(server.requests, hasLength(1));
        },
        size: 129,
        handler: (request, server) =>
            server.reply(request, ignoreRange: true, chunked: chunked),
      ),
    );
  }

  test(
    'range-discovered image above the limit starts no segments',
    () => _withServer(
      (server) async {
        await expectLater(
          server.loader.load(server.source(size: 0)),
          throwsA(isA<AppException>()),
        );
        expect(server.requests, hasLength(1));
      },
      size: 128,
      handler: (request, server) => server.reply(request, total: 65 * _mib),
    ),
  );

  test(
    'mismatched metadata is rejected before reading a full image',
    () => _withServer((server) async {
      await expectLater(
        server.loader.load(server.source(size: 127)),
        throwsA(isA<AppException>()),
      );
      expect(server.requests, hasLength(1));
    }, size: 128),
  );

  test(
    'single-response truncation retries once and never returns partial bytes',
    () => _withServer(
      (server) async {
        await expectLater(
          server.loader.load(server.source()),
          throwsA(isA<DownloadNetworkException>()),
        );
        expect(server.requests, hasLength(2));
      },
      size: 128,
      handler: (request, server) =>
          server.reply(request, chunked: true, missing: 1),
    ),
  );

  test(
    'ordinary request cannot treat a partial 206 as a complete image',
    () => _withServer(
      (server) async {
        await expectLater(
          server.loader.load(server.source()),
          throwsA(isA<AppException>()),
        );
        expect(server.requests, hasLength(1));
      },
      size: 128,
      handler: (request, server) async {
        request.response.statusCode = 206;
        request.response.headers.set('Content-Range', 'bytes 0-9/128');
        request.response.add(List.filled(10, 0));
        await request.response.close();
      },
    ),
  );

  for (final code in [401, 403]) {
    test(
      'authentication failure $code does not fan out or retry',
      () => _withServer(
        (server) async {
          await expectLater(
            server.loader.load(server.source()),
            throwsA(
              isA<DownloadHttpException>().having(
                (e) => e.status,
                'status',
                code,
              ),
            ),
          );
          expect(server.requests, hasLength(1));
        },
        handler: (request, server) async {
          request.response.statusCode = code;
          await request.response.close();
        },
      ),
    );
  }

  for (final stage in ['probe headers', 'parallel bodies', 'retry delay']) {
    test(
      'leaving preview promptly cancels $stage and starts no fallback',
      () async {
        final ready = Completer<void>();
        final scope = RequestScope();
        var segments = 0;
        await _withServer(
          (server) async {
            final loading = scope.run(
              () => server.loader.load(server.source(), connections: 4),
            );
            final canceled = expectLater(
              loading,
              throwsA(
                isA<DioException>().having(
                  (e) => e.type,
                  'type',
                  DioExceptionType.cancel,
                ),
              ),
            );
            await ready.future.timeout(const Duration(seconds: 3));
            if (stage == 'retry delay') {
              await Future<void>.delayed(const Duration(milliseconds: 80));
            }
            scope.cancel();
            await canceled.timeout(const Duration(seconds: 1));
            expect(
              server.requests,
              hasLength(stage == 'parallel bodies' ? 5 : 1),
            );
            expect(server.requests.where((r) => r['range'] == null), isEmpty);
          },
          handler: (request, server) async {
            if (stage == 'probe headers') {
              ready.complete();
              await server.closed.future;
            } else if (stage == 'retry delay') {
              request.response.statusCode = 429;
              request.response.headers.set('Retry-After', '60');
              await request.response.close();
              ready.complete();
            } else if (_isProbe(request)) {
              await server.reply(request);
            } else {
              final (first, last) = _requestedRange(request)!;
              request.response.statusCode = 206;
              request.response.contentLength = last - first + 1;
              request.response.headers.set('ETag', _etag);
              request.response.headers.set(
                'Content-Range',
                'bytes $first-$last/${server.bytes.length}',
              );
              request.response.add([server.bytes[first]]);
              await request.response.flush();
              if (++segments == 4) ready.complete();
              await server.closed.future;
            }
          },
        );
      },
    );
  }
}
