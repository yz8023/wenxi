import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/playback/playback_stall_monitor.dart';

void main() {
  late PlaybackStallMonitor monitor;
  setUp(() => monitor = PlaybackStallMonitor());

  bool sample(
    int seconds, {
    bool waiting = true,
    int position = 120,
    int buffer = 119,
    int received = 4096,
    int served = 4096,
  }) => monitor.observe(
    waiting: waiting,
    elapsed: Duration(seconds: seconds),
    position: Duration(seconds: position),
    buffer: Duration(seconds: buffer),
    receivedBytes: received,
    servedBytes: served,
  );

  test(
    'Twenty seconds of buffering without media or transport progress is recoverable',
    () {
      expect(sample(0), isFalse);
      expect(sample(5), isFalse);
      expect(sample(19), isFalse);
      expect(sample(20), isTrue);
      expect(monitor.stalledFor, const Duration(seconds: 20));
    },
  );

  for (final progress in ['position', 'buffer', 'received', 'served']) {
    test('$progress progress restarts the stall deadline', () {
      expect(sample(0), isFalse);
      expect(sample(15), isFalse);
      bool advancing(int seconds) => sample(
        seconds,
        position: progress == 'position' ? 121 : 120,
        buffer: progress == 'buffer' ? 122 : 119,
        received: progress == 'received' ? 8192 : 4096,
        served: progress == 'served' ? 8192 : 4096,
      );
      expect(advancing(20), isFalse);
      expect(advancing(35), isFalse);
      expect(advancing(40), isTrue);
    });
  }

  test(
    'Paused playback, active I/O and healthy playback do not accumulate stalled time',
    () {
      expect(sample(0), isFalse);
      expect(sample(15), isFalse);
      expect(sample(16, waiting: false), isFalse);
      expect(sample(600, waiting: false), isFalse);
      expect(sample(601), isFalse);
      expect(sample(620), isFalse);
      expect(sample(621), isTrue);
    },
  );

  test(
    'A seek or new source resets the deadline even if the first position has not arrived',
    () {
      expect(sample(0), isFalse);
      expect(sample(19), isFalse);
      monitor.reset();
      expect(sample(20), isFalse);
      expect(sample(39), isFalse);
      expect(sample(40), isTrue);
    },
  );
}
