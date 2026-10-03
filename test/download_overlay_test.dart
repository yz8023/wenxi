import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/download/download_overlay.dart';

DownloadTask task(
  String id, {
  int size = 100,
  int received = 50,
  DownloadStatus status = DownloadStatus.running,
  int created = 1,
}) => DownloadTask(
  id: id,
  spec: DownloadSpec(
    url: 'https://fixture.invalid/private?secret=never-copy',
    fileName: '$id.zip',
  ),
  createdAt: created,
  downloaded: received,
  total: size,
  status: status,
  speed: 100,
);

void main() {
  test(
    'Progress is weighted by size and old completed history is excluded',
    () {
      final batch = DownloadOverlayBatch();
      final value = batch.snapshot([
        task('small', received: 100),
        task('large', size: 900, received: 0),
        task('old', size: 10000, status: DownloadStatus.completed),
      ]);
      expect(value['progress'], 10);
      expect(value['count'], 2);
      expect(value.toString(), isNot(contains('secret')));
      expect(value.toString(), isNot(contains('https://')));
    },
  );
  test(
    'Unknown lengths never produce a made-up percentage; finished group stays at 100',
    () {
      final batch = DownloadOverlayBatch();
      expect(batch.snapshot([task('a', size: 0)])['progress'], -1);
      final complete = batch.snapshot([
        task('a', size: 0, status: DownloadStatus.completed),
      ]);
      expect(complete['progress'], 100);
      expect(complete['status'], '全部完成');
      expect(
        batch.snapshot([
          task('a', status: DownloadStatus.completed),
          task('next', received: 5),
        ])['progress'],
        5,
      );
    },
  );
  test('Paused, removed and failed tasks do not masquerade as complete', () {
    final batch = DownloadOverlayBatch();
    expect(
      batch.snapshot([task('a', status: DownloadStatus.paused)])['status'],
      '已暂停',
    );
    expect(
      batch.snapshot([task('a', status: DownloadStatus.failed)])['status'],
      '下载失败',
    );
    expect(batch.snapshot([])['status'], '暂无任务');
  });
  test('Old failures and paused tasks do not contaminate a new download', () {
    final batch = DownloadOverlayBatch();
    final history = [
      task('old-failed', status: DownloadStatus.failed, size: 900),
      task('old-paused', status: DownloadStatus.paused, size: 900),
    ];
    final running = batch.snapshot([...history, task('new', created: 2)]);
    expect(running['count'], 1);
    expect(running['progress'], 50);
    expect(running['failed'], 0);
    final done = batch.snapshot([
      ...history,
      task('new', created: 2, status: DownloadStatus.completed, received: 100),
    ]);
    expect(done['status'], '全部完成');
    expect(done['progress'], 100);
    expect(done['failed'], 0);
  });
  test('Starting another run replaces the previous failed run', () {
    final batch = DownloadOverlayBatch();
    batch.snapshot([task('first')]);
    final failed = task('first', status: DownloadStatus.failed);
    expect(batch.snapshot([failed])['status'], '下载失败');
    expect(batch.snapshot([failed, task('next', created: 2)])['count'], 1);
    final done = batch.snapshot([
      failed,
      task('next', created: 2, status: DownloadStatus.completed),
    ]);
    expect(done['status'], '全部完成');
    expect(done['progress'], 100);
  });
  test('Reopening with no active downloads shows the latest task result', () {
    final batch = DownloadOverlayBatch();
    expect(
      batch.snapshot([
        task('old', status: DownloadStatus.failed),
        task('new', created: 2, status: DownloadStatus.completed),
      ])['status'],
      '全部完成',
    );
    batch.reset();
    expect(
      batch.snapshot([
        task('old', status: DownloadStatus.completed),
        task('new', created: 2, status: DownloadStatus.failed),
      ])['status'],
      '下载失败',
    );
  });
  test('Failures within the current concurrent run remain visible', () {
    final batch = DownloadOverlayBatch();
    batch.snapshot([task('a'), task('b', created: 2)]);
    final failed = task('a', status: DownloadStatus.failed, received: 25);
    expect(batch.snapshot([failed, task('b', created: 2)])['status'], '正在下载');
    final done = batch.snapshot([
      failed,
      task('b', created: 2, status: DownloadStatus.completed, received: 100),
    ]);
    expect(done['count'], 2);
    expect(done['status'], '部分失败');
    expect(done['failed'], 1);
    expect(done['progress'], lessThan(100));
  });
  test('Retrying a historical failure joins the active run', () {
    final batch = DownloadOverlayBatch();
    batch.snapshot([
      task('old', status: DownloadStatus.failed),
      task('new', created: 2),
    ]);
    expect(batch.snapshot([task('old'), task('new', created: 2)])['count'], 2);
    expect(
      batch.snapshot([
        task('old', status: DownloadStatus.completed),
        task('new', created: 2, status: DownloadStatus.completed),
      ])['status'],
      '全部完成',
    );
  });
  test(
    'Fast downloads and retries finishing between refreshes are included',
    () {
      final batch = DownloadOverlayBatch();
      final failed = task('old', status: DownloadStatus.failed);
      batch.snapshot([failed]);
      expect(
        batch.snapshot([
          failed,
          task('fast', created: 2, status: DownloadStatus.completed),
        ])['status'],
        '全部完成',
      );
      expect(
        batch.snapshot([
          task('old', status: DownloadStatus.completed),
          task('fast', created: 2, status: DownloadStatus.completed),
        ])['count'],
        1,
      );
    },
  );
  test(
    'Deleting or cancelling the current task does not revive failed history',
    () {
      final batch = DownloadOverlayBatch();
      final history = task('old', status: DownloadStatus.failed);
      batch.snapshot([history, task('new', created: 2)]);
      expect(
        batch.snapshot([
          history,
          task('new', created: 2, status: DownloadStatus.cancelled),
        ])['status'],
        '暂无任务',
      );
      expect(batch.snapshot([history])['status'], '暂无任务');
    },
  );
  test(
    'Manually toggled overlay coalesces updates and keeps control in the download manager',
    () {
      fakeAsync((async) {
        final changes = ChangeNotifier(),
            calls = <String>[],
            actions = <String>[];
        final controller = DownloadOverlay(
          supported: true,
          changes: changes,
          tasks: () => [task('one')],
          dark: () => false,
          pause: (id) async {
            actions.add('pause:$id');
          },
          resume: (id) async {
            actions.add('resume:$id');
          },
          pauseAll: () async {
            actions.add('pauseAll');
          },
          resumeAll: () async {
            actions.add('resumeAll');
          },
          openDownloads: () {
            actions.add('open');
          },
          invoke: (method, data) async {
            calls.add(method);
            return method == 'downloadOverlayShow' ? {'visible': true} : null;
          },
        );
        changes.notifyListeners();
        async.elapse(const Duration(seconds: 2));
        expect(calls, isEmpty);
        controller.toggle();
        async.flushMicrotasks();
        expect(controller.visible, isTrue);
        for (var i = 0; i < 50; i++) {
          changes.notifyListeners();
        }
        async.elapse(const Duration(milliseconds: 800));
        expect(calls.where((c) => c == 'downloadOverlayUpdate'), hasLength(1));
        controller.action({'action': 'pause', 'id': 'one'});
        async.flushMicrotasks();
        controller.action({'action': 'pause', 'id': 'removed'});
        async.flushMicrotasks();
        controller.action({'action': 'openDownloads'});
        async.flushMicrotasks();
        expect(actions, ['pause:one', 'open']);
        controller.toggle();
        async.flushMicrotasks();
        expect(controller.visible, isFalse);
        controller.close();
        async.flushMicrotasks();
        changes.dispose();
      });
    },
  );
}
