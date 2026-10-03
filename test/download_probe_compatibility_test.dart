import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/download/transfer_http.dart';

class _Network extends HttpOverrides {}

void main() {
  test(
    'Retries a misleading one-byte full response before choosing file size',
    () => HttpOverrides.runWithHttpOverrides(() async {
      const total = 4518904017;
      final requests = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final range = request.headers.value('range')!;
        requests.add(range);
        expect(request.headers.value('cookie'), 'session=fixture');
        expect(request.headers.value('accept-encoding'), 'identity');
        expect(request.uri.queryParameters['sign'], 'fixture+value');
        if (range == 'bytes=0-0') {
          request.response.contentLength = 1;
          request.response.add([1]);
        } else {
          expect(range, 'bytes=0-1');
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set('content-range', 'bytes 0-1/$total');
          request.response.contentLength = 2;
          request.response.add([1, 2]);
        }
        await request.response.close();
      });
      final http = TransferHttp();
      try {
        final result = await http.probe(
          'http://127.0.0.1:${server.port}/file?sign=fixture%2Bvalue',
          {'Cookie': 'session=fixture'},
        );
        expect(result.identity.total, total);
        expect(requests, ['bytes=0-0', 'bytes=0-1']);
      } finally {
        http.dio.close(force: true);
        await server.close(force: true);
      }
    }, _Network()),
  );

  for (final length in [0, 1]) {
    test(
      'Compatibility probing preserves a genuine $length-byte file',
      () => HttpOverrides.runWithHttpOverrides(() async {
        var requests = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          requests++;
          if (length == 0) {
            request.response.statusCode =
                HttpStatus.requestedRangeNotSatisfiable;
            request.response.headers.set('content-range', 'bytes */0');
          } else {
            request.response.contentLength = 1;
            request.response.add([1]);
          }
          await request.response.close();
        });
        final http = TransferHttp();
        try {
          final result = await http.probe(
            'http://127.0.0.1:${server.port}/file',
            {},
          );
          expect(result.identity.total, length);
          expect(requests, length == 0 ? 1 : 2);
        } finally {
          http.dio.close(force: true);
          await server.close(force: true);
        }
      }, _Network()),
    );
  }

  for (final range in ['bytes 1-2/100', 'bytes 0-7/100', 'bytes 0-1/1']) {
    test(
      'Two-byte compatibility responses still validate their range: $range',
      () {
        expect(
          () => Probe.response(206, {
            'content-range': range,
            'content-length': '2',
          }, probeBytes: 2),
          throwsA(isA<AppException>()),
        );
      },
    );
  }

  test('A two-byte probe can end at the end of a one-byte file', () {
    final result = Probe.response(206, {
      'content-range': 'bytes 0-0/1',
      'content-length': '1',
    }, probeBytes: 2);
    expect(result.identity.total, 1);
  });
}
