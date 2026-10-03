import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'json.dart';

class CryptoBox {
  static Uint8List random(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }

  static Uint8List seal(Uint8List key, List<int> plain, {Uint8List? iv}) {
    final nonce = iv ?? random(12);
    require(key.length == 32 && nonce.length == 12, '加密参数无效');
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    return Uint8List.fromList([
      ...nonce,
      ...cipher.process(Uint8List.fromList(plain)),
    ]);
  }

  static Uint8List open(Uint8List key, List<int> packed) {
    require(key.length == 32 && packed.length >= 28, '加密数据格式错误');
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(key),
          128,
          Uint8List.fromList(packed.sublist(0, 12)),
          Uint8List(0),
        ),
      );
    try {
      return cipher.process(Uint8List.fromList(packed.sublist(12)));
    } on InvalidCipherTextException {
      throw const AppException('密码错误或加密数据已损坏');
    }
  }

  static Uint8List derive(String password, Uint8List salt, int rounds) {
    require(
      rounds >= 100000 &&
          rounds <= 2000000 &&
          salt.length >= 16 &&
          salt.length <= 64,
      '备份密钥参数无效',
    );
    final bytes = Uint8List.fromList(utf8.encode(password));
    try {
      final generator = PBKDF2KeyDerivator(HMac(SHA1Digest(), 64))
        ..init(Pbkdf2Parameters(salt, rounds, 32));
      return generator.process(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  static Uint8List aesCbc(
    bool encrypt,
    List<int> data,
    List<int> key,
    List<int> iv,
  ) {
    final cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
          ..init(
            encrypt,
            PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
              ParametersWithIV(
                KeyParameter(Uint8List.fromList(key)),
                Uint8List.fromList(iv),
              ),
              null,
            ),
          );
    return cipher.process(Uint8List.fromList(data));
  }
}
