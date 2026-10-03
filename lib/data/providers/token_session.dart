import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../../domain/web_tokens.dart';
import '../http.dart';
import '../state_store.dart';

class TokenSession {
  TokenSession(this.credential, {required this.managed});
  Credential credential;
  final bool managed;
  String get access => credential.field('accessToken');
  String get refresh => credential.field('refreshToken');
  String field(String key) => credential.field(key);
}

/// Serializes rotating tokens and keeps each request bound to its saved owner.
class TokenSessions {
  TokenSessions(this.platform, this.store, {int Function()? now})
    : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final CloudPlatform platform;
  final CredentialStore store;
  final int Function() now;
  final gate = AsyncGate();

  TokenSession open(Credential credential, {bool candidate = false}) {
    final session = TokenSession(credential, managed: !candidate);
    checkpoint(session);
    return session;
  }

  void checkpoint(TokenSession session) {
    RequestScope.checkpoint();
    if (!session.managed) return;
    final current = store.credential(platform);
    if (current == null) {
      throw AccountLoginRequired('${platform.shortName}账号已移除，请重新登录');
    }
    require(
      LoginCredentials.sameWebTokenSession(session.credential, current),
      '${platform.shortName}账号已变化，请重新打开文件列表',
    );
    session.credential = current;
  }

  bool expired(TokenSession session) {
    final expiry =
        int.tryParse(session.field('expiresAt')) ??
        WebTokens.jwtExpiry(session.access);
    return session.access.isEmpty || expiry > 0 && expiry <= now() + 60000;
  }

  Future<void> fresh(
    TokenSession session,
    Future<void> Function(TokenSession) renew, {
    bool force = false,
    String? rejectedAccess,
  }) async {
    checkpoint(session);
    if (!force && !expired(session)) return;
    await RequestScope.cancellable(
      gate.run(() async {
        checkpoint(session);
        if (force &&
            rejectedAccess != null &&
            session.access != rejectedAccess &&
            session.access.isNotEmpty) {
          return;
        }
        if (!force && !expired(session)) return;
        if (session.refresh.isEmpty) {
          throw AccountLoginRequired('${platform.shortName}登录已过期，请重新网页登录');
        }
        await renew(session);
        checkpoint(session);
      }),
    );
  }

  Future<void> update(TokenSession session, Map<String, String> fields) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      checkpoint(session);
      final previous = session.credential;
      final userId = fields['userId'] ?? '';
      require(
        userId.isEmpty ||
            previous.field('userId').isEmpty ||
            userId == previous.field('userId'),
        '${platform.shortName}返回的账号不一致，请重新登录',
      );
      final updated = previous.withFields(fields, preserveRevision: true);
      if (!session.managed) {
        session.credential = updated;
        return;
      }
      final cancel = RequestScope.current;
      final committed = await store.replaceCredential(
        platform,
        previous,
        updated,
        canCommit: () => cancel?.isCancelled != true,
      );
      checkpoint(session);
      if (committed) return;
    }
    throw AppException('${platform.shortName}登录信息保存失败，请重试');
  }

  Map<String, String> refreshedFields(TokenSession session, Json data) {
    final access = data.str('access_token').ifEmpty(data.str('accessToken'));
    final refresh = data
        .str('refresh_token')
        .ifEmpty(data.str('refreshToken'))
        .ifEmpty(session.refresh);
    require(WebTokens.validToken(access), '${platform.shortName}未返回有效登录凭据');
    require(
      refresh.isEmpty || WebTokens.validToken(refresh),
      '${platform.shortName}返回的续期凭据无效',
    );
    var expires = WebTokens.epochMilliseconds(
      data.str('expire_time').ifEmpty(data.str('expires_at')),
    );
    final seconds = data.integer('expires_in', data.integer('expiresIn'));
    if (expires == 0 && seconds > 0) expires = now() + seconds * 1000;
    if (expires == 0) expires = WebTokens.jwtExpiry(access);
    return {
      'primary':
          platform == CloudPlatform.aliyun || platform == CloudPlatform.wopan
          ? refresh
          : access,
      'accessToken': access,
      'refreshToken': refresh,
      'expiresAt': '$expires',
      if (data.str('user_id').ifEmpty(data.str('sub')).isNotEmpty)
        'userId': data.str('user_id').ifEmpty(data.str('sub')),
      if (data.str('nick_name').ifEmpty(data.str('nickname')).isNotEmpty)
        'nickname': data.str('nick_name').ifEmpty(data.str('nickname')),
      for (final pair in const [
        ('default_drive_id', 'defaultDriveId'),
        ('resource_drive_id', 'resourceDriveId'),
        ('backup_drive_id', 'backupDriveId'),
      ])
        if (data.str(pair.$1).isNotEmpty) pair.$2: data.str(pair.$1),
    };
  }
}

String checkedCloudUrl(String value, String message) {
  final uri = Uri.tryParse(value);
  require(
    uri != null &&
        {'https', 'http'}.contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !RegExp(r'[\x00-\x20\x7f]').hasMatch(value),
    message,
  );
  return value;
}

(String?, String?) cloudChecksum(String type, String value) {
  final algorithm = type.toLowerCase().replaceAll('-', '');
  final length = const {'md5': 32, 'sha1': 40, 'sha256': 64}[algorithm];
  return length != null && RegExp('^[a-fA-F0-9]{$length}\$').hasMatch(value)
      ? (algorithm, value.toLowerCase())
      : (null, null);
}

void cloudFileName(String name) => require(
  name.trim().isNotEmpty &&
      !{'.', '..'}.contains(name.trim()) &&
      !RegExp(r'[/\\\x00-\x1f]').hasMatch(name),
  '文件名不能包含路径分隔符或控制字符',
);
