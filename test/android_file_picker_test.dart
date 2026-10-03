import 'dart:io';
import 'dart:typed_data';
import 'package:file_selector_android/file_selector_android.dart';
import 'package:file_selector_android/src/file_selector_api.g.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api extends FileSelectorApi {
  _Api(this.path);
  final String path;
  @override
  Future<List<FileResponse>> openFiles(
    String? directory,
    FileTypes types,
  ) async => [
    FileResponse(
      path: path,
      name: 'selected.bin',
      size: 0,
      bytes: Uint8List(0),
    ),
  ];
}

void main() {
  test(
    'Android selected files stream from disk and support upload ranges',
    () async {
      final dir = await Directory.systemTemp.createTemp('picker-test-');
      try {
        final file = await File(
          '${dir.path}/selected.bin',
        ).writeAsBytes([1, 2, 3, 4, 5]);
        final files = await FileSelectorAndroid(
          api: _Api(file.path),
        ).openFiles();
        expect(files.single.path, file.path);
        expect(await files.single.length(), 5);
        expect(
          await files.single.openRead(1, 4).expand((bytes) => bytes).toList(),
          [2, 3, 4],
        );
        await file.writeAsBytes([6, 7, 8]);
        expect(await files.single.length(), 3);
        expect(await files.single.readAsBytes(), [6, 7, 8]);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
