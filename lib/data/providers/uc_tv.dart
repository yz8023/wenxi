import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../http.dart';
import '../state_store.dart';
import 'uc_tv_protocol.dart';

class UcTvAuthorization {
  UcTvAuthorization._(
    this.qr,
    this.device,
    this.owner,
    this.generation,
    this.grant,
  );
  final UcTvQrCode qr;
  final String device, grant;
  final Credential owner;
  final int generation;
  bool _polling = false, _complete = false;
}

/// TV grants belong to the current explicit web login. Automatic Cookie/token
/// renewal preserves its revision; another web login drops the TV fields.
class UcTvService {
  UcTvService(JsonHttp http, {this.store, int Function()? now})
    : protocol = UcTvProtocol(http, now: now);

  final CredentialStore? store;
  final UcTvProtocol protocol;
  final _refreshGate = AsyncGate();
  int _authorizationGeneration = 0;
  static const _keys = {
    'tv_access_token',
    'tv_refresh_token',
    'tv_access_token_expires_at',
    'tv_device_id',
    'tv_grant_id',
    'tv_status',
    'tv_nickname',
  };

  static bool authorized(Credential? c) =>
      c != null &&
      c.primary.isNotEmpty &&
      c.field('tv_status') != 'expired' &&
      c.field('tv_grant_id').isNotEmpty &&
      UcTvProtocol.validDevice(c.field('tv_device_id')) &&
      (UcTvProtocol.validSecret(c.field('tv_access_token')) ||
          UcTvProtocol.validSecret(c.field('tv_refresh_token')));

  static String status(Credential? c) => authorized(c)
      ? '已授权 · 自动选择最高可用画质'
      : c?.field('tv_status') == 'expired'
      ? '授权已失效 · 请重新扫码'
      : '未授权 · 扫码后可使用 TV 播放';

  Credential _owner(Credential expected) {
    RequestScope.checkpoint();
    final current = store == null
        ? expected
        : store!.credential(CloudPlatform.uc);
    require(
      current != null &&
          current.updatedAt == expected.updatedAt &&
          current.label == expected.label,
      'UC 账号已变化，请重新打开授权页面或文件列表',
    );
    return current!;
  }

  Credential _grant(Credential expected) {
    final current = _owner(expected);
    if (!authorized(current)) throw const UcTvAuthorizationRequired();
    require(
      current.field('tv_grant_id') == expected.field('tv_grant_id'),
      'UC TV 授权已变化，请重新播放',
    );
    return current;
  }

  void cancelAuthorization() => ++_authorizationGeneration;

  void _checkAuthorization(UcTvAuthorization authorization) {
    require(
      authorization.generation == _authorizationGeneration,
      'UC TV 扫码已取消，请重新获取二维码',
    );
    final current = _owner(authorization.owner);
    require(
      current.field('tv_grant_id') == authorization.owner.field('tv_grant_id'),
      'UC TV 授权已变化，请重新打开授权页面',
    );
    require(protocol.now() < authorization.qr.expiresAt, '二维码已超时，请重新获取');
  }

  Future<UcTvAuthorization> beginAuthorization() async {
    final generation = ++_authorizationGeneration;
    final owner = store?.credential(CloudPlatform.uc);
    if (owner == null ||
        !LoginCredentials.plausible(CloudPlatform.uc, owner.primary)) {
      throw const AccountLoginRequired('请先完成 UC 网页登录，再授权 TV 播放');
    }
    final previousDevice = owner.field('tv_device_id');
    final device = UcTvProtocol.validDevice(previousDevice)
        ? previousDevice
        : newId().replaceAll('-', '');
    final qr = await protocol.authorize(device);
    final authorization = UcTvAuthorization._(
      qr,
      device,
      owner,
      generation,
      newId(),
    );
    _checkAuthorization(authorization);
    return authorization;
  }

  Future<bool> pollAuthorization(UcTvAuthorization authorization) async {
    if (authorization._complete) {
      final current = _owner(authorization.owner);
      require(
        current.field('tv_grant_id') == authorization.grant &&
            authorized(current),
        'UC TV 授权已变化，请重新打开授权页面',
      );
      return true;
    }
    _checkAuthorization(authorization);
    require(!authorization._polling, '正在等待扫码确认');
    authorization._polling = true;
    try {
      final code = await protocol.pollCode(
        authorization.device,
        authorization.qr.queryToken,
      );
      _checkAuthorization(authorization);
      if (code == null) return false;
      final tokens = await protocol.exchange(authorization.device, code: code);
      _checkAuthorization(authorization);
      final user = await protocol.userInfo(authorization.device, tokens.access);
      _checkAuthorization(authorization);
      await _write(
        authorization.owner,
        {
          'tv_access_token': tokens.access,
          'tv_refresh_token': tokens.refresh,
          'tv_access_token_expires_at': '${tokens.expiresAt}',
          'tv_device_id': authorization.device,
          'tv_grant_id': authorization.grant,
          'tv_status': 'authorized',
          'tv_nickname': user.str('nickname').ifEmpty(user.str('nick_name')),
        },
        canCommit: () => authorization.generation == _authorizationGeneration,
      );
      authorization._complete = true;
      DiagnosticLog.event(
        'uc_tv.authorization_saved',
        fields: {'platform': 'uc'},
      );
      return true;
    } finally {
      authorization._polling = false;
    }
  }

