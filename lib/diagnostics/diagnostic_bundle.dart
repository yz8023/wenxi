import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/json.dart';
import 'app_log.dart';
import 'diagnostic_summary.dart';
import 'redaction.dart';

class DiagnosticBundle {
  DiagnosticBundle(
    this.log, {
    required this.snapshot,
    this.nativeEnabled = true,
    this.nativeCall,
  });
  final DiagnosticLog log;
  final Json Function() snapshot;
  final bool nativeEnabled;
  final Future<Object?> Function(String method, Json args)? nativeCall;
  static const _channel = MethodChannel('com.asterlink.app/native');

  Future<Object?> _call(String method, [Json args = const {}]) async {
    if (!nativeEnabled || (!Platform.isAndroid && nativeCall == null)) {
      return null;
    }
    return await (nativeCall?.call(method, args) ??
            _channel.invokeMethod<Object?>(method, args))
        .timeout(const Duration(seconds: 8));
  }

  Future<Json> platformSnapshot() async {
    try {
      return asJson(await _call('diagnosticSnapshot'));
    } catch (error, stack) {
      DiagnosticLog.error('logging.native_snapshot_failed', error, stack);
      return {'collectionFailed': true, 'note': '无法读取系统诊断，本包仍包含 Flutter 日志'};
    }
  }

  Future<void> setEnabled(bool value) async {
    final old = log.enabled;
    await _call('diagnosticEnabled', {'enabled': value});
    try {
      log.setEnabled(value);
    } catch (_) {
      await _call('diagnosticEnabled', {'enabled': old});
      rethrow;
    }
  }

  Future<void> clear() async {
    await _call('diagnosticClear');
    log.clear();
  }

  Future<String> summary({String note = ''}) async =>
      diagnosticSummary(log, await platformSnapshot(), note: note);

  Future<Uint8List> build({String note = ''}) async {
    Json state;
    try {
      state = snapshot();
    } catch (error, stack) {
      log.record(
        'logging.state_snapshot_failed',
        level: 'error',
        error: error,
        stack: stack,
      );
      state = {'stateSnapshotFailed': true};
    }
    final native = await platformSnapshot();
    final files = <String, String>{
      'summary.txt': diagnosticSummary(log, native, note: note),
      'README.txt':
          '文析助手本地诊断包\n'
          '版本：$applicationVersion\n'
          'summary.txt：便于反馈的简短排查摘要，已按日志脱敏规则隐藏敏感内容。\n'
          'logs/：Flutter 错误与操作线索，按 UTC 时间和会话编号关联。\n'
          'native/：Android Java/Kotlin 错误和系统退出信息。\n'
          'diagnostics.json：脱敏运行状态；manifest.json：SHA-256 校验。\n'
          '仅保存本机最近 7 天、受容量上限约束的记录，不自动上传。\n'
          '不主动读取请求正文、请求头、用户下载文件或账号数据库；常见凭据、完整链接和绝对路径已脱敏。\n'
          '系统未提供堆栈时只记录退出原因；low_memory/user_requested 不等于代码崩溃。\n'
          'previousSessionInterrupted 仅说明上次没有正常关闭标记，不能据此认定崩溃。\n'
          'Android 11 以下无系统退出历史；Windows 原生进程硬崩溃可能只有最后操作线索。\n'
          '旧版未启用此功能时的 Dart 堆栈无法补录。\n',
      'diagnostics.json': const JsonEncoder.withIndent('  ').convert(
        LogRedactor.value({
          ...state,
          'version': applicationVersion,
          'logEnabled': log.enabled,
          'logBytes': log.sizeBytes,
          'previousSessionInterrupted': log.previousSessionInterrupted,
          'storageError': log.storageError,
          'suppressedRepeats': log.suppressed,
          'system': Platform.operatingSystem,
          'systemVersion': Platform.operatingSystemVersion,
          'dart': Platform.version,
          'processors': Platform.numberOfProcessors,
          'exportedAt': log.clock().toUtc().toIso8601String(),
          'timezoneOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
          'note': LogRedactor.text(note, limit: 2000),
        }),
      ),
      for (final entry in log.exportFiles().entries)
        'logs/${entry.key}': entry.value,
    };
    var index = 0;
    for (final report in native.list('reports').take(8)) {
      final reportIndex = index++;
      try {
        files['native/error-$reportIndex.json'] = const JsonEncoder.withIndent(
          '  ',
        ).convert(LogRedactor.value(jsonDecode(report.str('content'))));
      } catch (_) {
        files['native/error-$reportIndex.txt'] = '系统错误记录写入中断，已跳过不完整内容。';
      }
    }
    native.remove('reports');
    files['native/system.json'] = const JsonEncoder.withIndent(
      '  ',
    ).convert(LogRedactor.value(native));
    return compute(_encodeBundle, files);
  }
}

Uint8List _encodeBundle(Map<String, String> files) {
  final archive = Archive();
  final manifest = <String, Object?>{};
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    manifest[entry.key] = {
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    };
    archive.add(ArchiveFile(entry.key, bytes.length, bytes));
  }
  archive.add(
    ArchiveFile.string(
      'manifest.json',
      const JsonEncoder.withIndent('  ').convert(manifest),
    ),
  );
  return ZipEncoder().encodeBytes(archive);
}
