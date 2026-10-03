import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' as pc;
import '../../core/json.dart';

/// The web device protocol uses a compact, recoverable secp256k1 signature.
class AliyunSignature {
  static const appId = '5dde4e1bdf9e4966b387ba58f4b3fdc3';
  static final _curve = pc.ECDomainParameters('secp256k1');

  static String privateKey() {
    final random = Random.secure();
    while (true) {
      final value = List.generate(
        32,
        (_) => random.nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      final number = BigInt.parse(value, radix: 16);
      if (number > BigInt.zero && number < _curve.n) return value;
    }
  }

  static ({String signature, String publicKey}) sign({
    required String privateKey,
    required String deviceId,
    required String userId,
    int nonce = 0,
  }) {
    require(
      RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(privateKey),
      '阿里设备密钥格式无效，请重新登录',
    );
    final number = BigInt.parse(privateKey, radix: 16);
    require(number > BigInt.zero && number < _curve.n, '阿里设备密钥无效，请重新登录');
    final digest = Uint8List.fromList(
      sha256.convert(utf8.encode('$appId:$deviceId:$userId:$nonce')).bytes,
    );
    final signer = pc.ECDSASigner(null, pc.HMac(pc.SHA256Digest(), 64))
      ..init(
        true,
        pc.PrivateKeyParameter<pc.ECPrivateKey>(
          pc.ECPrivateKey(number, _curve),
        ),
      );
    final value = signer.generateSignature(digest) as pc.ECSignature;
    final s = value.s > (_curve.n >> 1) ? _curve.n - value.s : value.s;
    final public = (_curve.G * number)!;
    final inverse = s.modInverse(_curve.n);
    final hash = BigInt.parse(_hex(digest), radix: 16);
    final point =
        ((_curve.G * (hash * inverse % _curve.n))! +
        public * (value.r * inverse % _curve.n))!;
    final recovery =
        (point.y!.toBigInteger()!.isOdd ? 1 : 0) |
        (point.x!.toBigInteger()! >= _curve.n ? 2 : 0);
    return (
      signature:
          '${value.r.toRadixString(16).padLeft(64, '0')}${s.toRadixString(16).padLeft(64, '0')}${recovery.toRadixString(16).padLeft(2, '0')}',
      publicKey: _hex(public.getEncoded(false)),
    );
  }

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
