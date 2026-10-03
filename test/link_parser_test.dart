import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';

void main() {
  for (final (url, platform) in [
    ('https://www.alipan.com/s/Ali123', CloudPlatform.aliyun),
    ('https://www.aliyundrive.com/s/Ali123', CloudPlatform.aliyun),
    ('https://www.guangyapan.com/s/Guangya123', CloudPlatform.guangya),
  ]) {
    test('$url is a supported share and upgrades its saved history', () {
      final link = LinkParser.parse('$url 提取码：a123').single;
      expect(link.kind, LinkKind.cloudShare);
      expect(link.platform, platform);
      expect(link.shareId, url.split('/').last);
      expect(link.passcode, 'a123');
      expect(link.unsupportedPlatform, isNull);
      final restored = ParsedLink.fromJson({
        ...link.toJson(),
        'platform': null,
        'kind': 'unsupportedCloud',
        'unsupportedPlatform': platform.name,
      });
      expect(restored.kind, LinkKind.cloudShare);
      expect(restored.platform, platform);
      expect(restored.passcode, 'a123');
      expect(restored.id, link.id);
    });
  }

  test(
    'Recognizes pasted prose, omitted schemes and an adjacent code label',
    () {
      final link = LinkParser.parse(
        '我分享了「旅行视频」：pan.quark.cn/s/Abc123提取码：a1B2，复制后打开。',
      ).single;
      expect(link.url, 'https://pan.quark.cn/s/Abc123');
      expect(link.platform, CloudPlatform.quark);
      expect(link.passcode, 'a1B2');
      expect(link.source, contains('旅行视频'));
    },
  );
  test(
    'Reads embedded query, percent-encoded codes and supported fragments',
    () {
      for (final (url, code) in [
        ('https://pan.baidu.com/s/1AbCd?pwd=%61%31B2', 'a1B2'),
        ('https://www.123pan.com/s/Abc-Def#q123', 'q123'),
        ('https://drive.uc.cn/s/Abcd#pwd=u321', 'u321'),
        ('https://yun.139.com/shareweb/#/w/i/Abc_ID?passcode=m123', 'm123'),
      ]) {
        expect(LinkParser.parse('$url 提取码：wrong').single.passcode, code);
      }
    },
  );
  test('Lanzou labels allow 1 to 12 characters; other clouds require four', () {
    for (final code in ['A', '123', 'a1B2', 'Ab1234567890']) {
      expect(
        LinkParser.parse(
          '密码为【$code】\nhttps://www.lanzouj.com/iAbcd',
        ).single.passcode,
        code,
      );
      expect(
        LinkParser.parse(
          'https://www.lanzouj.com/iAbcd\npwd: $code',
        ).single.passcode,
        code,
      );
    }
    expect(
      LinkParser.parse(
        'https://pan.quark.cn/s/Abcd 提取码：Ab12345678901',
      ).single.passcode,
      isNull,
    );
    expect(
      LinkParser.parse('提取码：https://pan.quark.cn/s/Abcd').single.passcode,
      isNull,
    );
  });
  test('Each multiline trailing code belongs to its own share', () {
    final links = LinkParser.parse(
      'https://pan.quark.cn/s/First\n提取码：q123\n\nhttps://drive.uc.cn/s/Second\n访问码：u123\nhttps://pan.baidu.com/s/1Third',
    );
    expect(links.map((l) => l.passcode), ['q123', 'u123', null]);
  });
  test('Leading codes, same-line codes and blank blocks do not cross shares', () {
    final leading = LinkParser.parse(
      '提取码：aaaa\nhttps://pan.quark.cn/s/First\n密码：bbbb\nhttps://drive.uc.cn/s/Second',
    );
    expect(leading.map((l) => l.passcode), ['aaaa', 'bbbb']);
    final separated = LinkParser.parse(
      'https://pan.quark.cn/s/First\n\n提取码：bbbb\nhttps://drive.uc.cn/s/Second',
    );
    expect(separated.map((l) => l.passcode), [null, 'bbbb']);
    final inline = LinkParser.parse(
      'https://pan.quark.cn/s/First 提取码：aaaa\n访问码：bbbb https://drive.uc.cn/s/Second',
    );
    expect(inline.map((l) => l.passcode), ['aaaa', 'bbbb']);
  });
  test('Duplicate normalization keeps a later recognized code', () {
    final links = LinkParser.parse(
      'https://pan.quark.cn/s/Abcd\nhttps://PAN.QUARK.CN/s/Abcd 提取码：a1b2',
    );
    expect(links, hasLength(1));
    expect(links.single.passcode, 'a1b2');
  });
  test('Signed bytes and Unicode paths of direct files remain intact', () {
    const url = 'HTTPS://Example.COM/旅行%2fY%2Fz?b=2&a=%2b+%20&a=3';
    final link = LinkParser.parse('文件：$url').single;
    expect(link.url, 'https://example.com/旅行%2fY%2Fz?b=2&a=%2b+%20&a=3');
    expect(link.kind, LinkKind.direct);
    expect(
      LinkParser.parse('example.com/file.mp4').single.url,
      'https://example.com/file.mp4',
    );
  });
  test('Codes never get stolen from direct URL query parameters', () {
    final links = LinkParser.parse(
      'https://pan.quark.cn/s/Abcd\nhttps://example.com/file?pwd=abcd',
    );
    expect(links.first.passcode, isNull);
    expect(links.last.passcode, isNull);
  });
  test(
    'A manual passcode replaces the embedded value without rewriting the signed URL',
    () {
      final link = LinkParser.parse(
        'https://pan.baidu.com/s/1Abcd?pwd=old1',
      ).single;
      expect(link.withPasscode('new1').passcode, 'new1');
      expect(link.withPasscode('new1').url, link.url);
      expect(link.withPasscode('').passcode, isNull);
    },
  );
}
