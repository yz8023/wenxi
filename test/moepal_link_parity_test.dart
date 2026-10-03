import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic shares: expected results come from the supplied MoePal 4.3.0
// classifier/extractors. No test contacts a cloud service or uses a real share.
void main() {
  group('MoePal share formats', () {
    const cases = <(String, CloudPlatform, String)>[
      ('https://pan.baidu.com/s/1Ab_C-d', CloudPlatform.baidu, 'Ab_C-d'),
      (
        'https://pan.baidu.com/share/init?surl=Ab_C-d',
        CloudPlatform.baidu,
        'Ab_C-d',
      ),
      (
        'https://pan.baidu.com/share/link?surl=Ab_C-d&pwd=a123',
        CloudPlatform.baidu,
        'Ab_C-d',
      ),
      ('https://baidu.com/s/1Ab_C-d', CloudPlatform.baidu, 'Ab_C-d'),
      ('https://pan.baidu.com/s/2Ab_C-d', CloudPlatform.baidu, 'Ab_C-d'),
      (
        'https://pan.baidu.com/s/1PathId?surl=QueryId',
        CloudPlatform.baidu,
        'QueryId',
      ),
      ('https://pan.quark.cn/s/Ab123', CloudPlatform.quark, 'Ab123'),
      ('https://quark.cn/s/Ab123', CloudPlatform.quark, 'Ab123'),
      ('https://share.quark.cn/s/Ab123', CloudPlatform.quark, 'Ab123'),
      ('https://drive.uc.cn/s/Ab123', CloudPlatform.uc, 'Ab123'),
      ('https://uc.cn/s/Ab123', CloudPlatform.uc, 'Ab123'),
      ('https://share.uc.cn/s/Ab123', CloudPlatform.uc, 'Ab123'),
      ('https://pan.xunlei.com/s/Ab_C-d', CloudPlatform.xunlei, 'Ab_C-d'),
      ('https://xunlei.com/s/Ab_C-d', CloudPlatform.xunlei, 'Ab_C-d'),
      ('https://www.123pan.com/s/Abc-Def', CloudPlatform.pan123, 'Abc-Def'),
      ('https://123pan.cn/s/Abc_Def', CloudPlatform.pan123, 'Abc_Def'),
      ('https://www.123684.com/s/Abc-Def', CloudPlatform.pan123, 'Abc-Def'),
      ('https://123912.cn/s/Abc-Def', CloudPlatform.pan123, 'Abc-Def'),
      ('https://share.123pan.com/s/AbcDef', CloudPlatform.pan123, 'AbcDef'),
      (
        'https://author.share.123pan.cn/123pan/Abc_Def',
        CloudPlatform.pan123,
        'Abc_Def',
      ),
      (
        'https://author.123912.com/123pan/AbcDef',
        CloudPlatform.pan123,
        'AbcDef',
      ),
      ('https://caiyun.139.com/w/i/Ab123456', CloudPlatform.c139, 'Ab123456'),
      ('https://yun.139.com/m/i?Ab123456', CloudPlatform.c139, 'Ab123456'),
      (
        'https://caiyun.139.com/m/i?Ab123456&pwd=a123',
        CloudPlatform.c139,
        'Ab123456',
      ),
      (
        'https://yun.139.com/share?linkID=Ab123456',
        CloudPlatform.c139,
        'Ab123456',
      ),
      ('https://yun.139.com/w/Ab123456', CloudPlatform.c139, 'Ab123456'),
      ('https://yun.139.com/Ab123456', CloudPlatform.c139, 'Ab123456'),
      (
        'https://yun.139.com/shareweb/#/w/i/Ab123456?pass=139a',
        CloudPlatform.c139,
        'Ab123456',
      ),
      (
        'https://yun.139.com/w/i/Ab%2012%0A34%0D56/',
        CloudPlatform.c139,
        'Ab123456',
      ),
      (
        'https://yun.139.com/w/i/Ab123456/*description',
        CloudPlatform.c139,
        'Ab123456',
      ),
      (
        'https://yun.139.com/share?key=Ab123456',
        CloudPlatform.c139,
        'Ab123456',
      ),
      ('https://cloud.189.cn/t/Ab123456', CloudPlatform.tianyi, 'Ab123456'),
      (
        'https://cloud.189.cn/web/share?code=Ab123456',
        CloudPlatform.tianyi,
        'Ab123456',
      ),
      (
        'https://h5.cloud.189.cn/share.html#/t/Ab123456',
        CloudPlatform.tianyi,
        'Ab123456',
      ),
      (
        'https://h5.cloud.189.cn/share.html/t/Ab123456',
        CloudPlatform.tianyi,
        'Ab123456',
      ),
      ('https://189.cn/t/Ab123456', CloudPlatform.tianyi, 'Ab123456'),
      (
        'https://cloud.189.cn/web/share?code=QueryId#/t/PathId',
        CloudPlatform.tianyi,
        'QueryId',
      ),
      ('https://author.lanzou123.net/iAb123', CloudPlatform.lanzou, 'iAb123'),
      ('https://author.lansox.org/bAb123', CloudPlatform.lanzou, 'bAb123'),
    ];
    for (final (url, platform, shareId) in cases) {
      test(url, () {
        final link = LinkParser.parse('分享文件：$url').single;
        expect(link.platform, platform);
        expect(link.kind, LinkKind.cloudShare);
        expect(link.shareId, shareId);
      });
    }
  });

  group('MoePal code precedence', () {
    const share = 'https://pan.quark.cn/s/Ab123';
    const cases = <(String, String?)>[
      ('$share?pass=a123', 'a123'),
      ('$share?password=d444&passcode=c333&pass=b222&pwd=a111', 'a111'),
      ('$share?password=d444&passcode=c333&pass=b222', 'b222'),
      ('$share?password=d444&passcode=c333', 'c333'),
      ('$share?PWD=%61+1%20B%32', 'a1B2'),
      ('$share?pwd=%E3%80%80a1B2%C2%A0', 'a1B2'),
      ('$share?pwd=a1B2EXTRA', 'a1B2'),
      ('$share?pwd=abc', null),
      ('$share?pwd=a', null),
      ('$share?pwd=http', null),
      ('$share?pwd=https', null),
      ('$share?pwd=&pass=b222', 'b222'),
      ('$share?pwd=aa&pass=b222', 'b222'),
      ('$share?pwd=a111#/?pwd=b222', 'a111'),
      ('$share?pwd=aa#/?pwd=b222', 'b222'),
      ('$share#/?password=d444&pwd=a111', 'a111'),
      ('$share?pwd=%ZZ', null),
      ('$share 提取码：a111 密码：b222', 'b222'),
      ('$share 提取码：a111 密码：bb', 'a111'),
      ('$share 提取码：http 密码：b222', 'b222'),
      ('$share 提取码：a111 密码：https', 'a111'),
      ('$share 提取码：Ab123456', null),
      ('$share?pwd=a111 提取码：b222', 'a111'),
      ('https://www.lanzouj.com/iAb123?pass=A', 'A'),
      ('https://www.lanzouj.com/iAb123?pwd=Ab123456789012345', 'Ab1234567890'),
      ('https://www.lanzouj.com/iAb123 提取码：A', 'A'),
      ('https://www.lanzouj.com/iAb123 提取码：Ab123456789012345', 'Ab1234567890'),
      ('https://www.lanzouj.com/iAb123 提取码：first 密码：last', 'last'),
    ];
    for (final (text, expected) in cases) {
      test(text, () {
        final links = LinkParser.parse(text);
        if (text.contains('%ZZ')) {
          expect(links, isEmpty);
        } else {
          expect(links.single.passcode, expected);
        }
      });
    }
  });

  test('Bare aliases and punctuation work together in a pasted message', () {
    final links = LinkParser.parse(
      '文件一：https://pan.baidu.com/share/init?surl=Ab_123，提取码：b123。\n\n'
      '文件二：author.share.123pan.com/s/Cd_456 访问码：c456；\n\n'
      '文件三：caiyun.139.com/m/i?Ef123456 密码：d789。',
    );
    expect(links.map((l) => l.platform), [
      CloudPlatform.baidu,
      CloudPlatform.pan123,
      CloudPlatform.c139,
    ]);
    expect(links.map((l) => l.shareId), ['Ab_123', 'Cd_456', 'Ef123456']);
    expect(links.map((l) => l.passcode), ['b123', 'c456', 'd789']);
  });

  test(
    'Personal-only cloud connectors retain share IDs without becoming direct downloads',
    () {
      for (final (url, id, platform) in [
        ('https://share.weiyun.com/Wei123', 'Wei123', CloudPlatform.weiyun),
        ('https://www.ilanzou.com/s/IL123', 'IL123', CloudPlatform.ilanzou),
        ('https://pan.wo.cn/s?shareId=Wo123', 'Wo123', CloudPlatform.wopan),
      ]) {
        final link = LinkParser.parse('$url 提取码：a123').single;
        expect(link.kind, LinkKind.cloudShare);
        expect(link.platform, platform);
        expect(link.platform!.supportsSharing, isFalse);
        expect(link.shareId, id);
        expect(link.passcode, 'a123');
      }
    },
  );

  test('Cloud aliases require an actual host boundary', () {
    for (final url in [
      'https://notquark.cn/s/Ab123',
      'https://drive.uc.cn.evil.test/s/Ab123',
      'https://abc123865.com/s/Ab123',
      'https://123865.net/s/Ab123',
      'https://123abc.com/s/Ab123',
      'https://123pan.cn.evil.test/s/Ab123',
      'https://lanzouj.com.evil.test/iAb123',
      'https://not189.cn/t/Ab123',
      'https://caiyun.139.com.evil.test/w/i/Ab123',
      'https://alipan.com.evil.test/s/Ab123',
      'https://example.com/?url=https://pan.baidu.com/s/1Ab123',
    ]) {
      final link = LinkParser.parse(url).single;
      expect(link.platform, isNull, reason: url);
      expect(link.unsupportedPlatform, isNull, reason: url);
      expect(link.kind, LinkKind.direct, reason: url);
    }
    for (final text in [
      'https://user@pan.quark.cn/s/Ab123',
      'https://pan.quark.cn@evil.test/s/Ab123',
      'friend@pan.quark.cn/s/Ab123',
      'ftp://www.123865.com/s/Ab123',
    ]) {
      expect(LinkParser.parse(text), isEmpty, reason: text);
    }
  });

  test('Login pages and nested redirect paths never become share IDs', () {
    for (final url in [
      'https://pan.quark.cn/?url=https://pan.quark.cn/s/Ab123',
      'https://pan.quark.cn/s/Ab123_Invalid',
      'https://pan.baidu.com/account/login',
      'https://yun.139.com/account/login',
      'https://yun.139.com/shareweb/#/',
      'https://yun.139.com/share?pwd=Ab1234567890',
      'https://yun.139.com/share?url=https%3A%2F%2Fexample.com%2FAb123456',
      'https://yun.139.com/w/i/',
    ]) {
      final link = LinkParser.parse(url).single;
      expect(link.isCloudShare, isFalse, reason: url);
      expect(link.shareId, isNull, reason: url);
    }
  });

  test('Mixed label lengths and last valid codes stay with each share', () {
    final links = LinkParser.parse(
      'https://pan.quark.cn/s/First 提取码：a111 密码：b222\n\n'
      'https://www.lanzouj.com/iSecond 提取码：long 密码：X\n\n'
      'https://www.123684.com/s/Third?pass=c333 提取码：d444\n\n'
      'https://caiyun.139.com/m/i?Fourth123 提取码：wrong\n',
    );
    expect(links.map((l) => l.passcode), ['b222', 'X', 'c333', null]);
  });

  test('Decoded query codes preserve symbols and the original signed bytes', () {
    const url =
        'https://pan.baidu.com/share/init?b=%2f&surl=Ab123&pwd=a%2B12&a=1&a=2';
    final link = LinkParser.parse('$url 提取码：b123').single;
    expect(link.passcode, 'a+12');
    expect(link.url, url);
    expect(link.withPasscode('ManualCode123456').passcode, 'ManualCode123456');
    expect(link.withPasscode('ManualCode123456').url, url);
    expect(link.withPasscode('').passcode, isNull);
  });

  test(
    'Cloud classification survives serialization and manual passcode edits',
    () {
      for (final url in [
        'https://www.123684.com/s/Ab_123',
        'https://share.weiyun.com/Ab123',
        'https://www.alipan.com/s/Ab123',
        'https://www.guangyapan.com/s/Ab_123',
      ]) {
        final original = LinkParser.parse('$url 密码：a123').single;
        final restored = ParsedLink.fromJson(
          original.toJson(),
        ).withPasscode('b234');
        expect(restored.kind, original.kind);
        expect(restored.platform, original.platform);
        expect(restored.unsupportedPlatform, original.unsupportedPlatform);
        expect(restored.cloudLabel, original.cloudLabel);
        expect(restored.shareId, original.shareId);
        expect(restored.url, original.url);
        expect(restored.passcode, 'b234');
      }
    },
  );
}
