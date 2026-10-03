import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';
import 'crypto_box.dart';
import 'json.dart';

/// The providers' login protocols use RSAES-PKCS1-v1_5 (JSEncrypt).
class LoginRsa {
  LoginRsa(String publicKey) : key = _parse(publicKey);
  final RSAPublicKey key;

  static RSAPublicKey _parse(String value) {
    try {
      require(value.length <= 8192, '登录加密公钥无效');
      final der = base64Decode(
        value.replaceAll(
          RegExp(
            r'-----BEGIN (?:RSA )?PUBLIC KEY-----|-----END (?:RSA )?PUBLIC KEY-----|\s',
          ),
          '',
        ),
      );
      var sequence = ASN1Parser(der).nextObject() as ASN1Sequence;
      final elements = sequence.elements!;
      if (elements.length == 2 && elements.last is ASN1BitString) {
        final bits = elements.last as ASN1BitString;
        require(bits.unusedbits == 0, '登录加密公钥无效');
        sequence =
            ASN1Parser(Uint8List.fromList(bits.stringValues!)).nextObject()
                as ASN1Sequence;
      }
      require(sequence.elements?.length == 2, '登录加密公钥无效');
      final n = (sequence.elements![0] as ASN1Integer).integer!;
      final e = (sequence.elements![1] as ASN1Integer).integer!;
      require(
        n.isOdd &&
            n.bitLength >= 1024 &&
            n.bitLength <= 4096 &&
            e >= BigInt.from(3) &&
            e.isOdd &&
            e.bitLength <= 32,
        '登录加密公钥无效',
      );
      return RSAPublicKey(n, e);
    } catch (_) {
      throw const AppException('无法读取官方登录加密公钥，请稍后重试');
    }
  }

  String encrypt(String value) =>
      base64Encode(_encrypt(Uint8List.fromList(utf8.encode(value))));

  /// The current Tianyi login bundle returns raw hexadecimal RSA output.
  /// Its JS encoder handles UTF-16 code units individually (CESU-8), including
  /// surrogate pairs in passwords. Captcha's separate RSA protocol uses Base64.
  String encryptTianyi(String value) {
    final bytes = <int>[];
    for (final unit in value.codeUnits) {
      if (unit < 0x80) {
        bytes.add(unit);
      } else if (unit < 0x800) {
        bytes.addAll([0xc0 | (unit >> 6), 0x80 | (unit & 0x3f)]);
      } else {
        bytes.addAll([
          0xe0 | (unit >> 12),
          0x80 | ((unit >> 6) & 0x3f),
          0x80 | (unit & 0x3f),
        ]);
      }
    }
    final plain = Uint8List.fromList(bytes);
    bytes.fillRange(0, bytes.length, 0);
    return _encrypt(plain)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .replaceFirst(RegExp(r'^(?:00)+'), '');
  }

  Uint8List _encrypt(Uint8List plain) {
    try {
      final random = FortunaRandom()..seed(KeyParameter(CryptoBox.random(32)));
      final cipher = PKCS1Encoding(RSAEngine())
        ..init(
          true,
          ParametersWithRandom(PublicKeyParameter<RSAPublicKey>(key), random),
        );
      require(plain.length <= cipher.inputBlockSize, '账号或密码过长');
      return cipher.process(plain);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }
}
