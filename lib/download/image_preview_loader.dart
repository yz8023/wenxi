import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../domain/downloads.dart';
import '../domain/models.dart';
import 'transfer_http.dart';

class _RangeUnavailable implements Exception {}

/// Image bytes stay in one bounded buffer. Only large, validated resources use
/// concurrent ranges; ordinary responses and small images keep one connection.
class ImagePreviewLoader {
  const ImagePreviewLoader(this.http);
  final TransferHttp http;
  static const maxConnections = 8;
  static const parallelThreshold = 1024 * 1024;
  static const minimumSegmentBytes = 512 * 1024;

  Future<Uint8List> load(
    DownloadSpec source, {
    int limit = 64 * 1024 * 1024,
    int connections = maxConnections,
  }) async {
    require(limit > 0, '图片预览大小限制无效');
    require(source.expectedSize <= limit, '图片过大，请下载后查看');
    RequestScope.checkpoint();
    final budget = connections.clamp(1, maxConnections);
    if (budget == 1 ||
        source.expectedSize > 0 && source.expectedSize <= parallelThreshold) {
      return _single(source, limit);
    }

    final requests = _PreviewRequests();
    RemoteIdentity? identity;
    try {
      final complete = await _request<Uint8List?>(
        source,
        {...http.headers(source.headers), 'Range': 'bytes=0-0'},
        requests,
        (response) async {
          final code = response.statusCode ?? 0;
          if (code == 200) return _readFull(response, source, limit, requests);
          if (_refusesRange(code)) throw _RangeUnavailable();
          if (code != 206) throw DownloadHttpException.response(response);
          final range = _range(response);
          require(
            range != null && range.$1 == 0 && range.$2 == 0,
            '图片分段响应无效，请重新打开',
          );
          _checkSize(range!.$3, source, limit);
          identity = _identity(response, range.$3);
          if (!_unencoded(response) ||
              identity!.ifRange == null ||
              range.$3 <= parallelThreshold) {
            throw _RangeUnavailable();
          }
          await _readRange(response, Uint8List(1), 0, 0, requests);
          return null;
        },
      );
      if (complete != null) return complete;
    } on _RangeUnavailable {
      identity = null;
    } finally {
      requests.close();
    }
    if (identity == null) return _single(source, limit);

    try {
      return await _parallel(source, identity!, budget);
    } on _RangeUnavailable {
      // All range readers have stopped before a fresh full response is read.
      // Never combine a server's full response with already received segments.
      return _single(source, limit);
    }
  }

  Future<Uint8List> _single(DownloadSpec source, int limit) async {
    final requests = _PreviewRequests();
    try {
      return await _request(
        source,
        http.headers(source.headers),
        requests,
        (response) => _readFull(response, source, limit, requests),
      );
    } finally {
      requests.close();
    }
  }

  Future<Uint8List> _parallel(
    DownloadSpec source,
    RemoteIdentity identity,
    int budget,
  ) async {
    final count = math.min(budget, identity.total ~/ minimumSegmentBytes);
    final bytes = Uint8List(identity.total);
    final requests = _PreviewRequests();
    Object? failure;
    StackTrace? trace;
    try {
      await Future.wait([
        for (var index = 0; index < count; index++)
          () async {
            final first = identity.total * index ~/ count;
            final last = identity.total * (index + 1) ~/ count - 1;
            try {
              await _request<void>(
                source,
                {
                  ...http.headers(source.headers),
                  'Range': 'bytes=$first-$last',
                  'If-Range': identity.ifRange!,
                },
                requests,
                (response) async {
                  final code = response.statusCode ?? 0;
                  if (code == 200 || _refusesRange(code)) {
                    throw _RangeUnavailable();
                  }
                  if (code != 206) {
                    throw DownloadHttpException.response(response);
                  }
                  require(
                    _range(response) == (first, last, identity.total) &&
                        _unencoded(response) &&
                        identity.canResume(_identity(response, identity.total)),
                    '图片内容或分段响应已变化，请重新打开',
                  );
                  await _readRange(response, bytes, first, last, requests);
                },
              );
            } catch (error, stack) {
              if (failure == null) {
                failure = error;
                trace = stack;
                requests.cancel();
              }
            }
          }(),
      ]);
      if (failure != null) Error.throwWithStackTrace(failure!, trace!);
      requests.check();
      return bytes;
    } finally {
      requests.close();
    }
  }

  Future<T> _request<T>(
    DownloadSpec source,
    Map<String, String> headers,
    _PreviewRequests requests,
    Future<T> Function(Response<ResponseBody>) read,
  ) async {
    for (var attempt = 0; ; attempt++) {
      requests.check();
      final cancel = requests.open();
      Object? retry;
      try {
        final response = await http.stream(source.url, headers, cancel: cancel);
        requests.check();
        return await read(response);
      } catch (error, stack) {
        requests.check();
        final normalized = switch (error) {
          DioException e when !CancelToken.isCancel(e) =>
            DownloadNetworkException(
              e.type.name,
              retryable: retryableDownloadError(e) || e.error is HttpException,
            ),
          HttpException() ||
          SocketException() ||
          TimeoutException() => const DownloadNetworkException('imageStream'),
          _ => error,
        };
        if (attempt >= 1 || !retryableDownloadError(normalized)) {
          Error.throwWithStackTrace(normalized, stack);
        }
        retry = normalized;
      } finally {
        requests.release(cancel);
      }
      await requests.wait(downloadRetryDelay(attempt, retry));
    }
  }

