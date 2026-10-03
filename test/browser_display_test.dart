import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/cloud_thumbnail.dart';
import 'package:asterlink/ui/common.dart';
import 'package:asterlink/ui/downloads_page.dart';
import 'browser_test_support.dart';
import 'support.dart';

class _WaitingDownloadConnector extends BrowserTestConnector {
  _WaitingDownloadConnector() : super(CloudPlatform.tianyi);
  int preparing = 0;
  @override
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    preparing++;
    await RequestScope.wait(const Duration(hours: 1));
    throw const AppException('fixture did not release its download');
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late ThumbnailHttpClient images;
  final active = <BrowserUiFixture>[];
  void browserTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      debugNetworkImageHttpClientProvider = () => images;
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final value in active) {
          await value.close();
        }
        active.clear();
        debugNetworkImageHttpClientProvider = null;
      }
    });
  }

  setUp(() {
    images = ThumbnailHttpClient();
    binding.imageCache.clear();
    binding.imageCache.clearLiveImages();
  });
  tearDown(() {
    debugNetworkImageHttpClientProvider = null;
  });
  Future<BrowserUiFixture> fixture(
    WidgetTester tester, {
    CloudPlatform platform = CloudPlatform.tianyi,
    String view = 'list',
  }) async {
    final value = await BrowserUiFixture.create(platform: platform, view: view);
    active.add(value);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    return value;
  }

  Future<void> setView(WidgetTester tester, String name) async {
    await tester.tap(find.byTooltip('显示方式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Future<void> chooseFamily(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(const ValueKey('family-space')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
  }

  browserTest(
    'Batch download returns to browsing while links prepare in independent queue rows',
    (tester) async {
      final value = await fixture(tester);
      final connector = _WaitingDownloadConnector();
      value.services.cloud.connectors[CloudPlatform.tianyi] = connector;
      await value.render(tester, size: const Size(1100, 780));
      for (final name in ['使用说明.txt', '02 旅行视频.mp4']) {
        final row = find.ancestor(
          of: find.text(name),
          matching: find.byType(ListTile),
        );
        await tester.tap(
          find.descendant(of: row, matching: find.byType(Checkbox)),
        );
        await tester.pump();
      }
      await tester.tap(find.text('下载'));
      await tester.runAsync(() => until(() => connector.preparing == 2));
      await tester.pumpAndSettle();
      expect(find.text('正在添加下载任务…'), findsNothing);
      expect(find.text('已添加 2 个下载任务'), findsOneWidget);
      expect(value.services.downloads.tasks, hasLength(2));
      expect(
        value.services.downloads.tasks.every(
          (task) => task.spec.needsPreparation,
        ),
        isTrue,
      );
      expect(find.text('已选 2 项'), findsNothing);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: DownloadsPage(value.services))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('02 旅行视频.mp4'));
      await tester.pumpAndSettle();
      final copy = find.ancestor(
        of: find.text('复制下载链接'),
        matching: find.byType(ListTile),
      );
      expect(tester.widget<ListTile>(copy).enabled, isFalse);
      expect(find.byKey(const Key('download-stream-play')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'Grid selection and sorting survive display changes and the preference reopens',
    (tester) async {
      final value = await fixture(tester);
      await value.render(tester);
      expect(find.byType(GridView), findsNothing);
      await setView(tester, '大图标');
      expect(find.byType(GridView), findsOneWidget);
      expect(value.services.settings.browserView, 'grid');
      final folderPosition = tester.getTopLeft(find.text('假期相册'));
      final photoPosition = tester.getTopLeft(find.text('01 海边照片.jpg'));
      expect(folderPosition.dy, lessThan(photoPosition.dy));
      await tester.longPress(find.text('01 海边照片.jpg'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      await setView(tester, '列表');
      expect(find.text('已选 1 项'), findsOneWidget);
      expect(find.byType(GridView), findsNothing);
      await tester.tap(find.byTooltip('取消选择'));
      await setView(tester, '大图标');
      await tester.tap(find.byTooltip('排序'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('大小'));
      await tester.pumpAndSettle();
      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(grid.semanticChildCount, 6);
      await tester.pumpWidget(const SizedBox.shrink());
      await value.render(tester);
      expect(find.byType(GridView), findsOneWidget);
      expect(find.text('已选 1 项'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final platform in [CloudPlatform.tianyi, CloudPlatform.c139]) {
    browserTest(
      '${platform.name} space switching clears old folder, search and selection',
      (tester) async {
        final value = await fixture(tester, platform: platform, view: 'grid');
        await value.render(tester);
        await tester.tap(find.text('假期相册'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '旧目录');
        await tester.longPress(find.text('旧目录视频.mp4'));
        await tester.pumpAndSettle();
        expect(find.text('已选 1 项'), findsOneWidget);
        await chooseFamily(tester, '家人的云盘');
        expect(value.connector.reads.last, (
          '12002',
          platform == CloudPlatform.tianyi ? '' : 'root-12002',
        ));
        expect(find.text('已选 1 项'), findsNothing);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        expect(find.text('旧目录视频.mp4'), findsNothing);
        expect(find.byTooltip('新建文件夹'), findsNothing);
        await tester.tap(find.byTooltip('02 旅行视频.mp4操作'));
        await tester.pumpAndSettle();
        expect(find.text('重命名'), findsNothing);
        expect(find.text('删除'), findsNothing);
        expect(find.text('创建分享'), findsNothing);
        expect(find.text('复制下载链接'), findsOneWidget);
        expect(find.text('预览 / 文件详情'), findsOneWidget);
        Navigator.of(tester.element(find.text('复制下载链接'))).pop();
        await tester.pumpAndSettle();
        await chooseFamily(tester, '周末相册');
        expect(value.connector.reads.last.$1, '12001');
        await tester.tap(find.byKey(const ValueKey('personal-space')));
        await tester.pumpAndSettle();
        expect(value.connector.reads.last, ('', 'personal-root'));
        expect(find.byType(GridView), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  browserTest('No-family and failed discovery keep the current directory', (
    tester,
  ) async {
    final value = await fixture(tester);
    await value.render(tester);
    await tester.tap(find.text('假期相册'));
    await tester.pumpAndSettle();
    value.connector.spaces = [];
    await tester.tap(find.byKey(const ValueKey('family-space')));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前账号还没有家庭云'), findsOneWidget);
    expect(find.text('旧目录视频.mp4'), findsOneWidget);
    value.connector.familyFailure = const AppException('家庭云暂时不可用');
    await tester.tap(find.byKey(const ValueKey('family-space')));
    await tester.pumpAndSettle();
    expect(find.text('旧目录视频.mp4'), findsOneWidget);
    expect(value.connector.reads.last, ('', 'photos'));
    expect(tester.takeException(), isNull);
  });

  browserTest(
    'A late folder response cannot overwrite the newly selected family',
    (tester) async {
      final value = await fixture(tester);
      await value.render(tester);
      final pending = value.connector.pendingFolder =
          Completer<List<CloudFile>>();
      await tester.tap(find.text('假期相册'));
      await tester.pump();
      await chooseFamily(tester, '周末相册');
      pending.complete([const CloudFile(id: 'stale', name: '过期目录结果.txt')]);
      await tester.pumpAndSettle();
      expect(find.text('过期目录结果.txt'), findsNothing);
      expect(find.text('周末相册'), findsOneWidget);
      expect(find.text('01 海边照片.jpg'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'Folder picking remains in the supplied family and hides view and space switches',
    (tester) async {
      final value = await fixture(tester, view: 'grid');
      final session = value.connector.familySession(
        value.connector.spaces.first,
      );
      await value.render(tester, session: session, picking: true);
      expect(find.byTooltip('显示方式'), findsNothing);
      expect(find.byKey(const ValueKey('personal-space')), findsNothing);
      expect(find.byKey(const ValueKey('family-space')), findsNothing);
      expect(find.byType(GridView), findsNothing);
      expect(find.text('01 海边照片.jpg'), findsNothing);
      expect(find.text('假期相册'), findsOneWidget);
      expect(value.connector.reads.last.$1, '12001');
      expect(find.text('选择“全部文件”'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'Thumbnails decode images and video covers without credentials and safely fall back',
    (tester) async {
      const files = [
        CloudFile(
          id: 'image',
          name: '照片.jpg',
          thumbnailUrl: 'https://preview.example.test/photo.png',
        ),
        CloudFile(
          id: 'video',
          name: '视频.mp4',
          thumbnailUrl: 'https://preview.example.test/video.png',
        ),
        CloudFile(
          id: 'broken',
          name: '失败.jpg',
          thumbnailUrl: 'https://preview.example.test/broken.png',
        ),
        CloudFile(
          id: 'document',
          name: '文件.txt',
          thumbnailUrl: 'https://preview.example.test/original.txt',
        ),
        CloudFile(
          id: 'folder',
          name: '目录.jpg',
          isDirectory: true,
          thumbnailUrl: 'https://preview.example.test/folder.png',
        ),
        CloudFile(
          id: 'local',
          name: '本地.jpg',
          thumbnailUrl: 'file:///private/photo.jpg',
        ),
        CloudFile(
          id: 'secret',
          name: '凭据.jpg',
          thumbnailUrl: 'https://user:secret@preview.example.test/photo.png',
        ),
        CloudFile(
          id: 'relative',
          name: '手机.heic',
          thumbnailUrl: '//preview.example.test/mobile.png',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Wrap(
              children: [
                for (final file in files)
                  CloudThumbnail(
                    file,
                    CloudPlatform.tianyi,
                    key: ValueKey(file.id),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(images.requests.map((r) => r.uri.path).toSet(), {
        '/photo.png',
        '/video.png',
        '/broken.png',
        '/mobile.png',
      });
      for (final request in images.requests) {
        expect(request.headers.values.keys.toSet(), {'user-agent', 'referer'});
      }
      for (final id in ['image', 'video', 'relative']) {
        final raw = tester.widget<RawImage>(
          find.descendant(
            of: find.byKey(ValueKey(id)),
            matching: find.byType(RawImage),
          ),
        );
        expect(raw.image, isNotNull, reason: id);
      }
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('broken')),
          matching: find.byType(FileGlyph),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('video')),
          matching: find.byIcon(CupertinoIcons.play_fill),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final (size, scale, dark) in [
    (const Size(320, 700), 1.8, false),
    (const Size(393, 864), 1.0, true),
    (const Size(1100, 780), 1.0, false),
    (const Size(700, 360), 1.6, true),
  ]) {
    browserTest('List and grid fit $size with scale $scale', (tester) async {
      final value = await fixture(tester);
      await value.render(tester, size: size, scale: scale, dark: dark);
      expect(tester.takeException(), isNull);
      await setView(tester, '大图标');
      expect(find.byType(GridView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(GridView), const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
