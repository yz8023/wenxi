import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/cloud_thumbnail.dart';
import 'package:asterlink/ui/cloud_thumbnail_image.dart';

class _Headers implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = '$value';
  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(
    this.statusCode, {
    this.bytes = const [1, 2, 3],
    String? location,
    this.reportedLength,
  }) {
    if (location != null) headers.set('location', location);
  }
  @override
  final int statusCode;
  final List<int> bytes;
  final int? reportedLength;
  @override
  final _Headers headers = _Headers();
  @override
  int get contentLength => reportedLength ?? bytes.length;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.uri, this.response);
  @override
  final Uri uri;
  final _Response response;
  @override
  final _Headers headers = _Headers();
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  _Client(this.responses);
  final List<_Response> responses;
  final requests = <_Request>[];
  bool closed = false;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    final r = _Request(uri, responses[requests.length]);
    requests.add(r);
    return r;
  }

  @override
  void close({bool force = false}) => closed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageHttp extends HttpOverrides {
  _ImageHttp(this.client);
  final HttpClient client;
  @override
  HttpClient createHttpClient(SecurityContext? context) => client;
}

Credential _account([
  String cookie = '__pus=fixture; __puus=fixture',
  int revision = 1,
]) => Credential('fixture', {'primary': cookie}, updatedAt: revision);
final _quark = Uri.parse(
  'https://drive-pc.quark.cn/1/clouddrive/file/video/thumbnail?fid=test',
);

void main() {
  testWidgets('Protected thumbnails decode through the actual resized widget', (
    tester,
  ) async {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final client = _Client([_Response(200, bytes: png)]);
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CloudThumbnail(
              CloudFile(
                id: 'fixture',
                name: 'fixture.mp4',
                thumbnailUrl: _quark.toString(),
              ),
              CloudPlatform.quark,
              credential: _account(),
              large: true,
            ),
          ),
        ),
      );
      final errors = <Object>[];
      final stream = tester
          .widget<Image>(find.byType(Image))
          .image
          .resolve(const ImageConfiguration());
      final listener = ImageStreamListener(
        (_, _) {},
        onError: (Object error, StackTrace? stack) {
          errors.add(error);
          if (stack != null) errors.add(stack);
        },
      );
      stream.addListener(listener);
      for (
        var attempt = 0;
        attempt < 50 && find.byType(RawImage).evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      stream.removeListener(listener);
      expect(errors, isEmpty);
    }, _ImageHttp(client));
    expect(client.requests, hasLength(1));
    expect(client.closed, isTrue);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(client.requests.single.headers.value('cookie'), _account().primary);
    expect(client.closed, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'Both official thumbnail endpoints get only their own account cookie',
    () async {
      for (final (platform, host) in [
        (CloudPlatform.quark, 'drive-pc.quark.cn'),
        (CloudPlatform.uc, 'pc-api.uc.cn'),
      ]) {
        final uri = Uri.parse(
          'https://$host/1/clouddrive/file/video/thumbnail?fid=test',
        );
        final client = _Client([_Response(200)]);
        final result = await CloudThumbnailImage(
          uri,
          platform,
          _account(),
        ).loadBytes(client: client);
        expect(result, [1, 2, 3]);
        expect(client.closed, isTrue);
        expect(client.requests.single.followRedirects, isFalse);
        expect(
          client.requests.single.headers.value('cookie'),
          _account().primary,
        );
        expect(
          client.requests.single.headers.values.keys,
          unorderedEquals(['user-agent', 'referer', 'cookie']),
        );
      }
    },
  );
  test(
    'Untrusted hosts, ports, paths, platforms and HTTP never receive cookies',
    () async {
      for (final raw in [
        'http://drive-pc.quark.cn/1/clouddrive/file/video/thumbnail',
        'https://drive-pc.quark.cn.evil.test/1/clouddrive/file/video/thumbnail',
        'https://sub.drive-pc.quark.cn/1/clouddrive/file/video/thumbnail',
        'https://drive-pc.quark.cn:8443/1/clouddrive/file/video/thumbnail',
        'https://user:secret@drive-pc.quark.cn/1/clouddrive/file/video/thumbnail',
        'https://drive-pc.quark.cn/other',
        'https://pc-api.uc.cn/1/clouddrive/file/video/thumbnail',
      ]) {
        final uri = Uri.parse(raw), client = _Client([]);
        expect(
          CloudThumbnailImage.requiresAccount(uri, CloudPlatform.quark),
          isFalse,
        );
        await expectLater(
          CloudThumbnailImage(
            uri,
            CloudPlatform.quark,
            _account(),
          ).loadBytes(client: client),
          throwsA(isA<HttpException>()),
        );
        expect(client.requests, isEmpty);
      }
      expect(
        CloudThumbnailImage.requiresAccount(_quark, CloudPlatform.tianyi),
        isFalse,
      );
    },
  );
  test(
    'CDN redirects drop cookies, including a later return to the API origin',
    () async {
      final client = _Client([
        _Response(302, location: 'https://cdn.example.test/thumb'),
        _Response(302, location: _quark.toString()),
        _Response(200),
      ]);
      await CloudThumbnailImage(
        _quark,
        CloudPlatform.quark,
        _account(),
      ).loadBytes(client: client);
      expect(client.requests[0].headers.value('cookie'), isNotNull);
      expect(client.requests[1].headers.value('cookie'), isNull);
      expect(client.requests[2].headers.value('cookie'), isNull);
      expect(client.closed, isTrue);
    },
  );
  test(
    'Thumbnail redirects reject downgrade and embedded credentials',
    () async {
      for (final next in [
        'http://cdn.example.test/thumb',
        'https://user:secret@cdn.example.test/thumb',
        'file:///tmp/thumb',
      ]) {
        final client = _Client([_Response(302, location: next)]);
        await expectLater(
          CloudThumbnailImage(
            _quark,
            CloudPlatform.quark,
            _account(),
          ).loadBytes(client: client),
          throwsA(isA<HttpException>()),
        );
        expect(client.requests, hasLength(1));
        expect(client.closed, isTrue);
      }
    },
  );
  test(
    'Oversized, empty and rejected thumbnails close the transport',
    () async {
      for (final response in [
        _Response(401),
        _Response(200, bytes: const []),
        _Response(200, reportedLength: CloudThumbnailImage.maxBytes + 1),
        _Response(
          200,
          bytes: List.filled(CloudThumbnailImage.maxBytes + 1, 1),
          reportedLength: -1,
        ),
      ]) {
        final client = _Client([response]);
        await expectLater(
          CloudThumbnailImage(
            _quark,
            CloudPlatform.quark,
            _account(),
          ).loadBytes(client: client),
          throwsA(isA<HttpException>()),
        );
        expect(client.closed, isTrue);
      }
    },
  );
  test(
    'Image cache keys change on account replacement and session refresh',
    () {
      final original = CloudThumbnailImage(
        _quark,
        CloudPlatform.quark,
        _account(),
      );
      expect(
        original,
        CloudThumbnailImage(_quark, CloudPlatform.quark, _account()),
      );
      expect(
        original,
        isNot(
          CloudThumbnailImage(
            _quark,
            CloudPlatform.quark,
            _account('changed', 1),
          ),
        ),
      );
      expect(
        original,
        isNot(
          CloudThumbnailImage(
            _quark,
            CloudPlatform.quark,
            _account(_account().primary, 2),
          ),
        ),
      );
      expect(original.toString(), isNot(contains('fixture')));
      expect(original.toString(), isNot(contains('fid=')));
    },
  );
}
