import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/json.dart';
import 'models.dart';

part 'remote_control_parser.dart';

/// Remote configuration only controls the features declared in this schema.
/// Remote text is displayed as plain text and links are opened by user action.
class RemoteControlConfig {
  const RemoteControlConfig({
    this.revision = 0,
    this.announcement,
    this.clouds = const {},
    this.updates = const {},
    this.helpUrl,
    this.aboutDescription = '',
  });

  static const defaults = RemoteControlConfig();
  static const maxBytes = 256 * 1024;
  final int revision;
  final RemoteAnnouncement? announcement;
  final Map<CloudPlatform, CloudControl> clouds;
  final Map<String, RemoteUpdate> updates;
  final Uri? helpUrl;
  final String aboutDescription;
  static const defaultAboutDescription =
      '网盘文件管理与 Gopeed 下载器\nAndroid · Windows';
  String get aboutText =>
      aboutDescription.isEmpty ? defaultAboutDescription : aboutDescription;

  CloudControl cloud(CloudPlatform platform) =>
      clouds[platform] ?? const CloudControl();

  factory RemoteControlConfig.decode(String text) =>
      RemoteControlDocument.decode(text).validated;

  factory RemoteControlConfig.fromJson(Object? value) =>
      RemoteControlDocument.parse(value).validated;

  Json toJson() => {
    'schema': 1,
    'revision': revision,
    if (announcement case final notice?)
      'announcement': {
        'enabled': true,
        if (notice.id.isNotEmpty) 'id': notice.id,
        'title': notice.title,
        'content': notice.content,
        if (notice.buttonUrl != null) ...{
          'buttonText': notice.buttonText,
          'buttonUrl': notice.buttonUrl.toString(),
        },
      },
    'clouds': {
      for (final p in CloudPlatform.values)
        p.name: {
          'enabled': cloud(p).enabled,
          'message': cloud(p).message,
          if (cloud(p).expiresAt != null)
            'expiresAt': cloud(p).expiresAt!.toUtc().toIso8601String(),
        },
    },
    'updates': {
      for (final platform in ['android', 'windows'])
        if (updates[platform] case final update?)
          platform: {
            'enabled': true,
            'force': update.force,
            'version': update.version,
            'build': update.build,
            'downloadUrl': update.downloadUrl.toString(),
            'notes': update.notes,
            if (update.expiresAt != null)
              'expiresAt': update.expiresAt!.toUtc().toIso8601String(),
          },
    },
    if (helpUrl != null) 'help': {'enabled': true, 'url': helpUrl.toString()},
    if (aboutDescription.isNotEmpty) 'about': {'description': aboutDescription},
  };
}

class CloudControl {
  const CloudControl({this.enabled = true, this.message = '', this.expiresAt});
  final bool enabled;
  final String message;
  final DateTime? expiresAt;
  String reason(CloudPlatform platform) =>
      message.isNotEmpty ? message : '${platform.label}暂时停用，请稍后再试';
}

class RemoteAnnouncement {
  const RemoteAnnouncement(
    this.id,
    this.title,
    this.content, {
    this.buttonText = '',
    this.buttonUrl,
  });
  final String id, title, content;
  final String buttonText;
  final Uri? buttonUrl;

  // Local reminder state follows the displayed content, not a publisher-managed
  // ID. Keep the optional ID only for older configurations and clients.
  String get contentKey => sha256
      .convert(
        utf8.encode(
          jsonEncode([title, content, buttonText, buttonUrl?.toString()]),
        ),
      )
      .toString();
}

class RemoteUpdate {
  const RemoteUpdate(
    this.version,
    this.build,
    this.downloadUrl,
    this.notes, {
    this.force = false,
    this.expiresAt,
    this.releaseKey,
  });
  final String version, notes;
  final int build;
  final Uri downloadUrl;
  final bool force;
  final DateTime? expiresAt;
  // GitHub may provide a version without an Android/Windows build number.
  // Keep its reminder identity separate instead of inventing a build number.
  final String? releaseKey;
  String get key => releaseKey ?? 'build:$build';
}

Uri httpsUri(String value) {
  final uri = Uri.tryParse(value);
  if (value.isEmpty ||
      value.length > 2048 ||
      RegExp(r'[\s\x00-\x1f\x7f\\]').hasMatch(value) ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
    throw const FormatException('链接必须是有效的 HTTPS 地址');
  }
  return uri;
}

Map<String, dynamic> _object(Object? value, String field) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('$field 必须是 JSON 对象');
  }
  return value;
}

bool _boolean(Map<String, dynamic> object, String key, {bool fallback = true}) {
  if (!object.containsKey(key)) return fallback;
  final value = object[key];
  if (value is! bool) throw FormatException('$key 必须是 true 或 false');
  return value;
}

String _string(Map<String, dynamic> object, String key, {required int max}) {
  if (!object.containsKey(key)) return '';
  final value = object[key];
  if (value is! String || value.length > max) {
    throw FormatException('$key 必须为不超过 $max 字的文本');
  }
  return value.trim();
}

int _integer(Map<String, dynamic> object, String key, {bool required = false}) {
  if (!object.containsKey(key) && !required) return 0;
  final value = object[key];
  if (value is! int || value < 0 || value > 2147483647) {
    throw FormatException('$key 必须为 0–2147483647 之间的整数');
  }
  return value;
}
