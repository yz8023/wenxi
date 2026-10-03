import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/login_page.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'package:asterlink/ui/recent_playback_page.dart';
import 'support.dart';
import 'lanzou_support.dart';
import 'lanzou_folder_support.dart';
import 'token_cloud_support.dart';

class _ShareConnector extends CloudConnector {
  _ShareConnector([this.platform = CloudPlatform.quark]);
  @override
  final CloudPlatform platform;
  final opened = <ParsedLink>[];
  int lists = 0;
  Future<void>? openBarrier, listBarrier;
  String? requiredCode;
  Object? failure;
  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    opened.add(link);
    await openBarrier;
    if (failure != null) throw failure!;
    if (requiredCode != null && link.passcode != requiredCode) {
      throw const AppException('分享提取码错误或未填写');
    }
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: '旅行视频合集',
      rootId: 'root',
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async {
    lists++;
    await listBarrier;
    return const [
      CloudFile(id: 'video1', name: '第一集.mp4', size: 5000, parentId: 'root'),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppServices services;
  late _ShareConnector connector;
  late GlobalKey<ParsePageState> pageKey;
  const text = '我分享了视频 https://pan.quark.cn/s/Abcd?pwd=old1 提取码：old1';
  Future<void> render(WidgetTester tester, {bool loggedIn = true}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 960);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    services = AppServices(
      controlEnabled: false,
      store: StateStore.memory({
        'credentials': {
          if (loggedIn)
            'Quark': Credential('fixture', {
              'primary': '__pus=a; __puus=b',
            }, updatedAt: 1).toJson(),
        },
      }),
      dataDirectory: Directory('parse-fixture'),
      cacheDirectory: Directory('parse-fixture/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('parse-fixture/files')),
      http: FakeHttp(),
      platformFeatures: false,
      clock: () => DateTime(2026, 9, 14, 20),
    );
    connector = _ShareConnector();
    services.cloud.connectors[CloudPlatform.quark] = connector;
    pageKey = GlobalKey<ParsePageState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(body: ParsePage(services, key: pageKey)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, [String value = text]) async {
    await tester.enterText(find.byKey(const Key('parse-input')), value);
    await tester.pump();
  }

  String code(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('parse-code')))
      .controller!
      .text;
  Future<void> start(WidgetTester tester, {bool settle = true}) async {
    await tester.ensureVisible(find.byKey(const Key('parse-start')));
    await tester.tap(find.byKey(const Key('parse-start')));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  void scenario(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        services.close().then((_) => closed = true);
        for (var i = 0; i < 20 && !closed; i++) {
          await tester.pump();
        }
        expect(closed, isTrue);
      }
    });
  }

