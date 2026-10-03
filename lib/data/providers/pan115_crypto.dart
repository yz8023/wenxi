// 115 m115 wire protocol, adapted from SheltonZhu/115driver (MIT).
// License: assets/licenses/115driver.txt.
import 'dart:convert';
import 'dart:math';
import '../../core/json.dart';

class Pan115Cipher {
  Pan115Cipher({List<int>? key, Random? random})
    : _random = random ?? Random.secure(),
      key = key ?? List.generate(16, (_) => Random.secure().nextInt(256)) {
    require(
      this.key.length == 16 && this.key.every((b) => b >= 0 && b < 256),
      '115 加密参数无效',
    );
  }
  final List<int> key;
  final Random _random;
  static final _n = BigInt.parse(
    '8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021'
    '36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633'
    '8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1'
    '0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683',
    radix: 16,
  );
  static const _seed = [
    0xf0,
    0xe5,
    0x69,
    0xae,
    0xbf,
    0xdc,
    0xbf,
    0x8a,
    0x1a,
    0x45,
    0xe8,
    0xbe,
    0x7d,
    0xa6,
    0x73,
    0xb8,
    0xde,
    0x8f,
    0xe7,
    0xc4,
    0x45,
    0xda,
    0x86,
    0xc4,
    0x9b,
    0x64,
    0x8b,
    0x14,
    0x6a,
    0xb4,
    0xf1,
    0xaa,
    0x38,
    0x01,
    0x35,
    0x9e,
    0x26,
    0x69,
    0x2c,
    0x86,
    0x00,
    0x6b,
    0x4f,
    0xa5,
    0x36,
    0x34,
    0x62,
    0xa6,
    0x2a,
    0x96,
    0x68,
    0x18,
    0xf2,
    0x4a,
    0xfd,
    0xbd,
    0x6b,
    0x97,
    0x8f,
    0x4d,
    0x8f,
    0x89,
    0x13,
    0xb7,
    0x6c,
    0x8e,
    0x93,
    0xed,
    0x0e,
    0x0d,
    0x48,
    0x3e,
    0xd7,
    0x2f,
    0x88,
    0xd8,
    0xfe,
    0xfe,
    0x7e,
    0x86,
    0x50,
    0x95,
    0x4f,
    0xd1,
    0xeb,
    0x83,
    0x26,
    0x34,
    0xdb,
    0x66,
    0x7b,
    0x9c,
    0x7e,
    0x9d,
    0x7a,
    0x81,
    0x32,
    0xea,
    0xb6,
    0x33,
    0xde,
    0x3a,
    0xa9,
    0x59,
    0x34,
    0x66,
    0x3b,
    0xaa,
    0xba,
    0x81,
    0x60,
    0x48,
    0xb9,
    0xd5,
    0x81,
    0x9c,
    0xf8,
    0x6c,
    0x84,
    0x77,
    0xff,
    0x54,
    0x78,
    0x26,
    0x5f,
    0xbe,
    0xe8,
    0x1e,
    0x36,
    0x9f,
    0x34,
    0x80,
    0x5c,
    0x45,
    0x2c,
    0x9b,
    0x76,
    0xd5,
    0x1b,
    0x8f,
    0xcc,
    0xc3,
    0xb8,
    0xf5,
  ];
  static const _client = [
    0x78,
    0x06,
    0xad,
    0x4c,
    0x33,
    0x86,
    0x5d,
    0x18,
    0x4c,
    0x01,
    0x3f,
    0x46,
  ];
  static List<int> _derive(List<int> seed, int size) => List.generate(
    size,
    (i) => ((seed[i] + _seed[size * i]) & 255) ^ _seed[size * (size - i - 1)],
  );
  static List<int> _xor(List<int> data, List<int> key) {
    final mod = data.length % 4;
    return List.generate(
      data.length,
      (i) => data[i] ^ key[(i < mod ? i : i - mod) % key.length],
    );
  }

  static List<int> _rsa(List<int> bytes) {
    var value = BigInt.zero;
    for (final b in bytes) {
      value = (value << 8) | BigInt.from(b);
    }
    require(value < _n, '115 加密响应无效');
    final hex = value
        .modPow(BigInt.from(65537), _n)
        .toRadixString(16)
        .padLeft(256, '0');
    return [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
  }

  String encode(Json payload) {
    final bytes = [
      ...key,
      ..._xor(
        _xor(
          utf8.encode(jsonEncode(payload)),
          _derive(key, 4),
        ).reversed.toList(),
        _client,
      ),
    ];
    final output = <int>[];
    for (var offset = 0; offset < bytes.length; offset += 117) {
      final part = bytes.sublist(offset, min(offset + 117, bytes.length));
      output.addAll(
        _rsa([
          0,
          2,
          ...List.generate(125 - part.length, (_) => _random.nextInt(255) + 1),
          0,
          ...part,
        ]),
      );
    }
    return base64Encode(output);
  }

  Json decode(String encoded) {
    try {
      require(encoded.length <= 1024 * 1024, '115 下载响应过大');
      final bytes = base64Decode(encoded);
      require(bytes.isNotEmpty && bytes.length % 128 == 0, '115 加密响应长度无效');
      final output = <int>[];
      for (var offset = 0; offset < bytes.length; offset += 128) {
        final block = _rsa(bytes.sublist(offset, offset + 128));
        final separator = block.indexOf(0, 2);
        require(
          block[0] == 0 && (block[1] == 1 || block[1] == 2) && separator >= 10,
          '115 加密响应填充无效',
        );
        output.addAll(block.sublist(separator + 1));
      }
      require(output.length > 16, '115 下载响应为空');
      final decoded = _xor(
        _xor(
          output.sublist(16),
          _derive(output.sublist(0, 16), 12),
        ).reversed.toList(),
        _derive(key, 4),
      );
      final result = jsonDecode(utf8.decode(decoded));
      require(result is Map, '115 下载响应格式无效');
      return asJson(result);
    } on FormatException {
      throw const AppException('115 下载响应无法解密，请重试');
    }
  }
}
