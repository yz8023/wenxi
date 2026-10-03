import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/core/operation_progress.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

void main() {
  test('A step stays running until its real work completes', () async {
    final progress = OperationProgress(), pending = Completer<String>();
    addTearDown(progress.dispose);
    final work = progress.run(
      () =>
          OperationProgress.step(OperationStage.transfer, () => pending.future),
    );
    expect(progress.value.single.stage, OperationStage.transfer);
    expect(progress.value.single.status, OperationStepStatus.running);
    pending.complete('transferred-file');
    expect(await work, 'transferred-file');
    expect(progress.value.single.status, OperationStepStatus.completed);
  });

  test(
    'Late completion from a cancelled run cannot overwrite a new run',
    () async {
      final progress = OperationProgress();
      addTearDown(progress.dispose);
      final old = Completer<void>(), current = Completer<void>();
      final before = progress.run(
        () => OperationProgress.step(
          OperationStage.verifyShare,
          () => old.future,
        ),
      );
      progress.close(cancelled: true);
      expect(progress.value.single.status, OperationStepStatus.cancelled);
      final after = progress.run(
        () => OperationProgress.step(
          OperationStage.readFiles,
          () => current.future,
        ),
      );
      old.complete();
      await before;
      expect(progress.value.single.stage, OperationStage.readFiles);
      expect(progress.value.single.status, OperationStepStatus.running);
      current.complete();
      await after;
      expect(progress.value.single.status, OperationStepStatus.completed);
    },
  );

  test(
    'Failure is preserved and unexecuted stages are never reported',
    () async {
      final progress = OperationProgress();
      addTearDown(progress.dispose);
      const failure = AppException('fixture transfer failure');
      await expectLater(
        progress.run(() async {
          await OperationProgress.step(
            OperationStage.createTemporary,
            () async {},
          );
          await OperationProgress.step<void>(
            OperationStage.transfer,
            () async => throw failure,
          );
          await OperationProgress.step(
            OperationStage.downloadLink,
            () async {},
          );
        }),
        throwsA(same(failure)),
      );
      expect(progress.value.map((s) => s.stage), [
        OperationStage.createTemporary,
        OperationStage.transfer,
      ]);
      expect(progress.value.map((s) => s.status), [
        OperationStepStatus.completed,
        OperationStepStatus.failed,
      ]);
    },
  );

  test(
    'Nested progress preserves account scope and notifies in the UI zone',
    () async {
      final outer = OperationProgress(),
          inner = OperationProgress(),
          unrelated = OperationProgress();
      addTearDown(outer.dispose);
      addTearDown(inner.dispose);
      addTearDown(unrelated.dispose);
      final accountScope = Object();
      final notificationScopes = <Object?>[];
      outer.addListener(
        () => notificationScopes.add(Zone.current[accountScope]),
      );
      inner.addListener(
        () => notificationScopes.add(Zone.current[accountScope]),
      );
      await outer.run(
        () => inner.run(
          () => runZoned(
            () => OperationProgress.step(OperationStage.downloadLink, () async {
              await Future<void>.delayed(Duration.zero);
              expect(Zone.current[accountScope], 'fixture-owner');
            }),
            zoneValues: {accountScope: 'fixture-owner'},
          ),
        ),
      );
      expect(outer.value.single.status, OperationStepStatus.completed);
      expect(inner.value.single.status, OperationStepStatus.completed);
      expect(notificationScopes, isNotEmpty);
      expect(notificationScopes.every((value) => value == null), isTrue);
      expect(unrelated.value, isEmpty);
    },
  );

  test(
    'Long batches stay bounded and disposed observers ignore late results',
    () async {
      final progress = OperationProgress();
      await progress.run(() async {
        for (var i = 0; i < 60; i++) {
          await OperationProgress.step(
            OperationStage.downloadLink,
            () async {},
          );
        }
      });
      expect(progress.value, hasLength(12));
      final pending = Completer<void>();
      final work = progress.run(
        () => OperationProgress.step(
          OperationStage.readFiles,
          () => pending.future,
        ),
      );
      progress.dispose();
      pending.complete();
      await work;
    },
  );

  test(
    'Cleanup progress starts only after leases release and follows the deletion response',
    () async {
      final store = StateStore.memory();
      final entered = Completer<void>(), response = Completer<void>();
      final http = FakeHttp((request) async {
        expect(request.uri.path, '/remove-temporary');
        entered.complete();
        await response.future;
        return jsonResponse({'code': 0});
      });
      final outbox = CleanupOutbox(store, http), progress = OperationProgress();
      addTearDown(outbox.progress.dispose);
      addTearDown(progress.dispose);
      const cleanup = DownloadCleanup(
        url: 'https://fixture.invalid/remove-temporary',
      );
      await outbox.stage(cleanup);
      outbox.retain(cleanup);
      await outbox.ready(cleanup);
      await outbox.drain();
      expect(http.calls, isEmpty);
      expect(outbox.progress.value, isEmpty);
      await outbox.release(cleanup);
      await outbox.ready(cleanup);
      final work = progress.run(outbox.drain);
      await entered.future;
      expect(outbox.progress.value.single.stage, OperationStage.cleanup);
      expect(outbox.progress.value.single.status, OperationStepStatus.running);
      expect(outbox.pendingCount, 1);
      response.complete();
      await work;
      expect(outbox.pendingCount, 0);
      expect(
        outbox.progress.value.single.status,
        OperationStepStatus.completed,
      );
      expect(progress.value.single.status, OperationStepStatus.completed);
    },
  );

  test(
    'Failed cleanup remains queued and is not displayed as completed',
    () async {
      final store = StateStore.memory();
      final outbox = CleanupOutbox(
        store,
        FakeHttp((_) => jsonResponse({'code': 500})),
      );
      addTearDown(outbox.progress.dispose);
      const cleanup = DownloadCleanup(
        url: 'https://fixture.invalid/remove-temporary',
      );
      await outbox.stage(cleanup);
      await outbox.ready(cleanup);
      await outbox.drain();
      expect(outbox.pendingCount, 1);
      expect(outbox.progress.value.single.status, OperationStepStatus.failed);
      expect(
        asJson(store.data.obj('cleanups').values.single).integer('attempts'),
        1,
      );
    },
  );
}
