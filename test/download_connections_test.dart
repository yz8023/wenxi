import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/main.dart';
import 'support.dart';

class _ConnectionHttp extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(4, '"counts-fixture"', null), false);
}

class _ConnectionNative extends FakeNative {
  int active = 7;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    final result = await super.call(method, args);
    if (method != 'snapshot') return result;
    return {
      ...asJson(result),
      'activeConnections': active,
      'totalConnections': 16,
    };
  }
}

void main() {
  testWidgets(
    'Download rows and live details distinguish activity from the configured limit',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 864);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late AppServices services;
      late String id;
      final native = _ConnectionNative()..finish = false;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('aster-connection-ui-');
        services = AppServices(
          controlEnabled: false,
          store: StateStore.memory(),
          dataDirectory: Directory('${root.path}/state'),
          cacheDirectory: Directory('${root.path}/cache'),
          transport: native,
          files: FakeFiles(Directory('${root.path}/saved')),
          http: FakeHttp(),
          transferHttp: _ConnectionHttp(),
          platformFeatures: false,
        );
        await services.downloads.initialize();
        id = await services.downloads.enqueue(
          const DownloadSpec(
            url: 'https://example.com/connections',
            fileName: '连接数示例.bin',
            expectedSize: 4,
            source: {'platform': 'Quark'},
          ),
        );
        await until(() => services.downloads.httpConnections(id) != null);
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await services.close();
          await root.delete(recursive: true);
        });
      });
      await tester.pumpWidget(AsterLinkApp(services, initialTab: 2));
      await tester.pumpAndSettle();
      final badge = find.byKey(ValueKey('download-connections-$id'));
      expect(tester.widget<Text>(badge).data, '7 连接');
      await tester.tap(find.byKey(ValueKey('download-row-$id')));
      await tester.pumpAndSettle();
      expect(find.textContaining('工作连接 7 · 分段 16'), findsOneWidget);
      expect(find.textContaining('连接上限 512'), findsOneWidget);
      native.active = 3;
      await tester.runAsync(() async {
        await until(() => services.downloads.httpConnections(id)?.active == 3);
      });
      await tester.pump();
      expect(find.textContaining('工作连接 3 · 分段 16'), findsOneWidget);
      await tester.runAsync(() => services.downloads.pause(id));
      await tester.pumpAndSettle();
      expect(find.textContaining('工作连接'), findsNothing);
      expect(find.textContaining('连接上限 512'), findsOneWidget);
      expect(tester.widget<Text>(badge).data, 'HTTP');
      expect(tester.takeException(), isNull);
    },
  );
}
