import 'dart:convert';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/providers/c139.dart';
import 'package:asterlink/data/providers/pan123.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/links.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support.dart';

void main() {
  for (final host in [
    'www.123684.com',
    'author.share.123pan.com',
    '123912.cn',
  ]) {
    test(
      '123 alias $host sends the extracted key and password to the share API',
      () async {
        final store = StateStore.memory();
        addTearDown(store.dispose);
        final http = FakeHttp((request) {
          expect(request.uri.host, 'yun.123pan.cn');
          expect(request.uri.path, '/b/api/share/get');
          expect(request.uri.queryParameters['shareKey'], 'Abc_Def');
          expect(request.uri.queryParameters['SharePwd'], 'p123');
          return jsonResponse({
            'code': 0,
            'data': {'InfoList': []},
          });
        });
        final link = LinkParser.parse(
          'https://$host/s/Abc_Def?pass=p123 提取码：a123',
        ).single;
        final session = await Pan123Connector(
          http,
          Vault(store),
        ).openShare(link, null);
        expect(session.meta('shareKey'), 'Abc_Def');
        expect(session.meta('passcode'), 'p123');
        expect(http.calls, hasLength(1));
      },
    );
  }

  for (final url in [
    'https://caiyun.139.com/m/i?Mobile123&pass=m123',
    'https://yun.139.com/shareweb/#/w/i/Mobile123?pwd=m123',
  ]) {
    test('Mobile input $url reaches the encrypted share request', () async {
      final http = FakeHttp((request) {
        expect(request.uri.path, endsWith('/IOutLink/getOutLinkGeneral'));
        final body = asJson(
          jsonDecode(C139Protocol.decrypt(request.body as String)),
        );
        expect(body.obj('getOutLinkGeneralReq')['linkID'], 'Mobile123');
        return jsonResponse({
          'code': 0,
          'data': {
            'getOutLinkGeneralResp': {
              'outLinkGeneral': [
                {'lkName': 'fixture', 'passwd': 'old1'},
              ],
            },
          },
        });
      });
      final session = await C139Connector(
        http,
      ).openShare(LinkParser.parse(url).single, null);
      expect(session.meta('linkId'), 'Mobile123');
      expect(session.meta('password'), 'm123');
      expect(http.calls, hasLength(1));
    });
  }
}
