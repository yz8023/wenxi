import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/json.dart';
import '../domain/downloads.dart';
import '../platform/native_engine.dart';

/// Tracks the current run, excluding unrelated completed, failed and paused history.
class DownloadOverlayBatch {
  final _ids = <String>{};
  final _previous = <String, DownloadStatus>{};
  bool _initialized = false;

  void reset() {
    _ids.clear();
    _previous.clear();
    _initialized = false;
  }

  static bool _active(DownloadStatus? status) =>
      status == DownloadStatus.pending || status == DownloadStatus.running;

  Json snapshot(List<DownloadTask> all, {bool dark = false}) {
    final available = all
        .where((t) => t.status != DownloadStatus.cancelled)
        .toList();
    final activeTasks = available.where((t) => t.active).toList();
    if (!_initialized) {
      _ids.addAll(activeTasks.map((t) => t.id));
      if (_ids.isEmpty && available.isNotEmpty) {
        final latest = available.reduce(
          (a, b) => a.createdAt >= b.createdAt ? a : b,
        );
        _ids.add(latest.id);
      }
      _initialized = true;
    } else {
      final started = available.where((t) {
        final previous = _previous[t.id];
        // Also observe short downloads/retries that finish between UI updates.
        return previous == null ||
            t.active && !_active(previous) ||
            t.status == DownloadStatus.completed &&
                previous != DownloadStatus.completed &&
                !_active(previous);
      }).toList();
      if (started.isNotEmpty) {
        final runContinues = activeTasks.any(
          (t) => _ids.contains(t.id) && _active(_previous[t.id]),
        );
        if (!runContinues) _ids.clear();
        _ids.addAll(started.map((t) => t.id));
      }
      _ids.addAll(activeTasks.map((t) => t.id));
    }
    final availableIds = available.map((t) => t.id).toSet();
    _ids.removeWhere((id) => !availableIds.contains(id));
    _previous
      ..clear()
      ..addEntries(all.map((t) => MapEntry(t.id, t.status)));
    final tasks = all.where((t) => _ids.contains(t.id)).toList()
      ..sort((a, b) {
        final status = (a.active ? 0 : 1).compareTo(b.active ? 0 : 1);
        return status != 0 ? status : b.createdAt.compareTo(a.createdAt);
      });
    final complete =
        tasks.isNotEmpty &&
        tasks.every((t) => t.status == DownloadStatus.completed);
    final known = tasks.isNotEmpty && tasks.every((t) => t.total > 0);
    final total = tasks.fold<int>(0, (n, t) => n + t.total);
    final received = tasks.fold<int>(
      0,
      (n, t) =>
          n + (t.total > 0 ? t.downloaded.clamp(0, t.total) : t.downloaded),
    );
    final active = tasks.where((t) => t.active).length;
    final failed = tasks.where((t) => t.status == DownloadStatus.failed).length;
    final completed = tasks
        .where((t) => t.status == DownloadStatus.completed)
        .length;
    return {
      'dark': dark,
      'count': tasks.length,
      'active': active,
      'completed': completed,
      'failed': failed,
      'downloaded': received,
      'total': known ? total : 0,
      'progress': complete
          ? 100
          : known
          ? (received * 100 ~/ total).clamp(0, 99)
          : -1,
      'speed': tasks.where((t) => t.active).fold<int>(0, (n, t) => n + t.speed),
      'status': tasks.isEmpty
          ? '暂无任务'
          : complete
          ? '全部完成'
          : active > 0
          ? '正在下载'
          : failed > 0
          ? (completed > 0 ? '部分失败' : '下载失败')
          : '已暂停',
      'canPause': active > 0,
      'canResume': tasks.any(
        (t) =>
            t.status == DownloadStatus.paused ||
            t.status == DownloadStatus.failed,
      ),
      'tasks': [
        for (final t in tasks.take(20))
          {
            'id': t.id,
            'name': String.fromCharCodes(t.spec.fileName.runes.take(120)),
            'status': t.status.name,
            'label': t.phase.isNotEmpty && t.active ? t.phase : t.status.label,
            'downloaded': t.downloaded,
            'total': t.total,
            'speed': t.active ? t.speed : 0,
            'progress': t.status == DownloadStatus.completed
                ? 100
                : t.total > 0
                ? (t.progress * 100).floor().clamp(0, 99)
                : -1,
            'action': t.active
                ? 'pause'
                : t.status == DownloadStatus.paused ||
                      t.status == DownloadStatus.failed
                ? 'resume'
                : '',
          },
      ],
    };
  }
}

class DownloadOverlay extends ChangeNotifier {
  DownloadOverlay({
    required this.supported,
    required this.changes,
    required this.tasks,
    required this.pause,
    required this.resume,
    required this.pauseAll,
    required this.resumeAll,
    required this.openDownloads,
    required this.dark,
    Future<Object?> Function(String, Json)? invoke,
  }) : _invoke =
           invoke ??
           ((method, args) =>
               nativeChannel.invokeMethod<Object?>(method, args)) {
    if (supported) changes.addListener(_changed);
  }
  final bool supported;
  final Listenable changes;
  final List<DownloadTask> Function() tasks;
  final Future<void> Function(String) pause, resume;
  final Future<void> Function() pauseAll, resumeAll;
  final VoidCallback openDownloads;
  final bool Function() dark;
  final Future<Object?> Function(String, Json) _invoke;
  final _batch = DownloadOverlayBatch();
  Timer? _timer;
  bool visible = false,
      pendingPermission = false,
      _closed = false,
      _opening = false;

  Future<void> toggle() async {
    if (!supported || _closed || _opening) return;
    _opening = true;
    try {
      if (visible || pendingPermission) {
        await _invoke('downloadOverlayClose', {});
        stateChanged({});
      } else {
        _batch.reset();
        final state = await _invoke('downloadOverlayShow', _snapshot());
        stateChanged(asJson(state));
      }
    } on PlatformException catch (e) {
      throw AppException(e.message ?? '无法开启下载悬浮窗，请检查悬浮窗权限');
    } finally {
      _opening = false;
    }
  }

  Json _snapshot() => _batch.snapshot(tasks(), dark: dark());
  void stateChanged(Json state) {
    if (_closed) return;
    visible = state.boolean('visible');
    pendingPermission = state.boolean('pendingPermission');
    notifyListeners();
    if (visible) _changed();
  }

  void _changed() {
    if (_closed || !visible || _timer != null) return;
    _timer = Timer(const Duration(milliseconds: 750), () async {
      _timer = null;
      if (_closed || !visible) return;
      try {
        await _invoke('downloadOverlayUpdate', _snapshot());
      } on PlatformException {
        stateChanged({});
      } on MissingPluginException {
        stateChanged({});
      }
    });
  }

  Future<void> action(Json arguments) async {
    if (_closed) return;
    final id = arguments.str('id');
    switch (arguments.str('action')) {
      case 'pause':
        if (tasks().any((t) => t.id == id && t.active)) {
          await pause(id);
        }
      case 'resume':
        if (tasks().any(
          (t) =>
              t.id == id &&
              (t.status == DownloadStatus.paused ||
                  t.status == DownloadStatus.failed),
        )) {
          await resume(id);
        }
      case 'pauseAll':
        await pauseAll();
      case 'resumeAll':
        await resumeAll();
      case 'openDownloads':
        openDownloads();
    }
    _changed();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    if (supported) {
      changes.removeListener(_changed);
      try {
        await _invoke('downloadOverlayClose', {});
      } on PlatformException {
        /* Platform already detached. */
      } on MissingPluginException {
        /* No Android host. */
      }
    }
    dispose();
  }
}