  scenario(
    'Compact home keeps parsing and recent playback accessible without the old header',
    (tester) async {
      await render(tester);
      expect(find.text('14'), findsNothing);
      expect(find.text('九月'), findsNothing);
      expect(find.text('晚上好'), findsNothing);
      expect(find.text('AsterLink'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('parse-start')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('parse-bt')))
            .onPressed,
        isNotNull,
      );
      await services.store.put('playbackHistory', {
        'fixture': {
          'name': '旅行第一集.mp4',
          'position': 120000,
          'duration': 600000,
          'updatedAt': 1234,
          'completed': false,
        },
      });
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('parse-recent')));
      await tester.tap(find.byKey(const Key('parse-recent')));
      await tester.pumpAndSettle();
      expect(find.byType(RecentPlaybackPage), findsOneWidget);
      expect(find.text('旅行第一集.mp4'), findsOneWidget);
      expect(find.textContaining('已播放 02:00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'Live recognition, per-link manual codes and clear do not start requests',
    (tester) async {
      await render(tester);
      await enter(tester);
      expect(find.text('已识别：夸克网盘'), findsOneWidget);
      expect(code(tester), 'old1');
      await tester.enterText(find.byKey(const Key('parse-code')), 'new1');
      await enter(tester, '$text\nhttps://drive.uc.cn/s/Uc123\n提取码：u123');
      expect(code(tester), 'new1');
      await tester.ensureVisible(find.byKey(const Key('parse-choice-1')));
      await tester.tap(find.byKey(const Key('parse-choice-1')));
      await tester.pump();
      expect(code(tester), 'u123');
      expect(connector.opened, isEmpty);
      await tester.ensureVisible(find.byTooltip('清空输入'));
      await tester.tap(find.byTooltip('清空输入'));
      await tester.pump();
      expect(code(tester), isEmpty);
      expect(find.text('等待粘贴链接'), findsOneWidget);
      expect(services.store.data.list('history'), isEmpty);
    },
  );

  scenario(
    'System share prefers the cloud URL and passes its ID and manual code to the connector',
    (tester) async {
      await render(tester);
      services.sharedText.value =
          '详情：https://example.com/help\n\n'
          'https://share.quark.cn/s/Ab123?password=c333&pass=b222';
      await tester.pumpAndSettle();
      expect(pageKey.currentState!.current!.shareId, 'Ab123');
      expect(code(tester), 'b222');
      expect(connector.opened, isEmpty);
      connector.requiredCode = 'Manual123456';
      await tester.enterText(
        find.byKey(const Key('parse-code')),
        'Manual123456',
      );
      await start(tester);
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(connector.opened.single.shareId, 'Ab123');
      expect(connector.opened.single.passcode, 'Manual123456');
      expect(
        connector.opened.single.url,
        'https://share.quark.cn/s/Ab123?password=c333&pass=b222',
      );
    },
  );

  scenario(
    'Personal-only clouds explain unsupported shares without a login or download dialog',
    (tester) async {
      await render(tester, loggedIn: false);
      for (final (url, label) in [
        ('https://share.weiyun.com/Wei123', '腾讯微云'),
        ('https://www.ilanzou.com/s/IL123', '蓝奏云优享版'),
      ]) {
        await enter(tester, '$url 提取码：a123');
        expect(find.text('已识别：$label（暂不支持分享解析）'), findsOneWidget);
        expect(code(tester), 'a123');
        await start(tester);
        expect(find.text('$label暂不支持分享解析，请在网盘页登录后浏览个人文件'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(WebLoginPage), findsNothing);
        expect(find.byType(BrowserPage), findsNothing);
      }
      expect(connector.opened, isEmpty);
      expect(services.store.data.list('history'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'Wopan short links open a share without exposing unsupported save actions',
    (tester) async {
      await render(tester, loggedIn: false);
      final wopan = _ShareConnector(CloudPlatform.wopan);
      services.cloud.connectors[CloudPlatform.wopan] = wopan;
      await enter(tester, 'https://pan.wo.cn/s/1TEST123456');
      await start(tester);
      expect(wopan.opened.single.shareId, '1TEST123456');
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(find.byType(WebLoginPage), findsNothing);
      expect(find.text('转存'), findsNothing);
      expect(find.text('转存到网盘'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'Authentication preflight preserves text and opens the matching configuration',
    (tester) async {
      await render(tester, loggedIn: false);
      await enter(tester);
      await start(tester);
      expect(find.text('去配置'), findsOneWidget);
      expect(connector.opened, isEmpty);
      await tester.tap(find.text('去配置'));
      await tester.pumpAndSettle();
      expect(find.byType(WebLoginPage), findsOneWidget);
      expect(
        tester.widget<WebLoginPage>(find.byType(WebLoginPage)).target.platform,
        CloudPlatform.quark,
      );
      Navigator.of(tester.element(find.byType(WebLoginPage))).pop();
      await tester.pumpAndSettle();
      expect(code(tester), 'old1');
      expect(pageKey.currentState!.input.text, text);
      expect(find.text('尚未完成登录，链接和提取码已保留'), findsOneWidget);
      expect(services.store.data.list('history'), isEmpty);
    },
  );

  for (final p in [CloudPlatform.aliyun, CloudPlatform.guangya]) {
    scenario('${p.key} parses its share with a saved token account', (
      tester,
    ) async {
      await render(tester, loggedIn: false);
      final provider = _ShareConnector(p);
      services.cloud.connectors[p] = provider;
      await services.vault.putCredential(p, tokenCredential(p));
      await enter(tester, '${tokenShare(p).sourceLink!.url} 提取码：a123');
      await start(tester);
      expect(provider.opened.single.platform, p);
      expect(provider.opened.single.passcode, 'a123');
      expect(provider.lists, 1);
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(find.byType(WebLoginPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  scenario(
    'Success uses the edited passcode, preloads once and restores successful history',
    (tester) async {
      await render(tester);
      connector.requiredCode = 'new1';
      await enter(tester);
      await tester.enterText(find.byKey(const Key('parse-code')), 'new1');
      await start(tester);
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(find.text('第一集.mp4'), findsOneWidget);
      expect(connector.lists, 1);
      expect(connector.opened.single.passcode, 'new1');
      final item = services.store.data.list('history').single;
      expect(item.integer('itemCount'), 1);
      expect(item.str('fileName'), '旅行视频合集');
      Navigator.of(tester.element(find.byType(BrowserPage))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('清空输入'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('parse-history')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('旅行视频合集'));
      await tester.pumpAndSettle();
      expect(pageKey.currentState!.input.text, text);
      expect(code(tester), 'new1');
      expect(connector.opened, hasLength(1));
    },
  );

  scenario(
    'Anonymous Lanzou parsing opens files with download-only management',
    (tester) async {
      await render(tester, loggedIn: false);
      final fixture = LanzouFixture();
      services.cloud.connectors[CloudPlatform.lanzou] = fixture.connector;
      await enter(tester, lanzouTestUrl);
      await start(tester);
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(find.byType(WebLoginPage), findsNothing);
      expect(find.byType(NativePasswordLoginPage), findsNothing);
      expect(find.byTooltip('切换或更新账号'), findsNothing);
      expect(services.vault.credential(CloudPlatform.lanzou), isNull);
      expect(fixture.http.calls, hasLength(3));
      expect(services.store.data.list('history'), hasLength(1));
      await tester.tap(find.byTooltip('Example & 1.zip操作'));
      await tester.pumpAndSettle();
      expect(find.text('下载'), findsOneWidget);
      expect(find.text('复制下载链接'), findsOneWidget);
      for (final label in ['转存到我的网盘', '重命名', '移动', '创建分享', '删除']) {
        expect(find.text(label), findsNothing);
      }
      Navigator.of(tester.element(find.text('复制下载链接'))).pop();
      await tester.pumpAndSettle();
      await tester.longPress(find.widgetWithText(ListTile, 'Example & 1.zip'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      for (final label in ['转存', '移动', '分享', '删除']) {
        expect(find.text(label), findsNothing);
      }
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'Anonymous folder parsing supports navigation and selecting folders for download',
    (tester) async {
      await render(tester, loggedIn: false);
      final fixture = LanzouFolderFixture()..withChild();
      services.cloud.connectors[CloudPlatform.lanzou] = fixture.connector;
      await enter(tester, '$lanzouFolderUrl 提取码：code');
      await start(tester);
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(find.byType(WebLoginPage), findsNothing);
      expect(find.byTooltip('切换或更新账号'), findsNothing);
      expect(find.text('Example & 1.zip'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, '子目录'));
      await tester.pumpAndSettle();
      expect(find.text('nested.zip'), findsOneWidget);
      await tester.tap(find.text('全部文件'));
      await tester.pumpAndSettle();
      await tester.longPress(find.widgetWithText(ListTile, '子目录'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      for (final label in ['转存', '移动', '分享', '删除']) {
        expect(find.text(label), findsNothing);
      }
      expect(services.vault.credential(CloudPlatform.lanzou), isNull);
      expect(fixture.http.calls.any((r) => r.method == 'HEAD'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'Lanzou extraction-code retry stays anonymous and records only a successful parse',
    (tester) async {
      await render(tester, loggedIn: false);
      final fixture = LanzouFixture()..page = lanzouTestPasswordPage;
      services.cloud.connectors[CloudPlatform.lanzou] = fixture.connector;
      await enter(tester, lanzouTestUrl);
      await start(tester);
      expect(find.textContaining('需要提取码'), findsOneWidget);
      expect(pageKey.currentState!.codeFocus.hasFocus, isTrue);
      expect(find.byType(WebLoginPage), findsNothing);
      expect(services.store.data.list('history'), isEmpty);
      fixture.result = {'zt': 0, 'inf': '密码不正确'};
      await tester.enterText(find.byKey(const Key('parse-code')), 'bad');
      await start(tester);
      expect(find.textContaining('提取码错误'), findsOneWidget);
      fixture.result = {
        'zt': 1,
        'dom': 'https://download.lanzouj.com',
        'url': 'ticket',
        'inf': 'Private.zip',
      };
      await tester.enterText(find.byKey(const Key('parse-code')), 'good');
      await start(tester);
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(services.store.data.list('history'), hasLength(1));
      expect(services.vault.credential(CloudPlatform.lanzou), isNull);
    },
  );

  scenario(
    'A missing or wrong code focuses the editor and retry records only success',
    (tester) async {
      await render(tester);
      connector.requiredCode = 'good';
      await enter(tester, 'https://pan.quark.cn/s/Abcd');
      await start(tester);
      expect(find.byType(BrowserPage), findsNothing);
      expect(find.textContaining('请在上方修改提取码'), findsOneWidget);
      expect(find.text('验证分享链接 · 未完成'), findsOneWidget);
      expect(find.textContaining('获取下载链接'), findsNothing);
      expect(pageKey.currentState!.codeFocus.hasFocus, isTrue);
      expect(services.store.data.list('history'), isEmpty);
      await tester.enterText(find.byKey(const Key('parse-code')), 'good');
      await start(tester);
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(services.store.data.list('history'), hasLength(1));
      expect(connector.lists, 1);
    },
  );

  scenario(
    'Cancellation releases the form immediately and ignores a late root listing',
    (tester) async {
      await render(tester);
      final pending = Completer<void>();
      connector.listBarrier = pending.future;
      await enter(tester);
      await start(tester, settle: false);
      expect(find.text('正在读取文件列表…'), findsOneWidget);
      expect(find.text('验证分享链接 · 完成'), findsOneWidget);
      await pageKey.currentState!
          .parse(); // A second tap must not create a request.
      expect(connector.opened, hasLength(1));
      await tester.tap(find.byKey(const Key('parse-cancel')));
      await tester.pumpAndSettle();
      expect(pageKey.currentState!.working, isFalse);
      expect(find.text('读取文件列表 · 已取消'), findsOneWidget);
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(BrowserPage), findsNothing);
      expect(services.store.data.list('history'), isEmpty);
      connector.listBarrier = null;
      await start(tester);
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(services.store.data.list('history'), hasLength(1));
    },
  );

  scenario('Timeout ends the running step and ignores the eventual response', (
    tester,
  ) async {
    await render(tester);
    final pending = Completer<void>();
    connector.listBarrier = pending.future;
    await enter(tester);
    await start(tester, settle: false);
    await tester.pump(const Duration(seconds: 91));
    await tester.pumpAndSettle();
    expect(pageKey.currentState!.working, isFalse);
    expect(find.text('解析超时，请检查网络后重试'), findsOneWidget);
    expect(find.text('读取文件列表 · 未完成'), findsOneWidget);
    expect(find.text('正在读取文件列表…'), findsNothing);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byType(BrowserPage), findsNothing);
    expect(find.text('读取文件列表 · 未完成'), findsOneWidget);
    expect(services.store.data.list('history'), isEmpty);
  });

  scenario(
    'Changing accounts during parsing cannot publish stale files or history',
    (tester) async {
      await render(tester);
      final pending = Completer<void>();
      connector.listBarrier = pending.future;
      await enter(tester);
      await start(tester, settle: false);
      await services.vault.putCredential(
        CloudPlatform.quark,
        Credential('new', {'primary': '__pus=new; __puus=new'}, updatedAt: 2),
      );
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(BrowserPage), findsNothing);
      expect(find.textContaining('账号已变化'), findsOneWidget);
      expect(services.store.data.list('history'), isEmpty);
    },
  );

  scenario(
    'Expired authentication offers login and leaving cancels pending work',
    (tester) async {
      await render(tester);
      connector.failure = const AccountLoginRequired('登录已失效');
      await enter(tester);
      await start(tester);
      expect(find.text('去登录 / 配置'), findsOneWidget);
      expect(services.store.data.list('history'), isEmpty);
      connector.failure = null;
      final pending = Completer<void>();
      connector.openBarrier = pending.future;
      await start(tester, settle: false);
      await tester.pumpWidget(const SizedBox());
      pending.complete();
      await tester.pumpAndSettle();
      expect(connector.lists, 0);
      expect(services.store.data.list('history'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
