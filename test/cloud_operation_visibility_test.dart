import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/quark.dart';
import 'package:asterlink/data/providers/uc.dart';
import 'package:asterlink/data/providers/xunlei.dart';
import 'package:asterlink/data/providers/xunlei_protocol.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

void main() {
  for (final platform in [CloudPlatform.quark, CloudPlatform.uc]) {
    final session = BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: 'fixture',
      rootId: '0',
    );
    final credential = Credential('fixture', {'primary': '__pus=a; __puus=b'});
    const file = CloudFile(id: 'file', name: 'before', parentId: 'parent');
    CloudConnector connector(FakeHttp http) => platform == CloudPlatform.quark
        ? QuarkConnector(http, taskDelay: Duration.zero)
        : UcConnector(http, taskDelay: Duration.zero);
    HttpResult ok(Object data) =>
        jsonResponse({'status': 200, 'code': 0, 'data': data});

    test(
      '${platform.key} rename waits for directory indexing without resubmitting',
      () async {
        var lists = 0, mutations = 0;
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('/rename')) {
            mutations++;
            return ok({});
          }
          expect(r.uri.queryParameters['pdir_fid'], 'parent');
          lists++;
          return ok({
            'list': [
              {'fid': 'file', 'file_name': lists < 3 ? 'before' : 'after'},
            ],
          });
        });
        await connector(http).rename(session, file, 'after', credential);
        expect(mutations, 1);
        expect(lists, 3);
      },
    );

    test(
      '${platform.key} move awaits its task and every selected destination entry',
      () async {
        var lists = 0, polls = 0, mutations = 0;
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('/move')) {
            mutations++;
            return ok({'task_id': 'task', 'finish': false});
          }
          if (r.uri.path.endsWith('/task')) {
            polls++;
            return ok({'status': polls < 2 ? 1 : 2});
          }
          expect(polls, 2);
          expect(r.uri.queryParameters['pdir_fid'], 'target');
          lists++;
          return ok({
            'list': [
              {'fid': 'file'},
              if (lists > 1) {'fid': 'second'},
            ],
          });
        });
        await connector(http).move(
          session,
          [file, const CloudFile(id: 'second', name: 'two')],
          'target',
          credential,
        );
        expect(mutations, 1);
        expect(lists, 2);
        expect(polls, 2);
      },
    );

    test(
      '${platform.key} stalled indexing reports accepted status with a bounded wait',
      () async {
        var lists = 0, mutations = 0;
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('/rename')) {
            mutations++;
            return ok({});
          }
          lists++;
          return ok({
            'list': [
              {'fid': 'file', 'file_name': 'before'},
            ],
          });
        });
        await expectLater(
          connector(http).rename(session, file, 'after', credential),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              contains('已受理操作'),
            ),
          ),
        );
        expect(mutations, 1);
        expect(lists, 8);
      },
    );

    test(
      '${platform.key} cancelled visibility checks do not repeat mutations',
      () async {
        final scope = RequestScope();
        var mutations = 0, lists = 0;
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('/rename')) {
            mutations++;
            return ok({});
          }
          lists++;
          scope.cancel();
          return ok({'list': []});
        });
        await expectLater(
          scope.run(
            () => connector(http).rename(session, file, 'after', credential),
          ),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              contains('取消'),
            ),
          ),
        );
        expect(mutations, 1);
        expect(lists, 1);
      },
    );
  }

  for (final mode in ['delayed', 'stalled', 'cancelled', 'account_changed']) {
    test('Xunlei move confirms the destination: $mode', () async {
      final store = StateStore.memory(), scope = RequestScope();
      final vault = Vault(store);
      final c = Credential('fixture', {
        'primary': 'access',
        'deviceId': 'device',
      }, updatedAt: 1);
      await vault.putCredential(CloudPlatform.xunlei, c);
      var mutations = 0, lists = 0;
      final http = FakeHttp((r) async {
        if (r.uri.path.endsWith('files:batchMove')) {
          mutations++;
          expect(r.json['ids'], ['file', 'second']);
          expect(r.json.obj('to').str('parent_id'), 'target');
          return jsonResponse({});
        }
        expect(r.uri.queryParameters['parent_id'], 'target');
        lists++;
        if (mode == 'cancelled') scope.cancel();
        if (mode == 'account_changed') {
          await vault.putCredential(
            CloudPlatform.xunlei,
            Credential('replacement', {
              'primary': 'other',
              'deviceId': 'device',
            }, updatedAt: 2),
          );
        }
        return jsonResponse({
          'files': [
            {'id': 'file', 'name': 'one'},
            if (mode != 'stalled' && lists >= 3)
              {'id': 'second', 'name': 'two'},
          ],
        });
      });
      final connector = XunleiConnector(
        http,
        vault,
        XunleiDevices(vault),
        mutationDelay: Duration.zero,
      );
      final work = scope.run(
        () => connector.move(
          const BrowseSession(
            platform: CloudPlatform.xunlei,
            mode: BrowseMode.personal,
            title: 'fixture',
            rootId: '',
          ),
          const [
            CloudFile(id: 'file', name: 'one'),
            CloudFile(id: 'second', name: 'two'),
          ],
          'target',
          c,
        ),
      );
      if (mode == 'delayed') {
        await work;
        expect(lists, 3);
      } else {
        await expectLater(
          work,
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              contains(switch (mode) {
                'stalled' => '已受理移动',
                'cancelled' => '取消',
                _ => '账号已变化',
              }),
            ),
          ),
        );
        expect(lists, mode == 'stalled' ? 8 : 1);
      }
      expect(mutations, 1);
      store.dispose();
    });
  }
}
