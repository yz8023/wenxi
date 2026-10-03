import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/diagnostics/diagnostic_bundle.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/diagnostics_page.dart';

class _UiBundle extends DiagnosticBundle {
  _UiBundle(super.log) : super(snapshot: () => {}, nativeEnabled: false);
  String? exportedNote;
  int exports = 0;
  bool failExport = false;
  @override
  Future<Uint8List> build({String note = ''}) async {
    exportedNote = note;
    exports++;
    if (failExport) throw StateError('fixture export failure');
    return Uint8List.fromList([80, 75, 3, 4]);
  }
}

void main() {
  late DiagnosticLog log;
  late _UiBundle bundle;
  setUp(() {
    log = DiagnosticLog.open(null);
    bundle = _UiBundle(log);
  });
  tearDown(() {
    log.close();
  });

  Future<void> render(
    WidgetTester tester, {
    Future<String?> Function(Uint8List, String)? save,
    Future<ShareResultStatus> Function(Uint8List, String)? share,
    Future<void> Function(String)? openLocation,
    Future<bool> Function(Uri)? linkLauncher,
    bool dark = false,
    double scale = 1,
    Size size = const Size(390, 844),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(dark ? Brightness.dark : Brightness.light),
        home: DiagnosticsPage(
          bundle,
          saveExport: save ?? (_, _) async => null,
          shareExport: share,
          openExportLocation: openLocation,
          linkLauncher: linkLauncher,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Diagnostic UI uses Beijing time and omits removed descriptions',
    (tester) async {
      log.close();
      log = DiagnosticLog.open(
        null,
        clock: () => DateTime.utc(2026, 9, 19, 23, 45, 12),
      );
      log.previousSessionInterrupted = true;
      log.record('fixture.beijing', level: 'error');
      bundle = _UiBundle(log);
      await render(tester);
      expect(find.textContaining('记录崩溃、操作错误'), findsNothing);
      expect(find.textContaining('上次运行没有正常结束标记'), findsNothing);
      await tester.ensureVisible(find.text('fixture.beijing'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2026-09-20 07:45:12'), findsOneWidget);
      await tapVisible(tester, find.text('fixture.beijing'));
      expect(find.textContaining('北京时间 UTC+08:00'), findsOneWidget);
    },
  );

  testWidgets('Export includes problem note and reports successful save once', (
    tester,
  ) async {
    String? filename;
    Uint8List? exported;
    await render(
      tester,
      save: (bytes, name) async {
        exported = bytes;
        filename = name;
        return r'D:\Reports\diagnostics.zip';
      },
    );
    await tester.enterText(find.byType(TextField), '删除记录后闪退，约 15:20');
    await tapVisible(tester, find.byKey(const Key('diagnostics-export')));
    expect(bundle.exportedNote, '删除记录后闪退，约 15:20');
    expect(bundle.exports, 1);
    expect(exported, [80, 75, 3, 4]);
    expect(
      filename,
      startsWith('文析助手-logs-${applicationVersion.replaceAll('+', '-')}-'),
    );
    expect(filename, endsWith('.zip'));
    expect(find.text('日志已导出，可将 ZIP 发给开发者排查'), findsOneWidget);
  });

  testWidgets('Cancelling the destination picker does not claim a saved file', (
    tester,
  ) async {
    await render(tester);
    await tapVisible(tester, find.byKey(const Key('diagnostics-export')));
    expect(find.text('已取消导出'), findsOneWidget);
    expect(find.text('日志已导出，可将 ZIP 发给开发者排查'), findsNothing);
  });

  testWidgets('Sharing includes the note and preserves original records', (
    tester,
  ) async {
    log.record('fixture.failure', level: 'error', error: 'sample failure');
    String? sharedName;
    Uint8List? sharedBytes;
    await render(
      tester,
      share: (bytes, name) async {
        sharedName = name;
        sharedBytes = bytes;
        return ShareResultStatus.success;
      },
    );
    await tester.enterText(find.byType(TextField), '网页登录失败，约 10:30');
    await tapVisible(tester, find.byKey(const Key('diagnostics-share')));
    expect(bundle.exportedNote, '网页登录失败，约 10:30');
    expect(sharedName, endsWith('.zip'));
    expect(sharedBytes, [80, 75, 3, 4]);
    expect(log.entries(errorsOnly: true), hasLength(1));
    expect(find.text('日志已交给所选应用，请在该应用内确认发送'), findsOneWidget);
  });

  testWidgets('Dismissing sharing does not report delivery and permits retry', (
    tester,
  ) async {
    var attempts = 0;
    await render(
      tester,
      share: (_, _) async {
        attempts++;
        return attempts == 1
            ? ShareResultStatus.dismissed
            : ShareResultStatus.unavailable;
      },
    );
    await tapVisible(tester, find.byKey(const Key('diagnostics-share')));
    expect(find.text('已取消分享'), findsOneWidget);
    expect(find.textContaining('请在该应用内确认发送'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tapVisible(tester, find.byKey(const Key('diagnostics-share')));
    expect(attempts, 2);
    expect(find.text('已打开系统分享窗口'), findsOneWidget);
  });

  testWidgets('Sharing failure permits a subsequent ordinary export', (
    tester,
  ) async {
    await render(
      tester,
      share: (_, _) async => throw PlatformException(code: 'fixture'),
    );
    await tapVisible(tester, find.byKey(const Key('diagnostics-share')));
    expect(find.text('分享未完成，可以重试或保存日志 ZIP'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tapVisible(tester, find.byKey(const Key('diagnostics-export')));
    expect(bundle.exports, 2);
    expect(find.text('已取消导出'), findsOneWidget);
  });

  testWidgets(
    'Feedback opens the repository without exporting diagnostic data',
    (tester) async {
      Uri? opened;
      log.record(
        'web_login.http_failed',
        level: 'error',
        fields: {'platform': 'quark', 'stage': 'http', 'httpStatus': 403},
      );
      await render(
        tester,
        linkLauncher: (url) async {
          opened = url;
          return true;
        },
      );
      expect(find.text('反馈错误建议先清空当前日志再去复现错误导出最新日志'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '白屏，pwd=private-password');
      await tapVisible(tester, find.byKey(const Key('diagnostics-feedback')));
      expect(opened.toString(), 'https://github.com/z7786/wenxi');
      expect(bundle.exports, 0);
      expect(bundle.exportedNote, isNull);
      expect(find.text('复制排查摘要'), findsNothing);
      expect(log.entries(errorsOnly: true), hasLength(1));
    },
  );

  testWidgets('Only a successfully saved path can be opened', (tester) async {
    String? opened;
    var attempts = 0;
    await render(
      tester,
      save: (_, _) async =>
          ++attempts == 1 ? null : r'D:\Reports\diagnostics.zip',
      openLocation: (path) async => opened = path,
    );
    await tapVisible(tester, find.byKey(const Key('diagnostics-export')));
    expect(find.byKey(const Key('diagnostics-open-location')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tapVisible(tester, find.byKey(const Key('diagnostics-export')));
    await tapVisible(
      tester,
      find.byKey(const Key('diagnostics-open-location')),
    );
    expect(opened, r'D:\Reports\diagnostics.zip');
  });

  testWidgets('Export failure releases the button for a retry', (tester) async {
    bundle.failExport = true;
    await render(tester);
    await tapVisible(tester, find.byKey(const Key('diagnostics-export')));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    bundle.failExport = false;
    await tapVisible(tester, find.byKey(const Key('diagnostics-export')));
    expect(bundle.exports, 2);
    expect(find.text('已取消导出'), findsOneWidget);
  });

  testWidgets(
    'Startup failure page can open diagnostics without app services',
    (tester) async {
      DiagnosticLog.active = log;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: StartupFailurePage(StateError('fixture startup failure')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出故障日志'));
      await tester.pumpAndSettle();
      expect(find.byType(DiagnosticsPage), findsOneWidget);
      expect(find.byKey(const Key('diagnostics-export')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Switch persists recording preference without preventing export',
    (tester) async {
      await render(tester);
      await tapVisible(tester, find.byKey(const Key('diagnostics-enabled')));
      expect(log.enabled, isFalse);
      final count = log.entries().length;
      log.record('should.be.disabled', level: 'fatal');
      expect(log.entries().length, count);
      await tapVisible(tester, find.byKey(const Key('diagnostics-export')));
      expect(bundle.exports, 1);
      await tapVisible(tester, find.byKey(const Key('diagnostics-enabled')));
      expect(log.enabled, isTrue);
    },
  );

  testWidgets(
    'Clear requires confirmation and does not delete on cancellation',
    (tester) async {
      log.record(
        'fixture.failure',
        level: 'error',
        error: StateError('fixture'),
      );
      await render(tester);
      await tapVisible(tester, find.text('清空日志'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(log.entries(errorsOnly: true), hasLength(1));
      await tapVisible(tester, find.text('清空日志'));
      await tester.tap(find.widgetWithText(TextButton, '清空'));
      await tester.pumpAndSettle();
      expect(log.entries(errorsOnly: true), isEmpty);
      expect(find.textContaining('暂无此类运行记录'), findsOneWidget);
    },
  );

  testWidgets(
    'Error filter and redacted detail are usable on a small dark screen',
    (tester) async {
      log.clear();
      log.record('download.begin');
      log.record(
        'download.failed',
        level: 'error',
        error: 'Cookie: private-cookie',
        stack: StackTrace.fromString('manager.dart:20'),
      );
      await render(tester, dark: true, scale: 1.7, size: const Size(320, 568));
      final list = find.byType(ListView);
      await tester.drag(list, const Offset(0, -1300));
      await tester.pumpAndSettle();
      expect(find.text('download.begin'), findsNothing);
      await tapVisible(tester, find.text('download.failed'));
      expect(find.text('记录详情'), findsOneWidget);
      final detail = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .data!;
      expect(detail, contains('manager.dart:20'));
      expect(detail, isNot(contains('private-cookie')));
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('仅错误'));
      await tester.drag(list, const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.text('download.begin'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
