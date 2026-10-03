import 'package:path/path.dart' as p;

class PlaybackSubtitle {
  const PlaybackSubtitle(this.id, this.name);
  final String id, name;
}

String _stem(String name) {
  var value = p.basenameWithoutExtension(name).toLowerCase();
  value = value.replaceAll(
    RegExp(r'(?<!\d)(?:2160|1080|720|480)[pi](?!\d)'),
    ' ',
  );
  value = value.replaceAll(RegExp(r'[\s._\-\[\]()（）【】]+'), ' ').trim();
  const decorations = {
    'chs',
    'cht',
    'zh',
    'cn',
    'tw',
    'hans',
    'hant',
    'zhcn',
    'zhtw',
    'zh-cn',
    'zh-tw',
    'chi',
    'zho',
    'sc',
    'tc',
    'en',
    'eng',
    'english',
    'ja',
    'jpn',
    'jp',
    '简体',
    '简体中文',
    '繁體中文',
    '繁体中文',
    '繁体',
    '简中',
    '繁中',
    '中文',
    '中英',
    '双语',
    '中字',
    '简繁',
    '简英',
    '繁英',
    'h264',
    'h265',
    'x264',
    'x265',
    'hevc',
    'avc',
    'av1',
    'aac',
    'dts',
    'bluray',
    'bdrip',
    'webrip',
    'webdl',
    'web',
    'dl',
    'hdr',
    '10bit',
  };
  return value
      .split(' ')
      .where((word) => !decorations.contains(word))
      .join(' ');
}

String? _episode(String value) {
  final series = RegExp(r'\bs(\d{1,2})\s*e(\d{1,3})\b').firstMatch(value);
  if (series != null) {
    return 's${int.parse(series[1]!)}e${int.parse(series[2]!)}';
  }
  final episode =
      RegExp(r'(?:\bep?\s*|第\s*)(\d{1,3})(?:\b|\s*[集话話])').firstMatch(value) ??
      RegExp(r'(?:^|\s)(\d{1,3})$').firstMatch(value);
  return episode == null ? null : 'e${int.parse(episode[1]!)}';
}

int subtitleMatchScore(String video, String subtitle) {
  final a = _stem(video), b = _stem(subtitle);
  final episodeA = _episode(a), episodeB = _episode(b);
  if (episodeA != episodeB && (episodeA != null || episodeB != null)) return 0;
  if (a.isEmpty || a != b) return 0;
  // An explicit Chinese language tag is a useful default for this Chinese UI.
  final chinese = RegExp(
    r'(?:\b(?:chs|zh|zhcn|chi|zho|sc)\b|简|中)',
    caseSensitive: false,
  ).hasMatch(subtitle);
  return chinese ? 110 : 100;
}

List<PlaybackSubtitle> sortSubtitles(
  String video,
  Iterable<PlaybackSubtitle> candidates,
) {
  final result = candidates.toList();
  result.sort((a, b) {
    final score = subtitleMatchScore(
      video,
      b.name,
    ).compareTo(subtitleMatchScore(video, a.name));
    return score != 0 ? score : a.name.compareTo(b.name);
  });
  return result;
}

PlaybackSubtitle? matchingSubtitle(
  String video,
  List<PlaybackSubtitle> candidates,
) {
  final sorted = sortSubtitles(video, candidates);
  if (sorted.isEmpty) return null;
  final score = subtitleMatchScore(video, sorted.first.name);
  if (score == 0 ||
      sorted.length > 1 && subtitleMatchScore(video, sorted[1].name) == score) {
    return null;
  }
  return sorted.first;
}
