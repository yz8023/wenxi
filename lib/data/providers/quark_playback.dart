import 'dart:convert';
import 'dart:math';
import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../../domain/auth.dart';
import '../http.dart';

/// Playback authorization recovered from MoePal 4.3.0's ARM64 call sites.
/// Only protocol fields are reused; cookies and tokens belong to this session.
class QuarkPlaybackSource {
  QuarkPlaybackSource(this.http, {required this.headers});
  final JsonHttp http;
  final Map<String, String> Function() headers;

  // MoePal's sendToPC target (conversation_type 3), also its token fallback.
  // See caiiliao/01_MoePal解包/夸克播放分析-2026-09-16, 0x8d6d38.
  static const pcConversation = '3000008641494773';
  static const _social =
      'https://drive-social-api.quark.cn/1/clouddrive/chat/conv';
  static const _socialQuery = '?pr=ucpro&fr=pc&sys=win32&ve=3.19.0';
  static const _download =
      'https://drive-pc.quark.cn/1/clouddrive/file/download'
      '?pr=ucpro&fr=pc&sys=win32&ve=3.23.2';
  static final _random = Random.secure();

  String _localId() =>
      '${DateTime.now().millisecondsSinceEpoch}'
      '${_random.nextInt(1000000).toString().padLeft(6, '0')}';

  Future<Json> resolve(String fid, String name) async {
    RequestScope.checkpoint();
    require(_identifier(fid).isNotEmpty, '夸克播放文件标识缺失，请刷新文件列表');
    final message = await _post(
      'batch_send',
      '快传准备',
      '$_social/msg/batch_send$_socialQuery',
      {
        'conversations': [
          {
            'merge_file': 0,
            'conversation_id': pcConversation,
            'conversation_type': 3,
            'file_list': [
              {
                'fid': fid,
                'content': name,
                'client_extra': {
                  'group_id': _localId(),
                  'device_model': 'Administrator',
                  'local_msg_id': _localId(),
                },
              },
            ],
          },
        ],
        'return_msg_as_list': 1,
      },
      (data) => _message(data, fid),
    );
    String token;
    try {
      token = await _token(message.conversation, message.id);
    } on _QuarkPlaybackResponseError {
      // Retry only a rejected/missing token with the PC target, once. Network
      // cancellation, logout and changed-account errors must propagate.
      if (message.conversation == pcConversation) rethrow;
      RequestScope.checkpoint();
      token = await _token(pcConversation, message.id, attempt: 2);
    }
    return _post('file_download', '播放取址', _download, {
      'fids': [fid],
      'speedup_session': '',
      'token': token,
    }, (data) => _downloadItem(data, fid));
  }

  Future<String> _token(
    String conversation,
    String message, {
    int attempt = 1,
  }) => _post(
    'acquire_dl_token',
    '快传授权',
    '$_social/file/acquire_dl_token$_socialQuery',
    {
      'conversation_id': conversation,
      'conversation_type': 3,
      'msg_id': message,
    },
    (data) {
      final token = _object(data)['token'];
      if (token is! String ||
          token.isEmpty ||
          token.length > 32768 ||
          token.toLowerCase() == 'null' ||
          RegExp(r'\s|[\x00-\x1f\x7f]').hasMatch(token)) {
        throw const _QuarkPlaybackResponseError('夸克快传授权未返回有效令牌，请稍后重试');
      }
      return token;
    },
    attempt: attempt,
  );

  Future<T> _post<T>(
    String stage,
    String label,
    String endpoint,
    Json body,
    T Function(Object?) parse, {
    int attempt = 1,
  }) async {
    final watch = Stopwatch()..start();
    int? status, code;
    Map<String, Object?> fields() => {
      'platform': 'Quark',
      'route': 'fast_transfer',
      'stage': stage,
      'attempt': attempt,
      'httpStatus': ?status,
      'responseCode': ?code,
      'elapsedMs': watch.elapsedMilliseconds,
    };
    try {
      RequestScope.checkpoint();
      final response = await http.postJson(endpoint, body, headers());
      RequestScope.checkpoint();
      status = response.status;
      if (status == 401) {
        throw const AccountLoginRequired('夸克 登录已失效，请重新网页登录');
      }
      Json json;
      try {
        json = response.json;
      } on AppException {
        throw _QuarkPlaybackResponseError('夸克$label响应格式无效（HTTP $status）');
      }
      code = int.tryParse(json.str('code'));
      final businessStatus = int.tryParse(json.str('status'));
      if (status == 401 || businessStatus == 401 || code == 31001) {
        throw const AccountLoginRequired('夸克 登录已失效，请重新网页登录');
      }
      if (!response.successful ||
          code != 0 ||
          json.containsKey('status') && businessStatus != 200) {
        throw _QuarkPlaybackResponseError(
          '夸克$label失败（HTTP $status${code == null ? '' : '，服务码 $code'}），请稍后重试',
        );
      }
      final value = parse(json['data']);
      DiagnosticLog.event('cloud.playback_source', fields: fields());
      return value;
    } catch (error, stack) {
      if (RequestScope.current?.isCancelled != true) {
        DiagnosticLog.error(
          'cloud.playback_source_failed',
          error,
          stack,
          fields: fields(),
        );
      }
      rethrow;
    }
  }

