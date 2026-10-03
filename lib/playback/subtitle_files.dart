import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import '../domain/models.dart';

class SubtitleFiles {
  SubtitleFiles(this.directory);
  final Directory directory;
  static const maximumBytes = 8 * 1024 * 1024;
  static const extensions = ['srt', 'vtt', 'ass', 'ssa'];
  Future<File> stage(String name, Stream<List<int>> stream) async {
    final extension = p.extension(name).toLowerCase().replaceFirst('.', '');
    require(extensions.contains(extension), '请选择 SRT、VTT、ASS 或 SSA 字幕');
    final data = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      require(data.length + chunk.length <= maximumBytes, '字幕文件不能超过 8 MB');
      data.add(chunk);
    }
    require(data.length > 0, '字幕文件为空');
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, '${newId()}.$extension'));
    try {
      return await file.writeAsBytes(data.takeBytes(), flush: true);
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }
}
