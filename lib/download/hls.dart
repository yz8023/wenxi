import '../core/json.dart';

class HlsMedia {
  const HlsMedia(this.urls, this.fragmentedMp4);
  final List<String> urls;
  final bool fragmentedMp4;
}

class HlsPlaylist {
  static final _attributes = RegExp(r'(?:^|,)([A-Z0-9-]+)=("[^"]*"|[^,]*)');

  static String? _attribute(String tag, String name) {
    final value = tag.substring(tag.indexOf(':') + 1);
    for (final match in _attributes.allMatches(value)) {
      if (match.group(1) != name) continue;
      final attribute = match.group(2)!;
      return attribute.length >= 2 &&
              attribute.startsWith('"') &&
              attribute.endsWith('"')
          ? attribute.substring(1, attribute.length - 1)
          : attribute;
    }
    return null;
  }

  static void validateEncryption(String text) {
    require(
      !text
          .split('\n')
          .map((l) => l.trim())
          .any(
            (l) =>
                (l.startsWith('#EXT-X-KEY') ||
                    l.startsWith('#EXT-X-SESSION-KEY')) &&
                _attribute(l, 'METHOD') != 'NONE',
          ),
      '暂不支持下载加密 HLS 视频',
    );
  }

  static String resolve(String base, String ref) {
    final uri = Uri.parse(base).resolve(ref);
    require(
      {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty,
      '播放列表含无效分片地址',
    );
    return uri.toString();
  }

  static String choose(String base, String text) {
    validateEncryption(text);
    final lines = text.split('\n').map((l) => l.trim()).toList();
    var best = -1, result = base;
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF:')) continue;
      require(_attribute(lines[i], 'AUDIO') == null, '此视频使用独立音轨，请使用在线播放');
      final bandwidth =
          int.tryParse(_attribute(lines[i], 'BANDWIDTH') ?? '') ?? 0;
      final path = lines
          .skip(i + 1)
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .firstOrNull;
      if (path != null && bandwidth > best) {
        best = bandwidth;
        result = resolve(base, path);
      }
    }
    return result;
  }

  static HlsMedia media(String base, String text) {
    require(text.trimLeft().startsWith('#EXTM3U'), '播放列表格式错误');
    final lines = text.split('\n').map((l) => l.trim()).toList();
    validateEncryption(text);
    require(
      !text.contains('#EXT-X-BYTERANGE') && !text.contains('BYTERANGE='),
      '暂不支持此分片范围格式，请使用在线播放',
    );
    require(text.contains('#EXT-X-ENDLIST'), '直播流无法保存为完整文件，请使用在线播放');
    final maps = RegExp(
      r'#EXT-X-MAP:[^\n]*URI="([^"]+)"',
    ).allMatches(text).toList();
    require(maps.length <= 1, '此视频包含多个初始化分片，请使用在线播放');
    final urls = [
      if (maps.isNotEmpty) resolve(base, maps.first.group(1)!),
      ...lines
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .map((l) => resolve(base, l)),
    ];
    require(urls.isNotEmpty && urls.length <= 100000, '视频分片数量无效');
    return HlsMedia(urls, maps.isNotEmpty);
  }
}