  static ({String id, String conversation}) _message(Object? data, String fid) {
    final root = _object(data);
    final raw = root['send_msg_list'];
    final messages = raw is List
        ? raw.map(_object).toList()
        : [_object(raw ?? root)];
    final item = _select(messages, fid, '快传消息');
    final id = _identifier(
      item['store_msg_id'],
    ).ifEmpty(_identifier(item['msg_id'])).ifEmpty(_identifier(item['id']));
    if (id.isEmpty) {
      throw const _QuarkPlaybackResponseError('夸克快传准备未返回消息标识，请稍后重试');
    }
    final type = item['conversation_type'] ?? root['conversation_type'];
    if (type != null && '$type' != '3') {
      throw const _QuarkPlaybackResponseError('夸克快传会话类型不匹配，请稍后重试');
    }
    return (
      id: id,
      conversation: _identifier(
        item['conversation_id'],
      ).ifEmpty(_identifier(root['conversation_id'])).ifEmpty(pcConversation),
    );
  }

  static Json _downloadItem(Object? data, String fid) {
    final root = _object(data);
    final raw = data is List ? data : root['data'] ?? root;
    final items = raw is List ? raw.map(_object).toList() : [_object(raw)];
    final item = _select(items, fid, '播放地址');
    final url = item.str('download_url').ifEmpty(item.str('url'));
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(url)) {
      throw const _QuarkPlaybackResponseError('夸克快传未返回有效播放地址，请稍后重试');
    }
    if (item.containsKey('size') &&
        (int.tryParse(item.str('size')) ?? -1) < 0) {
      throw const _QuarkPlaybackResponseError('夸克播放文件大小无效，请刷新文件列表');
    }
    return {...item, 'download_url': url};
  }

  /// One file is requested at a time. A response without a fid is usable only
  /// if it is the sole entry; never guess between files or use a foreign fid.
  static Json _select(List<Json> items, String fid, String label) {
    Set<String> identities(Json item) {
      final extra = _object(item['extra']);
      final custom = _object(extra['custom_extra']);
      return {
        for (final node in [
          item,
          _object(item['file']),
          _object(custom['file']),
        ])
          if (node['fid'] != null) _identifier(node['fid']),
      };
    }

    final matches = items.where((item) {
      final ids = identities(item);
      return ids.length == 1 && ids.single == fid;
    }).toList();
    if (matches.length == 1) return matches.single;
    if (matches.isEmpty &&
        items.length == 1 &&
        identities(items.single).isEmpty) {
      return items.single;
    }
    throw _QuarkPlaybackResponseError('夸克$label与所选文件不匹配，请刷新列表后重试');
  }

  // Some responses serialize metadata as JSON. Decode only known containers,
  // never regex-scan an unrelated file's response for a convenient message ID.
  static Json _object(Object? value) {
    for (var depth = 0; depth < 2 && value is String; depth++) {
      if (value.length > 128 * 1024) return {};
      try {
        value = jsonDecode(value);
      } on FormatException {
        return {};
      }
    }
    return asJson(value);
  }

  static String _identifier(Object? value) {
    if (value is! String && value is! int) return '';
    final text = '$value';
    if (text.isEmpty ||
        text.length > 512 ||
        text == '0' ||
        text.toLowerCase() == 'null' ||
        RegExp(r'\s|[\x00-\x1f\x7f]').hasMatch(text)) {
      return '';
    }
    return text;
  }
}

class _QuarkPlaybackResponseError extends AppException {
  const _QuarkPlaybackResponseError(super.message);
}
