import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/operation_progress.dart';
import 'loading_indicator.dart';

class OperationProgressView extends StatelessWidget {
  const OperationProgressView({
    super.key,
    required this.progress,
    required this.label,
    this.foreground,
    this.compact = false,
    this.maxSteps = 6,
  }) : assert(maxSteps > 0);

  final OperationProgress progress;
  final String label;
  final Color? foreground;
  final bool compact;
  final int maxSteps;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<List<OperationStep>>(
        valueListenable: progress,
        builder: (context, steps, _) {
          final colors = Theme.of(context).colorScheme;
          final color = foreground ?? colors.onSurface;
          final accent = foreground ?? colors.primary;
          final muted =
              foreground?.withValues(alpha: .72) ?? colors.onSurfaceVariant;
          final active = steps
              .where((step) => step.status == OperationStepStatus.running)
              .lastOrNull;
          final issue = steps
              .where(
                (step) =>
                    step.status == OperationStepStatus.failed ||
                    step.status == OperationStepStatus.cancelled,
              )
              .lastOrNull;
          final current = active ?? issue ?? steps.lastOrNull;
          final running = steps.isEmpty || active != null;
          final status = current?.status;

          if (compact) {
            final step = current;
            return Row(
              children: [
                _StatusMark(status: status, accent: accent, foreground: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Semantics(
                    liveRegion: running,
                    child: Text(
                      step == null ? label : _stepLabel(step),
                      style: TextStyle(
                        color: color,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  ),
                ),
              ],
            );
          }

          // Leave room for the heading and dialog actions at large text scales.
          final textScale = MediaQuery.textScalerOf(context).scale(13) / 13;
          final stepLimit =
              ((MediaQuery.sizeOf(context).height * .55 - 68 * textScale) /
                      (52 * textScale))
                  .floor()
                  .clamp(1, maxSteps);
          // Keep the current stage visible during nested or parallel work.
          final visible = steps
              .skip(steps.length > stepLimit ? steps.length - stepLimit : 0)
              .toList();
          if (current != null && !visible.contains(current)) {
            visible[0] = current;
            visible.sort((a, b) => a.id.compareTo(b.id));
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (running)
                    AppLoadingEmblem(size: 48, color: accent)
                  else
                    Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: _StatusMark(
                        status: status,
                        accent: accent,
                        foreground: color,
                        size: 24,
                      ),
                    ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.4,
                            fontWeight: FontWeight.w600,
                            color: color,
                          ),
                        ),
                        if (steps.isEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            '请稍候，正在为你处理',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: muted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (visible.isNotEmpty) ...[
                const SizedBox(height: 20),
                for (var index = 0; index < visible.length; index++) ...[
                  if (index > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 22),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: 1,
                          height: 10,
                          color: accent.withValues(alpha: .16),
                        ),
                      ),
                    ),
                  _StepRow(
                    step: visible[index],
                    accent: accent,
                    foreground: color,
                    muted: muted,
                  ),
                ],
              ],
            ],
          );
        },
      );
}

String _stepLabel(OperationStep step) => switch (step.status) {
  OperationStepStatus.running => step.stage.runningLabel,
  OperationStepStatus.completed => '${step.stage.label} · 完成',
  OperationStepStatus.failed => '${step.stage.label} · 未完成',
  OperationStepStatus.cancelled => '${step.stage.label} · 已取消',
};

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.step,
    required this.accent,
    required this.foreground,
    required this.muted,
  });

  final OperationStep step;
  final Color accent, foreground, muted;

  @override
  Widget build(BuildContext context) {
    final running = step.status == OperationStepStatus.running;
    final failed = step.status == OperationStepStatus.failed;
    final error = Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: running
            ? accent.withValues(alpha: .07)
            : failed
            ? error.withValues(alpha: .07)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: _StatusMark(
              status: step.status,
              accent: accent,
              foreground: foreground,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Semantics(
              liveRegion: running || failed,
              child: Text(
                _stepLabel(step),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  fontWeight: running ? FontWeight.w600 : FontWeight.w400,
                  color: running
                      ? foreground
                      : failed
                      ? error
                      : muted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusMark extends StatelessWidget {
  const _StatusMark({
    required this.status,
    required this.accent,
    required this.foreground,
    this.size = 20,
  });

  final OperationStepStatus? status;
  final Color accent, foreground;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: status == null || status == OperationStepStatus.running
        ? AppLoadingIndicator(size: size, color: accent, strokeWidth: 2)
        : Icon(
            switch (status!) {
              OperationStepStatus.completed =>
                CupertinoIcons.checkmark_circle_fill,
              OperationStepStatus.failed =>
                CupertinoIcons.exclamationmark_circle,
              _ => CupertinoIcons.minus_circle,
            },
            size: size,
            color: switch (status!) {
              OperationStepStatus.completed => accent.withValues(alpha: .75),
              OperationStepStatus.failed => Theme.of(context).colorScheme.error,
              _ => foreground.withValues(alpha: .5),
            },
          ),
  );
}
