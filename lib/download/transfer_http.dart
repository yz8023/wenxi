import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../domain/downloads.dart';

class DownloadHttpException extends AppException {
  DownloadHttpException(this.status, {this.retryAfter, this.exhausted = false})
    : super(status == 429 ? '服务器请求过于频繁，请稍后重试' : '服务器返回 $status');
  final int status;
  final Duration? retryAfter;
  final bool exhausted;
  bool get mayRefresh => {401, 403, 410}.contains(status);
  factory DownloadHttpException.response(Response response) =>
      DownloadHttpException(
        response.statusCode ?? 0,
        retryAfter: parseRetryAfter(response.headers.value('retry-after')),
      );
}

Duration? parseRetryAfter(String? header) {
  if (header == null) return null;
  final seconds = int.tryParse(header.trim());
  if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
  try {
    final value = HttpDate.parse(header).difference(DateTime.now().toUtc());
    return value.isNegative ? Duration.zero : value;
  } catch (_) {
    return null;
  }
}

class DownloadNetworkException extends AppException {
  const DownloadNetworkException(this.kind, {this.retryable = true})
    : super('下载连接中断或超时，请检查网络后重试');
  final String kind;
  final bool retryable;
}

class DownloadRetryExhausted extends AppException {
  DownloadRetryExhausted(Object cause)
    : super(cause is AppException ? cause.message : '网络重试次数已用完，请稍后继续下载');
}

bool retryableDownloadError(Object error) => switch (error) {
  DownloadHttpException e =>
    !e.exhausted && {408, 425, 429, 500, 502, 503, 504}.contains(e.status),
  DownloadNetworkException e => e.retryable,
  DioException e => HttpRequestFailure.network(e).retryable,
  SocketException() || TimeoutException() => true,
  _ => false,
};

Duration downloadRetryDelay(int attempt, Object error) {
  final normal = Duration(seconds: const [2, 5, 10][attempt.clamp(0, 2)]);
  final server = error is DownloadHttpException ? error.retryAfter : null;
  return server != null && server > normal ? server : normal;
}

class Probe {
  const Probe(this.identity, this.hls);
  final RemoteIdentity identity;
  final bool hls;

  factory Probe.response(
    int code,
    Map<String, String> headers, {
    bool hlsPath = false,
    int probeBytes = 1,
  }) {
    if (code == 416 && headers['content-range'] == 'bytes */0') {
      return Probe(
        RemoteIdentity(0, headers['etag'], headers['last-modified']),
        false,
      );
    }
    if (code < 200 || code >= 300) {
      throw DownloadHttpException(
        code,
        retryAfter: parseRetryAfter(headers['retry-after']),
      );
    }
    var total = int.tryParse(headers['content-length'] ?? '') ?? 0;
    if (code == 206) {
      final match = RegExp(
        r'^bytes 0-(\d+)/(\d+)$',
        caseSensitive: false,
      ).firstMatch(headers['content-range'] ?? '');
      require(match != null, '服务器返回的文件范围无效');
      final end = int.parse(match!.group(1)!);
      total = int.parse(match.group(2)!);
      final length = int.tryParse(headers['content-length'] ?? '');
      require(
        probeBytes > 0 &&
            total > 0 &&
            end == (total < probeBytes ? total : probeBytes) - 1 &&
            (length == null || length == end + 1),
        '服务器返回的文件范围无效',
      );
    }
    return Probe(
      RemoteIdentity(total, headers['etag'], headers['last-modified']),
      hlsPath ||
          (headers['content-type']?.toLowerCase().contains('mpegurl') ?? false),
    );
  }
}

