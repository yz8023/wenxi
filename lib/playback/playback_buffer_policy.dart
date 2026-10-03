import 'dart:math' as math;

/// Rebalances packet and Range caches without increasing their combined budget.
/// Connection choices are ceilings; congestion reduces active concurrency.
class PlaybackBufferPolicy {
  PlaybackBufferPolicy({required int connectionLimit})
    : limit = connectionLimit.clamp(1, 32),
      connections = math.min(4, connectionLimit.clamp(1, 32));

  static const mib = 1024 * 1024;
  static const totalBytes = 58 * mib;
  static const backBytes = 2 * mib;
  int limit, connections;
  int forwardBytes = 8 * mib;
  double bytesPerSecond = 0;
  Duration? _sampleAt, _holdUntil;
  int _received = 0, _failures = 0, _healthySamples = 0;
  double _previousThroughput = 0;

  void setLimit(int value) {
    limit = value.clamp(1, 32);
    connections = math.min(connections, limit);
    _healthySamples = 0;
  }

  int forwardTarget({
    required int size,
    required Duration duration,
    required double rate,
  }) {
    if (size <= 0 || duration <= Duration.zero) return forwardBytes;
    final average = size / (duration.inMilliseconds / 1000);
    final target =
        (average * 8 * rate.clamp(.25, 4) / mib).ceil().clamp(8, 32) * mib;
    // Only grow the packet cache within a session: mpv may keep old packets
    // briefly after a reduction, so immediately giving those bytes to the
    // proxy would exceed the combined memory budget.
    return math.max(forwardBytes, target);
  }

  int proxyBytesFor(int forward) => totalBytes - backBytes - forward;

  int observe({
    required Duration elapsed,
    required int receivedBytes,
    required int failures,
    required int? status,
    required int activeRequests,
    required double bufferedSeconds,
    required bool buffering,
    required bool playing,
  }) {
    final previous = _sampleAt;
    final delta = receivedBytes - _received;
    final failed = failures > _failures;
    _sampleAt = elapsed;
    _received = receivedBytes;
    _failures = failures;
    if (previous == null || elapsed <= previous) return connections;
    final seconds = (elapsed - previous).inMilliseconds / 1000;
    if (seconds <= 0) return connections;
    final speed = math.max(0, delta) / seconds;
    bytesPerSecond = bytesPerSecond == 0
        ? speed
        : bytesPerSecond * .65 + speed * .35;
    if (!playing) {
      _healthySamples = 0;
      return connections;
    }
    if (failed || ({429, 503}.contains(status) && activeRequests > 0)) {
      connections = math.max(1, connections ~/ 2);
      _holdUntil = elapsed + const Duration(seconds: 12);
      _healthySamples = 0;
    } else if (_holdUntil == null || elapsed >= _holdUntil!) {
      if ((buffering || bufferedSeconds < 4) &&
          activeRequests >= connections &&
          delta > 0) {
        connections = math.min(limit, connections + 2);
        _healthySamples = 0;
      } else if (bufferedSeconds >= 8 && delta > 0 && activeRequests > 0) {
        _healthySamples++;
        if (_healthySamples >= 3 &&
            connections > 2 &&
            speed <= _previousThroughput * 1.1) {
          connections--;
          _healthySamples = 0;
        }
      } else {
        _healthySamples = 0;
      }
    }
    _previousThroughput = speed;
    return connections;
  }
}
