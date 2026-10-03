import 'dart:async';
import 'package:flutter/foundation.dart';
import '../domain/downloads.dart';
import '../diagnostics/app_log.dart';
import '../platform/file_access.dart';
import 'download_manager.dart';

class _Availability {
  _Availability(this.path, this.state, this.checkedAt);
  final String? path;
  final FileAvailability state;
  final DateTime checkedAt;
}

/// File availability is transient: a disconnected drive or revoked grant must
/// never rewrite a completed transfer as a failed download or erase its path.
class CompletedFiles extends ChangeNotifier {
  CompletedFiles(this.manager);
  final DownloadManager manager;
  final _states = <String, _Availability>{};
  final _checks = <String, int>{};
  int _sequence = 0;
  Future<void>? _refreshing;
  bool _closed = false, _again = false, _forceAgain = false;
  FileAvailability state(DownloadTask task) {
    final known = _states[task.id];
    return known?.path == task.savedPath && known != null
        ? known.state
        : FileAvailability.unknown;
  }

  Future<FileAvailability> check(DownloadTask task) async {
    final sequence = ++_sequence;
    _checks[task.id] = sequence;
    FileAvailability value;
    try {
      value = await manager.files
          .inspect(task.savedPath)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      value = FileAvailability.inaccessible;
    }
    if (_checks[task.id] != sequence) {
      return _checks.containsKey(task.id)
          ? FileAvailability.unknown
          : state(task);
    }
    _checks.remove(task.id);
    final current = manager.task(task.id);
    if (!_closed &&
        current?.status == DownloadStatus.completed &&
        current?.savedPath == task.savedPath) {
      final changed = state(task) != value;
      if (changed && value != FileAvailability.present) {
        DiagnosticLog.event(
          'download.file_state',
          fields: {
            'ref': DiagnosticLog.reference(task.id),
            'availability': value.name,
          },
        );
      }
      _states[task.id] = _Availability(task.savedPath, value, DateTime.now());
      if (changed) notifyListeners();
    }
    return value;
  }

  Future<void> refresh({bool force = false}) {
    if (_closed) return Future.value();
    if (_refreshing != null) {
      _again = true;
      _forceAgain |= force;
      return _refreshing!;
    }
    return _refreshing = _drain(force).whenComplete(() => _refreshing = null);
  }

  Future<void> _drain(bool force) async {
    do {
      _again = _forceAgain = false;
      await _refresh(force);
      force = _forceAgain;
    } while (_again && !_closed);
  }

  Future<void> _refresh(bool force) async {
    final all = manager.tasks
        .where((t) => t.status == DownloadStatus.completed)
        .toList();
    final ids = all.map((t) => t.id).toSet();
    _states.removeWhere((id, _) => !ids.contains(id));
    final now = DateTime.now();
    final pending = all.where((task) {
      final known = _states[task.id];
      return force ||
          known == null ||
          known.path != task.savedPath ||
          now.difference(known.checkedAt) >= const Duration(seconds: 30);
    }).iterator;
    Future<void> worker() async {
      while (!_closed && pending.moveNext()) {
        await check(pending.current);
      }
    }

    await Future.wait([worker(), worker()]);
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
