// Explicit public-share probe; offline tests never access the cloud network.
import 'dart:convert';
import 'dart:io';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/lanzou.dart';
import 'package:asterlink/domain/links.dart';

class _ObservedHttp extends JsonHttp {
  final transport = DioJsonHttp();
  final requests = <Json>[];
  Future<HttpResult> _record(
    String method,
    String url,
    Future<HttpResult> Function() action, {
    int? limit,
  }) async {
    final uri = Uri.parse(url);
    final result = await action();
    requests.add({
      'method': method,
      'host': uri.host,
      'status': result.status,
      'contentType': result.header('content-type'),
      'bodyCharactersRead': result.body.length,
      'responseCookieScopes': [
        for (final raw in result.headers['set-cookie'] ?? <String>[])
          {
            'name': Cookie.fromSetCookieValue(raw).name,
            'domain': Cookie.fromSetCookieValue(raw).domain,
            'path': Cookie.fromSetCookieValue(raw).path,
          },
      ],
      'stage': uri.path.contains('ajax')
          ? 'resolve'
          : uri.path == '/fn'
          ? 'iframe'
          : uri.path.startsWith('/i')
          ? 'share'
          : 'download-probe',
      'readLimitBytes': ?limit,
    });
    if (method == 'GET' || method == 'POST') {
      // Local troubleshooting only; never included in a delivery or report.
      final file = File(
        '.local/lanzou-preflight/response-${requests.length}.txt',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString(result.body);
    }
    return result;
  }

  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) => _record(
    method,
    url,
    () => transport.request(
      method,
      url,
      body: body,
      headers: headers,
      followRedirects: followRedirects,
      contentType: contentType,
    ),
  );
  @override
  Future<HttpResult> peek(
    String url,
    Map<String, String> headers, {
    int maxBytes = 8192,
    bool followRedirects = true,
  }) => _record(
    'GET',
    url,
    () => transport.peek(
      url,
      headers,
      maxBytes: maxBytes,
      followRedirects: followRedirects,
    ),
    limit: maxBytes,
  );
}

Future<void> main() async {
  const url = 'https://daxiaamu.lanzouu.com/ixLqp3xhy4ah';
  final http = _ObservedHttp();
  final scope = RequestScope();
  final report = <String, Object?>{
    'checkedUtc': DateTime.now().toUtc().toIso8601String(),
    'publicShareUrl': url,
    'realAccountCredentialsUsed': false,
    'gopeedTaskStarted': false,
    'entireFileDownloaded': false,
  };
  try {
    await scope
        .run(() async {
          final connector = LanzouConnector(http);
          final session = await connector.openShare(
            LinkParser.parse(url).single,
            null,
          );
          final files = await connector.list(session, session.rootId, null);
          require(
            files.length == 1 && files.single.name.isNotEmpty,
            'Public file metadata unavailable',
          );
          final spec = await connector.download(session, files.single, null);
          require(
            Uri.parse(spec.url).scheme == 'https' && spec.expectedSize > 0,
            'Public download target could not be verified',
          );
          report.addAll({
            'passed': true,
            'singleFileMetadataParsed': true,
            'finalDownloadHeadersVerified': true,
            'exactContentLength': spec.expectedSize,
            'cloudTransferRequired': false,
            'temporarySignedUrlOmittedFromReport': true,
          });
        })
        .timeout(
          const Duration(seconds: 100),
          onTimeout: () {
            scope.cancel();
            throw const AppException('Public Lanzou preflight timed out');
          },
        );
  } catch (error) {
    report['passed'] = false;
    report['error'] = error is AppException
        ? error.message
        : error.runtimeType.toString();
    exitCode = 1;
  } finally {
    report['requests'] = http.requests;
    http.transport.dio.close(force: true);
    final text = const JsonEncoder.withIndent('  ').convert(report);
    await File('docs/PUBLIC-LANZOU-PREFLIGHT.json').writeAsString('$text\n');
    stdout.writeln(text);
  }
}
