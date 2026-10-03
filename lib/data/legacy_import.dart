import '../core/json.dart';
import '../domain/downloads.dart';
import '../domain/models.dart';
import 'cleanup_outbox.dart';
import 'state_store.dart';

class LegacyImporter {
  LegacyImporter(this.store);
  final StateStore store;
  Future<int> import(Json legacy) async {
    if (store.data.boolean('legacyImported')) return 0;
    final tasks = <Json>[];
    final cleanupByTask = <String, DownloadCleanup>{};
    final cleanups = <String, dynamic>{};
    for (final item in legacy.list('cleanups')) {
      final cleanup = DownloadCleanup.fromJson(item.obj('payload'));
      cleanupByTask[item.str('taskId')] = cleanup;
      cleanups[cleanupKey(cleanup)] = {
        'payload': cleanup.toJson(),
        'ready': item.boolean('ready'),
        'attempts': item.integer('attempts'),
        'createdAt': item.integer('updatedAt'),
      };
    }
    for (final old in legacy.list('tasks')) {
      require(
        RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(old.str('id')),
        '旧版下载记录格式错误，原数据已保留',
      );
      final spec = DownloadSpec(
        url: old.str('url'),
        fileName: old.str('fileName'),
        relativePath: old.str('relativePath'),
        headers: strings(old['headers']),
        expectedSize: old.integer('totalBytes'),
        checksumType: old['checksumType'] as String?,
        checksumValue: old['checksumValue'] as String?,
        cleanup: cleanupByTask[old.str('id')],
        source: old['source'] == null
            ? null
            : DownloadOrigin.fromJson(old.obj('source')).toJson(),
      );
      tasks.add(
        DownloadTask(
          id: old.str('id'),
          spec: spec,
          createdAt: old.integer('createdAt'),
          status: old.str('status') == 'completed'
              ? DownloadStatus.completed
              : DownloadStatus.paused,
          total: old.integer('totalBytes'),
          downloaded: old.integer('downloadedBytes'),
          connections: old.integer('threadCount', 64).clamp(1, 512),
          retries: old.integer('retryLimit', 3).clamp(0, 3),
          speedLimit: old.integer('speedLimitBytes'),
          destination: old['destinationTreeUri'] as String?,
          savedPath: old['savedUri'] as String?,
          identity: RemoteIdentity(
            old.integer('totalBytes'),
            old['remoteEtag'] as String?,
            old['remoteLastModified'] as String?,
          ),
        ).toJson(),
      );
    }
    final credentials = <String, dynamic>{};
    for (final entry in legacy.obj('credentials').entries) {
      final platform = CloudPlatform.fromKey(entry.key);
      if (platform == null) continue;
      final c = Credential.fromJson(asJson(entry.value));
      require(c.fields.isNotEmpty && c.updatedAt > 0, '旧版账号信息格式错误');
      credentials[platform.key] = c.toJson();
    }
    await store.change((draft) {
      if (draft.boolean('legacyImported')) return;
      draft['credentials'] = {...credentials, ...draft.obj('credentials')};
      draft['secrets'] = {...legacy.obj('secrets'), ...draft.obj('secrets')};
      final existingIds = draft.list('tasks').map((t) => t.str('id')).toSet();
      draft['tasks'] = [
        ...draft.list('tasks'),
        ...tasks.where((t) => !existingIds.contains(t.str('id'))),
      ];
      draft['cleanups'] = {...cleanups, ...draft.obj('cleanups')};
      final history = {
        ...{for (final h in legacy.list('history')) h.str('normalizedUrl'): h},
        ...{for (final h in draft.list('history')) h.str('normalizedUrl'): h},
      };
      draft['history'] = history.values.toList();
      if (draft['settings'] == null && legacy['settings'] != null) {
        draft['settings'] = legacy['settings'];
      }
      draft['legacyImported'] = true;
      draft['legacyImportedAt'] = DateTime.now().millisecondsSinceEpoch;
    });
    return tasks.length;
  }
}
