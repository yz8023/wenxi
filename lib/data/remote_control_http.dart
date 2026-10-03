import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../domain/remote_control.dart';

abstract interface class RemoteControlFetcher {
  Future<String> fetch(Uri endpoint);
  void close();
}

class ControlAccessException extends FormatException {
  const ControlAccessException(super.message, {this.statusCode});
  final int? statusCode;
}

/// A separate client prevents cloud cookies and authentication interceptors
/// from ever being attached to a public configuration request.
class DioRemoteControlFetcher implements RemoteControlFetcher {
  DioRemoteControlFetcher({
    Dio? client,
    this.timeout = const Duration(seconds: 15),
    this.headers = const {
      'Accept': 'application/json, text/plain;q=0.9',
      'Cache-Control': 'no-cache',
    },
  }) : _client = client ?? Dio();

  static const maxRedirects = 3;
  final Dio _client;
  final Duration timeout;
  final Map<String, String> headers;
  final _requests = <CancelToken>{};
  bool _closed = false;

  @override
  Future<String> fetch(Uri endpoint) async {
    if (_closed) throw StateError('配置请求已关闭');
    httpsUri(endpoint.toString());
    final token = CancelToken();
    _requests.add(token);
    try {
      return await _read(endpoint, token).timeout(
        timeout,
        onTimeout: () {
          token.cancel('Configuration timeout');
          throw TimeoutException('配置请求超时');
        },
      );
    } finally {
      if (!token.isCancelled) token.cancel('Configuration request finished');
      _requests.remove(token);
    }
  }

  Future<String> _read(Uri endpoint, CancelToken token) async {
    var current = endpoint;
    final visited = <Uri>{};
    for (var redirects = 0; ; redirects++) {
      if (token.isCancelled) throw token.cancelError!;
      if (!visited.add(current)) {
        throw const ControlAccessException('配置地址出现循环跳转');
      }
      final requestToken = CancelToken();
      unawaited(token.whenCancel.then(requestToken.cancel));
      try {
        final response = await _client.getUri<ResponseBody>(
          current,
          cancelToken: requestToken,
          options: Options(
            responseType: ResponseType.stream,
            // Validate each destination before making the next request.
            followRedirects: false,
            receiveTimeout: timeout,
            sendTimeout: timeout,
            validateStatus: (_) => true,
            headers: headers,
          ),
        );
        if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers.value('location');
          if (redirects >= maxRedirects ||
              location == null ||
              location.isEmpty) {
            throw const ControlAccessException('配置地址跳转无效或次数过多');
          }
          if (RegExp(r'[\s\x00-\x1f\x7f\\]').hasMatch(location)) {
            throw const ControlAccessException('配置地址跳转无效');
          }
          try {
            current = httpsUri(
              current.resolve(location).toString(),
            ).removeFragment();
          } on FormatException {
            throw const ControlAccessException('配置地址跳转无效');
          }
          continue;
        }
        if (response.statusCode != 200 || response.data == null) {
          throw ControlAccessException(
            '配置服务未返回完整文件',
            statusCode: response.statusCode,
          );
        }
        final length = int.tryParse(
          response.headers.value('content-length') ?? '',
        );
        if (length != null && length > RemoteControlConfig.maxBytes) {
          throw const FormatException('配置文件超过 256 KiB');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.data!.stream) {
          if (bytes.length + chunk.length > RemoteControlConfig.maxBytes) {
            throw const FormatException('配置文件超过 256 KiB');
          }
          bytes.add(chunk);
        }
        return utf8.decode(bytes.takeBytes());
      } finally {
        // A redirect body may never finish. Abort its request before following
        // the next URL while preserving the overall timeout/cancellation token.
        requestToken.cancel('Configuration response finished');
      }
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final token in _requests.toList()) {
      token.cancel('Application closed');
    }
    _client.close(force: true);
  }
}
