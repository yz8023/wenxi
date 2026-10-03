import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/platform/windows_actions.dart';

void main() {
  test(
    'Explorer selects an existing path as arguments without a shell',
    () async {
      final root = await Directory.systemTemp.createTemp('wenxi-explorer-');
      addTearDown(() => root.delete(recursive: true));
      final file = await File(
        '${root.path}/中文 video & (1).mp4',
      ).writeAsString('x');
      final calls = <(String, List<String>)>[];
      final windows = WindowsActions(
        supported: true,
        start: (command, arguments) async => calls.add((command, arguments)),
        run: (_, _) async => fail('No shutdown expected'),
      );
      await windows.revealFile(file.path);
      expect(calls.single.$1, 'explorer.exe');
      expect(calls.single.$2, ['/select,', p.normalize(file.path)]);
      calls.clear();
      await windows.revealFile(root.path);
      expect(calls.single.$2, [root.path]);
      await file.delete();
      await expectLater(
        windows.revealFile(file.path),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        windows.revealFile('relative.mp4'),
        throwsA(isA<AppException>()),
      );
      expect(calls.length, 1);
    },
  );

  test(
    'Shutdown request uses no force, restart, or system countdown',
    () async {
      final calls = <(String, List<String>)>[];
      final windows = WindowsActions(
        supported: true,
        start: (_, _) async => fail('No process start expected'),
        run: (command, arguments) async => calls.add((command, arguments)),
      );
      await windows.shutdown();
      expect(calls.single.$1, 'shutdown.exe');
      expect(calls.single.$2, ['/s', '/t', '0']);
      final unavailable = WindowsActions(
        supported: false,
        run: (_, _) async => fail('Unsupported platform must not run commands'),
      );
      await expectLater(unavailable.shutdown(), throwsA(isA<AppException>()));
    },
  );
}
