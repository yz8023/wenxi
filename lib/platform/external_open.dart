import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/json.dart';
import '../domain/links.dart';
import '../domain/models.dart';
import 'file_access.dart';
import 'native_engine.dart';

enum ExternalOpenKind { share, download, play, error }

class ExternalOpenRequest {
  const ExternalOpenRequest._({
    required this.id,
    required this.kind,
    this.uri = '',
    this.text = '',
    this.name = '',
    this.mime = '',
    this.message = '',
    this.headers = const {},
  });

  final String id, uri, text, name, mime, message;
  final ExternalOpenKind kind;
  final Map<String, String> headers;

  factory ExternalOpenRequest.fromPlatform(Object? raw) {
    final value = asJson(raw);
    final id = value.str('id');
    final kind = ExternalOpenKind.values
        .where((kind) => kind.name == value.str('kind'))
        .firstOrNull;
    if (kind == ExternalOpenKind.error) {
      return ExternalOpenRequest._(
        id: id,
        kind: ExternalOpenKind.error,
        message: value.str('message', '外部文件信息无效'),
      );
    }
    try {
      require(kind != null && id.isNotEmpty && id.length <= 100, '外部文件信息无效');
      var uri = value.str('uri');
      final text = value.str('text').trim();
      if (kind == ExternalOpenKind.share) {
        require(text.isNotEmpty && text.length <= 65536, '外部应用没有提供有效链接');
      } else {
        require(uri.isNotEmpty && uri.length <= 16384, '外部文件地址无效');
        final parsed = Uri.tryParse(uri);
        require(
          parsed != null && !RegExp(r'[\x00-\x20\x7f]').hasMatch(uri),
          '外部文件地址无效',
        );
        if (parsed!.scheme == 'http' || parsed.scheme == 'https') {
          uri = LinkParser.normalize(uri);
        } else {
          require(
            kind == ExternalOpenKind.play &&
                (parsed.scheme == 'content' && parsed.authority.isNotEmpty ||
                    parsed.scheme == 'file' && parsed.path.startsWith('/')),
            '不支持此外部文件地址',
          );
        }
      }
      final providedName = value.str('name').trim();
      final pathName = Uri.tryParse(uri)?.pathSegments.lastOrNull ?? '';
      final name = providedName.isNotEmpty ? providedName : pathName;
      return ExternalOpenRequest._(
        id: id,
        kind: kind!,
        uri: uri,
        text: text,
        name: name.isEmpty ? '' : safeFileName(name),
        mime: value.str('mime'),
        headers: _headers(value['headers']),
      );
    } on Object {
      return ExternalOpenRequest._(
        id: id,
        kind: ExternalOpenKind.error,
        message: '外部应用提供的链接或文件信息无效，请重新选择',
      );
    }
  }

  String get sharedText => text.isNotEmpty ? text : uri;
  bool get network => uri.startsWith('https://') || uri.startsWith('http://');
  String get fileName => name.isNotEmpty
      ? name
      : kind == ExternalOpenKind.play
      ? '外部视频'
      : 'download.bin';

  /// Cloud shares and magnets keep the existing parser and login flow.
  String? get downloadUrl {
    if (kind != ExternalOpenKind.download && kind != ExternalOpenKind.share) {
      return null;
    }
    final links = LinkParser.parse(sharedText);
    if (links.length != 1 || links.single.kind != LinkKind.direct) return null;
    return kind == ExternalOpenKind.download ? uri : links.single.url;
  }

  DownloadSpec get playbackSpec => DownloadSpec(
    url: uri,
    fileName: fileName,
    headers: network ? headers : const {},
  );

  static Map<String, String> _headers(Object? raw) {
    if (raw is! Map) return const {};
    final result = <String, String>{};
    final token = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
    const blocked = {
      'host',
      'connection',
      'content-length',
      'transfer-encoding',
      'range',
      'accept-encoding',
    };
    var size = 0;
    for (final entry in raw.entries.take(48)) {
      if (entry.key is! String || entry.value is! String) continue;
      final key = entry.key as String, value = entry.value as String;
      if (key.length > 128 ||
          !token.hasMatch(key) ||
          blocked.contains(key.toLowerCase()) ||
          value.length > 8192 ||
          RegExp(r'[\r\n\x00]').hasMatch(value) ||
          size + key.length + value.length > 32768) {
        continue;
      }
      result.removeWhere((k, _) => k.toLowerCase() == key.toLowerCase());
      result[key] = value;
      size += key.length + value.length;
    }
    return Map.unmodifiable(result);
  }
}

/// Availability events and the initial read share one drain, including events
/// arriving while a platform read is already in flight.
class ExternalOpenInbox extends ChangeNotifier {
  ExternalOpenInbox({MethodChannel channel = nativeChannel})
    : _channel = channel;
  final MethodChannel _channel;
  final _pending = Queue<ExternalOpenRequest>();
  final _seen = <String>{};
  Future<void>? _reading;
  bool _again = false, _closed = false;
  bool get hasPending => _pending.isNotEmpty;
  ExternalOpenRequest? take() =>
      _pending.isEmpty ? null : _pending.removeFirst();

  Future<void> refresh() {
    if (_closed) return Future.value();
    _again = true;
    return _reading ??= _read().whenComplete(() {
      _reading = null;
      if (_again && !_closed) return refresh();
    });
  }

  Future<void> _read() async {
    do {
      _again = false;
      final values = await _channel.invokeListMethod<Object?>(
        'takeExternalOpens',
      );
      if (_closed) return;
      var changed = false;
      for (final value in values ?? const []) {
        final request = ExternalOpenRequest.fromPlatform(value);
        if (request.id.isEmpty || !_seen.add(request.id)) continue;
        if (_seen.length > 64) _seen.remove(_seen.first);
        if (_pending.length >= 16) _pending.removeFirst();
        _pending.add(request);
        changed = true;
      }
      if (changed) notifyListeners();
    } while (_again && !_closed);
  }

  @override
  void dispose() {
    _closed = true;
    _pending.clear();
    super.dispose();
  }
}
