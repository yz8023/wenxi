import 'dart:convert';
import 'dart:typed_data';
import '../../core/json.dart';
import '../../domain/uploads.dart';
import '../http.dart';

/// Weiyun requests unpadded SHA-1 state at MiB boundaries, in little-endian words.
class WeiyunHash {
  final _state = Uint32List.fromList([
    0x67452301,
    0xefcdab89,
    0x98badcfe,
    0x10325476,
    0xc3d2e1f0,
  ]);
  final _buffer = Uint8List(64), _words = Uint32List(80);
  int _used = 0, _length = 0;
  static int _rotate(int value, int count) =>
      ((value << count) | (value >>> (32 - count))) & 0xffffffff;

  void add(List<int> bytes) {
    _length += bytes.length;
    var offset = 0;
    while (offset < bytes.length) {
      final count = (bytes.length - offset).clamp(0, 64 - _used);
      _buffer.setRange(_used, _used + count, bytes, offset);
      offset += count;
      _used += count;
      if (_used == 64) {
        _block();
        _used = 0;
      }
    }
  }

  void _block() {
    final data = ByteData.sublistView(_buffer);
    for (var i = 0; i < 16; i++) {
      _words[i] = data.getUint32(i * 4, Endian.big);
    }
    for (var i = 16; i < 80; i++) {
      _words[i] = _rotate(
        _words[i - 3] ^ _words[i - 8] ^ _words[i - 14] ^ _words[i - 16],
        1,
      );
    }
    var a = _state[0],
        b = _state[1],
        c = _state[2],
        d = _state[3],
        e = _state[4];
    for (var i = 0; i < 80; i++) {
      final int f, k;
      if (i < 20) {
        f = (b & c) | ((~b) & d);
        k = 0x5a827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ed9eba1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8f1bbcdc;
      } else {
        f = b ^ c ^ d;
        k = 0xca62c1d6;
      }
      final temp = (_rotate(a, 5) + f + e + k + _words[i]) & 0xffffffff;
      e = d;
      d = c;
      c = _rotate(b, 30);
      b = a;
      a = temp;
    }
    for (final entry in [a, b, c, d, e].asMap().entries) {
      _state[entry.key] = (_state[entry.key] + entry.value) & 0xffffffff;
    }
  }

  String _hex(Endian endian) {
    final bytes = ByteData(20);
    for (var i = 0; i < 5; i++) {
      bytes.setUint32(i * 4, _state[i], endian);
    }
    return bytes.buffer
        .asUint8List()
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  String get checkpoint {
    require(_used == 0, '微云校验位置必须位于完整数据块边界');
    return _hex(Endian.little);
  }

  String finish() {
    final length = _length;
    final padding = Uint8List((_used < 56 ? 56 - _used : 120 - _used) + 8)
      ..[0] = 0x80;
    ByteData.sublistView(
      padding,
    ).setUint64(padding.length - 8, length * 8, Endian.big);
    add(padding);
    return _hex(Endian.big);
  }

  static Future<Json> plan(
    UploadFile source,
    UploadProgressCallback? onProgress,
  ) async {
    const block = 1024 * 1024;
    final last = source.size == 0 ? 0 : (source.size - 1) % block + 1;
    final check = last == 0 ? 0 : (last - 1) % 128 + 1;
    final before = source.size - last, state = WeiyunHash(), blocks = <Json>[];
    Future<void> read(int start, int end) async {
      var offset = start;
      await for (final bytes in source.openRead(start, end)) {
        RequestScope.checkpoint();
        state.add(bytes);
        offset += bytes.length;
        onProgress?.call(
          UploadProgress(UploadPhase.preparing, offset, source.size),
        );
      }
    }

    for (var offset = 0; offset < before; offset += block) {
      await read(offset, offset + block);
      blocks.add({'sha': state.checkpoint, 'offset': offset, 'size': block});
    }
    await read(before, source.size - check);
    final checkSha = state.checkpoint, tail = BytesBuilder(copy: false);
    await for (final bytes in source.openRead(source.size - check)) {
      RequestScope.checkpoint();
      state.add(bytes);
      tail.add(bytes);
    }
    final full = state.finish();
    blocks.add({'sha': full, 'offset': before, 'size': last});
    return {
      'block_size': block,
      'check_sha': checkSha,
      'check_data': base64Encode(tail.takeBytes()),
      'block_info_list': blocks,
    };
  }
}
