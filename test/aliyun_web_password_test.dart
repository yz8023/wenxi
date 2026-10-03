import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/aliyun_web_password.dart';

void main() {
  test(
    'credentials are excluded from frame scripts and submission can be consumed only once',
    () {
      const username = 'fixture-user';
      const password = ' quotes" \\ \n 😀 </script> ';
      final attempt = AliyunWebPassword(username, password);
      expect(attempt.pending, isTrue);
      expect(attempt.bootstrapScript, isNot(contains(username)));
      expect(attempt.bootstrapScript, isNot(contains(password)));
      expect(attempt.statusScript, isNot(contains(password)));
      final script = attempt.takeSubmissionScript()!;
      expect(script, contains(jsonEncode([username, password])));
      expect(attempt.pending, isFalse);
      expect(attempt.rememberedLogin['loginPassword'], password);
      expect(attempt.takeSubmissionScript(), isNull);
    },
  );

  test('cancelling an attempt prevents a later password submission', () {
    final attempt = AliyunWebPassword('fixture-user', 'fixture-password');
    attempt.clear();
    expect(attempt.rememberedLogin, isEmpty);
    expect(attempt.pending, isFalse);
    expect(attempt.takeSubmissionScript(), isNull);
    expect(AliyunWebPassword('next', 'next').id, isNot(attempt.id));
  });
}
