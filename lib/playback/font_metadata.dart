import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

class SubtitleFontFace {
  const SubtitleFontFace(this.path, this.family);
  final String path, family;
}

// Inspect the actual cmap, not Android Paint.hasGlyph: Paint may silently use
// another fallback font. Only table metadata is read, including TTC faces.
SubtitleFontFace? findChineseSubtitleFont(List<String> paths) {
  final candidates = paths.toSet().toList()
    ..sort((a, b) {
      final order = _priority(a).compareTo(_priority(b));
      return order == 0 ? a.compareTo(b) : order;
    });
  for (final path in candidates.take(512)) {
    final face = inspectSubtitleFont(path);
    if (face != null) return face;
  }
  return null;
}

int _priority(String path) {
  final name = p.basename(path).toLowerCase();
  if (name == 'notosanssc-regular.otf' ||
      name == 'notosanscjksc-regular.otf' ||
      name == 'notosanscjk-regular.ttc' ||
      name == 'msyh.ttc') {
    return 0;
  }
  if (name == 'droidsansfallback.ttf' || name == 'simsun.ttc') return 1;
  if (RegExp(r'cjk|hans|sanssc|cjksc|simhei|msyh').hasMatch(name)) return 2;
  if (RegExp(r'bold|black|italic|light|thin').hasMatch(name)) return 4;
  return 3;
}

SubtitleFontFace? inspectSubtitleFont(String path) {
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    final length = file.lengthSync();
    if (length < 12 || length > 128 * 1024 * 1024) return null;
    ByteData read(int offset, int count) {
      if (offset < 0 || count < 0 || offset + count > length) {
        throw const FormatException('Font table is outside the file');
      }
      file!.setPositionSync(offset);
      final bytes = file.readSync(count);
      if (bytes.length != count) throw const FormatException('Truncated font');
      return ByteData.sublistView(bytes);
    }

    final header = read(0, 12);
    final offsets = <int>[0];
    if (header.getUint32(0) == 0x74746366) {
      final count = header.getUint32(8);
      if (count == 0 || count > 64) return null;
      final collection = read(12, count * 4);
      offsets
        ..clear()
        ..addAll(List.generate(count, (i) => collection.getUint32(i * 4)));
    }
    SubtitleFontFace? fallback;
    for (final offset in offsets) {
      final face = read(offset, 12);
      if (!{0x00010000, 0x4f54544f, 0x74727565}.contains(face.getUint32(0))) {
        continue;
      }
      final count = face.getUint16(4);
      if (count == 0 || count > 256) continue;
      final tables = read(offset + 12, count * 16);
      ByteData? cmap, name;
      for (var i = 0; i < count; i++) {
        final at = i * 16, tag = tables.getUint32(at);
        if (tag != 0x636d6170 && tag != 0x6e616d65) continue;
        final size = tables.getUint32(at + 12);
        if (size > (tag == 0x636d6170 ? 4 * 1024 * 1024 : 256 * 1024)) {
          continue;
        }
        final table = read(tables.getUint32(at + 8), size);
        if (tag == 0x636d6170) cmap = table;
        if (tag == 0x6e616d65) name = table;
      }
      if (cmap == null || name == null || !_coversChinese(cmap)) continue;
      final family = _family(name);
      if (family == null) continue;
      final result = SubtitleFontFace(path, family);
      // A CJK collection can put its Japanese face before Simplified Chinese.
      if (RegExp(
        r'\bSC\b|Hans|YaHei|SimSun|SimHei|简体',
        caseSensitive: false,
      ).hasMatch(family)) {
        return result;
      }
      fallback ??= result;
    }
    return fallback;
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  } on RangeError {
    return null;
  } finally {
    file?.closeSync();
  }
}

bool _coversChinese(ByteData cmap) {
  const sample = 'Aa09中文字幕简体繁體测试漢字，。！？';
  final count = cmap.getUint16(2);
  if (count > 64 || 4 + count * 8 > cmap.lengthInBytes) return false;
  for (var i = 0; i < count; i++) {
    final at = 4 + i * 8;
    final platform = cmap.getUint16(at), encoding = cmap.getUint16(at + 2);
    if (platform != 0 && !(platform == 3 && {1, 10}.contains(encoding))) {
      continue;
    }
    final offset = cmap.getUint32(at + 4);
    if (offset + 2 > cmap.lengthInBytes) continue;
    final format = cmap.getUint16(offset);
    if (!{4, 12, 13}.contains(format)) continue;
    final length = format == 4
        ? cmap.getUint16(offset + 2)
        : cmap.getUint32(offset + 4);
    if (length < 16 || offset + length > cmap.lengthInBytes) continue;
    final table = ByteData.sublistView(
      cmap.buffer.asUint8List(cmap.offsetInBytes + offset, length),
    );
    if (sample.runes.every((code) => _hasGlyph(table, format, code))) {
      return true;
    }
  }
  return false;
}

bool _hasGlyph(ByteData data, int format, int code) {
  if (format == 4) {
    final count = data.getUint16(6) ~/ 2;
    if (code > 0xffff || count == 0 || 16 + count * 8 > data.lengthInBytes) {
      return false;
    }
    var low = 0, high = count;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (data.getUint16(14 + mid * 2) < code) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (low == count) return false;
    final start = data.getUint16(16 + count * 2 + low * 2);
    if (start > code) return false;
    final delta = data.getUint16(16 + count * 4 + low * 2);
    final rangeAt = 16 + count * 6 + low * 2;
    final range = data.getUint16(rangeAt);
    if (range == 0) return ((code + delta) & 0xffff) != 0;
    final glyphAt = rangeAt + range + (code - start) * 2;
    if (glyphAt + 2 > data.lengthInBytes) return false;
    final glyph = data.getUint16(glyphAt);
    return glyph != 0 && ((glyph + delta) & 0xffff) != 0;
  }
  final count = data.getUint32(12);
  if (16 + count * 12 > data.lengthInBytes) return false;
  var low = 0, high = count;
  while (low < high) {
    final mid = (low + high) ~/ 2, at = 16 + mid * 12;
    if (data.getUint32(at + 4) < code) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  if (low == count) return false;
  final at = 16 + low * 12, start = data.getUint32(at);
  if (start > code) return false;
  final glyph = data.getUint32(at + 8);
  return (format == 13 ? glyph : glyph + code - start) != 0;
}

String? _family(ByteData data) {
  final count = data.getUint16(2), strings = data.getUint16(4);
  if (6 + count * 12 > data.lengthInBytes) return null;
  String? result;
  var best = -1;
  for (var i = 0; i < count; i++) {
    final at = 6 + i * 12, platform = data.getUint16(at);
    final language = data.getUint16(at + 4), id = data.getUint16(at + 6);
    if (!{1, 16}.contains(id) || !{0, 3}.contains(platform)) continue;
    final length = data.getUint16(at + 8);
    final offset = strings + data.getUint16(at + 10);
    if (length == 0 ||
        length > 512 ||
        length.isOdd ||
        offset + length > data.lengthInBytes) {
      continue;
    }
    final name = String.fromCharCodes(
      List.generate(length ~/ 2, (j) => data.getUint16(offset + j * 2)),
    ).trim();
    if (name.isEmpty || name.codeUnits.any((unit) => unit < 32)) continue;
    final score = (id == 16 ? 2 : 0) + (language == 0x409 ? 4 : 0);
    if (score > best) {
      result = name;
      best = score;
    }
  }
  return result;
}
