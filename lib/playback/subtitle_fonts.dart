import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../diagnostics/app_log.dart';
import '../platform/native_engine.dart';
import 'font_metadata.dart';

enum SubtitleFontOrigin { system, cache, download }

class SubtitleFont {
  const SubtitleFont(this.path, this.family, this.origin);
  final String path, family;
  final SubtitleFontOrigin origin;
  String get directory => p.dirname(path);
}

/// Shared by player sessions. Resolving local fonts never starts a download.
class SubtitleFontStore {
  SubtitleFontStore({
    Future<List<String>> Function()? systemFiles,
    Future<Directory> Function()? directory,
    HttpClient Function()? clientFactory,
    List<Uri>? downloadUrls,
    this.downloadTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 8),
  }) : _systemFiles = systemFiles ?? _availableSystemFiles,
       _directory = directory ?? _defaultDirectory,
       _clientFactory = clientFactory ?? HttpClient.new,
       _downloadUrls = List.unmodifiable(downloadUrls ?? sources);

  static final shared = SubtitleFontStore();
  static const fontBytes = 8331336;
  static const fontSha256 =
      'faa6c9df652116dde789d351359f3d7e5d2285a2b2a1f04a2d7244df706d5ea9';
  static const revision = '523d033d6cb47f4a80c58a35753646f5c3608a78';
  static const _fontPath = 'Sans/SubsetOTF/SC/NotoSansSC-Regular.otf';
  static final sources = [
    Uri.parse(
      'https://fastly.jsdelivr.net/gh/notofonts/noto-cjk@$revision/$_fontPath',
    ),
    Uri.parse(
      'https://raw.githubusercontent.com/notofonts/noto-cjk/$revision/$_fontPath',
    ),
  ];

  final Future<List<String>> Function() _systemFiles;
  final Future<Directory> Function() _directory;
  final HttpClient Function() _clientFactory;
  final List<Uri> _downloadUrls;
  final Duration downloadTimeout, idleTimeout;
  Future<List<String>>? _systemPaths;
  Future<Directory>? _root;
  Future<SubtitleFont?>? _localTask;
  Future<SubtitleFont>? _downloadTask;
  SubtitleFont? _ready;
  FileStat? _readyStat;

  Future<Directory> _cacheRoot() => _root ??= _directory()
      .then((directory) async {
        await directory.create(recursive: true);
        return directory;
      })
      .catchError((Object error, StackTrace stack) {
        _root = null;
        Error.throwWithStackTrace(error, stack);
      });

  Future<SubtitleFont?> local() => _localTask ??= _local().whenComplete(() {
    _localTask = null;
  });

  Future<SubtitleFont?> _local() async {
    final ready = _ready;
    if (ready != null) {
      final stat = await File(ready.path).stat();
      if (stat.type == FileSystemEntityType.file &&
          stat.size == _readyStat?.size &&
          stat.modified == _readyStat?.modified) {
        return ready;
      }
      _ready = null;
    }
    try {
      final paths = await (_systemPaths ??= _systemFiles());
      final face = await Isolate.run(() => findChineseSubtitleFont(paths));
      if (face != null) return await _remember(await _stageSystemFont(face));
    } catch (error, stack) {
      _systemPaths = null;
      DiagnosticLog.error('player.system_font', error, stack);
    }
    final cached = await _fallbackFile();
    if (await _verified(cached)) {
      return _remember(
        SubtitleFont(cached.path, 'Noto Sans SC', SubtitleFontOrigin.cache),
      );
    }
    if (await cached.exists()) await cached.delete();
    return null;
  }

  Future<SubtitleFont> ensureAvailable() =>
      _downloadTask ??= _ensureAvailable().whenComplete(() {
        _downloadTask = null;
      });

  Future<SubtitleFont> _ensureAvailable() async {
    final existing = await local();
    if (existing != null) return existing;
    final target = await _fallbackFile();
    Object? failure;
    for (final url in _downloadUrls) {
      try {
        await _download(url, target);
        return _remember(
          SubtitleFont(
            target.path,
            'Noto Sans SC',
            SubtitleFontOrigin.download,
          ),
        );
      } catch (error, stack) {
        failure = error;
        DiagnosticLog.error(
          'player.subtitle_font_download',
          error,
          stack,
          fields: {'host': url.host},
        );
      }
    }
    throw FileSystemException('Subtitle font download failed: $failure');
  }

  Future<SubtitleFont> _remember(SubtitleFont font) async {
    _readyStat = await File(font.path).stat();
    _ready = font;
    return font;
  }

  Future<File> _fallbackFile() async => File(
    p.join((await _cacheRoot()).path, fontSha256, 'NotoSansSC-Regular.otf'),
  );

  Future<SubtitleFont> _stageSystemFont(SubtitleFontFace face) async {
    final source = File(face.path).absolute;
    final stat = await source.stat();
    final identity = sha256.convert(
      utf8.encode(
        '${source.path}\n${stat.size}\n${stat.modified.microsecondsSinceEpoch}',
      ),
    );
    final folder = Directory(
      p.join((await _cacheRoot()).path, 'system', identity.toString()),
    );
    await folder.create(recursive: true);
    final target = File(
      p.join(folder.path, 'subtitle${p.extension(face.path)}'),
    );
    if (!await target.exists() || await target.length() != stat.size) {
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await File(target.path).delete();
      }
      // libass loads every file in sub-fonts-dir into memory. Give it only the
      // selected face/collection, never the entire system font directory.
      try {
        await Link(target.path).create(source.path);
      } on FileSystemException {
        final partial = File('${target.path}.partial');
        try {
          await source.copy(partial.path);
          await partial.rename(target.path);
        } finally {
          if (await partial.exists()) await partial.delete();
        }
      }
    }
    return SubtitleFont(target.path, face.family, SubtitleFontOrigin.system);
  }

  Future<bool> _verified(File file) {
    final path = file.path;
    return Isolate.run(() async {
      try {
        final font = File(path);
        if (await font.length() != fontBytes) return false;
        return (await sha256.bind(font.openRead()).first).toString() ==
            fontSha256;
      } on FileSystemException {
        return false;
      }
    });
  }

  Future<void> _download(Uri initial, File target) async {
    final root = await _cacheRoot();
    final partialRoot = await Directory(
      p.join(root.path, 'partial'),
    ).create(recursive: true);
    final temporary = await partialRoot.createTemp('font-');
    final partial = File(p.join(temporary.path, 'font.part'));
    final client = _clientFactory()
      ..connectionTimeout = idleTimeout
      ..autoUncompress = false;
    final watch = Stopwatch()..start();
    var expired = false;
    final deadline = Timer(downloadTimeout, () {
      expired = true;
      client.close(force: true);
    });
    Duration remaining() {
      final value = downloadTimeout - watch.elapsed;
      if (expired || value <= Duration.zero) {
        throw TimeoutException('Subtitle font download timed out');
      }
      return value;
    }

    RandomAccessFile? output;
    try {
      var url = initial;
      HttpClientResponse? response;
      for (var redirects = 0; redirects <= 4; redirects++) {
        // Plain HTTP is accepted only for explicitly supplied loopback fixtures.
        final loopback =
            initial.scheme == 'http' &&
            {'127.0.0.1', '::1', 'localhost'}.contains(initial.host) &&
            url.origin == initial.origin;
        if (url.scheme != 'https' && !loopback) {
          throw const HttpException('Font download requires HTTPS');
        }
        final request = await client.getUrl(url).timeout(remaining());
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        response = await request.close().timeout(remaining());
        if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) break;
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) throw const HttpException('Missing redirect');
        // Discard the redirect body without waiting for an unbounded response.
        await response.listen((_) {}).cancel();
        url = url.resolve(location);
      }
      if (response?.statusCode != HttpStatus.ok) {
        throw HttpException('Font server returned ${response?.statusCode}');
      }
      final body = response!;
      if (body.contentLength >= 0 && body.contentLength != fontBytes) {
        throw const FormatException('Unexpected subtitle font size');
      }
      output = await partial.open(mode: FileMode.write);
      var received = 0;
      await for (final bytes in body.timeout(idleTimeout)) {
        remaining();
        received += bytes.length;
        if (received > fontBytes) {
          throw const FormatException('Subtitle font exceeds expected size');
        }
        await output.writeFrom(bytes);
      }
      await output.close();
      output = null;
      remaining();
      if (received != fontBytes || !await _verified(partial)) {
        throw const FormatException('Subtitle font failed integrity check');
      }
      remaining();
      await target.parent.create(recursive: true);
      await partial.rename(target.path);
    } finally {
      deadline.cancel();
      client.close(force: true);
      await output?.close();
      if (await partial.exists()) await partial.delete();
      await temporary.delete();
    }
  }

  static Future<Directory> _defaultDirectory() async {
    if (Platform.isAndroid) {
      final paths = await nativeChannel.invokeMapMethod<String, Object?>(
        'paths',
      );
      final data = paths?['data'];
      if (data is String && data.isNotEmpty) {
        return Directory(p.join(data, 'subtitle_fonts'));
      }
    }
    return Directory(
      p.join((await getApplicationSupportDirectory()).path, 'subtitle_fonts'),
    );
  }

  static Future<List<String>> _availableSystemFiles() async {
    if (Platform.isAndroid) {
      try {
        final files = await nativeChannel.invokeListMethod<String>(
          'subtitleFontFiles',
        );
        if (files != null && files.isNotEmpty) return files;
      } catch (error, stack) {
        DiagnosticLog.error('player.system_font_files', error, stack);
      }
    }
    final roots = Platform.isWindows
        ? [
            p.join(Platform.environment['WINDIR'] ?? r'C:\Windows', 'Fonts'),
            if (Platform.environment['LOCALAPPDATA'] case final String local)
              p.join(local, 'Microsoft', 'Windows', 'Fonts'),
          ]
        : Platform.isAndroid
        ? [
            '/system/fonts',
            '/product/fonts',
            '/system_ext/fonts',
            '/vendor/fonts',
          ]
        : ['/System/Library/Fonts', '/usr/share/fonts/truetype'];
    final paths = <String>[];
    for (final root in roots) {
      try {
        await for (final file in Directory(root).list()) {
          if ({
            '.ttc',
            '.ttf',
            '.otf',
          }.contains(p.extension(file.path).toLowerCase())) {
            paths.add(file.path);
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    return paths;
  }
}
