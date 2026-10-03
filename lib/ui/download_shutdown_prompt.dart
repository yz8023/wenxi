import 'dart:async';
import 'package:flutter/material.dart';
import '../download/download_shutdown.dart';

/// Stays mounted at the shell so a tray download can also show its countdown.
class DownloadShutdownPrompt extends StatefulWidget {
  const DownloadShutdownPrompt(this.controller, {super.key, this.showWindow});
  final DownloadShutdown controller;
  final Future<void> Function()? showWindow;

  @override
  State<DownloadShutdownPrompt> createState() => _DownloadShutdownPromptState();
}

class _DownloadShutdownPromptState extends State<DownloadShutdownPrompt> {
  DialogRoute<void>? _route;
  bool _scheduled = false, _showing = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _changed();
  }

  void _changed() {
    if (!mounted || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_sync());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _sync() async {
    final controller = widget.controller;
    if (!controller.countingDown) {
      final route = _route;
      _route = null;
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
      return;
    }
    if (_route != null || _showing) return;
    _showing = true;
    try {
      await widget.showWindow?.call();
      if (!mounted || !controller.countingDown) return;
      final route = _route = DialogRoute<void>(
        context: context,
        builder: (context) => AnimatedBuilder(
          animation: controller,
          builder: (context, _) => AlertDialog(
            scrollable: true,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            title: const Text('下载完成，即将关机'),
            content: Text(
              '文件已全部保存，将在 ${controller.remainingSeconds ?? 0} 秒后关闭电脑。\n请保存其他应用中的工作。',
            ),
            actions: [
              FilledButton(
                onPressed: () => controller.setEnabled(false),
                child: const Text('取消关机'),
              ),
            ],
          ),
        ),
      );
      await Navigator.of(context, rootNavigator: true).push(route);
      if (_route == route) {
        _route = null;
        // Esc/back/barrier dismissals cancel the opt-in, just like the button.
        controller.setEnabled(false);
      }
    } catch (_) {
      controller.setEnabled(false);
    } finally {
      _showing = false;
      if (mounted) _changed();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.setEnabled(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