  Future<Uint8List> _readFull(
    Response<ResponseBody> response,
    DownloadSpec source,
    int limit,
    _PreviewRequests requests,
  ) async {
    final code = response.statusCode ?? 0;
    if (code != 200 && code != 206) {
      throw DownloadHttpException.response(response);
    }
    int? length = _unencoded(response) ? _length(response) : null;
    if (code == 206) {
      final range = _range(response);
      require(
        range != null && range.$1 == 0 && range.$2 + 1 == range.$3,
        '服务器未返回完整图片，请重新打开',
      );
      length = range!.$3;
    }
    if (length != null) _checkSize(length, source, limit);
    final known =
        length ?? (source.expectedSize > 0 ? source.expectedSize : null);
    final buffer = known == null ? null : Uint8List(known);
    final chunks = buffer == null ? BytesBuilder(copy: false) : null;
    var received = 0;
    await for (final chunk in response.data!.stream) {
      requests.check();
      require(received + chunk.length <= limit, '图片过大，请下载后查看');
      require(
        known == null || received + chunk.length <= known,
        '图片大小与文件信息不一致，请重新打开',
      );
      buffer?.setRange(received, received + chunk.length, chunk);
      chunks?.add(chunk);
      received += chunk.length;
    }
    requests.check();
    if (known != null && received < known) {
      throw const DownloadNetworkException('incompleteImage');
    }
    _checkSize(received, source, limit);
    return buffer ?? chunks!.takeBytes();
  }

  Future<void> _readRange(
    Response<ResponseBody> response,
    Uint8List buffer,
    int first,
    int last,
    _PreviewRequests requests,
  ) async {
    final length = _length(response);
    require(length == null || length == last - first + 1, '图片分段长度不一致，请重新打开');
    var position = first;
    await for (final chunk in response.data!.stream) {
      requests.check();
      require(position + chunk.length <= last + 1, '图片分段长度不一致，请重新打开');
      buffer.setRange(position, position + chunk.length, chunk);
      position += chunk.length;
    }
    requests.check();
    if (position != last + 1) {
      throw const DownloadNetworkException('incompleteImageRange');
    }
  }

  static void _checkSize(int size, DownloadSpec source, int limit) {
    require(size > 0, '图片内容为空');
    require(size <= limit, '图片过大，请下载后查看');
    require(
      source.expectedSize <= 0 || source.expectedSize == size,
      '图片大小与文件信息不一致，请重新打开',
    );
  }

  static bool _refusesRange(int code) => {400, 405, 416, 501}.contains(code);
  static int? _length(Response response) =>
      int.tryParse(response.headers.value('content-length') ?? '');
  static bool _unencoded(Response response) => {
    '',
    'identity',
  }.contains((response.headers.value('content-encoding') ?? '').toLowerCase());
  static RemoteIdentity _identity(Response response, int total) =>
      RemoteIdentity(
        total,
        response.headers.value('etag'),
        response.headers.value('last-modified'),
      );
  static (int, int, int)? _range(Response response) {
    final match = RegExp(
      r'^bytes (\d+)-(\d+)/(\d+)$',
      caseSensitive: false,
    ).firstMatch(response.headers.value('content-range') ?? '');
    if (match == null) return null;
    final first = int.tryParse(match[1]!);
    final last = int.tryParse(match[2]!);
    final total = int.tryParse(match[3]!);
    if (first == null ||
        last == null ||
        total == null ||
        first > last ||
        last >= total) {
      return null;
    }
    return (first, last, total);
  }
}

/// The parent belongs to the preview page. A failed range cancels only this
/// batch, allowing one subsequent full-response fallback without reviving a
/// preview whose page has already been closed.
class _PreviewRequests {
  _PreviewRequests() {
    parent?.whenCancel.then((_) {
      if (!_closed) cancel();
    });
  }
  final parent = RequestScope.current;
  final stopped = CancelToken();
  final _active = <CancelToken>{};
  bool _closed = false;

  void check() {
    if (parent?.isCancelled == true) throw parent!.cancelError!;
    if (stopped.isCancelled) throw stopped.cancelError!;
  }

  CancelToken open() {
    check();
    final token = CancelToken();
    _active.add(token);
    return token;
  }

  void release(CancelToken token) {
    _active.remove(token);
    if (!token.isCancelled) token.cancel();
  }

  void cancel() {
    if (!stopped.isCancelled) stopped.cancel();
    for (final token in _active.toList()) {
      if (!token.isCancelled) token.cancel();
    }
  }

  Future<void> wait(Duration delay) async {
    check();
    final done = Completer<void>();
    final timer = Timer(delay, () => done.complete());
    unawaited(
      stopped.whenCancel.then((_) {
        if (!done.isCompleted) done.complete();
      }),
    );
    try {
      await done.future;
      check();
    } finally {
      timer.cancel();
    }
  }

  void close() {
    _closed = true;
    cancel();
  }
}
