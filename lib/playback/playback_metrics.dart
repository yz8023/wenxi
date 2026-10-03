/// Monotonic timings exclude user pauses and initial buffering from rebuffering.
class PlaybackMetrics {
  Duration? firstFrame, _bufferingAt, _seekAt, _seekTarget;
  Duration bufferingTime = Duration.zero;
  Duration? lastSeekTime;
  int bufferingCount = 0, seekCount = 0, seekTimeoutCount = 0;
  bool _started = false;
  Duration _lastPosition = Duration.zero;

  void seek(Duration target, Duration elapsed) {
    _seekAt = elapsed;
    _seekTarget = target;
    seekCount++;
    _finishBuffering(elapsed);
  }

  void pause(Duration elapsed) => _finishBuffering(elapsed);

  void observe({
    required Duration elapsed,
    required bool playing,
    required bool buffering,
    required Duration position,
  }) {
    final previousPosition = _lastPosition;
    _lastPosition = position;
    if (_seekAt != null && _seekTarget != null) {
      if (!buffering &&
          (position - _seekTarget!).abs() < const Duration(milliseconds: 500)) {
        lastSeekTime = elapsed - _seekAt!;
        _seekAt = _seekTarget = null;
      } else if (elapsed - _seekAt! > const Duration(seconds: 30)) {
        seekTimeoutCount++;
        _seekAt = _seekTarget = null;
      }
      return;
    }
    if (!playing) {
      _finishBuffering(elapsed);
      return;
    }
    if (!buffering) {
      if (firstFrame != null || position > previousPosition) _started = true;
      _finishBuffering(elapsed);
    } else if (_started && _bufferingAt == null) {
      _bufferingAt = elapsed;
      bufferingCount++;
    }
  }

  void _finishBuffering(Duration elapsed) {
    final start = _bufferingAt;
    if (start != null) bufferingTime += elapsed - start;
    _bufferingAt = null;
  }

  Map<String, Object?> fields(Duration elapsed) => {
    'firstFrameMs': ?firstFrame?.inMilliseconds,
    'rebufferCount': bufferingCount,
    'rebufferMs':
        (bufferingTime +
                (_bufferingAt == null
                    ? Duration.zero
                    : elapsed - _bufferingAt!))
            .inMilliseconds,
    'seekCount': seekCount,
    'seekTimeoutCount': seekTimeoutCount,
    if (_seekAt != null) 'seekWaitMs': (elapsed - _seekAt!).inMilliseconds,
    'seekReadyMs': ?lastSeekTime?.inMilliseconds,
  };
}
