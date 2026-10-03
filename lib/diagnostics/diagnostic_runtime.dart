import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../core/json.dart';
import 'app_log.dart';

class DiagnosticRuntime with WidgetsBindingObserver {
  DiagnosticRuntime.attach(this.log) {
    DiagnosticLog.active = log;
    WidgetsBinding.instance.addObserver(this);
    _previousFlutter = FlutterError.onError;
    _flutterHandler = (details) {
      log.record(
        'flutter.framework',
        level: 'error',
        error: details.exception,
        stack: details.stack,
        fields: {
          'library': details.library,
          'context': details.context?.toDescription(),
        },
      );
      // Keep Flutter's presentation and debugger behavior intact.
      if (_previousFlutter != null) {
        _previousFlutter!(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    FlutterError.onError = _flutterHandler;
    final dispatcher = PlatformDispatcher.instance;
    _previousPlatform = dispatcher.onError;
    _platformHandler = (error, stack) {
      log.record(
        'flutter.unhandled_async',
        level: 'error',
        error: error,
        stack: stack,
      );
      return _previousPlatform?.call(error, stack) ?? true;
    };
    dispatcher.onError = _platformHandler;
  }
  final DiagnosticLog log;
  static DiagnosticRuntime? _current;
  void Function(FlutterErrorDetails)? _previousFlutter;
  late final void Function(FlutterErrorDetails) _flutterHandler;
  bool Function(Object, StackTrace)? _previousPlatform;
  late final bool Function(Object, StackTrace) _platformHandler;
  bool _disposed = false;

  static Future<DiagnosticLog> start() async {
    if (_current != null) return _current!.log;
    Directory? directory;
    Object? failure;
    bool? enabled;
    try {
      if (Platform.isAndroid) {
        final paths = asJson(
          await const MethodChannel('com.asterlink.app/native')
              .invokeMethod<Object?>('diagnosticPaths')
              .timeout(const Duration(seconds: 5)),
        );
        require(paths.str('logs').isNotEmpty, '无法读取日志目录');
        directory = Directory(paths.str('logs'));
        enabled = paths.boolean('enabled', true);
      } else {
        directory = Directory(
          p.join(
            (await getApplicationSupportDirectory()).path,
            'AsterLink',
            'diagnostics',
          ),
        );
      }
    } catch (error) {
      failure = error;
      // If Android cannot read the persisted preference, respect a possible opt-out.
      if (Platform.isAndroid) enabled = false;
    }
    final log = DiagnosticLog.open(directory, enabled: enabled);
    _current = DiagnosticRuntime.attach(log);
    if (failure != null) {
      log.record(
        'logging.storage_unavailable',
        level: 'warning',
        error: failure,
      );
    }
    return log;
  }

  static void stop() => _current?.dispose();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    if (identical(FlutterError.onError, _flutterHandler)) {
      FlutterError.onError = _previousFlutter;
    }
    final dispatcher = PlatformDispatcher.instance;
    if (identical(dispatcher.onError, _platformHandler)) {
      dispatcher.onError = _previousPlatform;
    }
    log.close();
    if (identical(_current, this)) _current = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      log.lifecycle(state.name);
  @override
  void didHaveMemoryPressure() =>
      log.record('system.memory_pressure', level: 'warning');
}
