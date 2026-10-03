/// Detects a buffering player whose transport has stopped making progress.
/// The caller supplies monotonic elapsed time and excludes paused/in-flight I/O.
class PlaybackStallMonitor {
  PlaybackStallMonitor({this.timeout = const Duration(seconds: 20)});
  final Duration timeout;
  (Duration, Duration, int, int)? _previous;
  Duration? _since;
  Duration stalledFor = Duration.zero;

  void reset() {
    _previous = null;
    _since = null;
    stalledFor = Duration.zero;
  }

  bool observe({
    required bool waiting,
    required Duration elapsed,
    required Duration position,
    required Duration buffer,
    required int receivedBytes,
    required int servedBytes,
  }) {
    if (!waiting) {
      reset();
      return false;
    }
    final current = (position, buffer, receivedBytes, servedBytes);
    if (current != _previous || _since == null || elapsed < _since!) {
      _previous = current;
      _since = elapsed;
    }
    stalledFor = elapsed - _since!;
    return stalledFor >= timeout;
  }
}
