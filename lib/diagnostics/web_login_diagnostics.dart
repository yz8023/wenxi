import '../domain/models.dart';
import 'app_log.dart';

/// The interface deliberately accepts no URLs, cookies, response text or page
/// contents. Browser failures retain their type/stage without login secrets.
class WebLoginDiagnostics {
  WebLoginDiagnostics(
    this.platform, {
    this.flow = 'account',
    DiagnosticLog? log,
    int Function()? milliseconds,
  }) : _log = log,
       _milliseconds = milliseconds {
    _clock.start();
  }
  final CloudPlatform platform;
  final String flow;
  final DiagnosticLog? _log;
  final int Function()? _milliseconds;
  final _clock = Stopwatch();
  int _page = 0, _pageStarted = 0;
  bool _closed = false;
  int get _elapsed => _milliseconds?.call() ?? _clock.elapsedMilliseconds;

  void record(
    String event, {
    String level = 'info',
    String stage = 'page',
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stack,
  }) {
    if (_closed) return;
    (_log ?? DiagnosticLog.active)?.record(
      'web_login.$event',
      level: level,
      error: error,
      stack: stack,
      fields: {
        'platform': platform.key,
        'flow': flow,
        'stage': stage,
        'page': _page,
        'elapsedMs': _elapsed,
        if (_page > 0)
          'pageElapsedMs': (_elapsed - _pageStarted).clamp(0, 1 << 31),
        ...fields,
      },
    );
  }

  void pageStarted() {
    if (_closed) return;
    _page++;
    _pageStarted = _elapsed;
    record('page_started');
  }

  void pageLoaded() => record('page_loaded');

  void resourceFailed({
    required bool? isMainFrame,
    required String type,
    int? code,
  }) => record(
    'resource_failed',
    level: isMainFrame == true ? 'error' : 'warning',
    stage: 'network',
    fields: {'isMainFrame': isMainFrame, 'errorType': type, 'errorCode': code},
  );

  void httpFailed({required bool? isMainFrame, required int? status}) => record(
    'http_failed',
    level: isMainFrame == true ? 'error' : 'warning',
    stage: 'http',
    fields: {'isMainFrame': isMainFrame, 'httpStatus': status},
  );

  void rendererGone({required bool didCrash, int? priority}) => record(
    'renderer_gone',
    level: didCrash ? 'error' : 'warning',
    stage: 'renderer',
    fields: {'didCrash': didCrash, 'rendererPriority': priority},
  );

  void close({required bool completed}) {
    if (_closed) return;
    record('closed', fields: {'completed': completed});
    _closed = true;
    _clock.stop();
  }
}
