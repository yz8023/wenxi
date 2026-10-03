import 'dart:convert';
import 'dart:io';
import 'package:asterlink/data/remote_control_http.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/remote_control.dart';

Future<void> main(List<String> args) async {
  String path = 'control.json';
  String? againstUrl, againstFile;
  var hasPath = false;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if ((arg == '--against-url' || arg == '--against-file') &&
        i + 1 < args.length &&
        againstUrl == null &&
        againstFile == null) {
      if (arg == '--against-url') {
        againstUrl = args[++i];
      } else {
        againstFile = args[++i];
      }
    } else if (!arg.startsWith('-') && !hasPath) {
      path = arg;
      hasPath = true;
    } else {
      stderr.writeln(
        '用法：dart run tool/validate_control.dart [control.json] '
        '[--against-url HTTPS地址 | --against-file 已下载的线上JSON]',
      );
      exitCode = 64;
      return;
    }
  }
  RemoteControlDocument readFile(String path) {
    final file = File(path);
    if (file.lengthSync() > RemoteControlConfig.maxBytes) {
      throw const ControlFormatException('control', '配置文件超过 256 KiB');
    }
    return RemoteControlDocument.decode(file.readAsStringSync());
  }

  DioRemoteControlFetcher? fetcher;
  try {
    final document = readFile(path);
    if (document.issues.isNotEmpty) {
      for (final issue in document.issues) {
        stderr.writeln('配置无效：${issue.path}：${issue.message}');
      }
      exitCode = 1;
      return;
    }
    final config = document.validated;
    RemoteControlDocument? published;
    if (againstUrl != null) {
      final endpoint = httpsUri(againstUrl);
      if (endpoint.hasFragment) throw const FormatException('配置地址不能含片段');
      fetcher = DioRemoteControlFetcher();
      published = RemoteControlDocument.decode(await fetcher.fetch(endpoint));
    } else if (againstFile != null) {
      published = readFile(againstFile);
    }
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'valid': true,
        'revision': config.revision,
        'checkedAgainst': againstUrl != null
            ? 'live'
            : againstFile != null
            ? 'file'
            : 'none',
        'publishedRevision': published?.config.revision,
        'contentChanged': published == null
            ? null
            : document.fingerprint != published.fingerprint,
        'publishedIssues': published?.issues
            .map((issue) => issue.path)
            .toList(),
        'announcement': config.announcement?.id,
        'announcementLinkEnabled': config.announcement?.buttonUrl != null,
        'disabledClouds': [
          for (final p in CloudPlatform.values)
            if (!config.cloud(p).enabled) p.name,
        ],
        'updates': {
          for (final entry in config.updates.entries)
            entry.key: entry.value.build,
        },
        'forcedUpdates': [
          for (final entry in config.updates.entries)
            if (entry.value.force) entry.key,
        ],
        'helpEnabled': config.helpUrl != null,
      }),
    );
  } on FormatException catch (error) {
    stderr.writeln(
      '配置无效：${error is ControlFormatException ? '${error.path}：' : ''}${error.message}',
    );
    exitCode = 1;
  } on FileSystemException {
    stderr.writeln('无法读取配置文件，请检查路径和权限。');
    exitCode = 1;
  } catch (_) {
    stderr.writeln('未能完成线上核对，请检查网络后重试，或用 --against-file 核对刚下载的线上文件。');
    exitCode = 1;
  } finally {
    fetcher?.close();
  }
}
