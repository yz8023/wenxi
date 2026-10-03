import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/http.dart';

class _LocalIo extends HttpOverrides {}

void main() {
  test(
    'Bounded probes can inspect a redirect without following it or forwarding cookies',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var finalRequests = 0;
      server.listen((request) async {
        if (request.uri.path == '/file') {
          finalRequests++;
          request.response.write('file');
        } else {
          request.response.statusCode = 302;
          request.response.headers.set('Location', '/file');
        }
        await request.response.close();
      });
      final http = DioJsonHttp();
      try {
        final response = await http.peek(
          'http://127.0.0.1:${server.port}/redirect',
          {'Cookie': 'scoped=only'},
          followRedirects: false,
        );
        expect(response.status, 302);
        expect(response.header('location'), '/file');
        expect(finalRequests, 0);
      } finally {
        http.dio.close(force: true);
        await server.close(force: true);
      }
    }, _LocalIo()),
  );

  test(
    'A server ignoring Range cannot make a probe wait for or buffer the entire file',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      server.listen((request) async {
        try {
          request.response.headers.contentType = ContentType.binary;
          request.response.add(List.filled(64 * 1024, 65));
          await request.response.flush();
          await release.future;
          await request.response.close();
        } on HttpException {
          // The client is expected to stop reading and close early.
        } on SocketException {
          // The client is expected to stop reading and close early.
        }
      });
      final http = DioJsonHttp();
      try {
        final result = await http
            .peek(
              'http://127.0.0.1:${server.port}/large',
              {},
              maxBytes: 4096,
              followRedirects: false,
            )
            .timeout(const Duration(seconds: 5));
        expect(result.status, 200);
        expect(result.body, hasLength(4096));
        expect(release.isCompleted, isFalse);
      } finally {
        release.complete();
        http.dio.close(force: true);
        await server.close(force: true);
      }
    }, _LocalIo()),
  );
}
