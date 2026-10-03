import '../core/json.dart';
import 'downloads.dart';
import 'models.dart';
import 'torrent.dart';

enum PlaybackSourceKind { cloud, local, torrent, download }

/// Durable media identity. Short-lived playback URLs, cookies and cleanup
/// leases belong to the active session, never to a history entry.
class PlaybackSource {
  const PlaybackSource.cloud(DownloadOrigin origin)
    : kind = PlaybackSourceKind.cloud,
      cloud = origin,
      path = '',
      downloadId = '',
      size = 0,
      torrentHash = '',
      torrentIndex = -1,
      torrentData = '',
      torrentFiles = const [];

  const PlaybackSource.local({
    required this.path,
    this.downloadId = '',
    this.size = 0,
  }) : kind = PlaybackSourceKind.local,
       cloud = null,
       torrentHash = '',
       torrentIndex = -1,
       torrentData = '',
       torrentFiles = const [];

  const PlaybackSource.download(this.downloadId, {this.size = 0})
    : kind = PlaybackSourceKind.download,
      cloud = null,
      path = '',
      torrentHash = '',
      torrentIndex = -1,
      torrentData = '',
      torrentFiles = const [];

  PlaybackSource.torrent(
    String hash,
    TorrentFile file, {
    this.torrentData = '',
    this.torrentFiles = const [],
  }) : kind = PlaybackSourceKind.torrent,
       cloud = null,
       path = file.path,
       downloadId = '',
       size = file.size,
       torrentHash = hash,
       torrentIndex = file.index;

  final PlaybackSourceKind kind;
  final DownloadOrigin? cloud;
  final String path, downloadId, torrentHash;
  final int size, torrentIndex;
  // In-memory context, persisted once per info hash by PlaybackStore.
  final String torrentData;
  final List<TorrentFile> torrentFiles;

  String get label => switch (kind) {
    PlaybackSourceKind.cloud =>
      cloud!.session.isFamily
          ? '${cloud!.session.platform.shortName}家庭云'
          : cloud!.session.platform.label,
    PlaybackSourceKind.local => '本地文件',
    PlaybackSourceKind.torrent => 'BT 在线播放',
    PlaybackSourceKind.download => '边下边播',
  };

  Json toJson() => {
    'version': 1,
    'kind': kind.name,
    if (cloud != null)
      'origin': {
        ...cloud!.toJson(),
        'session': {
          ...cloud!.session.toJson(),
          'metadata': cloud!.session.spaceMetadata,
        },
        'file': {...cloud!.file.toJson(), 'token': ''},
      },
    if (kind != PlaybackSourceKind.cloud) ...{'path': path, 'size': size},
    if (kind == PlaybackSourceKind.local || kind == PlaybackSourceKind.download)
      'downloadId': downloadId,
    if (kind == PlaybackSourceKind.torrent) ...{
      'hash': torrentHash,
      'index': torrentIndex,
    },
  };

  static PlaybackSource? tryFromJson(Object? value) {
    if (value is! Map) return null;
    try {
      final json = asJson(value);
      require(json.integer('version') == 1, '播放来源版本无效');
      switch (json.str('kind')) {
        case 'download':
          require(
            RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(json.str('downloadId')),
            '下载任务编号无效',
          );
          return PlaybackSource.download(
            json.str('downloadId'),
            size: json.integer('size'),
          );
        case 'cloud':
          final origin = DownloadOrigin.fromJson(json.obj('origin'));
          require(
            origin.file.id.isNotEmpty &&
                !origin.file.isDirectory &&
                (origin.session.mode == BrowseMode.personal ||
                    origin.session.sourceLink?.kind == LinkKind.cloudShare &&
                        origin.session.sourceLink?.platform ==
                            origin.session.platform),
            '播放来源不完整',
          );
          return PlaybackSource.cloud(origin);
        case 'local':
          require(json.str('path').isNotEmpty, '本地文件位置缺失');
          return PlaybackSource.local(
            path: json.str('path'),
            downloadId: json.str('downloadId'),
            size: json.integer('size'),
          );
        case 'torrent':
          require(
            RegExp(r'^[0-9a-f]{40}$').hasMatch(json.str('hash')) &&
                json.integer('index', -1) >= 0 &&
                json.str('path').isNotEmpty &&
                json.integer('size') > 0,
            '种子来源不完整',
          );
          return PlaybackSource.torrent(
            json.str('hash'),
            TorrentFile(
              json.integer('index'),
              json.str('path'),
              json.integer('size'),
            ),
          );
      }
    } on Object {
      // A damaged or older source must not hide the remaining history.
    }
    return null;
  }
}
