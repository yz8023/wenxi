import 'dart:async';
import 'dart:convert';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/remote_control_http.dart';
import 'package:asterlink/data/remote_control_service.dart';

const controlEndpoint = 'https://config.example.test/control.json';
final controlNow = DateTime(2026, 9, 19, 12);

Json controlJson({
  int revision = 1,
  String? noticeId,
  int? androidBuild,
  int? windowsBuild,
  bool force = false,
  String? buttonText,
  String? buttonUrl,
  List<String> disabled = const [],
  bool help = false,
}) => {
  'schema': 1,
  'revision': revision,
  if (noticeId != null)
    'announcement': {
      'enabled': true,
      'id': noticeId,
      'title': '维护公告',
      'content': '网盘维护说明\n稍后恢复服务。',
      'buttonText': ?buttonText,
      'buttonUrl': ?buttonUrl,
    },
  'clouds': {
    for (final platform in disabled)
      platform: {'enabled': false, 'message': '网盘维护中，请稍后再试'},
  },
  'updates': {
    for (final entry in {
      'android': androidBuild,
      'windows': windowsBuild,
    }.entries)
      if (entry.value != null)
        entry.key: {
          'enabled': true,
          'force': force,
          'version': '0.4.0',
          'build': entry.value,
          'downloadUrl': 'https://download.example.test/${entry.key}',
          'notes': '改善网盘体验\n修复已知问题',
        },
  },
  'help': {'enabled': help, 'url': 'https://help.example.test/guide#cloud'},
};

Json controlCache(
  Json config, {
  DateTime? fetched,
  String endpoint = controlEndpoint,
}) => {
  RemoteControlService.cacheKey: {
    'endpoint': endpoint,
    'fetchedAt': (fetched ?? controlNow).millisecondsSinceEpoch,
    'control': config,
  },
};

class FakeControlFetcher implements RemoteControlFetcher {
  FakeControlFetcher([Json? config])
    : text = jsonEncode(config ?? controlJson());
  String text;
  FutureOr<String> Function(Uri)? respond;
  final calls = <Uri>[];
  bool closed = false;
  @override
  Future<String> fetch(Uri endpoint) async {
    calls.add(endpoint);
    return respond == null ? text : await respond!(endpoint);
  }

  @override
  void close() => closed = true;
}
