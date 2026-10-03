import 'dart:async';
import 'package:flutter/foundation.dart';

enum OperationStage {
  verifyShare('验证分享链接'),
  readFiles('读取文件列表'),
  createTemporary('创建临时转存目录'),
  transfer('转存文件'),
  waitTransfer('等待转存完成'),
  downloadLink('获取下载链接'),
  playbackLink('获取播放链接'),
  cleanup('删除临时转存');

  const OperationStage(this.label);
  final String label;
  String get runningLabel => '正在$label…';
}

enum OperationStepStatus { running, completed, failed, cancelled }

class OperationStep {
  const OperationStep(this.id, this.stage, this.status);
  final int id;
  final OperationStage stage;
  final OperationStepStatus status;
}

class _ProgressBinding {
  const _ProgressBinding(this.progress, this.generation);
  final OperationProgress progress;
  final int generation;
}

/// Progress belongs to the operation that started it, including across account
/// scopes. Only fixed stage names are exposed; links and credentials stay out.
class OperationProgress extends ValueNotifier<List<OperationStep>> {
  OperationProgress() : super(const []);
  static final _key = Object();
  static final _stageKey = Object();
  static OperationStage? get currentStage =>
      Zone.current[_stageKey] as OperationStage?;
  final _notificationZone = Zone.current;
  int _generation = 0, _nextId = 0;
  bool _closed = false;

  Future<T> run<T>(Future<T> Function() action) {
    _closed = false;
    final generation = ++_generation;
    _publish(const []);
    final previous = Zone.current[_key] as List<_ProgressBinding>? ?? const [];
    return runZoned(
      action,
      zoneValues: {
        _key: [
          for (final binding in previous)
            if (binding.progress != this) binding,
          _ProgressBinding(this, generation),
        ],
      },
    );
  }

  static Future<T> step<T>(
    OperationStage stage,
    Future<T> Function() action,
  ) async {
    final bindings = Zone.current[_key] as List<_ProgressBinding>? ?? const [];
    final started = [
      for (final binding in bindings)
        (binding, binding.progress._start(binding.generation, stage)),
    ];
    try {
      final result = await runZoned(action, zoneValues: {_stageKey: stage});
      for (final (binding, id) in started) {
        binding.progress._finish(
          binding.generation,
          id,
          OperationStepStatus.completed,
        );
      }
      return result;
    } catch (_) {
      for (final (binding, id) in started) {
        binding.progress._finish(
          binding.generation,
          id,
          OperationStepStatus.failed,
        );
      }
      rethrow;
    }
  }

  bool _current(int generation) => !_closed && generation == _generation;

  int _start(int generation, OperationStage stage) {
    final id = ++_nextId;
    if (!_current(generation)) return id;
    final entries = [
      ...value,
      OperationStep(id, stage, OperationStepStatus.running),
    ];
    // Keep long batch downloads bounded while preserving active steps.
    while (entries.length > 12) {
      final old = entries.indexWhere(
        (step) => step.status != OperationStepStatus.running,
      );
      if (old < 0) break;
      entries.removeAt(old);
    }
    _publish(entries);
    return id;
  }

  void _finish(int generation, int id, OperationStepStatus status) {
    if (!_current(generation)) return;
    _publish([
      for (final step in value)
        step.id == id ? OperationStep(id, step.stage, status) : step,
    ]);
  }

  void _publish(List<OperationStep> steps) {
    if (steps.isEmpty && value.isEmpty) return;
    _notificationZone.run(() => value = List.unmodifiable(steps));
  }

  void close({bool cancelled = false, bool failed = false}) {
    if (_closed) return;
    _closed = true;
    _generation++;
    if (cancelled || failed) {
      _publish([
        for (final step in value)
          step.status == OperationStepStatus.running
              ? OperationStep(
                  step.id,
                  step.stage,
                  cancelled
                      ? OperationStepStatus.cancelled
                      : OperationStepStatus.failed,
                )
              : step,
      ]);
    }
  }

  void clear() {
    close();
    _publish(const []);
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}
