import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../domain/models.dart';
import '../domain/torrent.dart';
import '../platform/native_engine.dart';
import 'transfer_http.dart';

class TorrentSession extends ChangeNotifier {
  TorrentSession(this.engine, this.http);
  final GopeedEngine engine;
  final TransferHttp http;
  final String id = newId();
  final RequestScope _scope = RequestScope();
  final Completer<void> _cancelled = Completer<void>();
  TorrentInfo? info;
  String error = '', stage = '正在读取种子信息…';
  bool _closed = false, _started = false;

  Future<void> resolve(String source) async {
    if (_started || _closed) return;
    _started = true;
    try {
      var value = source;
      if (value.startsWith('http://') || value.startsWith('https://')) {
        stage = '正在读取种子文件…';
        final response = await http.stream(value, {}, cancel: _scope.token);
        require(
          (response.statusCode ?? 0) >= 200 && (response.statusCode ?? 0) < 300,
          '种子文件读取失败',
        );
        final bytes = <int>[];
        await for (final chunk in response.data!.stream) {
          require(
            bytes.length + chunk.length <= maxTorrentBytes,
            '种子文件不能超过 4 MiB',
          );
          bytes.addAll(chunk);
        }
        value = '$torrentDataPrefix${base64Encode(bytes)}';
      }
      if (_closed) return;
      stage = value.startsWith('magnet:') ? '正在连接做种者获取文件列表…' : '正在解析种子文件…';
      notifyListeners();
      await engine.torrentCall('torrentResolve', {'id': id, 'url': value});
      while (!_closed) {
        final result = await engine.torrentCall('torrentMetadata', {'id': id});
        if (_closed) return;
        if (result.str('status') == 'ready') {
          info = TorrentInfo.fromJson(result.obj('info'));
          stage = '';
          notifyListeners();
          return;
        }
        if (result.str('status') == 'error') {
          throw AppException(result.str('error').ifEmpty('种子解析失败'));
        }
        await Future.any([
          Future<void>.delayed(const Duration(milliseconds: 350)),
          _cancelled.future,
        ]);
      }
    } catch (e) {
      if (!_closed) {
        error = e is AppException ? e.message : '种子解析失败，请检查网络或重新选择文件';
        stage = '';
        notifyListeners();
      }
    } finally {
      await _release();
    }
  }

  Future<void> _release() async {
    try {
      await engine.torrentCall('torrentCancel', {'id': id});
    } catch (_) {}
  }

  @override
  void dispose() {
    _closed = true;
    _scope.cancel();
    if (!_cancelled.isCompleted) _cancelled.complete();
    unawaited(_release());
    super.dispose();
  }
}
