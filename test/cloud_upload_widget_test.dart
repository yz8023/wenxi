import 'dart:async';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/ui/cloud_upload_dialog.dart';
import 'support.dart';

class _UploadConnector extends CloudConnector {
  @override
  CloudPlatform get platform => CloudPlatform.quark;
  final started = <String>[], finished = <String>[];
  Completer<void>? release;
  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async => [const CloudFile(id: 'old', name: 'existing.txt', size: 3)];
  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    started.add(source.name);
    onProgress?.call(UploadProgress(UploadPhase.uploading, 1, source.size));
    if (release != null) await RequestScope.cancellable(release!.future);
    expect(await source.openRead().expand((c) => c).toList(), [1, 2, 3]);
    finished.add(source.name);
    return CloudFile(
      id: source.name,
      name: source.name,
      size: source.size,
      parentId: parent,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _session = BrowseSession(
  platform: CloudPlatform.quark,
  mode: BrowseMode.personal,
  title: 'files',
  rootId: '0',
);
XFile _file(String name) => XFile.fromData(
  Uint8List.fromList([1, 2, 3]),
  path: name,
  lastModified: DateTime.utc(2026, 9, 25),
);

Future<(Vault, _UploadConnector)> _render(
  WidgetTester tester,
  List<String> names, {
  bool waiting = false,
}) async {
  final store = StateStore.memory(),
      http = FakeHttp(),
      provider = _UploadConnector();
  if (waiting) provider.release = Completer<void>();
  final vault = Vault(store);
  await vault.putCredential(
    CloudPlatform.quark,
    Credential('fixture', {'primary': 'fixture'}, updatedAt: 1),
  );
  final repository = CloudRepository(http, vault, CleanupOutbox(store, http));
  repository.connectors[CloudPlatform.quark] = provider;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(393, 864);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => CloudUploadDialog(
                cloud: repository,
                session: repository.bindSession(_session),
                parent: '0',
                files: names.map(_file).toList(),
              ),
            ),
            child: const Text('upload'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('upload'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return (vault, provider);
}

void main() {
  testWidgets(
    'Upload dialog reports individual conflicts and continues the remaining files',
    (tester) async {
      final (_, provider) = await _render(tester, [
        'first.txt',
        'existing.txt',
        'last.txt',
      ]);
      await tester.pumpAndSettle();
      expect(provider.finished, ['first.txt', 'last.txt']);
      expect(find.text('成功上传 2 个文件'), findsOneWidget);
      expect(find.textContaining('目录中已有同名项目'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.byType(CloudUploadDialog), findsNothing);
    },
  );
  testWidgets(
    'Cancelling the upload stops the active file and skips the rest',
    (tester) async {
      final (_, provider) = await _render(tester, [
        'first.txt',
        'last.txt',
      ], waiting: true);
      expect(find.text('正在上传'), findsOneWidget);
      await tester.tap(find.text('取消上传'));
      await tester.pumpAndSettle();
      expect(find.text('上传已取消'), findsOneWidget);
      expect(provider.started, ['first.txt']);
      expect(provider.finished, isEmpty);
      expect(find.text('成功上传 0 个文件'), findsOneWidget);
      provider.release!.complete();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Replacing the account stops the batch and preserves a visible failure',
    (tester) async {
      final (vault, provider) = await _render(tester, [
        'first.txt',
        'last.txt',
      ], waiting: true);
      await vault.putCredential(
        CloudPlatform.quark,
        Credential('changed', {'primary': 'new'}, updatedAt: 2),
      );
      provider.release!.complete();
      await tester.pumpAndSettle();
      expect(provider.started, ['first.txt']);
      expect(provider.finished, isEmpty);
      expect(find.textContaining('账号已变化'), findsOneWidget);
      expect(find.text('成功上传 0 个文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
