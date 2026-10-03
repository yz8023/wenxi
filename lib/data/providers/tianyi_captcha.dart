import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import '../../core/crypto_box.dart';
import '../../core/json.dart';
import '../../core/login_crypto.dart';
import '../http.dart';

class TianyiCaptchaImage {
  const TianyiCaptchaImage({
    required this.type,
    required this.token,
    required this.background,
    this.piece,
    this.instruction = '',
  });
  final int type;
  final String token, instruction;
  final Uint8List background;
  final Uint8List? piece;
  static const width = 310.0;
}

class TianyiCaptchaProof {
  const TianyiCaptchaProof(this.type, this.token, this.validate);
  final int type;
  final String token, validate;
}

/// A submission produced by the user's drag or ordered taps. Coordinates use
/// the captcha's 310 logical pixel canvas, independent of display scaling.
class TianyiCaptchaGesture {
  const TianyiCaptchaGesture(this.points, this.rates, this.milliseconds);
  final List<Map<String, num>> points;
  final List<Map<String, num>> rates;
  final int milliseconds;
}

class TianyiCaptchaClient {
  TianyiCaptchaClient({
    required this.request,
    required this.referer,
    required this.appId,
    required this.checkpoint,
    required this.cancel,
    DateTime Function()? clock,
    LoginRsa? encryption,
  }) : clock = clock ?? DateTime.now,
       _encryption = encryption ?? _rsa;
  final Future<HttpResult> Function(Uri) request;
  final String referer, appId;
  final void Function() checkpoint, cancel;
  final DateTime Function() clock;
  final LoginRsa _encryption;
  final _finger = Random.secure().nextInt(0x7fffffff);
  TianyiCaptchaImage? _current;
  int _generation = 0;
  DateTime? _created;
  static const _publicKey =
      'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDky91Sokyr2UI/K87VMiZp/Pmiggg4fFKgclUZoPCoO+FvdeU/wSvv59Z6fEZi4Uvtzzv5UqCMfFRykokoiGSq8B3X1kr24RbtsWif/+pxfRDCA8tXw3V2DIZ/a03tg8BBgQLpdWuwTmM1448WFIs5O9pyFgjKDFoo5cWvs88HBQIDAQAB';
  static final _rsa = LoginRsa(_publicKey);

  static String _id(int length) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  (Map<String, Object?>, Uint8List) _pack(Json data) {
    final key = Uint8List.fromList(utf8.encode(_id(16)));
    final encrypted = CryptoBox.aesCbc(
      true,
      utf8.encode(encoded(data)),
      key,
      key,
    );
    return (
      {
        'pb': encrypted
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join()
            .toUpperCase(),
        'cp': _encryption.encrypt(base64Encode(key)),
        'appId': appId,
        'version': '1.0.1',
        'reqId': _id(32),
      },
      key,
    );
  }

  Json _response(HttpResult response, String callback) {
    checkpoint();
    require(
      response.successful && response.body.length <= 2 * 1024 * 1024,
      '天翼验证码加载失败，请刷新重试',
    );
    var text = response.body.trim();
    if (text.startsWith('$callback(')) {
      if (text.endsWith(';')) {
        text = text.substring(0, text.length - 1).trimRight();
      }
      require(text.endsWith(')'), '天翼验证码响应格式错误');
      text = text.substring(callback.length + 1, text.length - 1);
    }
    final result = HttpResult(response.status, text).json;
    require(
      result.str('result') == '0',
      result.str('result') == '50009'
          ? '验证码尝试次数过多，请稍后再登录'
          : '天翼验证码未通过，请刷新后重新验证',
    );
    return result;
  }

  static Uint8List _image(String value) {
    require(value.length <= 900000, '天翼验证码图片过大，请刷新');
    final match = RegExp(
      r'^data:image/(?:png|jpg|jpeg|webp);base64,([A-Za-z0-9+/=\r\n]+)$',
    ).firstMatch(value);
    require(match != null, '天翼验证码图片格式已变化，请稍后重试');
    try {
      final bytes = base64Decode(match![1]!.replaceAll(RegExp(r'\s'), ''));
      require(bytes.isNotEmpty && bytes.length <= 650000, '天翼验证码图片无效');
      return bytes;
    } on FormatException {
      throw const AppException('天翼验证码图片损坏，请刷新');
    }
  }

