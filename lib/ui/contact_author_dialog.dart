import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'common.dart';

const authorEmail = 'a7786@foxmail.com';

Future<void> showContactAuthorDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: const Text('联系作者/侵权投诉'),
    content: const SingleChildScrollView(
      child: SelectableText(
        '本项目为开源项目，仅供学习交流，如果侵犯了贵公司的合法权益，请整理相应材料发送到a7786@foxmail.com',
        style: TextStyle(height: 1.7),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('关闭'),
      ),
      FilledButton(
        onPressed: () async {
          try {
            await Clipboard.setData(const ClipboardData(text: authorEmail));
            if (context.mounted) message(context, '邮箱已复制');
          } catch (_) {
            if (context.mounted) message(context, '复制失败，请长按邮箱手动复制');
          }
        },
        child: const Text('复制邮箱'),
      ),
    ],
  ),
);
