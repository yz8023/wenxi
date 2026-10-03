import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../core/json.dart';
import '../domain/models.dart';

/// A separate, session-owned transport: pausing the internal decoder must not
/// pause the player the user has just opened. Credentials stay on this side of
/// the loopback server, including requests for HLS playlists, keys and segments.
class ExternalPlaybackStream {
  ExternalPlaybackStream(this.source);

  final DownloadSpec source;
  final _token = newId();
  final _resources = <String, Uri>{};
  final _paths = <Uri, String>{};
  final _handlers = <Future<void>>{};
  final _requests = <HttpClientRequest>{};
  final _client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 20)
    ..maxConnectionsPerHost = 8;
  HttpServer? _server;
  bool _closed = false;
  Future<void>? _closing;
  String _url = '';
  String get url => _url;

  Future<void> start() async {
    require(!_closed, '第三方播放已取消');
    final uri = Uri.tryParse(source.url);
    require(source.url.isNotEmpty && uri != null, '视频地址无效，请重新打开视频');
    if (!{'http', 'https'}.contains(uri!.scheme)) {
      _url = source.url;
      return;
    }
    require(uri.host.isNotEmpty && uri.userInfo.isEmpty, '视频地址无效');
    // DASH templates cannot be rewritten as an HLS resource list. Public or
    // signed MPD URLs can be opened directly without leaking account headers.
    if (uri.path.toLowerCase().endsWith('.mpd')) {
      require(source.headers.isEmpty, '此 DASH 视频需要专用授权，请使用内置播放器');
      _url = source.url;
      return;
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw const AppException('第三方播放已取消');
    }
    _server = server;
    _url = _register(uri).toString();
    server.listen((request) {
      final task = _serve(request);
      _handlers.add(task);
      unawaited(task.whenComplete(() => _handlers.remove(task)));
    }, onError: (Object _) {});
  }

  Uri _register(Uri upstream) {
    require(
      {'http', 'https'}.contains(upstream.scheme) &&
          upstream.host.isNotEmpty &&
          upstream.userInfo.isEmpty,
      '播放列表含无效地址',
    );
    final path = _paths[upstream] ??= () {
      require(_resources.length < 65536, '播放列表过大，请重新打开视频');
      final suffix = upstream.path.toLowerCase().endsWith('.m3u8')
          ? 'index.m3u8'
          : 'video';
      final path = '/$_token/${_resources.length}/$suffix';
      _resources[path] = upstream;
      return path;
    }();
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: _server!.port,
      path: path,
    );
  }

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  Map<String, String> _headers(Uri url) => {
    for (final entry in source.headers.entries)
      if (!_hopHeaders.contains(entry.key.toLowerCase()) &&
          !{
            'range',
            'if-range',
            'accept-encoding',
          }.contains(entry.key.toLowerCase()) &&
          (_sameOrigin(Uri.parse(source.url), url) ||
              !_credentials.contains(entry.key.toLowerCase())))
        entry.key: entry.value,
  };

  static const _credentials = {
    'cookie',
    'authorization',
    'proxy-authorization',
  };
  static const _hopHeaders = {
    'host',
    'connection',
    'keep-alive',
    'transfer-encoding',
    'content-length',
    'te',
    'trailer',
    'upgrade',
    'proxy-connection',
  };

  bool _playlist(Uri uri, HttpClientResponse response) =>
      uri.path.toLowerCase().endsWith('.m3u8') ||
      (response.headers.contentType?.mimeType.contains('mpegurl') ?? false);

  Future<(HttpClientResponse, Uri, HttpClientRequest)> _fetch(
    HttpRequest downstream,
    Uri initial, {
    bool omitRange = false,
  }) async {
    var url = initial;
    var credentialsAllowed = true;
    for (var redirects = 0; redirects <= 5; redirects++) {
      require(!_closed, '第三方播放已结束');
      final outgoing = await _client.openUrl(downstream.method, url);
      _requests.add(outgoing);
      outgoing.followRedirects = false;
      final headers = _headers(url);
      if (!credentialsAllowed) {
        headers.removeWhere(
          (name, _) => _credentials.contains(name.toLowerCase()),
        );
      }
      headers.forEach(outgoing.headers.set);
      outgoing.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (!omitRange && !url.path.toLowerCase().endsWith('.m3u8')) {
        for (final name in [
          HttpHeaders.rangeHeader,
          HttpHeaders.ifRangeHeader,
        ]) {
          final value = downstream.headers.value(name);
          if (value != null) outgoing.headers.set(name, value);
        }
      }
      unawaited(
        downstream.response.done.then<void>(
          (_) {
            outgoing.abort();
          },
          onError: (Object _) {
            outgoing.abort();
          },
        ),
      );
      final HttpClientResponse response;
      try {
        response = await outgoing.close().timeout(
          const Duration(seconds: 20),
          onTimeout: () {
            throw TimeoutException('External video response timeout');
          },
        );
      } catch (_) {
        outgoing.abort();
        _requests.remove(outgoing);
        rethrow;
      }
      if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return (response, url, outgoing);
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.listen((_) {}).cancel();
      _requests.remove(outgoing);
      require(location != null && redirects < 5, '视频地址重定向失败');
      final next = url.resolve(location!);
      require(
        {'http', 'https'}.contains(next.scheme) &&
            next.userInfo.isEmpty &&
            !(url.scheme == 'https' && next.scheme != 'https'),
        '视频地址重定向无效',
      );
      if (!_sameOrigin(url, next)) credentialsAllowed = false;
      url = next;
    }
    throw const AppException('视频地址重定向过多');
  }

  String _rewrite(String text, Uri base) => text
      .split('\n')
      .map((line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return line;
        String local(String value) {
          final uri = base.resolve(value);
          // Inline encryption keys do not require an HTTP fetch.
          if (uri.scheme == 'data') return value;
          return _register(uri).toString();
        }

        if (!trimmed.startsWith('#')) return local(trimmed);
        return line.replaceAllMapped(
          RegExp(r'\bURI="([^"]+)"'),
          (match) => 'URI="${local(match[1]!)}"',
        );
      })
      .join('\n');

  Future<void> _serve(HttpRequest request) async {
    HttpClientRequest? outgoing;
    StreamIterator<List<int>>? body;
    try {
      final upstream = _resources[request.uri.path];
      if (_closed || upstream == null || request.uri.hasQuery) {
        request.response.statusCode = HttpStatus.notFound;
        return;
      }
      if (!{'GET', 'HEAD'}.contains(request.method)) {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      if (_handlers.length >= 24) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        request.response.headers.set(HttpHeaders.retryAfterHeader, '1');
        return;
      }
      var fetched = await _fetch(request, upstream);
      outgoing = fetched.$3;
      if (fetched.$1.statusCode == HttpStatus.partialContent &&
          _playlist(fetched.$2, fetched.$1)) {
        await fetched.$1.listen((_) {}).cancel();
        _requests.remove(outgoing);
        fetched = await _fetch(request, upstream, omitRange: true);
        outgoing = fetched.$3;
      }
      final (response, resolved, _) = fetched;
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      var playlist = ok && _playlist(resolved, response);
      request.response.statusCode = response.statusCode;
      for (final name in [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.contentEncodingHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
      ]) {
        final value = response.headers.value(name);
        if (value != null) request.response.headers.set(name, value);
      }
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (request.method == 'HEAD') {
        if (!playlist) request.response.contentLength = response.contentLength;
        await response.listen((_) {}).cancel();
        return;
      }
      final encoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      final payload = playlist && encoding == 'gzip'
          ? gzip.decoder.bind(response)
          : response;
      body = StreamIterator(payload.timeout(const Duration(seconds: 60)));
      final hasFirst = await body.moveNext();
      final first = hasFirst ? body.current : const <int>[];
      if (ok &&
          (encoding == null || encoding == 'identity') &&
          utf8
              .decode(first.take(128).toList(), allowMalformed: true)
              .trimLeft()
              .startsWith('#EXTM3U')) {
        playlist = true;
      }
      if (playlist) {
        final bytes = BytesBuilder(copy: false)..add(first);
        require(bytes.length <= 4 * 1024 * 1024, '播放列表过大');
        while (await body.moveNext()) {
          bytes.add(body.current);
          require(bytes.length <= 4 * 1024 * 1024, '播放列表过大');
        }
        final data = bytes.takeBytes();
        final rewritten = utf8.encode(_rewrite(utf8.decode(data), resolved));
        request.response.headers.removeAll(HttpHeaders.contentEncodingHeader);
        request.response.headers.removeAll(HttpHeaders.contentRangeHeader);
        request.response.headers.removeAll(HttpHeaders.acceptRangesHeader);
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.contentLength = rewritten.length;
        request.response.add(rewritten);
      } else {
        request.response.contentLength = response.contentLength;
        if (hasFirst) request.response.add(first);
        await request.response.flush();
        while (await body.moveNext()) {
          request.response.add(body.current);
          await request.response.flush();
        }
      }
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
    } finally {
      outgoing?.abort();
      _requests.remove(outgoing);
      try {
        await body?.cancel();
      } catch (_) {}
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() => _closing ??= () async {
    _closed = true;
    for (final request in _requests.toList()) {
      request.abort();
    }
    _client.close(force: true);
    await _server?.close(force: true);
    await Future.wait(_handlers.toList());
    _resources.clear();
    _paths.clear();
  }();
}
