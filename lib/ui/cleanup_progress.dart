import 'package:flutter/material.dart';
import '../core/operation_progress.dart';
import '../data/cleanup_outbox.dart';
import 'common.dart';
import 'loading_indicator.dart';

/// Deferred cleanup can start after its original loading dialog has closed.
class CleanupProgress extends StatelessWidget {
  const CleanupProgress(this.cleanups, {super.key});
  final CleanupOutbox cleanups;

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<List<OperationStep>>(
    valueListenable: cleanups.progress,
    builder: (context, steps, _) {
      if (!steps.any((step) => step.status == OperationStepStatus.running)) {
        return const SizedBox.shrink();
      }
      return Container(
        key: const Key('cleanup-progress'),
        margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: brandBlue.withValues(alpha: .06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          children: [
            AppLoadingIndicator(size: 15, strokeWidth: 1.8),
            SizedBox(width: 10),
            Expanded(child: Text('正在删除临时转存…', style: TextStyle(fontSize: 12))),
          ],
        ),
      );
    },
  );
}