class TransferHttp {
  TransferHttp({Dio? client})
    : dio =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 45),
              sendTimeout: const Duration(seconds: 30),
              validateStatus: (_) => true,
            ),
          );
  final Dio dio;

  Uri _responseUri(Response<dynamic> response) {
    var uri = response.requestOptions.uri;
    // The IO adapter preserves relative Location headers in redirect records.
    for (final redirect in response.redirects) {
      uri = uri.resolveUri(redirect.location);
    }
    return uri;
  }

  Map<String, String> headers(Map<String, String> source) => {
    for (final e in source.entries)
      if (!{
        'range',
        'if-range',
        'accept-encoding',
      }.contains(e.key.toLowerCase()))
        e.key: e.value,
    'Accept-Encoding': 'identity',
  };
  Future<Response<ResponseBody>> stream(
    String url,
    Map<String, String> h, {
    CancelToken? cancel,
  }) async {
    final uri = Uri.tryParse(url);
    require(
      uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty,
      '下载地址无效',
    );
    try {
      return await dio.get<ResponseBody>(
        url,
        cancelToken: cancel ?? RequestScope.current,
        options: Options(
          headers: h,
          responseType: ResponseType.stream,
          maxRedirects: 5,
        ),
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw DownloadNetworkException(
        e.type.name,
        retryable: retryableDownloadError(e),
      );
    }
  }

  Future<Probe> probe(String url, Map<String, String> h) async {
    final parent = RequestScope.current;
    var probeBytes = 1;
    while (true) {
      final cancel = CancelToken();
      if (parent?.isCancelled == true) cancel.cancel();
      parent?.whenCancel.then((_) {
        if (!cancel.isCancelled) cancel.cancel();
      });
      try {
        final response = await stream(url, {
          ...headers(h),
          'Range': 'bytes=0-${probeBytes - 1}',
        }, cancel: cancel);
        // Guangya's CDN answers 0-0 with HTTP 200 and Content-Length: 1,
        // even for a large file. A two-byte probe reveals its actual range.
        if (probeBytes == 1 &&
            response.statusCode == 200 &&
            response.headers.value('content-length') == '1' &&
            response.headers.value('content-range') == null) {
          probeBytes = 2;
          continue;
        }
        return Probe.response(
          response.statusCode ?? 0,
          {
            for (final entry in response.headers.map.entries)
              if (entry.value.isNotEmpty)
                entry.key.toLowerCase(): entry.value.first,
          },
          probeBytes: probeBytes,
          hlsPath:
              Uri.parse(url).path.toLowerCase().endsWith('.m3u8') ||
              _responseUri(response).path.toLowerCase().endsWith('.m3u8'),
        );
      } finally {
        cancel.cancel();
      }
    }
  }

  Future<Uint8List> limited(
    String url,
    Map<String, String> h,
    int limit,
  ) async => (await _limitedResponse(url, h, limit)).bytes;

  Future<({Uint8List bytes, String url})> _limitedResponse(
    String url,
    Map<String, String> h,
    int limit,
  ) async {
    final cancel = CancelToken(), parent = RequestScope.current;
    if (parent?.isCancelled == true) cancel.cancel();
    parent?.whenCancel.then((_) {
      if (!cancel.isCancelled) cancel.cancel();
    });
    try {
      final response = await stream(url, headers(h), cancel: cancel),
          bytes = BytesBuilder(copy: false);
      final code = response.statusCode ?? 0;
      if (code < 200 || code >= 300) {
        throw DownloadHttpException.response(response);
      }
      await for (final chunk in response.data!.stream) {
        require(bytes.length + chunk.length <= limit, '文件过大，请下载后查看');
        bytes.add(chunk);
      }
      return (bytes: bytes.takeBytes(), url: _responseUri(response).toString());
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw DownloadNetworkException(
        e.type.name,
        retryable: retryableDownloadError(e),
      );
    } finally {
      cancel.cancel();
    }
  }

  Future<String> text(
    String url,
    Map<String, String> h, {
    int limit = 2 * 1024 * 1024,
  }) async => utf8.decode(await limited(url, h, limit), allowMalformed: true);

  Future<({String text, String url})> textResponse(
    String url,
    Map<String, String> h, {
    int limit = 2 * 1024 * 1024,
  }) async {
    final response = await _limitedResponse(url, h, limit);
    return (
      text: utf8.decode(response.bytes, allowMalformed: true),
      url: response.url,
    );
  }
}
