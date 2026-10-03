import 'dart:async';
import 'package:flutter/material.dart';
import '../data/remote_control_service.dart';
import '../diagnostics/app_log.dart';

Future<void> showWenxiAbout(
  BuildContext context,
  RemoteControlService control,
) async {
  unawaited(control.refresh(force: true));
  await showDialog<void>(
    context: context,
    builder: (context) => AnimatedBuilder(
      animation: control,
      builder: (context, _) => AlertDialog(
        title: Row(
          children: [
            Image.asset('assets/icons/app.png', width: 44, height: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('文析助手'),
                  Text(
                    applicationVersion.split('+').first,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: SelectableText(
            control.config.aboutText,
            style: const TextStyle(height: 1.6),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    ),
  );
}
