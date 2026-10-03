import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/ui/preview_page.dart';
import 'browser_test_support.dart';
import 'support.dart';

class _ImageConnector extends BrowserTestConnector {
  _ImageConnector(this.bytes) : super(CloudPlatform.quark);
  final Uint8List bytes;

  @override
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async => DownloadSpec(
    url: 'https://preview.example.test/full.png',
    fileName: file.name,
    expectedSize: bytes.length,
    profile: 'quark_route_2',
  );
}

class _ImageTransfer extends TransferHttp {
  _ImageTransfer(this.bytes, {this.hold = false});
  final Uint8List bytes;
  final bool hold;
  final requests = <({String? range, CancelToken token})>[];

  @override
  Future<Response<ResponseBody>> stream(
    String url,
    Map<String, String> h, {
    CancelToken? cancel,
  }) async {
    requests.add((range: h['Range'], token: cancel!));
    if (hold && h['Range'] != 'bytes=0-0') {
      await cancel.whenCancel;
      throw cancel.cancelError!;
    }
    final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(h['Range'] ?? '');
    final first = match == null ? 0 : int.parse(match[1]!);
    final last = match == null ? bytes.length - 1 : int.parse(match[2]!);
    final headers = {
      'etag': ['"preview-v1"'],
      'content-length': ['${last - first + 1}'],
      if (match != null)
        'content-range': ['bytes $first-$last/${bytes.length}'],
    };
    return Response(
      requestOptions: RequestOptions(path: url),
      statusCode: match == null ? 200 : 206,
      headers: Headers.fromMap(headers),
      data: ResponseBody.fromBytes(
        Uint8List.sublistView(bytes, first, last + 1),
        match == null ? 200 : 206,
        headers: headers,
      ),
    );
  }
}

Future<Uint8List> _largePng() async {
  // A real, decodable image larger than 1 MiB, with no trailing padding.
  final random = Random(57);
  final pixels = Uint8List.fromList(
    List.generate(768 * 768 * 4, (_) => random.nextInt(256)),
  );
  final ready = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    768,
    768,
    ui.PixelFormat.rgba8888,
    ready.complete,
  );
  final image = await ready.future;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List bytes;
  setUpAll(() async {
    bytes = await _largePng();
    expect(bytes.length, greaterThan(1024 * 1024));
  });

  Future<AppServices> servicesFor(
    _ImageTransfer transfer,
    int connections,
  ) async {
    final directory = Directory.systemTemp.createTempSync('asterlink-preview-');
    final services = AppServices(
      controlEnabled: false,
      store: StateStore.memory({
        'settings': {
          'downloadThreadOverrides': {
            'quark_route_1': 8,
            'quark_route_2': connections,
          },
        },
        'credentials': {
          'Quark': Credential('preview test', {
            'primary': 'local-cookie',
          }, updatedAt: 1).toJson(),
        },
      }),
      dataDirectory: directory,
      cacheDirectory: Directory('${directory.path}/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('${directory.path}/saved')),
      platformFeatures: false,
      http: FakeHttp(),
      transferHttp: transfer,
    );
    services.cloud.connectors[CloudPlatform.quark] = _ImageConnector(bytes);
    await services.initialize();
    addTearDown(() {
      transfer.dio.close(force: true);
      directory.deleteSync(recursive: true);
    });
    return services;
  }

  Widget page(AppServices services) => MaterialApp(
    home: PreviewPage(
      services,
      const BrowseSession(
        platform: CloudPlatform.quark,
        mode: BrowseMode.personal,
        title: 'preview test',
        rootId: 'root',
      ),
      CloudFile(id: 'image', name: 'full.png', size: bytes.length),
    ),
  );

  for (final connections in [1, 3]) {
    testWidgets(
      'image page follows selected route budget $connections and renders',
      (tester) async {
        final transfer = _ImageTransfer(bytes);
        final services = await servicesFor(transfer, connections);
        try {
          await tester.pumpWidget(page(services));
          await tester.pump();
          expect(find.byType(Image), findsOneWidget);
          expect(
            transfer.requests,
            hasLength(connections == 1 ? 1 : connections + 1),
          );
          final provider = tester.widget<Image>(find.byType(Image)).image;
          final memory = (provider as ResizeImage).imageProvider as MemoryImage;
          expect(sha256.convert(memory.bytes), sha256.convert(bytes));
          // Advance both the native codec and the widget test's microtasks.
          for (
            var i = 0;
            i < 50 &&
                tester.widget<RawImage>(find.byType(RawImage)).image == null;
            i++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump();
          }
          expect(
            tester.widget<RawImage>(find.byType(RawImage)).image,
            isNotNull,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          // Close gates in the widget test's zone, before fake time is stopped.
          await services.close();
        }
      },
    );
  }

  testWidgets('closing the image page cancels every unfinished range', (
    tester,
  ) async {
    final transfer = _ImageTransfer(bytes, hold: true);
    final services = await servicesFor(transfer, 3);
    try {
      await tester.pumpWidget(page(services));
      await tester.pump();
      expect(transfer.requests, hasLength(4));
      expect(
        transfer.requests.skip(1).every((r) => !r.token.isCancelled),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(transfer.requests.every((r) => r.token.isCancelled), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await services.close();
    }
  });
}
