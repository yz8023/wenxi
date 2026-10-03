import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

HttpResult _ok(Object data) =>
    jsonResponse({'status': 200, 'code': 0, 'data': data});

HttpResult _notShared() => jsonResponse({
  'status': 400,
  'code': 41017,
  'message': '文件没有被分享:[{0}]',
}, 400);

class _Fixture {
  _Fixture({this.platform = CloudPlatform.quark, this.root = '0'}) {
    final stamp = '${DateTime.now().millisecondsSinceEpoch}';
    account = Credential('fixture', {
      'primary': '__pus=fixture-account; __puus=fixture-session',
      'quarkSessionRefreshedAt': stamp,
      'ucSessionRefreshedAt': stamp,
    }, updatedAt: 42);
    store = StateStore.memory({
      'credentials': {platform.key: account.toJson()},
    });
    vault = Vault(store);
    http = FakeHttp(reply);
    repository = CloudRepository(http, vault, CleanupOutbox(store, http));
  }

  final CloudPlatform platform;
  final String root;
  late final Credential account;
  late final StateStore store;
  late final Vault vault;
  late final FakeHttp http;
  late final CloudRepository repository;
  int generation = 0, directories = 0;
  String rootFileId = 'shared-file';
  int rootFileSize = 4;
  bool rootUnavailable = false;
  AppException? outsideError;
  final tasks = <String, String>{};

  ParsedLink get link => ParsedLink(
    source:
        'https://${platform == CloudPlatform.quark ? 'pan.quark.cn' : 'drive.uc.cn'}/s/fixture',
    url:
        'https://${platform == CloudPlatform.quark ? 'pan.quark.cn' : 'drive.uc.cn'}/s/fixture',
    kind: LinkKind.cloudShare,
    platform: platform,
    shareId: 'fixture',
  );

  List<RecordedRequest> calls(String suffix) =>
      http.calls.where((r) => r.uri.path.endsWith(suffix)).toList();

  List<String> get shareParents => http.calls
      .where((r) => r.uri.path.endsWith('/detail'))
      .map((r) => r.uri.queryParameters['pdir_fid']!)
      .toList();

  HttpResult reply(RecordedRequest r) {
    switch (r.uri.path) {
      case '/1/clouddrive/config':
        return _ok({});
      case '/1/clouddrive/share/sharepage/token':
        return _ok({
          'first_fid': root,
          'stoken': 'share-token-${++generation}',
        });
      case '/1/clouddrive/share/sharepage/detail':
      case '/1/clouddrive/transfer_share/detail':
        final parent = r.uri.queryParameters['pdir_fid'];
        if (parent == 'owner-only-folder') {
          if (outsideError != null) throw outsideError!;
          return _notShared();
        }
        if (parent == '0' && rootUnavailable) return _notShared();
        if (parent != '0' && parent != 'shared-folder') {
          throw StateError('Unexpected share directory');
        }
        return _ok({
          'list': [
            {
              'fid': parent == '0' ? rootFileId : 'nested-file',
              'file_name': 'fixture.bin',
              'size': parent == '0' ? rootFileSize : 4,
              // Root entries retain their owner's unshared physical parent.
              'pdir_fid': parent == '0' ? 'owner-only-folder' : parent,
              'share_fid_token': 'file-token-$generation',
              'dir': false,
            },
            if (parent == '0')
              {
                'fid': 'shared-folder',
                'file_name': 'folder',
                'pdir_fid': 'owner-only-folder',
                'share_fid_token': 'folder-token-$generation',
                'dir': true,
              },
          ],
        });
      case '/1/clouddrive/file/sort':
        return _ok({
          'list': [
            {
              'fid': 'temporary-base',
              'file_name': '文析助手临时转存',
              'pdir_fid': 'personal-parent',
              'dir': true,
            },
          ],
        });
      case '/1/clouddrive/file':
        return _ok({'fid': 'temporary-${++directories}'});
      case '/1/clouddrive/share/sharepage/save':
        final id = 'task-${tasks.length + 1}';
        tasks[id] = 'saved-${r.json['fid_list'][0]}-$directories';
        return _ok({'task_id': id});
      case '/1/clouddrive/task':
        return _ok({
          'status': 2,
          'save_as': {
            'save_as_top_fids': [tasks[r.uri.queryParameters['task_id']]],
          },
        });
      case '/1/clouddrive/file/download':
        final fid = r.json['fids'][0] as String;
        return _ok([
          {'fid': fid, 'size': 4, 'download_url': 'https://cdn.example/$fid'},
        ]);
      case '/1/clouddrive/file/delete':
        return _ok({});
      default:
        throw StateError('Unexpected fixture request ${r.uri.path}');
    }
  }

