import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import '../diagnostics/app_log.dart';
import '../data/cleanup_outbox.dart';
import '../data/http.dart';
import '../data/state_store.dart';
import '../domain/auth.dart';
import '../domain/downloads.dart';
import '../domain/file_types.dart';
import '../domain/models.dart';
import '../domain/settings.dart';
import '../domain/torrent.dart';
import '../platform/file_access.dart';
import '../platform/native_engine.dart';
import 'hls.dart';
import 'download_activity.dart';
import 'download_request.dart';
import 'download_playback_cache.dart';
import 'space_budget.dart';
import 'transfer_http.dart';

class _Stopped implements Exception {}

class _Run {
  final scope = RequestScope();
  final wake = Completer<void>();
  bool stopped = false;
  Future<void> done = Future.value();
  int networkRetries = 0;
  bool networkActive = true;
  ({int active, int total})? httpConnections;
  late StoragePlan storage;
  void stop() {
    stopped = true;
    scope.cancel();
    if (!wake.isCompleted) wake.complete();
  }

  void check() {
    if (stopped) throw _Stopped();
  }

  Future<void> delay(Duration duration) async {
    final elapsed = Completer<void>();
    final timer = Timer(duration, elapsed.complete);
    try {
      await Future.any([wake.future, elapsed.future]);
    } finally {
      timer.cancel();
    }
  }
}

