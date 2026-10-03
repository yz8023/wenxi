import 'dart:io';

// This script deliberately uses only the Dart SDK, so it runs before pub get.
void main(List<String> arguments) {
  try {
    final write = arguments.contains('--write');
    String? tag;
    for (var i = 0; i < arguments.length; i++) {
      switch (arguments[i]) {
        case '--write':
        case '--check':
          break;
        case '--tag':
          if (++i == arguments.length) {
            throw const FormatException('--tag requires a value');
          }
          tag = arguments[i];
        default:
          throw FormatException('Unknown argument: ${arguments[i]}');
      }
    }
    if (write && arguments.contains('--check')) {
      throw const FormatException('Choose --write or --check');
    }
    final root = File.fromUri(Platform.script).parent.parent;
    final pubspec = File('${root.path}/pubspec.yaml').readAsStringSync();
    final versions = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)\+([1-9]\d*)\s*$',
      multiLine: true,
    ).allMatches(pubspec).toList();
    if (versions.length != 1) {
      throw const FormatException(
        'pubspec.yaml must contain one version: major.minor.patch+build',
      );
    }
    final version = '${versions.single[1]}+${versions.single[2]}';
    if (int.parse(versions.single[2]!) > 2100000000) {
      throw const FormatException('Build number exceeds the Android limit');
    }
    if (tag != null && tag != 'v$version') {
      throw FormatException('Release tag must be v$version');
    }
    final generated = File('${root.path}/lib/core/app_version.dart');
    final expected =
        '// Generated from pubspec.yaml by tool/sync_version.dart. Do not edit by hand.\n'
        "const applicationVersion = '$version';\n";
    if (write) {
      generated.parent.createSync(recursive: true);
      generated.writeAsStringSync(expected);
    } else if (!generated.existsSync() ||
        generated.readAsStringSync().replaceAll('\r\n', '\n') != expected) {
      throw const FormatException(
        'Generated version is stale. Run dart tool/sync_version.dart --write',
      );
    }
    stdout.writeln('Version ${write ? 'generated' : 'verified'}: $version');
  } on Object catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
