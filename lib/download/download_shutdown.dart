import 'dart:async';
import 'package:flutter/foundation.dart';
import '../diagnostics/app_log.dart';
import '../domain/downloads.dart';

/// A session-only opt-in. Completed history never arms a shutdown by itself.
class DownloadShutdown extends ChangeNotifier {
  DownloadShutdown({
    required this.supported,
    required Listenable changes,
    required List<DownloadTask> Function() tasks,
    required bool Function() busy,
    required Future<void> Function() shutdown,
    required Future<void> Function() flush,
    this.countdownSeconds = 60,
  }) : assert(countdownSeconds > 0),
       _changes = changes,
       _tasks = tasks,
       _busy = busy,
       _shutdown = shutdown,
       _flush = flush {
    _changes.addListener(_evaluate);
  }

  final bool supported;
  final int countdownSeconds;
  final Listenable _changes;
  final List<DownloadTask> Function() _tasks;
  final bool Function() _busy;
  final Future<void> Function() _shutdown, _flush;
  final _known = <String>{}, _watched = <String>{};
  Timer? _timer;
  int? _remaining;
  int _generation = 0;
  bool _enabled = false, _preparing = false, _executing = false;
  bool _disposed = false;
  String? _notice;

  bool get enabled => _enabled;
  bool get executing => _executing;
  int? get remainingSeconds => _remaining;
  bool get countingDown => _remaining != null;
  String get detail {
    if (_notice != null) return _notice!;
    if (_executing) return '正在请求系统关机';
    if (_remaining != null) return '下载已全部保存，$_remaining 秒后关机';
    if (!_enabled) return '仅本次有效，全部保存后倒计时 $countdownSeconds 秒';
    if (_watched.isEmpty) return '已开启，等待添加下载任务';
    if (_tasks().any(
      (t) =>
          t.status == DownloadStatus.paused ||
          t.status == DownloadStatus.failed,
    )) {
      return '有暂停或失败任务，等待继续并完成下载';
    }
    return '等待全部下载和文件保存完成';
  }

  void setEnabled(bool value) {
    if (_disposed || _executing || (value && !supported)) return;
    if (_enabled == value && _notice == null) return;
    _stopCountdown();
    _enabled = value;
    _notice = null;
    _known.clear();
    _watched.clear();
    if (value) {
      for (final task in _tasks()) {
        _known.add(task.id);
        if (!task.terminal) _watched.add(task.id);
      }
      DiagnosticLog.event('download.shutdown_enabled');
      _evaluate();
    } else {
      DiagnosticLog.event('download.shutdown_cancelled');
      notifyListeners();
    }
  }

  void _stopCountdown() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _remaining = null;
    _preparing = false;
  }

  bool _ready(Map<String, DownloadTask> tasks) =>
      _watched.isNotEmpty &&
      !_busy() &&
      _watched.every((id) {
        final task = tasks[id];
        return task?.status == DownloadStatus.completed &&
            task?.savedPath?.isNotEmpty == true;
      }) &&
      tasks.values.every((task) => task.terminal);

  void _evaluate() {
    if (_disposed || !_enabled) return;
    final tasks = {for (final task in _tasks()) task.id: task};
    var added = false;
    for (final task in tasks.values) {
      if (_known.add(task.id) || !task.terminal) {
        added = _watched.add(task.id) || added;
      }
    }
    if (_watched.any(
      (id) =>
          !tasks.containsKey(id) ||
          tasks[id]!.status == DownloadStatus.cancelled,
    )) {
      setEnabled(false);
      _notice = '任务已移除，已取消下载完成后关机';
      notifyListeners();
      return;
    }
    if (added || !_ready(tasks)) _stopCountdown();
    if (_ready(tasks) && _timer == null && !_preparing) {
      _remaining = countdownSeconds;
      final generation = _generation;
      DiagnosticLog.event('download.shutdown_countdown');
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_disposed || !_enabled || generation != _generation) return;
        _evaluate();
        if (generation != _generation || _remaining == null) return;
        _remaining = _remaining! - 1;
        if (_remaining == 0) {
          _timer?.cancel();
          _timer = null;
          _preparing = true;
          unawaited(_perform(generation));
        }
        notifyListeners();
      });
    }
    notifyListeners();
  }

  Future<void> _perform(int generation) async {
    try {
      await _flush();
      if (_disposed || !_enabled || generation != _generation) return;
      // Recheck after flushing: a new task or cancellation may have arrived.
      if (!_ready({for (final task in _tasks()) task.id: task})) {
        _stopCountdown();
        _evaluate();
        return;
      }
      _enabled = false;
      _remaining = null;
      _preparing = false;
      _executing = true;
      notifyListeners();
      await _shutdown();
      DiagnosticLog.event('download.shutdown_requested');
      _notice = '已请求系统关机';
    } catch (error, stack) {
      if (_disposed || generation != _generation) return;
      DiagnosticLog.error('download.shutdown_failed', error, stack);
      _notice = '关机未成功，请检查系统权限后重新开启';
      _enabled = false;
      _executing = false;
      _stopCountdown();
      notifyListeners();
    } finally {
      if (!_disposed && generation == _generation) {
        _executing = false;
        notifyListeners();
      }
    }
  }

  // Stopping services can precede detaching the UI. Keep the notifier usable
  // until its owner disposes it, but cancel every pending shutdown immediately.
  void close() {
    if (_disposed) return;
    _disposed = true;
    _enabled = false;
    _stopCountdown();
    _changes.removeListener(_evaluate);
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}
