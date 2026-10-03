import '../core/json.dart';
import '../domain/downloads.dart';

/// The foreground service follows the queue, including gaps between files and
/// the final verify/export phase. It must not stop at each network completion.
class DownloadActivity {
  const DownloadActivity({
    required this.active,
    required this.text,
    this.progress = -1,
  });
  const DownloadActivity.idle() : active = 0, text = '', progress = -1;

  final int active, progress;
  final String text;

  factory DownloadActivity.fromTasks(Iterable<DownloadTask> values) {
    final tasks = values.toList(growable: false);
    if (tasks.isEmpty) return const DownloadActivity.idle();
    final speed = tasks.fold(0, (sum, task) => sum + task.speed);
    final total = tasks.fold(0, (sum, task) => sum + task.total);
    final downloaded = tasks.fold(
      0,
      (sum, task) =>
          sum + task.downloaded.clamp(0, task.total > 0 ? task.total : 0),
    );
    final progress = total > 0 && tasks.every((task) => task.total > 0)
        ? (downloaded * 100 ~/ total).clamp(0, 100)
        : -1;
    final phase = tasks.length == 1 ? tasks.first.phase : '${tasks.length} 个任务';
    return DownloadActivity(
      active: tasks.length,
      progress: progress,
      text: speed > 0
          ? '${_speed(speed)}/s${progress >= 0 ? ' · $progress%' : ''}'
          : phase.isNotEmpty
          ? phase
          : '正在准备下载',
    );
  }

  Json toJson() => {'active': active, 'text': text, 'progress': progress};

  static String _speed(int bytes) {
    var value = bytes.toDouble(), unit = 0;
    while (value >= 1024 && unit < 3) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${const ['B', 'KB', 'MB', 'GB'][unit]}';
  }
}
