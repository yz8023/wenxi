import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../platform/clipboard_links.dart';
import 'common.dart';

class ClipboardLinkBanner extends StatelessWidget {
  const ClipboardLinkBanner({
    super.key,
    required this.suggestion,
    required this.onUse,
    required this.onDismiss,
  });
  final ClipboardLinkSuggestion suggestion;
  final VoidCallback onUse, onDismiss;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
    child: Material(
      color: brandBlue.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Row(
          children: [
            const Icon(
              CupertinoIcons.doc_on_clipboard,
              size: 20,
              color: brandBlue,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 2,
                children: [
                  Text(
                    '剪贴板发现${suggestion.label}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  TextButton(onPressed: onUse, child: const Text('填入解析')),
                ],
              ),
            ),
            IconButton(
              tooltip: '忽略此链接',
              onPressed: onDismiss,
              icon: const Icon(CupertinoIcons.xmark, size: 16),
            ),
          ],
        ),
      ),
    ),
  );
}
