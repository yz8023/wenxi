import 'package:asterlink/core/json.dart';

const githubRepository = 'z7786/wenxi';

Json githubRelease({
  String tag = 'v0.6.0+54',
  List<String> files = const [
    'asterlink-0.6.0+54-android-arm64.apk',
    'asterlink-0.6.0+54-windows-x64-setup.exe',
  ],
  String repository = githubRepository,
}) => {
  'tag_name': tag,
  'draft': false,
  'prerelease': false,
  'body': '更新说明\n修复已知问题',
  'assets': [
    for (final name in files)
      {
        'name': name,
        'state': 'uploaded',
        'size': 123456,
        'browser_download_url': Uri.https(
          'github.com',
          '/$repository/releases/download/$tag/$name',
        ).toString(),
      },
  ],
};
