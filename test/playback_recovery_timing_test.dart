import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/playback_failure.dart';
import 'player_support.dart';

void advance(FakeAsync time, PlaybackFixture fixture, int intervals) {
  for (var i = 0; i < intervals; i++) {
    fixture.current.emit(
      fixture.current.state.copyWith(
        position: fixture.current.state.position + const Duration(seconds: 5),
      ),
    );
    time.elapse(const Duration(seconds: 5));
  }
}

void recover(FakeAsync time, PlaybackFixture fixture, int preparations) {
  fixture.current
    ..failure = PlaybackFailure.http(403)
    ..fail();
  time.flushMicrotasks();
  expect(fixture.preparations, preparations);
  expect(fixture.controller.ready, isTrue);
}

void main() {
  for (final platform in CloudPlatform.values) {
    test(
      '${platform.key} can recover another outage after sustained playback',
      () {
        fakeAsync((time) {
          final fixture = PlaybackFixture(
            renewable: true,
            platforms: List.filled(3, platform),
          );
          try {
            fixture.controller.start();
            time.flushMicrotasks();
            expect(fixture.controller.ready, isTrue);
            fixture.current.emit(
              fixture.current.state.copyWith(
                position: const Duration(seconds: 95),
              ),
            );
            recover(time, fixture, 2);
            for (var recovery = 3; recovery <= 4; recovery++) {
              advance(time, fixture, 6);
              final position = fixture.controller.state.position;
              recover(time, fixture, recovery);
              expect(fixture.current.openedStart, position);
              expect(fixture.current.state.playing, isTrue);
              expect(
                fixture.leases.values.where((leases) => leases == 1),
                hasLength(1),
              );
            }
          } finally {
            fixture.controller.close();
            time.flushMicrotasks();
            expect(time.periodicTimerCount, 0);
            fixture.store.dispose();
          }
        });
      },
    );
  }

  for (final interruption in ['stalled', 'paused', 'buffering', 'seeking']) {
    test('$interruption time cannot reset the consecutive recovery limit', () {
      fakeAsync((time) {
        final fixture = PlaybackFixture(renewable: true);
        try {
          fixture.controller.start();
          time.flushMicrotasks();
          recover(time, fixture, 2);
          advance(time, fixture, 4);
          switch (interruption) {
            case 'stalled':
              time.elapse(const Duration(minutes: 1));
            case 'paused':
              fixture.controller.pause();
              time.flushMicrotasks();
              time.elapse(const Duration(minutes: 1));
              fixture.controller.play();
              time.flushMicrotasks();
            case 'buffering':
              fixture.current.emit(
                fixture.current.state.copyWith(buffering: true),
              );
              time.elapse(const Duration(minutes: 1));
              fixture.current.emit(
                fixture.current.state.copyWith(buffering: false),
              );
            case 'seeking':
              for (var i = 0; i < 8; i++) {
                fixture.controller.seek(
                  fixture.current.state.position + const Duration(seconds: 20),
                );
                time.flushMicrotasks();
                time.elapse(const Duration(seconds: 5));
              }
          }
          advance(time, fixture, 2);
          fixture.current
            ..failure = PlaybackFailure.http(403)
            ..fail();
          time.flushMicrotasks();
          expect(fixture.preparations, 2);
          expect(fixture.controller.error, contains('失效'));
          expect(fixture.controller.state.playing, isFalse);
        } finally {
          fixture.controller.close();
          time.flushMicrotasks();
          expect(time.periodicTimerCount, 0);
          fixture.store.dispose();
        }
      });
    });
  }
}
