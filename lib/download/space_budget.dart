import '../core/json.dart';

class DownloadSpaceException extends AppException {
  const DownloadSpaceException() : super('存储空间不足，进度已保留，请释放空间后继续');
}

class SpaceBudget {
  SpaceBudget(
    this.available, {
    this.margin = 32 * 1024 * 1024,
    this.availableOnVolume,
  });
  final Future<int> Function() available;
  final Future<int> Function(String volume)? availableOnVolume;
  final int margin;
  final _reservations = <String, Map<String, int>>{};
  final _gate = AsyncGate();
  static int required(int total, int downloaded, {bool copy = true}) =>
      (total - downloaded.clamp(0, total)).clamp(0, total) + (copy ? total : 0);
  Future<void> reserve(String id, int remaining) =>
      reserveVolumes(id, {'cache': remaining});
  Future<void> reserveVolumes(
    String id,
    Map<String, int> remaining,
  ) => _gate.run(() async {
    for (final entry in remaining.entries) {
      require(entry.value >= 0, '下载空间计算错误');
      final free = await (availableOnVolume?.call(entry.key) ?? available());
      final others = _reservations.entries
          .where((e) => e.key != id)
          .fold(0, (sum, e) => sum + (e.value[entry.key] ?? 0));
      // Some document providers do not expose capacity. Export still retains
      // the complete cache and reports a provider error without losing it.
      if (free >= 0 && free < others + entry.value + margin) {
        throw const DownloadSpaceException();
      }
    }
    _reservations[id] = {
      for (final e in remaining.entries) e.key: e.value + margin,
    };
  });
  void consume(String id, String volume, int bytes) {
    final reservation = _reservations[id];
    final value = reservation?[volume];
    if (value != null && bytes > 0) {
      reservation![volume] = (value - bytes).clamp(margin, value);
    }
  }

  void release(String id) => _reservations.remove(id);
}
