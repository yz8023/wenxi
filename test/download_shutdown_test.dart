import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_shutdown.dart';
import 'package:asterlink/ui/download_shutdown_prompt.dart';

DownloadTask _task(
  String id,
  DownloadStatus status, {
  bool saved = true,
}) => DownloadTask(
  id: id,
  spec: const DownloadSpec(url: 'https://example.invalid/v', fileName: 'v.mp4'),
  createdAt: 1,
  status: status,
  downloaded: 100,
  total: 100,
  savedPath: status == DownloadStatus.completed && saved ? 'C:/v.mp4' : null,
);

class _Queue extends ChangeNotifier {
  _Queue({bool supported = true}) {
    shutdown = DownloadShutdown(
      supported: supported,
      changes: this,
      tasks: () => tasks,
      busy: () => busy,
      flush: () async {
        flushes++;
        await pendingFlush?.future;
      },
      shutdown: () async {
        requests++;
        if (fail) throw StateError('fake permission denial');
      },
    );
  }
  late final DownloadShutdown shutdown;
  List<DownloadTask> tasks = [];
  bool busy = false, fail = false;
  int requests = 0, flushes = 0;
  Completer<void>? pendingFlush;

  void update(List<DownloadTask> next, {bool busy = false}) {
    tasks = next;
    this.busy = busy;
    notifyListeners();
  }

  @override
  void dispose() {
    shutdown.dispose();
    super.dispose();
  }
}

