import 'package:flutter/material.dart';

/// The arc is decorative: announce activity without an invented percentage.
class AppLoadingIndicator extends StatefulWidget {
  const AppLoadingIndicator({
    super.key,
    this.size = 22,
    this.color,
    this.strokeWidth = 2.4,
    this.semanticLabel = '正在加载',
  });

  final double size;
  final Color? color;
  final double strokeWidth;
  final String semanticLabel;

  @override
  State<AppLoadingIndicator> createState() => _AppLoadingIndicatorState();
}

class _AppLoadingIndicatorState extends State<AppLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final _turns = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _turns.stop();
    } else if (!_turns.isAnimating) {
      _turns.repeat();
    }
  }

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return Semantics(
      label: widget.semanticLabel,
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: SizedBox.square(
            dimension: widget.size,
            child: RotationTransition(
              turns: _turns,
              child: CircularProgressIndicator(
                value: .72,
                color: color,
                backgroundColor: color.withValues(alpha: .12),
                strokeWidth: widget.strokeWidth,
                strokeCap: StrokeCap.round,
                strokeAlign: -1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppLoadingEmblem extends StatelessWidget {
  const AppLoadingEmblem({super.key, this.size = 52, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(size * .3),
        border: Border.all(color: accent.withValues(alpha: .06)),
      ),
      child: AppLoadingIndicator(size: size * .48, color: accent),
    );
  }
}
