import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/uc.dart';
import 'package:asterlink/data/providers/uc_tv.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/downloads_page.dart';
import 'package:asterlink/ui/uc_tv_authorization_page.dart';
import 'support.dart';
import 'uc_tv_support.dart';

const _file = CloudFile(id: 'video-1', name: '示例视频', size: 4, parentId: '0');
const _legacyError =
    'UC 返回的内容与所选文件不一致，可能受到外部播放或会员限制。请在 UC 账号菜单完成「TV 播放授权」后重新下载原文件';

class _Transfer extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(4, '"original"', null), false);
}

class _Fixture {
  _Fixture(
    this.root,
    this.api,
    this.services,
    this.native,
    this.id,
    this.ownerId,
  );
  final Directory root;
  final UcTvFixture api;
  final AppServices services;
  final FakeNative native;
  final String id, ownerId;
  DownloadTask get task => services.downloads.task(id)!;
  Credential get owner =>
      services.vault.credentialFor(CloudPlatform.uc, ownerId)!;

  static Future<_Fixture> render(
    WidgetTester tester, {
    bool legacy = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('aster-uc-download-auth-'),
    ))!;
    late UcTvFixture api;
    late FakeNative native;
    late AppServices services;
    var id = 'legacy-download';
    await tester.runAsync(() async {
      api = UcTvFixture(credential: ucTvCredential(authorized: false));
      api.respond = (request) {
        if (request.uri.path == '/1/clouddrive/file/sort') {
          return jsonResponse({
            'status': 200,
            'code': 0,
            'data': {
              'list': [
                {
                  'fid': _file.id,
                  'file_name': _file.name,
                  'size': 4,
                  'pdir_fid': '0',
                },
              ],
            },
          });
        }
        if (request.uri.path == '/1/clouddrive/file/download') {
          return jsonResponse({
            'status': 200,
            'code': 0,
            'data': [
              {
                'fid': _file.id,
                'file_name': _file.name,
                'size': 4,
                'md5': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'download_url': 'https://media.example/notice',
              },
            ],
          });
        }
        if (request.uri.path == '/file') return ucTvOriginal(size: 4);
        if (request.uri.host == 'media.example') {
          return request.uri.path == '/notice'
              ? const HttpResult(206, 'x', {
                  'content-range': ['bytes 0-0/2'],
                  'content-length': ['1'],
                })
              : const HttpResult(206, 'xx', {
                  'content-range': ['bytes 0-1/4'],
                  'content-length': ['2'],
                });
        }
        return null;
      };
      native = FakeNative();
      services = AppServices(
        store: api.store,
        dataDirectory: root,
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        transport: native,
        files: FakeFiles(Directory(p.join(root.path, 'saved'))),
        http: api.http,
        transferHttp: _Transfer(),
        controlEnabled: false,
        platformFeatures: false,
      );
      services.cloud.connectors[CloudPlatform.uc] = UcConnector(
        api.http,
        store: services.vault,
        now: () => api.now,
      );
      final planned = services.cloud.planDownload(ucTvPersonal, _file);
      if (legacy) {
        await services.store.change((data) {
          data['tasks'] = [
            DownloadTask(
              id: id,
              spec: planned,
              createdAt: 1,
              status: DownloadStatus.failed,
              error: _legacyError,
            ).toJson(),
          ];
        });
      }
      await services.downloads.initialize();
      if (!legacy) {
        id = await services.downloads.enqueue(planned);
        await until(
          () =>
              services.downloads.task(id)?.status == DownloadStatus.failed &&
              services.downloads.activeCount == 0,
        );
      }
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(body: DownloadsPage(services)),
      ),
    );
    await tester.pump();
    return _Fixture(
      root,
      api,
      services,
      native,
      id,
      services.vault.activeAccountId(CloudPlatform.uc)!,
    );
  }

  Future<void> tapAuthorize(WidgetTester tester) async {
    await tester.tap(find.byKey(ValueKey('download-authorize-$id')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 200 && !ready(); i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(ready(), isTrue);
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    Object? closeError;
    services.close().then(
      (_) => closed = true,
      onError: (Object error) {
        closeError = error;
        closed = true;
      },
    );
    await waitFor(tester, () => closed);
    if (closeError != null) throw closeError!;
    await tester.runAsync(() async {
      services.downloads.dispose();
      services.store.dispose();
      expect(p.isWithin(Directory.systemTemp.path, root.path), isTrue);
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'A failed ordinary download offers QR and resumes the same task after authorization',
    (tester) async {
      final f = await _Fixture.render(tester);
      try {
        expect(f.task.recoveryAction, DownloadRecoveryAction.ucAuthorization);
        expect(
          DownloadTask.fromJson(f.task.toJson()).needsUcAuthorization,
          isTrue,
        );
        expect(f.api.calls('/oauth/authorize'), isEmpty);
        expect(f.native.begins, isEmpty);
        await f.tapAuthorize(tester);
        expect(find.text('UC 下载授权'), findsOneWidget);
        expect(find.textContaining('Extscreen'), findsOneWidget);
        f.api.scanned = true;
        await f.waitFor(
          tester,
          () => f.task.status == DownloadStatus.completed,
        );
        expect(f.services.downloads.tasks, hasLength(1));
        expect(f.task.recoveryAction, DownloadRecoveryAction.none);
        expect(f.task.spec.fileName, _file.name);
        expect(f.owner.updatedAt, 7);
        expect(f.api.calls('/1/clouddrive/file/download'), hasLength(1));
        expect(
          f.api.calls('/file').single.uri.queryParameters['method'],
          'download',
        );
        expect(
          f.native.begins.single['url'],
          'https://media.example/original.mp4',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await f.close(tester);
      }
    },
  );

  testWidgets(
    'Legacy errors expose authorization in task details and cancellation does not retry',
    (tester) async {
      final f = await _Fixture.render(tester, legacy: true);
      try {
        expect(f.task.recoveryAction, DownloadRecoveryAction.none);
        expect(f.task.needsUcAuthorization, isTrue);
        await tester.tap(find.byKey(ValueKey('download-row-${f.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('授权并继续下载'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(UcTvAuthorizationPage), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(f.task.status, DownloadStatus.failed);
        expect(f.api.calls('/ucdrive/token'), isEmpty);
        expect(f.native.begins, isEmpty);
      } finally {
        await f.close(tester);
      }
    },
  );

  testWidgets(
    'Authorization follows the original download account when another UC account is selected',
    (tester) async {
      final f = await _Fixture.render(tester);
      try {
        final vault = f.services.vault;
        late String other;
        await tester.runAsync(() async {
          other = await vault.createAccount(CloudPlatform.uc);
          await vault.withAccount(
            CloudPlatform.uc,
            other,
            () => vault.putCredential(
              CloudPlatform.uc,
              ucTvCredential(authorized: false, revision: 99),
            ),
          );
          await vault.activate(CloudPlatform.uc, other);
        });
        await tester.pump();
        await f.tapAuthorize(tester);
        expect(
          tester
              .widget<UcTvAuthorizationPage>(find.byType(UcTvAuthorizationPage))
              .accountId,
          f.ownerId,
        );
        f.api.scanned = true;
        await f.waitFor(
          tester,
          () => f.task.status == DownloadStatus.completed,
        );
        expect(UcTvService.authorized(f.owner), isTrue);
        expect(
          UcTvService.authorized(vault.credentialFor(CloudPlatform.uc, other)),
          isFalse,
        );
        expect(vault.activeAccountId(CloudPlatform.uc), other);
      } finally {
        await f.close(tester);
      }
    },
  );

  testWidgets(
    'Authorization already completed in the account menu is used without another QR',
    (tester) async {
      final f = await _Fixture.render(tester);
      try {
        await tester.runAsync(
          () => f.services.vault.replaceCredential(
            CloudPlatform.uc,
            f.owner,
            ucTvCredential(),
          ),
        );
        await f.tapAuthorize(tester);
        await f.waitFor(
          tester,
          () => f.task.status == DownloadStatus.completed,
        );
        expect(f.api.calls('/oauth/authorize'), isEmpty);
        expect(f.api.calls('/file'), hasLength(1));
      } finally {
        await f.close(tester);
      }
    },
  );

  testWidgets(
    'Removing the original account does not authorize a different account or restart the task',
    (tester) async {
      final f = await _Fixture.render(tester);
      try {
        await tester.runAsync(
          () => f.services.vault.removeAccount(CloudPlatform.uc, f.ownerId),
        );
        await f.tapAuthorize(tester);
        expect(find.textContaining('原下载账号已退出或重新登录'), findsOneWidget);
        expect(f.api.calls('/oauth/authorize'), isEmpty);
        expect(f.task.status, DownloadStatus.failed);
      } finally {
        await f.close(tester);
      }
    },
  );

  test('Only failed UC tasks interpret the legacy authorization error', () {
    DownloadTask task(CloudPlatform platform, DownloadStatus status) =>
        DownloadTask(
          id: 'legacy',
          createdAt: 1,
          status: status,
          error: _legacyError,
          spec: DownloadSpec(
            url: '',
            fileName: _file.name,
            source: {'platform': platform.key},
          ),
        );
    expect(
      task(CloudPlatform.uc, DownloadStatus.failed).needsUcAuthorization,
      isTrue,
    );
    expect(
      task(CloudPlatform.quark, DownloadStatus.failed).needsUcAuthorization,
      isFalse,
    );
    expect(
      task(CloudPlatform.uc, DownloadStatus.completed).needsUcAuthorization,
      isFalse,
    );
    expect(
      task(CloudPlatform.uc, DownloadStatus.paused).needsUcAuthorization,
      isFalse,
    );
  });
}