void main() {
  const running = DownloadStatus.running, completed = DownloadStatus.completed;

  test('Default is off; history and empty queues do not trigger shutdown', () {
    fakeAsync((time) {
      final queue = _Queue();
      queue.update([_task('history', completed)]);
      expect(queue.shutdown.enabled, isFalse);
      queue.shutdown.setEnabled(true);
      time.elapse(const Duration(minutes: 5));
      expect(queue.requests, 0);
      expect(queue.shutdown.countingDown, isFalse);
      queue.update([_task('new', running)]);
      queue.update([_task('new', completed, saved: false)]);
      time.elapse(const Duration(minutes: 1));
      expect(queue.requests, 0);
      queue.update([_task('new', completed)], busy: true);
      expect(queue.shutdown.countingDown, isFalse);
      queue.update([_task('new', completed)]);
      expect(queue.shutdown.remainingSeconds, 60);
      time.elapse(const Duration(seconds: 59));
      expect(queue.requests, 0);
      time.elapse(const Duration(seconds: 1));
      expect(queue.flushes, 1);
      expect(queue.requests, 1);
      time.elapse(const Duration(minutes: 3));
      expect(queue.requests, 1);
      expect(queue.shutdown.enabled, isFalse);
      queue.dispose();
    });
  });

  test('Paused and failed downloads wait; the countdown can be cancelled', () {
    fakeAsync((time) {
      final queue = _Queue();
      queue.update([_task('a', running), _task('b', DownloadStatus.paused)]);
      queue.shutdown.setEnabled(true);
      queue.update([_task('a', completed), _task('b', DownloadStatus.failed)]);
      time.elapse(const Duration(minutes: 5));
      expect(queue.requests, 0);
      expect(queue.shutdown.detail, contains('暂停或失败'));
      queue.update([_task('a', completed), _task('b', completed)]);
      time.elapse(const Duration(seconds: 45));
      queue.shutdown.setEnabled(false);
      time.elapse(const Duration(minutes: 2));
      expect(queue.requests, 0);
      expect(queue.shutdown.countingDown, isFalse);
      queue.dispose();
    });
  });

  test('A new task interrupts countdown and starts a full new countdown', () {
    fakeAsync((time) {
      final queue = _Queue();
      queue.update([_task('a', running)]);
      queue.shutdown.setEnabled(true);
      queue.update([_task('a', completed)]);
      time.elapse(const Duration(seconds: 50));
      queue.update([_task('a', completed), _task('b', running)]);
      expect(queue.shutdown.countingDown, isFalse);
      time.elapse(const Duration(minutes: 2));
      expect(queue.requests, 0);
      queue.update([_task('a', completed), _task('b', completed)]);
      time.elapse(const Duration(seconds: 59));
      expect(queue.requests, 0);
      time.elapse(const Duration(seconds: 1));
      expect(queue.requests, 1);
      queue.dispose();
    });
  });

  for (final cancelled in [false, true]) {
    test(
      'Removing/cancelling a watched task disarms shutdown ($cancelled)',
      () {
        fakeAsync((time) {
          final queue = _Queue();
          queue.update([_task('a', running)]);
          queue.shutdown.setEnabled(true);
          queue.update([if (cancelled) _task('a', DownloadStatus.cancelled)]);
          time.elapse(const Duration(minutes: 2));
          expect(queue.shutdown.enabled, isFalse);
          expect(queue.requests, 0);
          queue.dispose();
        });
      },
    );
  }

  for (final newTask in [false, true]) {
    test('Rechecks cancel/new tasks while flushing state ($newTask)', () {
      fakeAsync((time) {
        final queue = _Queue()..pendingFlush = Completer<void>();
        queue.update([_task('a', running)]);
        queue.shutdown.setEnabled(true);
        queue.update([_task('a', completed)]);
        time.elapse(const Duration(seconds: 60));
        expect(queue.flushes, 1);
        expect(queue.requests, 0);
        if (newTask) {
          queue.update([_task('a', completed), _task('b', running)]);
        } else {
          queue.shutdown.setEnabled(false);
        }
        queue.pendingFlush!.complete();
        time.flushMicrotasks();
        expect(queue.requests, 0);
        queue.dispose();
      });
    });
  }

  test('System denial disarms the option and never retries on its own', () {
    fakeAsync((time) {
      final queue = _Queue()..fail = true;
      queue.update([_task('a', running)]);
      queue.shutdown.setEnabled(true);
      queue.update([_task('a', completed)]);
      time.elapse(const Duration(seconds: 60));
      expect(queue.requests, 1);
      expect(queue.shutdown.detail, contains('关机未成功'));
      expect(queue.shutdown.enabled, isFalse);
      queue.update([_task('a', completed)]);
      expect(queue.shutdown.executing, isFalse);
      time.elapse(const Duration(minutes: 5));
      expect(queue.requests, 1);
      queue.dispose();
    });
  });

  test('Disposal cancels timers; another session starts disabled', () {
    fakeAsync((time) {
      final queue = _Queue();
      queue.update([_task('a', running)]);
      queue.shutdown.setEnabled(true);
      queue.update([_task('a', completed)]);
      queue.dispose();
      time.elapse(const Duration(minutes: 2));
      expect(queue.requests, 0);
      final next = _Queue();
      expect(next.shutdown.enabled, isFalse);
      next.dispose();
      final unsupported = _Queue(supported: false);
      unsupported.shutdown.setEnabled(true);
      expect(unsupported.shutdown.enabled, isFalse);
      unsupported.dispose();
    });
  });

  testWidgets('Countdown overlays other pages, cancellation keeps that page', (
    tester,
  ) async {
    final queue = _Queue();
    final navigator = GlobalKey<NavigatorState>();
    var reveals = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: DownloadShutdownPrompt(
            queue.shutdown,
            showWindow: () async => reveals++,
          ),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('正在播放视频')),
      ),
    );
    await tester.pumpAndSettle();
    queue.update([_task('a', running)]);
    queue.shutdown.setEnabled(true);
    queue.update([_task('a', completed)]);
    await tester.pumpAndSettle();
    expect(reveals, 1);
    expect(find.text('下载完成，即将关机'), findsOneWidget);
    await tester.tap(find.text('取消关机'));
    await tester.pumpAndSettle();
    expect(find.text('正在播放视频'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pump(const Duration(seconds: 90));
    expect(queue.requests, 0);
    await tester.pumpWidget(const SizedBox());
    queue.dispose();
  });

  testWidgets('New download removes only countdown; back dismissal cancels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(240, 160);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final queue = _Queue();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(body: DownloadShutdownPrompt(queue.shutdown)),
      ),
    );
    queue.update([_task('a', running)]);
    queue.shutdown.setEnabled(true);
    queue.update([_task('a', completed)]);
    await tester.pumpAndSettle();
    queue.update([_task('a', completed), _task('b', running)]);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(queue.shutdown.enabled, isTrue);
    queue.update([_task('a', completed), _task('b', completed)]);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(queue.shutdown.enabled, isFalse);
    await tester.pump(const Duration(seconds: 90));
    expect(queue.requests, 0);
    await tester.pumpWidget(const SizedBox());
    queue.dispose();
  });
}