  Future<Credential> _write(
    Credential expected,
    Map<String, String> fields, {
    bool Function()? canCommit,
  }) async {
    final cancellation = RequestScope.current;
    for (var attempt = 0; attempt < 4; attempt++) {
      final current = _owner(expected);
      require(
        current.field('tv_grant_id') == expected.field('tv_grant_id') &&
            (canCommit?.call() ?? true),
        'UC TV 授权已变化，请重新操作',
      );
      final replacement = current.withFields(fields, preserveRevision: true);
      if (store == null) return replacement;
      final saved = await store!.replaceCredential(
        CloudPlatform.uc,
        current,
        replacement,
        canCommit: () =>
            cancellation?.isCancelled != true && (canCommit?.call() ?? true),
      );
      RequestScope.checkpoint();
      if (saved) return replacement;
    }
    throw const AppException('UC 登录信息正在更新，请稍后重试');
  }

  Future<void> removeAuthorization() async {
    cancelAuthorization();
    final owner = store?.credential(CloudPlatform.uc);
    if (owner == null) return;
    await _write(owner, {
      for (final key in _keys) key: '',
      'tv_grant_id': newId(),
    });
  }

  Future<Credential> _fresh(Credential expected, {String? rejectedAccess}) =>
      _refreshGate.run(() async {
        final current = _grant(expected);
        final access = current.field('tv_access_token');
        final expiresAt =
            int.tryParse(current.field('tv_access_token_expires_at')) ?? 0;
        if (UcTvProtocol.validSecret(access) &&
            (rejectedAccess != null
                ? access != rejectedAccess
                : expiresAt > protocol.now() + 60000)) {
          return current;
        }
        final refresh = current.field('tv_refresh_token');
        if (!UcTvProtocol.validSecret(refresh)) {
          await _markExpired(current);
          throw const UcTvAuthorizationRequired('UC TV 播放授权已过期，请重新扫码');
        }
        UcTvTokens tokens;
        try {
          tokens = await protocol.exchange(
            current.field('tv_device_id'),
            refresh: refresh,
          );
        } on UcTvAuthorizationRequired {
          await _markExpired(current);
          rethrow;
        }
        _grant(current);
        final updated = await _write(current, {
          'tv_access_token': tokens.access,
          'tv_refresh_token': tokens.refresh,
          'tv_access_token_expires_at': '${tokens.expiresAt}',
          'tv_status': 'authorized',
        });
        DiagnosticLog.event(
          'uc_tv.authorization_refreshed',
          fields: {'platform': 'uc'},
        );
        return updated;
      });

  Future<void> _markExpired(Credential expected) async {
    final current = store == null
        ? expected
        : store!.credential(CloudPlatform.uc);
    if (current == null ||
        current.updatedAt != expected.updatedAt ||
        current.field('tv_grant_id') != expected.field('tv_grant_id')) {
      return;
    }
    try {
      await _write(expected, {'tv_status': 'expired'});
    } on AppException {
      final latest = store?.credential(CloudPlatform.uc);
      if (store == null ||
          latest?.updatedAt == expected.updatedAt &&
              latest?.field('tv_grant_id') == expected.field('tv_grant_id')) {
        rethrow;
      }
    }
  }

  Future<Credential> ensureAuthorized(Credential expected) => _fresh(expected);

  Future<DownloadSpec> download(
    Credential expected,
    String fid,
    CloudFile file,
  ) async {
    var current = await _fresh(expected);
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final result = await protocol.download(
          current.field('tv_device_id'),
          current.field('tv_access_token'),
          fid,
          file,
        );
        _grant(current);
        DiagnosticLog.event(
          'uc_tv.download_source',
          fields: {
            'platform': 'uc',
            'file': DiagnosticLog.reference(fid),
            'strategy': 'original_file',
          },
        );
        return result;
      } on UcTvAuthorizationRequired {
        if (attempt == 1) {
          await _markExpired(current);
          rethrow;
        }
        current = await _fresh(
          current,
          rejectedAccess: current.field('tv_access_token'),
        );
      }
    }
    throw const UcTvAuthorizationRequired();
  }

  Future<DownloadSpec> playback(
    Credential expected,
    String fid,
    String name,
  ) async {
    var current = await _fresh(expected);
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final result = await protocol.streaming(
          current.field('tv_device_id'),
          current.field('tv_access_token'),
          fid,
          name,
        );
        _grant(current);
        DiagnosticLog.event(
          'uc_tv.playback_source',
          fields: {
            'platform': 'uc',
            'file': DiagnosticLog.reference(fid),
            'strategy': 'highest_available',
          },
        );
        return result;
      } on UcTvAuthorizationRequired {
        if (attempt == 1) {
          await _markExpired(current);
          rethrow;
        }
        current = await _fresh(
          current,
          rejectedAccess: current.field('tv_access_token'),
        );
      }
    }
    throw const UcTvAuthorizationRequired();
  }
}
