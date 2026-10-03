import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/platform/file_access.dart';

class RecordedRequest {
  RecordedRequest(this.method, this.url, this.body, this.headers);
  final String method, url;
  final Object? body;
  final Map<String, String> headers;
  Json get json =>
      body is String ? asJson(jsonDecode(body as String)) : asJson(body);
  Uri get uri => Uri.parse(url);
}

class FakeHttp extends JsonHttp {
  FakeHttp([this.respond]);
  final FutureOr<HttpResult> Function(RecordedRequest)? respond;
  final calls = <RecordedRequest>[];
  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) async {
    final call = RecordedRequest(method, url, body, headers);
    calls.add(call);
    return respond == null ? const HttpResult(200, '{}') : await respond!(call);
  }
}

HttpResult jsonResponse(Json value, [int status = 200]) =>
    HttpResult(status, jsonEncode(value));

class FakeNative extends NativeTransport {
  bool started = false, writer = false, removedWhileWriting = false;
  bool finish = true;
  String? cache;
  final calls = <String>[], begins = <Json>[];
  final content = <int>[1, 2, 3, 4];
  int openCount = 0;
  @override
  bool get connected => started;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    calls.add(method);
    switch (method) {
      case 'open':
        started = true;
        openCount++;
        cache = args.str('cacheDir');
      case 'begin':
        begins.add(args);
        writer = true;
        final file = File(p.join(cache!, args.str('id'), 'payload.gopeed'));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(content);
      case 'snapshot':
        if (finish) writer = false;
        return {
          'status': finish ? 'done' : 'running',
          'total': content.length,
          'downloaded': finish ? content.length : 0,
          'speed': 0,
          'path': p.join(cache!, args.str('id'), 'payload.gopeed'),
        };
      case 'pause':
        await Future<void>.delayed(const Duration(milliseconds: 10));
        writer = false;
      case 'remove':
        if (writer) removedWhileWriting = true;
      case 'freeSpace':
        return {'bytes': 1 << 40};
      case 'close':
        started = false;
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    if (started) await call('close');
  }
}

class FakeFiles extends FileAccess {
  FakeFiles(this.directory);
  final Directory directory;
  bool failDelete = false, failSave = false;
  int savedCount = 0;
  final availability = <String, FileAvailability>{};
  @override
  Future<FileAvailability> inspect(String? path) async => path == null
      ? FileAvailability.missing
      : availability[path] ?? FileAvailability.present;
  @override
  Future<String?> chooseDirectory() async => directory.path;
  @override
  Future<int> freeBytes(String path) async => 1 << 40;
  @override
  Future<void> cancelExport(String id) async {}
  @override
  Future<void> delete(String? path) async {
    if (failDelete) throw const AppException('文件正在使用');
    if (path != null && await File(path).exists()) await File(path).delete();
  }

  @override
  Future<String> save({
    required String id,
    required File source,
    required String name,
    required String relativePath,
    String? destination,
    required void Function() checkpoint,
    void Function(int copied, int total)? onProgress,
  }) async {
    checkpoint();
    if (failSave) throw const AppException('保存失败');
    await directory.create(recursive: true);
    final path = p.join(directory.path, '$id-$name');
    await source.copy(path);
    onProgress?.call(await source.length(), await source.length());
    savedCount++;
    checkpoint();
    return path;
  }
}

Future<void> until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 12),
}) async {
  final timer = Stopwatch()..start();
  while (!condition()) {
    if (timer.elapsed > timeout) {
      throw TimeoutException('Condition did not become true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