  Future<TianyiCaptchaImage> load() async {
    checkpoint();
    final generation = ++_generation;
    _current = null;
    final packed = _pack({
      'appId': appId,
      'captchaType': 1,
      'referer': referer,
      'time': clock().millisecondsSinceEpoch,
      'finger': _finger,
      'width': '310',
    });
    try {
      const callback = 'asterlinkCaptcha';
      final data = _response(
        await request(
          Uri.parse(
            query('https://open.e.189.cn/gw/captcha/get.do', {
              ...packed.$1,
              'callback': callback,
            }),
          ),
        ),
        callback,
      ).obj('data');
      checkpoint();
      require(generation == _generation, '验证码已更新，请重试');
      final type = data.integer('captchaType');
      require(type == 1 || type == 2, '天翼返回了暂不支持的验证方式');
      require(
        data.str('token').isNotEmpty && data.str('token').length <= 8192,
        '天翼验证码缺少验证标识，请刷新',
      );
      final image = TianyiCaptchaImage(
        type: type,
        token: data.str('token'),
        background: _image(data.str('bg')),
        piece: type == 1 ? _image(data.str('front')) : null,
        instruction: type == 2
            ? data
                  .str('front')
                  .replaceAll(RegExp(r'''[\[\]"']'''), '')
                  .replaceAll(',', '、')
            : '向右拖动滑块，完成拼图',
      );
      require(image.instruction.length <= 120, '天翼验证码提示无效，请刷新');
      _created = clock();
      return _current = image;
    } finally {
      packed.$2.fillRange(0, packed.$2.length, 0);
    }
  }

  Future<TianyiCaptchaProof> verify(
    TianyiCaptchaImage image,
    TianyiCaptchaGesture gesture,
  ) async {
    checkpoint();
    require(identical(image, _current), '验证码已更新，请重新验证');
    require(
      _created != null &&
          clock().difference(_created!) < const Duration(minutes: 3),
      '验证码已过期，请刷新',
    );
    require(
      gesture.points.length == (image.type == 1 ? 1 : 3) &&
          gesture.rates.length <= 50 &&
          gesture.milliseconds >= 0 &&
          gesture.milliseconds <= 180000,
      '请完成验证码操作',
    );
    for (final point in gesture.points) {
      final x = point['x'], y = point['y'];
      require(
        x != null &&
            y != null &&
            x.isFinite &&
            y.isFinite &&
            x >= 0 &&
            x <= TianyiCaptchaImage.width &&
            y >= 0 &&
            y <= 1000,
        '验证码坐标无效，请重新操作',
      );
    }
    for (final rate in gesture.rates) {
      require(
        rate['pointDiff']?.isFinite == true &&
            rate['timeDiff']?.isFinite == true &&
            rate['timeDiff']! >= 0,
        '验证码操作无效，请重新操作',
      );
    }
    _current = null; // A challenge is used once, including failed submissions.
    final packed = _pack({
      'token': image.token,
      'captchaType': image.type,
      'points': gesture.points,
      'rates': gesture.rates,
      'dragTime': gesture.milliseconds,
      'time': clock().millisecondsSinceEpoch,
      'finger': _finger,
    });
    try {
      const callback = 'asterlinkCaptcha';
      final result = _response(
        await request(
          Uri.parse(
            query('https://open.e.189.cn/gw/captcha/check.do', {
              ...packed.$1,
              'callback': callback,
            }),
          ),
        ),
        callback,
      );
      final hex = result.str('data');
      require(
        hex.length <= 32768 &&
            hex.length % 32 == 0 &&
            RegExp(r'^[A-Fa-f0-9]+$').hasMatch(hex),
        '天翼验证码校验响应无效，请刷新',
      );
      Json proof;
      try {
        final ciphertext = Uint8List.fromList([
          for (var i = 0; i < hex.length; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16),
        ]);
        proof = asJson(
          jsonDecode(
            utf8.decode(
              CryptoBox.aesCbc(false, ciphertext, packed.$2, packed.$2),
            ),
          ),
        );
      } catch (_) {
        throw const AppException('天翼验证码校验响应无效，请刷新');
      }
      checkpoint();
      require(
        proof.integer('captchaType') == image.type &&
            proof.str('token').isNotEmpty &&
            proof.str('validate').isNotEmpty &&
            proof.str('token').length <= 8192 &&
            proof.str('validate').length <= 8192,
        '天翼验证码校验尚未完成，请重新验证',
      );
      return TianyiCaptchaProof(
        image.type,
        proof.str('token'),
        proof.str('validate'),
      );
    } finally {
      packed.$2.fillRange(0, packed.$2.length, 0);
    }
  }
}
