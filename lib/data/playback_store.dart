import '../core/json.dart';
import '../domain/playback.dart';
import '../domain/playback_source.dart';
import 'state_store.dart';

class PlaybackStore {
  PlaybackStore(this.store);
  final StateStore store;
  static const historyLimit = 200;
  static const torrentCacheBytes = 16 * 1024 * 1024;
  List<PlaybackRecord> get recent => [
    for (final entry in store.data.obj('playbackHistory').entries)
      if (entry.value is Map)
        PlaybackRecord(
          entry.key,
          PlaybackBookmark.fromJson(asJson(entry.value)),
        ),
  ]..sort((a, b) => b.bookmark.updatedAt.compareTo(a.bookmark.updatedAt));
  PlaybackPreferences get preferences =>
      PlaybackPreferences.fromJson(store.data.obj('playbackPreferences'));
  PlaybackBookmark? bookmark(String key) {
    final value = store.data.obj('playbackHistory')[key];
    return value is Map ? PlaybackBookmark.fromJson(asJson(value)) : null;
  }

  Future<void> savePreferences(PlaybackPreferences value) =>
      store.put('playbackPreferences', value.toJson());
  VideoGeometry? videoGeometry(String key) {
    final value = store.data.obj('playbackVideoInfo')[key];
    return value is Map ? VideoGeometry.fromJson(asJson(value)) : null;
  }

  Future<void> saveVideoGeometry(String key, VideoGeometry geometry) =>
      store.change((draft) {
        final entries = draft.obj('playbackVideoInfo')..remove(key);
        entries[key] = geometry.toJson();
        draft['playbackVideoInfo'] = Map.fromEntries(
          entries.entries.skip(
            (entries.length - historyLimit).clamp(0, entries.length),
          ),
        );
      });
  Future<void> save(String key, PlaybackBookmark bookmark) => store.change((
    draft,
  ) {
    final history = draft.obj('playbackHistory');
    final previous = asJson(history[key]);
    history[key] = {
      ...bookmark.toJson(),
      if (bookmark.source == null && previous['source'] is Map)
        'source': previous['source'],
    };
    final entries = history.entries.toList()
      ..sort(
        (a, b) => asJson(
          b.value,
        ).integer('updatedAt').compareTo(asJson(a.value).integer('updatedAt')),
      );
    draft['playbackHistory'] = Map.fromEntries(entries.take(historyLimit));
    final source = bookmark.source;
    if (source?.kind == PlaybackSourceKind.torrent &&
        source!.torrentData.isNotEmpty) {
      final cache = draft.obj('playbackTorrents');
      final previous = asJson(cache.remove(source.torrentHash));
      final files = <int, Json>{
        for (final file in previous.list('files')) file.integer('index'): file,
        for (final file in source.torrentFiles)
          file.index: {
            'index': file.index,
            'path': file.path,
            'size': file.size,
          },
      };
      cache[source.torrentHash] = {
        'hash': source.torrentHash,
        'data': source.torrentData,
        'files': files.values.toList(),
      };
      draft['playbackTorrents'] = cache;
    }
    _pruneTorrents(draft);
  });
  static void _pruneTorrents(Json draft) {
    final used = draft
        .obj('playbackHistory')
        .values
        .map((value) => asJson(value).obj('source'))
        .where((value) => value.str('kind') == 'torrent')
        .map((value) => value.str('hash'))
        .toSet();
    final cache = draft.obj('playbackTorrents')
      ..removeWhere((key, _) => !used.contains(key));
    var bytes = 0;
    final keep = <String>{};
    for (final entry in cache.entries.toList().reversed) {
      final length = asJson(entry.value).str('data').length;
      if (bytes + length > torrentCacheBytes) continue;
      bytes += length;
      keep.add(entry.key);
    }
    cache.removeWhere((key, _) => !keep.contains(key));
    if (cache.isEmpty) {
      draft.remove('playbackTorrents');
    } else {
      draft['playbackTorrents'] = cache;
    }
  }

  Future<void> opened(String key, String name, PlaybackSource? source) async {
    // Legacy callers without a restorable origin keep their existing progress
    // behavior. A newly opened media with an origin is visible immediately.
    if (source == null) return;
    final previous = bookmark(key);
    await save(
      key,
      PlaybackBookmark(
        name: name,
        source: source,
        position: previous?.position ?? Duration.zero,
        duration: previous?.duration ?? Duration.zero,
        completed: previous?.completed ?? false,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> remove(String key) => store.change((draft) {
    draft['playbackHistory'] = draft.obj('playbackHistory')..remove(key);
    draft['playbackVideoInfo'] = draft.obj('playbackVideoInfo')..remove(key);
    _pruneTorrents(draft);
  });
  Future<void> clearHistory() => store.change((draft) {
    draft['playbackHistory'] = <String, dynamic>{};
    draft.remove('playbackVideoInfo');
    draft.remove('playbackTorrents');
  });
}