  Future<DownloadSpec> legacyPlan() async {
    final session = await repository.share(link);
    return repository.planDownload(
      session,
      const CloudFile(
        id: 'shared-file',
        name: 'fixture.bin',
        parentId: 'owner-only-folder',
        token: 'old-file-token',
        size: 4,
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final platform in [CloudPlatform.quark, CloudPlatform.uc]) {
    for (final root in ['0', '']) {
      test(
        '${platform.key} share entries retain the browsed root ($root)',
        () async {
          final f = _Fixture(platform: platform, root: root);
          final session = await f.repository.share(f.link);
          final files = await f.repository.list(session, session.rootId);
          expect(files, hasLength(2));
          expect(files.map((file) => file.parentId), everyElement('0'));
          expect(files.first.id, 'shared-file');
          expect(files.first.token, 'file-token-1');
        },
      );
    }

    test('${platform.key} personal entries retain the API parent', () async {
      final f = _Fixture(platform: platform);
      final session = await f.repository.personal(platform);
      final files = await f.repository.list(session, session.rootId);
      expect(files.single.parentId, 'personal-parent');
    });
  }

  for (final root in ['0', '']) {
    test(
      'A queued Quark root download restores the share and fresh tokens ($root)',
      () async {
        final f = _Fixture(root: root);
        final session = await f.repository.share(f.link);
        final file = (await f.repository.list(session, session.rootId)).first;
        final planned = f.repository.planDownload(session, file);
        final source = DownloadOrigin.fromJson(planned.source!);
        final restoredPlan = planned.copyWith(source: source.toJson());
        final downloaded = await f.repository.refresh(restoredPlan);
        expect(downloaded.needsPreparation, isFalse);
        expect(downloaded.expectedSize, 4);
        expect(downloaded.cleanup, isNotNull);
        expect(f.shareParents, ['0', '0']);
        final save = f.calls('/share/sharepage/save').single.json;
        expect(save['pdir_fid'], '0');
        expect(save['fid_list'], ['shared-file']);
        expect(save['fid_token_list'], ['file-token-2']);
        expect(save['stoken'], 'share-token-2');
        expect(f.calls('/file/download').single.json['fids'], [
          'saved-shared-file-1',
        ]);
      },
    );
  }

  test(
    'A nested Quark download restores only its shared subdirectory',
    () async {
      final f = _Fixture();
      final session = await f.repository.share(f.link);
      final file = (await f.repository.list(session, 'shared-folder')).single;
      final source = await f.repository.refresh(
        f.repository.planDownload(session, file),
      );
      expect(source.needsPreparation, isFalse);
      expect(f.shareParents, ['shared-folder', 'shared-folder']);
      expect(
        f.calls('/share/sharepage/save').single.json['pdir_fid'],
        'shared-folder',
      );
      expect(f.calls('/share/sharepage/save').single.json['fid_list'], [
        'nested-file',
      ]);
    },
  );

  test(
    'An old failed Quark root task is repaired and persists the correct parent',
    () async {
      final f = _Fixture();
      final source = await f.repository.refresh(await f.legacyPlan());
      expect(source.needsPreparation, isFalse);
      expect(f.shareParents, ['owner-only-folder', '0']);
      final origin = DownloadOrigin.fromJson(source.source!);
      expect(origin.file.id, 'shared-file');
      expect(origin.file.parentId, '0');
      expect(origin.file.token, 'file-token-2');
      final refreshed = await f.repository.refresh(source);
      expect(f.shareParents, ['owner-only-folder', '0', '0']);
      expect(DownloadOrigin.fromJson(refreshed.source!).file.parentId, '0');
    },
  );

  test(
    'Legacy fallback requires the original file ID even when names match',
    () async {
      final f = _Fixture()..rootFileId = 'another-file';
      await expectLater(
        f.repository.refresh(await f.legacyPlan()),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('文件没有被分享'),
          ),
        ),
      );
      expect(f.shareParents, ['owner-only-folder', '0']);
      expect(f.calls('/share/sharepage/save'), isEmpty);
    },
  );

  test(
    'Legacy fallback retains source-content validation before transferring',
    () async {
      final f = _Fixture()..rootFileSize = 5;
      await expectLater(
        f.repository.refresh(await f.legacyPlan()),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('内容已变化'),
          ),
        ),
      );
      expect(f.shareParents, ['owner-only-folder', '0']);
      expect(f.calls('/share/sharepage/save'), isEmpty);
    },
  );

  for (final error in [
    const AppException('网络暂时不可用'),
    const AccountLoginRequired('请重新登录'),
    const AppException('请求已取消'),
  ]) {
    test('Legacy fallback does not hide ${error.message}', () async {
      final f = _Fixture()..outsideError = error;
      await expectLater(
        f.repository.refresh(await f.legacyPlan()),
        throwsA(same(error)),
      );
      expect(f.shareParents, ['owner-only-folder']);
      expect(f.calls('/share/sharepage/save'), isEmpty);
    });
  }

  test(
    'An unavailable share root is not repeatedly retried or transferred',
    () async {
      final f = _Fixture()..rootUnavailable = true;
      final session = await f.repository.share(f.link);
      final planned = f.repository.planDownload(
        session,
        const CloudFile(
          id: 'shared-file',
          name: 'fixture.bin',
          parentId: '0',
          size: 4,
        ),
      );
      await expectLater(
        f.repository.refresh(planned),
        throwsA(isA<AppException>()),
      );
      expect(f.shareParents, ['0']);
      expect(f.calls('/share/sharepage/save'), isEmpty);
    },
  );
}