class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.store,
    required this.engine,
    required this.files,
    required this.cleanups,
    required this.http,
    required this.refreshSource,
    this.foreground,
    this.checkNewCloudTask,
  }) {
    space = SpaceBudget(
      () => files.freeBytes(engine.cache.path),
      availableOnVolume: (volume) =>
          files.freeBytes(_volumePaths[volume] ?? engine.cache.path),
    );
  }
  final StateStore store;
  final GopeedEngine engine;
  final FileAccess files;
  final CleanupOutbox cleanups;
  final TransferHttp http;
  final Future<DownloadSpec> Function(DownloadSpec) refreshSource;
  final void Function(CloudPlatform)? checkNewCloudTask;
  final Future<void> Function(DownloadActivity activity)? foreground;
  late final SpaceBudget space;
  final _tasks = <String, DownloadTask>{}, _running = <String, _Run>{};
  final _unsettledRuns = <_Run>{};
  final _controls = <String, AsyncGate>{};
  final _pumpGate = AsyncGate();
  final _removalGate = AsyncGate();
  final _foregroundGate = AsyncGate();
  final _interrupted = <String>{};
  final _volumePaths = <String, String>{};
  final _exportProgress = <String, double>{};
  final _postWaiters = <Completer<void>>[];
  final _playbackHolds = <String, int>{};
  final _cacheAccess = <String, AsyncGate>{};
  final _readable = <String, DownloadReadableState>{};
  int _torrentPlaybackHolds = 0;
  bool _postBusy = false;
  Timer? _progressFlush;
  Timer? _foregroundTimer;
  bool _foregroundPublishing = false;
  Future<void>? _pausingAll;
  double? exportProgress(String id) => _exportProgress[id];
  ({int active, int total})? httpConnections(String id) {
    final run = _running[id];
    return run != null &&
            !run.stopped &&
            run.networkActive &&
            _tasks[id]?.status == DownloadStatus.running
        ? run.httpConnections
        : null;
  }

  int get _networkCount =>
      _running.values.where((run) => run.networkActive).length;
  bool _closing = false, _initialised = false;
  String? lastError;
  List<DownloadTask> get tasks =>
      _tasks.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  int get activeCount => _running.length;
  AppSettings get settings => AppSettings.fromJson(store.data.obj('settings'));
  DownloadTask? task(String id) => _tasks[id];

  bool canStream(DownloadTask task) =>
      !task.spec.isTorrent &&
      task.status != DownloadStatus.cancelled &&
      {FileKind.video, FileKind.audio}.contains(fileKind(task.spec.fileName)) &&
      {'http', 'https'}.contains(Uri.tryParse(task.spec.url)?.scheme);

  Future<DownloadPlaybackCache> acquirePlayback(
    String id, {
    bool refresh = false,
  }) async {
    require(!_closing, '应用正在退出');
    final current = _tasks[id];
    require(current != null && canStream(current), '此下载任务无法边下边播');
    _playbackHolds[id] = (_playbackHolds[id] ?? 0) + 1;
    DownloadSpec? source;
    var released = false;
    Future<void> release() async {
      if (released) return;
      released = true;
      final count = (_playbackHolds[id] ?? 1) - 1;
      if (count <= 0) {
        _playbackHolds.remove(id);
      } else {
        _playbackHolds[id] = count;
      }
      if (source != null) {
        await cleanups.release(source.cleanup);
        await cleanups.ready(source.cleanup);
      }
      if (!_closing) {
        await _drainCompletedCaches();
        _background(cleanups.drain());
      }
    }

    try {
      if (refresh && current!.spec.source != null) {
        // CloudRepository.refresh returns a retained source of the same file.
        source = await refreshSource(current.spec);
      } else {
        source = current!.spec.copyWith();
        cleanups.retain(source.cleanup);
      }
      require(!_closing && _tasks[id] != null, '下载任务已关闭');
      await resume(id);
      _schedule();
      return DownloadPlaybackCache(
        source: source,
        read: (start, end, identity) async {
          require(!released && !_closing, '播放已结束');
          final bytes = await _readPlaybackCache(id, start, end, identity);
          if (bytes != null) return bytes;
          final task = _tasks[id];
          require(task != null, '下载任务已删除');
          require(
            task!.active || task.status == DownloadStatus.completed,
            task.status == DownloadStatus.failed
                ? '下载失败，请继续下载后重试播放'
                : '下载已暂停，请继续下载后重试播放',
          );
          return null;
        },
        onRelease: release,
      );
    } catch (_) {
      await release();
      rethrow;
    }
  }

  Future<Uint8List?> _readPlaybackCache(
    String id,
    int start,
    int end,
    RemoteIdentity identity,
  ) => (_cacheAccess[id] ??= AsyncGate()).run(() async {
    final state = _readable[id];
    if (state == null ||
        start < 0 ||
        end < start ||
        end - start >= 16 * 1024 * 1024 ||
        !state.identity.canResume(identity) ||
        !state.contains(start, end)) {
      return null;
    }
    RandomAccessFile? handle;
    try {
      final directory = engine.taskDirectory(id);
      final path = p.join(directory.path, 'payload.gopeed');
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final root = await engine.cache.resolveSymbolicLinks();
      final actual = await directory.resolveSymbolicLinks();
      if (!p.equals(p.dirname(actual), root)) return null;
      handle = await File(path).open();
      if (await handle.length() < end + 1) return null;
      await handle.setPosition(start);
      final bytes = await handle.read(end - start + 1);
      return bytes.length == end - start + 1 ? bytes : null;
    } on FileSystemException {
      return null;
    } finally {
      await handle?.close();
    }
  });

  DownloadActivity get activity => DownloadActivity.fromTasks(
    _tasks.values.where(
      (task) =>
          _running.containsKey(task.id) ||
          (task.active && (!task.spec.isTorrent || _torrentPlaybackHolds == 0)),
    ),
  );

  Future<void> _syncForeground() async {
    if (foreground == null) return;
    await _foregroundGate.run(() async {
      // Compute inside the gate: a delayed idle update must never stop a newer
      // task's service. Pending tasks keep it alive across background handoffs.
      final current = activity;
      if (current.active == 0) {
        _foregroundTimer?.cancel();
        _foregroundTimer = null;
      }
      await foreground!(current);
      if (current.active > 0 && !_closing) {
        _foregroundTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
          if (_foregroundPublishing) return;
          _foregroundPublishing = true;
          unawaited(
            _syncForeground()
                .catchError((Object error, StackTrace stack) {
                  DiagnosticLog.error('download.foreground_lost', error, stack);
                  _background(pauseAll(reason: '后台下载服务已中断，请返回应用继续'));
                })
                .whenComplete(() => _foregroundPublishing = false),
          );
        });
      }
    });
  }

  /// Only the Android service's system restart invokes this. Opening the app
  /// normally does not resume paused/failed history or a user's explicit stop.
  Future<void> recoverInterrupted() async {
    if (_closing) return;
    final ids = _interrupted.toList();
    for (final id in ids) {
      if (_tasks[id]?.status == DownloadStatus.paused) {
        // resume commits this ID together with its new pending status. Keep
        // later IDs recoverable if the process dies halfway through this loop.
        await resume(id);
      } else {
        _interrupted.remove(id);
      }
    }
    await _persist();
    await _syncForeground();
    DiagnosticLog.event(
      'download.service_recovered',
      fields: {'count': ids.length},
    );
  }

  Future<void> initialize() async {
    // Recovery is explicitly authorized by the native service after startup.
    if (_initialised) return;
    _loadSnapshot();
    await _persist();
    _initialised = true;
    await cleanups.reconcile(recoverOrphans: true);
    _background(cleanups.drain());
    _background(_drainRemovedDownloads());
    _background(_drainCompletedCaches());
  }

  Future<void> discardInterrupted() async {
    if (_interrupted.isEmpty) return;
    _interrupted.clear();
    await _persist();
  }

  void _loadSnapshot() {
    final loaded = <String, DownloadTask>{};
    _interrupted
      ..clear()
      ..addAll(
        (store.data['downloadRecovery'] as List? ?? []).whereType<String>(),
      );
    for (final value in store.data.list('tasks')) {
      var task = DownloadTask.fromJson(value);
      engine.validateId(task.id);
      if (task.active) {
        _interrupted.add(task.id);
        task = task.update({'status': 'paused', 'phase': '', 'speed': 0});
      }
      loaded[task.id] = task;
    }
    _interrupted.removeWhere(
      (id) => loaded[id]?.status != DownloadStatus.paused,
    );
    _tasks
      ..clear()
      ..addAll(loaded);
  }

  /// Hold scheduling while merging legacy records, then reload the committed
  /// queue before any later write can overwrite the imported tasks.
  Future<void> importPausedQueue(Future<void> Function() import) =>
      _pumpGate.run(() async {
        require(!_closing && _running.isEmpty, '请先暂停下载再导入旧版数据');
        await import();
        _loadSnapshot();
        await _persist();
        await cleanups.reconcile(recoverOrphans: true);
        _background(cleanups.drain());
        notifyListeners();
      });

  Future<void> _persist({
    Json addedTorrents = const {},
    String? removedDownload,
    List<String> removedDownloads = const [],
    List<DownloadCleanup?> removedCleanups = const [],
  }) {
    _progressFlush?.cancel();
    _progressFlush = null;
    return store.change((draft) {
      final removed = {?removedDownload, ...removedDownloads};
      final retained = _tasks.values
          .where((task) => !removed.contains(task.id))
          .toList();
      draft['tasks'] = retained.map((t) => t.toJson()).toList();
      draft['downloadRecovery'] = _interrupted
          .where((id) => !removed.contains(id))
          .toList();
      final used = retained
          .where((t) => t.spec.isTorrent)
          .map((t) => t.spec.torrent!.str('hash'))
          .toSet();
      draft['torrents'] = <String, dynamic>{
        ...draft.obj('torrents'),
        ...addedTorrents,
      }..removeWhere((key, _) => !used.contains(key));
      if (removedDownload != null || removedDownloads.isNotEmpty) {
        // Commit the history removal and cleanup markers together. A file
        // provider or native cleanup failure must not bring the row back.
        for (final key in ['downloadRemovals', 'nativeRemovals']) {
          draft[key] = <String>{
            ...(draft[key] as List? ?? []).map((value) => '$value'),
            ?removedDownload,
            ...removedDownloads,
          }.toList();
        }
        cleanups.readyInDraft(draft, removedCleanups);
      }
    });
  }

  Future<void> _update(
    String id,
    Json fields, {
    bool persist = true,
    bool progress = false,
  }) async {
    final old = _tasks[id];
    if (old == null) return;
    _tasks[id] = old.update(fields);
    notifyListeners();
    if (persist) {
      if (progress) {
        _progressFlush ??= Timer(const Duration(seconds: 2), () {
          _progressFlush = null;
          _background(_persist());
        });
      } else {
        await _persist();
      }
    }
  }

  void _background(Future<void> future) {
    unawaited(
      future.catchError((Object e, StackTrace stack) {
        DiagnosticLog.error('download.background_error', e, stack);
        lastError = e is AppException ? e.message : '操作失败，请检查存储空间后重试';
        notifyListeners();
      }),
    );
  }

  Future<String> enqueue(DownloadSpec spec) async =>
      (await enqueueAll([spec])).single;

  Future<List<String>> enqueueAll(List<DownloadSpec> specs) =>
      _pumpGate.run(() async {
        require(!_closing, '应用正在退出');
        RequestScope.checkpoint();
        require(specs.isNotEmpty && specs.length <= 10000, '请选择 1–10000 个文件');
        final options = settings;
        final tasks = <DownloadTask>[];
        for (final spec in specs) {
          if (spec.platform case final platform?) {
            checkNewCloudTask?.call(platform);
          }
          if (spec.needsPreparation) {
            final origin = DownloadOrigin.fromJson(spec.source!);
            require(
              origin.file.id.isNotEmpty && !origin.file.isDirectory,
              '下载文件信息不完整',
            );
          } else {
            _validateDownloadUrl(spec);
          }
          final safeSpec = spec.copyWith(
            fileName: safeFileName(spec.fileName),
            relativePath: safeRelativePath(spec.relativePath),
          );
          tasks.add(
            DownloadTask(
              id: newId(),
              spec: safeSpec,
              createdAt: DateTime.now().millisecondsSinceEpoch,
              total: spec.expectedSize,
              connections: options.connectionsFor(spec.platform, spec.profile),
              retries: options.retries,
              speedLimit: options.speedLimit,
              destination: options.destination,
              phase: spec.needsPreparation ? '等待获取下载链接' : '',
              connectionOptions: spec.needsPreparation
                  ? {
                      'default': options.threads,
                      for (final profile in AppSettings.profiles.keys)
                        profile: options.connectionsFor(spec.platform, profile),
                    }
                  : const {},
            ),
          );
        }
        for (final task in tasks) {
          _tasks[task.id] = task;
        }
        try {
          await _persist();
        } catch (_) {
          for (final task in tasks) {
            _tasks.remove(task.id);
          }
          rethrow;
        }
        for (final task in tasks) {
          await cleanups.release(task.spec.cleanup);
          DiagnosticLog.event(
            'download.enqueue',
            fields: {
              'ref': DiagnosticLog.reference(task.id),
              'platform': task.spec.platform?.name,
              'bytes': task.total,
              'connections': task.connections,
              'preparing': task.spec.needsPreparation,
            },
          );
        }
        notifyListeners();
        _schedule();
        return tasks.map((task) => task.id).toList();
      });

  void _validateDownloadUrl(DownloadSpec spec) {
    final uri = Uri.tryParse(spec.url);
    require(
      uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty,
      '只支持 HTTP / HTTPS 文件下载',
    );
  }

  Future<List<String>> enqueueTorrent(
    TorrentInfo info,
    List<int> selected,
  ) async {
    require(!_closing, '应用正在退出');
    final indices = selected.toSet().toList()..sort();
    require(
      indices.isNotEmpty &&
          indices.length <= 1000 &&
          indices.every((i) => i >= 0 && i < info.files.length),
      '每次请选择 1–1000 个文件',
    );
    require(
      !_tasks.values.any(
        (t) =>
            !t.terminal &&
            t.spec.torrent?.str('hash') == info.hash &&
            indices.contains(t.spec.torrent!.integer('index')),
      ),
      '选中的文件已有下载任务，请在下载页继续',
    );
    final ids = <String>[], options = settings;
    for (final index in indices) {
      final file = info.files[index], id = newId();
      ids.add(id);
      _tasks[id] = DownloadTask(
        id: id,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        spec: DownloadSpec(
          url: info.magnet,
          fileName: safeFileName(file.name),
          relativePath: safeRelativePath(file.directory),
          expectedSize: file.size,
          torrent: {'hash': info.hash, 'index': file.index, 'path': file.path},
        ),
        total: file.size,
        connections: 80,
        retries: options.retries,
        speedLimit: options.speedLimit,
        destination: options.destination,
      );
    }
    try {
      await _persist(
        addedTorrents: {
          info.hash: {
            'data': info.data,
            'name': info.name,
            'pieceLength': info.pieceLength,
          },
        },
      );
    } catch (_) {
      for (final id in ids) {
        _tasks.remove(id);
      }
      rethrow;
    }
    notifyListeners();
    _schedule();
    return ids;
  }

  void _schedule() {
    if (_closing || _pausingAll != null) return;
    _background(
      _pumpGate.run(() async {
        while (!_closing &&
            _pausingAll == null &&
            _networkCount < settings.concurrent &&
            _running.length < settings.concurrent + 2) {
          final pending = _tasks.values
              .where(
                (t) =>
                    t.status == DownloadStatus.pending &&
                    !_running.containsKey(t.id) &&
                    (!t.spec.isTorrent ||
                        (_torrentPlaybackHolds == 0 &&
                            !_running.keys.any(
                              (id) => _tasks[id]?.spec.isTorrent == true,
                            ))),
              )
              .toList();
          final next =
              pending
                  .where((task) => _playbackHolds.containsKey(task.id))
                  .firstOrNull ??
              pending.firstOrNull;
          if (next == null) break;
          final run = _Run();
          _running[next.id] = run;
          _unsettledRuns.add(run);
          run.done = run.scope
              .run(
                () => DownloadRequestContext(
                  id: next.id,
                  retries: next.retries,
                  onRetry: (_) async {
                    run.check();
                    run.networkRetries++;
                    await _update(next.id, {
                      'phase': '获取下载链接（重试中）',
                      'speed': 0,
                    }, persist: false);
                  },
                ).run(() => _run(next.id, run)),
              )
              .catchError((Object e) {
                lastError = e is AppException ? e.message : '下载状态保存失败，请检查存储空间';
              })
              .whenComplete(() async {
                try {
                  _running.remove(next.id);
                  _background(_drainCompletedCaches());
                  space.release(next.id);
                  _exportProgress.remove(next.id);
                  try {
                    await _syncForeground();
                  } catch (error, stack) {
                    DiagnosticLog.error(
                      'download.foreground_update_failed',
                      error,
                      stack,
                    );
                    _background(pauseAll(reason: '后台下载服务已中断，请返回应用继续'));
                  }
                  notifyListeners();
                  _schedule();
                } finally {
                  _unsettledRuns.remove(run);
                }
              });
        }
      }),
    );
  }

  Future<void> settingsChanged() async {
    // Existing transfers keep their captured thread/speed settings.
    if (_networkCount > settings.concurrent) {
      for (final id
          in _running.entries
              .where((e) => e.value.networkActive)
              .map((e) => e.key)
              .skip(settings.concurrent)
              .toList()) {
        await pause(id);
      }
    }
    _schedule();
  }

  /// Playback gets BT bandwidth without changing a user's explicit pause.
  /// Interrupted downloads remain queued with their native checkpoint intact.
  Future<VoidCallback> prioritizeTorrentPlayback() async {
    require(!_closing, '应用正在退出');
    _torrentPlaybackHolds++;
    try {
      await _pumpGate.run(() async {
        final ids = _running.entries
            .where(
              (entry) =>
                  entry.value.networkActive &&
                  _tasks[entry.key]?.spec.isTorrent == true,
            )
            .map((entry) => entry.key)
            .toList();
        for (final id in ids) {
          await _control(id, () async {
            final task = _tasks[id];
            if (task == null ||
                !task.active ||
                _running[id]?.networkActive != true) {
              return;
            }
            await _stop(id);
            if (_tasks[id] != null && !_tasks[id]!.terminal) {
              await _update(id, {
                'status': 'pending',
                'speed': 0,
                'phase': '在线播放优先，稍后继续下载',
              });
            }
          });
        }
      });
    } catch (_) {
      _torrentPlaybackHolds--;
      _schedule();
      rethrow;
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      _torrentPlaybackHolds--;
      _schedule();
    };
  }

  Future<void> resume(String id) => _control(id, () async {
    _interrupted.remove(id);
    final current = _tasks[id];
    if (current == null || current.terminal || current.active) return;
    await _update(id, {
      'status': 'pending',
      'error': '',
      'recoveryAction': DownloadRecoveryAction.none.name,
      'phase': '',
    });
    _schedule();
  });
  Future<void> _control(String id, Future<void> Function() action) =>
      (_controls[id] ??= AsyncGate()).run(action);
  Future<void> _stop(String id) async {
    final run = _running[id];
    if (run != null) {
      run.stop();
      await files.cancelExport(id);
      await engine.pause(id);
      await run.done;
    }
  }

  Future<void> pause(String id) => _control(id, () async {
    _interrupted.remove(id);
    DiagnosticLog.event(
      'download.pause',
      fields: {'ref': DiagnosticLog.reference(id)},
    );
    // Commit the user's pause before waiting for native/export writers. A
    // process loss during cancellation must not restore it as active work.
    if (_tasks[id]?.active == true) {
      _running[id]?.stop();
      await _update(id, {'status': 'paused', 'speed': 0, 'phase': ''});
    }
    await _stop(id);
    final current = _tasks[id];
    if (current != null && !current.terminal) {
      await _update(id, {'status': 'paused', 'speed': 0, 'phase': ''});
    }
  });
  Future<void> pauseAll({String reason = ''}) =>
      _pausingAll ??= _pauseAll(reason).whenComplete(() {
        _pausingAll = null;
        if (!_closing) Timer.run(_schedule);
      });

  Future<void> _pauseAll(String reason) async {
    _interrupted.clear();
    final ids = _tasks.values.where((t) => t.active).map((t) => t.id).toList();
    // Mark all pending tasks before the first writer finishes and frees a slot.
    for (final id in ids) {
      _running[id]?.stop();
      _tasks[id] = _tasks[id]!.update({
        'status': 'paused',
        'speed': 0,
        'phase': '',
      });
    }
    await _persist();
    await Future.wait(ids.map(pause));
    if (reason.isNotEmpty) {
      for (final id in ids) {
        if (_tasks[id]?.status == DownloadStatus.paused) {
          _tasks[id] = _tasks[id]!.update({'phase': reason});
        }
      }
      await _persist();
      DiagnosticLog.event(
        'download.service_paused',
        fields: {'reason': reason, 'count': ids.length},
      );
    }
    await _syncForeground();
    notifyListeners();
  }

  Future<void> resumeAll() async {
    for (final task in tasks) {
      if (task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.failed) {
        await resume(task.id);
      }
    }
  }

  Future<DownloadBatchResult> batch(
    Iterable<String> ids,
    DownloadBatchAction action, {
    bool deleteFiles = false,
  }) async {
    require(!_closing, '应用正在退出');
    final selected = ids.toSet().toList(growable: false);
    try {
      // Hold scheduling so stopping one writer cannot start another selected
      // queued task before its pause or deletion is processed.
      return await _pumpGate.run(() async {
        final succeeded = <String>[], skipped = <String>[];
        final failed = <String, Object>{};
        var cancelled = false;
        for (var index = 0; index < selected.length; index++) {
          final id = selected[index];
          if (_closing || RequestScope.current?.isCancelled == true) {
            cancelled = true;
            break;
          }
          if (action == DownloadBatchAction.delete && !deleteFiles) {
            final chunk = selected.sublist(
              index,
              (index + 64).clamp(0, selected.length),
            );
            final result = await _deleteIdleRecords(chunk);
            if (result != null) {
              succeeded.addAll(result.succeeded);
              skipped.addAll(result.skipped);
              failed.addAll(result.failed);
              index += chunk.length - 1;
              if (result.cancelled) {
                cancelled = true;
                break;
              }
              continue;
            }
          }
          final task = _tasks[id];
          if (task == null || !action.accepts(task)) {
            skipped.add(id);
            continue;
          }
          try {
            switch (action) {
              case DownloadBatchAction.pause:
                await pause(id);
              case DownloadBatchAction.resume:
                await resume(id);
              case DownloadBatchAction.delete:
                await delete(id, deleteFile: deleteFiles);
            }
            succeeded.add(id);
          } catch (e) {
            failed[id] = e;
          }
        }
        return DownloadBatchResult(
          succeeded: succeeded,
          skipped: skipped,
          failed: failed,
          cancelled: cancelled || RequestScope.current?.isCancelled == true,
        );
      });
    } finally {
      _schedule();
    }
  }

  Future<void> delete(String id, {bool deleteFile = false}) =>
      _control(id, () async {
        _interrupted.remove(id);
        var current = _tasks[id];
        if (current == null) return;
        require(!_playbackHolds.containsKey(id), '请先关闭此任务的播放器再删除');
        DiagnosticLog.event(
          'download.remove_start',
          fields: {
            'ref': DiagnosticLog.reference(id),
            'status': current.status.name,
            'deleteFile': deleteFile,
          },
        );
        if (current.active) {
          _running[id]?.stop();
          await _update(id, {'status': 'paused', 'speed': 0});
        }
        try {
          // Completed exports have no file writer left. Their run may still
          // be waiting for native/cache cleanup, which must not block history.
          if (current.status != DownloadStatus.completed) await _stop(id);
          current = _tasks[id]!;
          if (deleteFile) await files.delete(current.savedPath);
          _tasks.remove(id);
          // Once writers are stopped, persist removal before slow native or
          // filesystem cleanup. The durable markers retry after a restart.
          await _persist(removedDownload: id);
          DiagnosticLog.event(
            'download.record_removed',
            fields: {'ref': DiagnosticLog.reference(id)},
          );
          notifyListeners();
          _background(_drainRemovedDownloads());
          _background(_readyRemovedCleanup(current.spec.cleanup));
        } catch (e, stack) {
          DiagnosticLog.error(
            'download.remove_failed',
            e,
            stack,
            fields: {
              'ref': DiagnosticLog.reference(id),
              'deleteFile': deleteFile,
            },
          );
          _tasks[id] ??= current!;
          await _update(id, {
            'error': e is AppException ? e.message : '删除未完成，记录已保留，请重试',
          });
          rethrow;
        }
      });

  Future<DownloadBatchResult?> _deleteIdleRecords(List<String> ids) async {
    bool idle() => ids.every((id) {
      final task = _tasks[id];
      return task == null ||
          !task.active &&
              (task.status == DownloadStatus.completed ||
                  !_running.containsKey(id));
    });
    if (!idle()) return null;
    DownloadBatchResult? result;
    // Serialize against per-task pause/resume/delete while committing one
    // bounded group. Batches already share the scheduling gate.
    Future<void> locked(int index) async {
      if (index < ids.length) {
        await _control(ids[index], () => locked(index + 1));
        return;
      }
      if (!idle()) return;
      final failed = <String, Object>{}, skipped = <String>[];
      if (_closing || RequestScope.current?.isCancelled == true) {
        result = DownloadBatchResult(
          succeeded: [],
          skipped: [],
          failed: {},
          cancelled: true,
        );
        return;
      }
      final removed = <String, DownloadTask>{};
      for (final id in ids) {
        final task = _tasks[id];
        if (task == null) {
          skipped.add(id);
          continue;
        }
        if (_playbackHolds.containsKey(id)) {
          failed[id] = const AppException('请先关闭此任务的播放器再删除');
          continue;
        }
        removed[id] = task;
      }
      if (removed.isNotEmpty) {
        try {
          await _persist(
            removedDownloads: removed.keys.toList(),
            removedCleanups: removed.values.map((t) => t.spec.cleanup).toList(),
          );
        } catch (error) {
          for (final id in removed.keys) {
            failed[id] = error;
          }
          removed.clear();
          notifyListeners();
        }
        if (removed.isNotEmpty) {
          // Keep the live rows until the removal and cleanup markers commit.
          // An unrelated queued state save must not publish half a removal.
          for (final id in removed.keys) {
            _tasks.remove(id);
            _interrupted.remove(id);
          }
          DiagnosticLog.event(
            'download.records_removed',
            fields: {'count': removed.length},
          );
          notifyListeners();
          _background(_drainRemovedDownloads());
          _background(cleanups.drain());
        }
      }
      result = DownloadBatchResult(
        succeeded: removed.keys.toList(),
        skipped: skipped,
        failed: failed,
        cancelled: RequestScope.current?.isCancelled == true,
      );
    }

    await locked(0);
    return result;
  }

  Future<void> _readyRemovedCleanup(DownloadCleanup? cleanup) async {
    await cleanups.ready(cleanup);
    await cleanups.drain();
  }

  /// Removed history no longer owns a live writer. Retry its private cache
  /// separately, keeping the durable marker until cleanup succeeds.
  Future<void> _drainRemovedDownloads() => _removalGate.run(() async {
    final ids = (store.data['downloadRemovals'] as List? ?? [])
        .map((value) => '$value')
        .toList();
    for (final id in ids) {
      if (_closing) return;
      if (_tasks.containsKey(id)) continue;
      try {
        await engine.remove(id);
        if (_tasks.containsKey(id)) continue;
        await _deleteCache(id);
        await store.change((draft) {
          draft['downloadRemovals'] = (draft['downloadRemovals'] as List? ?? [])
              .where((value) => value != id)
              .toList();
        });
      } catch (error, stack) {
        DiagnosticLog.error(
          'download.cleanup_deferred',
          error,
          stack,
          fields: {'ref': DiagnosticLog.reference(id)},
        );
        // The next removal or app start retries this task. Exported files are
        // never touched here, even when the original URI is no longer usable.
      }
    }
  });

  Future<void> _drainCompletedCaches() => _removalGate.run(() async {
    final ids = (store.data['completedCacheRemovals'] as List? ?? [])
        .map((value) => '$value')
        .toList();
    for (final id in ids) {
      if (_closing) return;
      if (_playbackHolds.containsKey(id) ||
          _running.containsKey(id) ||
          (_tasks[id] != null &&
              _tasks[id]!.status != DownloadStatus.completed)) {
        continue;
      }
      try {
        await engine.remove(id);
        await _deleteCache(id);
        await store.change((draft) {
          draft['completedCacheRemovals'] =
              (draft['completedCacheRemovals'] as List? ?? [])
                  .where((value) => value != id)
                  .toList();
        });
      } catch (error, stack) {
        DiagnosticLog.error('download.playback_cache_cleanup', error, stack);
      }
    }
  });

  Future<void> _deleteCache(String id) =>
      (_cacheAccess[id] ??= AsyncGate()).run(() async {
        _readable.remove(id);
        final directory = engine.taskDirectory(id);
        if (!await directory.exists()) return;
        final root = await engine.cache.resolveSymbolicLinks(),
            actual = await directory.resolveSymbolicLinks();
        require(p.equals(p.dirname(actual), root), '缓存路径发生变化，已停止删除');
        await directory.delete(recursive: true);
      });

  Future<void> _run(String id, _Run run) async {
    String? newSaved;
    var committed = false;
    try {
      run.check();
      await _update(id, {'status': 'running', 'error': '', 'phase': '连接中'});
      await _syncForeground();
      run.check();
      run.storage = await files.storagePlan(
        engine.cache.path,
        _tasks[id]!.destination,
      );
      _volumePaths[run.storage.cache.id] = run.storage.cache.path;
      _volumePaths.putIfAbsent(
        run.storage.target.id,
        () => run.storage.target.path,
      );
      if (_tasks[id]!.spec.needsPreparation) {
        await _prepareSource(id, run);
      }
      File? output;
      final old = _tasks[id]!;
      if (old.payloadReady) {
        final cached = File(
          p.join(
            engine.taskDirectory(id).path,
            old.hls.isEmpty ? 'payload.gopeed' : 'payload.hls',
          ),
        );
        if (await cached.exists() && await cached.length() == old.total) {
          output = cached;
        }
      }
      if (output == null) {
        for (var refresh = 0; ; refresh++) {
          run.check();
          try {
            output = await _networkRetry<File>(
              id,
              run,
              () => _transfer(id, run),
            );
            break;
          } on DownloadHttpException catch (e) {
            if (!e.mayRefresh ||
                refresh >= 2 ||
                _tasks[id]!.spec.source == null) {
              rethrow;
            }
            await engine.pause(id);
            await _prepareSource(id, run);
          }
        }
      }
      run.check();
      final readyLength = await output.length();
      await _reserve(id, run, readyLength, readyLength, waitForExport: true);
      run.networkActive = false;
      await _update(id, {'phase': '等待校验 / 保存', 'speed': 0});
      _schedule();
      await _acquirePost(run);
      try {
        run.check();
        await _update(id, {'phase': '校验文件', 'speed': 0});
        final task = _tasks[id]!;
        if (task.hls.isEmpty) await _verify(output, task.spec, run);
        run.check();
        final length = await output.length();
        await _update(id, {
          'payloadReady': true,
          'total': length,
          'downloaded': length,
          'phase': '保存文件',
        });
        await _reserve(id, run, length, length);
        var copied = 0, lastUi = 0;
        final saveClock = Stopwatch()..start();
        _exportProgress[id] = 0;
        newSaved = await files.save(
          id: id,
          source: output,
          name: task.spec.fileName,
          relativePath: task.spec.relativePath,
          destination: task.destination,
          checkpoint: run.check,
          onProgress: (written, total) {
            if (run.stopped) return;
            final current = written.clamp(copied, length);
            space.consume(id, run.storage.target.id, current - copied);
            copied = current;
            _exportProgress[id] = length == 0 ? 1 : copied / length;
            if (saveClock.elapsedMilliseconds - lastUi >= 250 ||
                copied == length) {
              lastUi = saveClock.elapsedMilliseconds;
              final task = _tasks[id];
              if (task != null) {
                _tasks[id] = task.update({
                  'phase': '保存文件 ${(_exportProgress[id]! * 100).round()}%',
                });
                notifyListeners();
              }
            }
          },
        );
        DiagnosticLog.event(
          'download.saved',
          fields: {
            'ref': DiagnosticLog.reference(id),
            'bytes': length,
            'saveMs': saveClock.elapsedMilliseconds,
            'retries': run.networkRetries,
            'sameVolume': run.storage.cache.id == run.storage.target.id,
          },
        );
        run.check();
        await _update(id, {
          'status': 'completed',
          'savedPath': newSaved,
          'error': '',
          'phase': '',
          'speed': 0,
        });
        committed = true;
        // Export is already durable. Cache/remote cleanup failures do not undo it.
        try {
          if (_playbackHolds.containsKey(id)) {
            await store.change((draft) {
              draft['completedCacheRemovals'] = <String>{
                ...(draft['completedCacheRemovals'] as List? ?? []).map(
                  (value) => '$value',
                ),
                id,
              }.toList();
            });
          } else {
            await engine.remove(id);
            await _deleteCache(id);
          }
        } catch (_) {
          await _update(id, {'phase': '已保存，缓存稍后清理'});
        }
        // History can be removed while post-export cleanup is still pending.
        await cleanups.ready(task.spec.cleanup);
        _background(cleanups.drain());
      } finally {
        _releasePost();
      }
    } catch (e, stack) {
      if (!run.stopped && e is! _Stopped) {
        DiagnosticLog.error(
          'download.transfer_failed',
          e,
          stack,
          fields: {
            'ref': DiagnosticLog.reference(id),
            'phase': _tasks[id]?.phase,
            if (e is HttpRequestFailure) 'kind': e.kind,
            if (e is HttpRequestFailure) 'status': e.status ?? 0,
          },
        );
      }
      if (!committed) {
        if (newSaved != null) {
          try {
            await files.delete(newSaved);
          } catch (_) {
            await _update(id, {
              'savedPath': newSaved,
              'error': '保存被中断且文件清理失败，请在任务详情中删除',
            });
          }
        }
        final message = run.stopped || e is _Stopped
            ? ''
            : e is AppException
            ? e.message
            : e is FileSystemException
            ? '读写文件失败，请检查存储空间和目录权限'
            : '下载失败，请检查网络后重试';
        await _update(id, {
          'status': run.stopped || e is _Stopped ? 'paused' : 'failed',
          'error': message,
          'recoveryAction': !run.stopped && e is UcTvAuthorizationRequired
              ? DownloadRecoveryAction.ucAuthorization.name
              : DownloadRecoveryAction.none.name,
          'speed': 0,
          'phase': '',
        });
      }
    } finally {
      try {
        await engine.pause(id);
      } catch (_) {
        if (!committed) lastError = '暂停下载组件失败，重试前请重新打开应用';
      }
    }
  }

  Future<void> _acquirePost(_Run run) async {
    run.check();
    if (!_postBusy) {
      _postBusy = true;
      return;
    }
    final turn = Completer<void>();
    _postWaiters.add(turn);
    await Future.any([turn.future, run.wake.future]);
    if (run.stopped) {
      if (!_postWaiters.remove(turn)) _releasePost();
      run.check();
    }
  }

  void _releasePost() {
    if (_postWaiters.isEmpty) {
      _postBusy = false;
    } else {
      _postWaiters.removeAt(0).complete();
    }
  }

  Future<void> _reserve(
    String id,
    _Run run,
    int total,
    int downloaded, {
    int overhead = 0,
    bool waitForExport = false,
  }) async {
    final phase = _tasks[id]!.phase;
    var waiting = false;
    while (true) {
      run.check();
      try {
        await space.reserveVolumes(
          id,
          run.storage.requirements(total, downloaded, overhead: overhead),
        );
        if (waiting) await _update(id, {'phase': phase}, persist: false);
        return;
      } on DownloadSpaceException {
        if (!waitForExport ||
            !_running.entries.any(
              (entry) => entry.key != id && !entry.value.networkActive,
            )) {
          rethrow;
        }
        if (!waiting) {
          waiting = true;
          await _update(id, {'phase': '等待保存释放空间', 'speed': 0}, persist: false);
        }
        await run.delay(const Duration(milliseconds: 250));
      }
    }
  }

  Future<void> _prepareSource(String id, _Run run) async {
    run.check();
    final previous = _tasks[id]!;
    await _update(id, {
      'phase': previous.spec.needsPreparation ? '获取下载链接' : '刷新下载地址',
      'speed': 0,
    });
    final fresh = await refreshSource(previous.spec);
    var committed = false;
    try {
      run.check();
      _validateDownloadUrl(fresh);
      require(fresh.platform == previous.spec.platform, '下载来源发生变化，请重新添加任务');
      final profile = settings.connectionProfileFor(
        fresh.platform,
        fresh.profile,
      );
      final spec = fresh
          .copyWith(
            fileName: previous.spec.fileName,
            relativePath: previous.spec.relativePath,
          )
          .toJson();
      if (fresh.expectedSize <= 0 && previous.spec.expectedSize > 0) {
        spec['expectedSize'] = previous.spec.expectedSize;
      }
      if (fresh.checksumType?.isNotEmpty != true ||
          fresh.checksumValue?.isNotEmpty != true) {
        spec['checksumType'] = previous.spec.checksumType;
        spec['checksumValue'] = previous.spec.checksumValue;
      }
      try {
        await _update(id, {
          'spec': spec,
          'connections': previous.spec.needsPreparation
              ? previous.connectionOptions[profile ?? 'default'] ??
                    previous.connections
              : previous.connections,
          'connectionOptions': <String, int>{},
          'phase': '连接中',
        });
      } catch (_) {
        final current = _tasks[id];
        if (current != null) {
          _tasks[id] = current.update({
            'spec': previous.spec.toJson(),
            'connections': previous.connections,
            'connectionOptions': previous.connectionOptions,
          });
          notifyListeners();
        }
        rethrow;
      }
      committed = true;
    } finally {
      await cleanups.release(fresh.cleanup);
      if (!committed) await cleanups.ready(fresh.cleanup);
    }
    await cleanups.ready(previous.spec.cleanup);
  }

  Future<void> _retryWait(
    String id,
    _Run run,
    int attempt,
    Object error,
  ) async {
    run.check();
    final delay = downloadRetryDelay(attempt, error);
    final phase = _tasks[id]!.phase;
    run.networkRetries++;
    DiagnosticLog.event(
      'download.retry',
      fields: {
        'ref': DiagnosticLog.reference(id),
        'attempt': run.networkRetries,
        'status': error is DownloadHttpException ? error.status : 0,
        'kind': error is DownloadNetworkException ? error.kind : 'network',
        'waitMs': delay.inMilliseconds,
      },
    );
    await _update(id, {'phase': '${delay.inSeconds} 秒后重试', 'speed': 0});
    await run.delay(delay);
    run.check();
    await _update(id, {'phase': phase}, persist: false);
  }

  Future<T> _networkRetry<T>(
    String id,
    _Run run,
    Future<T> Function() operation,
  ) async {
    for (var attempt = 0; ; attempt++) {
      run.check();
      try {
        return await operation();
      } catch (error) {
        run.check();
        if (!retryableDownloadError(error)) rethrow;
        if (attempt >= _tasks[id]!.retries) throw DownloadRetryExhausted(error);
        await engine.pause(id);
        await _retryWait(id, run, attempt, error);
      }
    }
  }

  Future<Probe> _probe(String id, _Run run) async {
    final spec = _tasks[id]!.spec;
    if (spec.profile != 'wopan') return http.probe(spec.url, spec.headers);
    // Use the same TLS implementation as the actual Wopan file transfer.
    // Each native call returns promptly so pause/delete can cancel the probe.
    try {
      await engine.httpProbeCall('httpProbeStart', {
        'id': id,
        'url': spec.url,
        'headers': http.headers(spec.headers),
      });
      while (true) {
        run.check();
        final state = await engine.httpProbeCall('httpProbeStatus', {'id': id});
        run.check();
        final status = state.str('status');
        if (status == 'done') {
          return Probe.response(state.integer('code'), {
            for (final entry in state.obj('headers').entries)
              if (entry.value is String) entry.key: entry.value as String,
          }, hlsPath: state.boolean('hlsPath'));
        }
        if (status == 'error') {
          if (state.str('errorKind') == 'certificate') {
            throw const AppException('服务器证书校验失败');
          }
          throw DownloadNetworkException(
            'nativeProbe',
            retryable: state.boolean('retryable'),
          );
        }
        require(status == 'running', '下载连接检查已取消或响应无效');
        await run.delay(const Duration(milliseconds: 100));
      }
    } finally {
      await engine.httpProbeCall('httpProbeStop', {'id': id});
    }
  }

  Future<File> _transfer(String id, _Run run) async {
    run.httpConnections = null;
    var task = _tasks[id]!;
    if (task.spec.isTorrent) return _torrent(id, run);
    final probe = await _probe(id, run);
    run.check();
    if (probe.hls) return _hls(id, run);
    require(
      !(task.spec.expectedSize > 0 &&
          probe.identity.total > 0 &&
          task.spec.expectedSize != probe.identity.total),
      '远端文件长度已变化，请重新添加下载',
    );
    if (!task.identity.canResume(probe.identity)) {
      await engine.remove(id);
      await _deleteCache(id);
      await _update(id, {'downloaded': 0, 'hls': {}});
    }
    final total = probe.identity.total > 0
        ? probe.identity.total
        : task.spec.expectedSize;
    await _update(id, {
      'identity': probe.identity.toJson(),
      'total': total,
      'payloadReady': false,
      'phase': '',
    });
    task = _tasks[id]!;
    await _reserve(id, run, total, task.downloaded, waitForExport: true);
    final headers = {
      ...http.headers(task.spec.headers),
      if (probe.identity.ifRange != null) 'If-Range': probe.identity.ifRange!,
    };
    run.check();
    // The native resume can discard an evicted or truncated payload. Do not
    // reuse the previous run's intervals until its new snapshot arrives.
    await (_cacheAccess[id] ??= AsyncGate()).run(() async {
      _readable.remove(id);
      await engine.begin({
        'id': id,
        'url': task.spec.url,
        'headers': headers,
        'connections': task.connections,
        'connectionProfile': settings.connectionProfileFor(
          task.spec.platform,
          task.spec.profile,
        ),
        'retries': task.retries,
        'speedLimit': task.speedLimit,
      });
    });
    var persisted = 0;
    while (true) {
      run.check();
      final state = await engine.snapshot(id),
          now = DateTime.now().millisecondsSinceEpoch;
      final nativeTotal = state.integer('total'),
          downloaded = state.integer('downloaded');
      final connections = state.integer('totalConnections');
      run.httpConnections = connections > 0
          ? (
              active: state.str('status') == 'running'
                  ? state.integer('activeConnections').clamp(0, connections)
                  : 0,
              total: connections,
            )
          : null;
      require(
        !(total > 0 && nativeTotal > 0 && total != nativeTotal),
        '远端文件内容已变化，请重新添加下载',
      );
      final currentTotal = nativeTotal > 0 ? nativeTotal : total;
      final ranges = <(int, int)>[];
      for (final value in state['readableRanges'] as List? ?? const []) {
        if (value is List &&
            value.length == 2 &&
            value[0] is int &&
            value[1] is int &&
            value[0] >= 0 &&
            value[1] > value[0] &&
            value[1] <= currentTotal) {
          ranges.add((value[0] as int, value[1] as int));
        }
      }
      if (state.str('status') == 'done' && currentTotal > 0) {
        ranges.add((0, currentTotal));
      }
      _readable[id] = DownloadReadableState(probe.identity, ranges);
      if (now - persisted >= 1500) {
        await _reserve(id, run, currentTotal, downloaded);
        persisted = now;
        await _update(id, {
          'total': currentTotal,
          'downloaded': downloaded,
          'speed': state.integer('speed'),
        }, progress: true);
      } else {
        await _update(id, {
          'total': currentTotal,
          'downloaded': downloaded,
          'speed': state.integer('speed'),
        }, persist: false);
      }
      if (state.str('status') == 'done') {
        final file = File(state.str('path')),
            parent = await engine.taskDirectory(id).resolveSymbolicLinks();
        require(
          await file.exists() &&
              p.equals(p.dirname(await file.resolveSymbolicLinks()), parent),
          '下载结果路径无效',
        );
        require(
          currentTotal <= 0 || await file.length() == currentTotal,
          '下载文件长度不完整',
        );
        return file;
      }
      if (state.str('status') == 'error') {
        if (state.integer('httpCode') == 412) {
          throw const AppException('远端文件内容已变化，请重新添加下载');
        }
        if (state.integer('httpCode') != 0) {
          throw DownloadHttpException(
            state.integer('httpCode'),
            retryAfter: Duration(milliseconds: state.integer('retryAfterMs')),
            exhausted: state.boolean('retryExhausted', true),
          );
        }
        if (state.str('errorKind') == 'network') {
          throw DownloadNetworkException(
            'native',
            retryable: !state.boolean('retryExhausted', true),
          );
        }
        throw AppException(state.str('error').ifEmpty('Gopeed 下载失败，请重试'));
      }
      if (state.str('status') == 'pause') {
        run.check();
        throw const AppException('下载组件已暂停，请继续任务');
      }
      await run.delay(const Duration(milliseconds: 350));
    }
  }

  Future<File> _torrent(String id, _Run run) async {
    final task = _tasks[id]!, selection = _tasks[id]!.spec.torrent!;
    final metadata = store.data.obj('torrents').obj(selection.str('hash'));
    final data = metadata.str('data');
    final boundaryBytes = metadata.integer('pieceLength', 4 * 1024 * 1024) * 2;
    require(data.startsWith(torrentDataPrefix), '种子信息已丢失，请重新添加种子');
    await _reserve(
      id,
      run,
      task.total,
      task.downloaded,
      overhead: boundaryBytes,
    );
    run.check();
    await engine.begin({
      'id': id,
      'url': task.spec.url,
      'torrentData': data,
      'torrentIndex': selection.integer('index'),
      'connections': task.connections,
      'retries': task.retries,
      'speedLimit': task.speedLimit,
    });
    var persisted = 0;
    while (true) {
      run.check();
      final state = await engine.snapshot(id),
          now = DateTime.now().millisecondsSinceEpoch;
      require(
        state.integer('total') == task.total || state.integer('total') == 0,
        'BT 文件长度与种子不一致',
      );
      final downloaded = state.integer('downloaded');
      final persist = now - persisted >= 1500;
      if (persist) {
        persisted = now;
        await _reserve(
          id,
          run,
          task.total,
          downloaded,
          overhead: boundaryBytes,
        );
      }
      await _update(
        id,
        {
          'downloaded': downloaded.clamp(0, task.total),
          'speed': state.integer('speed'),
          'phase': downloaded == 0 ? '连接做种者 / 校验分片' : 'BT 分片下载',
        },
        persist: persist,
        progress: true,
      );
      if (state.str('status') == 'done') {
        final file = File(state.str('path')),
            directory = engine.taskDirectory(id);
        final root = await directory.resolveSymbolicLinks();
        require(
          await file.exists() &&
              p.isWithin(root, await file.resolveSymbolicLinks()) &&
              await file.length() == task.total,
          'BT 下载结果不完整或路径无效',
        );
        // Close the torrent and its seeding handles before moving/exporting.
        await engine.remove(id);
        run.check();
        final output = File(p.join(directory.path, 'payload.gopeed'));
        if (p.equals(file.path, output.path)) return file;
        if (await output.exists()) await output.delete();
        return file.rename(output.path);
      }
      if (state.str('status') == 'error') {
        throw AppException(state.str('error').ifEmpty('BT 下载失败，请检查做种人数后重试'));
      }
      if (state.str('status') == 'pause') {
        run.check();
        throw const AppException('BT 下载已暂停，请继续任务');
      }
      await run.delay(const Duration(milliseconds: 350));
    }
  }

  Future<void> _verify(File file, DownloadSpec spec, _Run run) async {
    if (spec.checksumValue?.isNotEmpty != true) return;
    final algorithm = spec.checksumType?.toLowerCase().replaceAll('-', '');
    final hash = switch (algorithm) {
      'md5' => md5,
      'sha1' => sha1,
      'sha256' => sha256,
      _ => null,
    };
    if (hash == null) return;
    final digest = await file
        .openRead()
        .map((chunk) {
          run.check();
          return chunk;
        })
        .transform(hash)
        .first;
    require(
      digest.toString().toLowerCase() == spec.checksumValue!.toLowerCase(),
      '文件校验失败，请删除此任务后重新下载',
    );
  }

  Future<File> _hls(String id, _Run run) async {
    final task = _tasks[id]!;
    var playlist = await http.textResponse(task.spec.url, task.spec.headers);
    for (var depth = 0; depth < 4; depth++) {
      final selected = HlsPlaylist.choose(playlist.url, playlist.text);
      if (selected == playlist.url) break;
      playlist = await http.textResponse(selected, task.spec.headers);
    }
    require(!playlist.text.contains('#EXT-X-STREAM-INF'), '视频播放列表嵌套过多');
    final media = HlsPlaylist.media(playlist.url, playlist.text);
    final fingerprint = sha256
        .convert(utf8.encode(jsonEncode(media.urls)))
        .toString();
    final directory = engine.taskDirectory(id);
    final output = File(p.join(directory.path, 'payload.hls'));
    var index = task.hls.integer('index'), retained = task.hls.integer('bytes');
    if (task.hls.str('fingerprint') != fingerprint ||
        !await output.exists() ||
        await output.length() < retained ||
        index > media.urls.length) {
      await engine.remove(id);
      await _deleteCache(id);
      index = 0;
      retained = 0;
    }
    await directory.create(recursive: true);
    final handle = await output.open(mode: FileMode.append);
    await handle.truncate(retained);
    await handle.setPosition(retained);
    final extension = media.fragmentedMp4 ? '.mp4' : '.ts';
    final spec = task.spec.copyWith(
      fileName: '${p.basenameWithoutExtension(task.spec.fileName)}$extension',
    );
    await _update(id, {
      'spec': spec.toJson(),
      'total': 0,
      'downloaded': retained,
      'phase': '下载视频分片',
      'payloadReady': false,
      'hls': {'fingerprint': fingerprint, 'index': index, 'bytes': retained},
    });
    final speedClock = Stopwatch()..start();
    var received = 0;
    try {
      for (; index < media.urls.length; index++) {
        var success = false;
        for (var attempt = 0; attempt <= task.retries; attempt++) {
          run.check();
          await handle.truncate(retained);
          await handle.setPosition(retained);
          var segmentBytes = 0;
          try {
            final response = await http.stream(
              media.urls[index],
              http.headers(task.spec.headers),
            );
            final code = response.statusCode ?? 0;
            if (code < 200 || code >= 300) {
              await response.data!.stream.listen((_) {}).cancel();
              throw DownloadHttpException.response(response);
            }
            await for (final chunk in response.data!.stream) {
              run.check();
              await _reserve(
                id,
                run,
                retained + segmentBytes + chunk.length,
                retained + segmentBytes,
              );
              await handle.writeFrom(chunk);
              segmentBytes += chunk.length;
              received += chunk.length;
              if (task.speedLimit > 0) {
                final target = received * 1000 ~/ task.speedLimit,
                    delay = target - speedClock.elapsedMilliseconds;
                if (delay > 0) await run.delay(Duration(milliseconds: delay));
              }
            }
            require(segmentBytes > 0, '视频分片为空');
            await handle.flush();
            retained += segmentBytes;
            await _update(id, {
              'downloaded': retained,
              'speed': received * 1000 ~/ (speedClock.elapsedMilliseconds + 1),
              'phase': '视频分片 ${index + 1}/${media.urls.length}',
              'hls': {
                'fingerprint': fingerprint,
                'index': index + 1,
                'bytes': retained,
              },
            });
            success = true;
            break;
          } catch (e) {
            run.check();
            if (!retryableDownloadError(e)) rethrow;
            if (attempt == task.retries) throw DownloadRetryExhausted(e);
            await _retryWait(id, run, attempt, e);
          }
        }
        require(success, '视频分片下载失败');
      }
    } finally {
      await handle.close();
    }
    return output;
  }

  Future<void> close() async {
    _closing = true;
    _foregroundTimer?.cancel();
    _foregroundTimer = null;
    await pauseAll();
    // Completed tasks can still be cleaning files or publishing their last
    // notification, after they no longer count as active downloads.
    await Future.wait(_unsettledRuns.map((run) => run.done).toList());
    await _removalGate.run(() async {});
    await engine.close();
    await store.flush();
  }

  @override
  void dispose() {
    _progressFlush?.cancel();
    _foregroundTimer?.cancel();
    super.dispose();
  }
}
