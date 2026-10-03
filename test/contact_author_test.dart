import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/contact_author_dialog.dart';

void main() {
  testWidgets('Contact dialog copies only the email and closes', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showContactAuthorDialog(context),
              child: const Text('联系'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('联系'));
    await tester.pumpAndSettle();
    expect(find.text('联系作者/侵权投诉'), findsOneWidget);
    expect(
      find.text('本项目为开源项目，仅供学习交流，如果侵犯了贵公司的合法权益，请整理相应材料发送到a7786@foxmail.com'),
      findsOneWidget,
    );
    await tester.tap(find.text('复制邮箱'));
    await tester.pumpAndSettle();
    expect(copied, 'a7786@foxmail.com');
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
