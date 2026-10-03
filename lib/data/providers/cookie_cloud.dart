import 'dart:async';
import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../http.dart';
import '../state_store.dart';
import 'quark_uc.dart';

class UcOriginalContentMismatch extends AppException {
  const UcOriginalContentMismatch() : super('UC 返回的内容与所选文件不一致，可能受到外部播放或会员限制');
}

/// Shared UC/Quark session lifetime; each connector keeps its protocol headers.
class CookieCloudConnector extends QuarkUcConnector {
  CookieCloudConnector(
    CloudPlatform platform,
    JsonHttp http, {
    required String webUserAgent,
    required String apiUserAgent,
    CredentialStore? store,
    Future<void> Function(DownloadCleanup)? stageCleanup,
    Duration taskDelay = const Duration(milliseconds: 750),
    int Function()? now,
  }) : this._(
         platform,
         _CookieCloudHttp(
           http,
           store,
           now,
           platform,
           webUserAgent,
           apiUserAgent,
         ),
         taskDelay,
         stageCleanup,
       );

  CookieCloudConnector._(
    CloudPlatform platform,
    this._sessions,
    Duration delay,
    Future<void> Function(DownloadCleanup)? stageCleanup,
  ) : super(platform, _sessions, taskDelay: delay, stageCleanup: stageCleanup);

  final _CookieCloudHttp _sessions;
  @override
  String get ua => quark ? _sessions.apiUserAgent : _sessions.webUserAgent;
  @override
  Map<String, String> headers(String cookie, {bool transfer = false}) => {
    'Cookie': _sessions.current?.cookie ?? cookie,
    'User-Agent': ua,
    'Origin': transfer ? 'https://fast.uc.cn' : origin,
    'Referer': '${transfer ? 'https://fast.uc.cn' : origin}/',
  };
  @override
  String url(String path, [Map<String, Object?> extra = const {}]) =>
      super.url(path, {
        if (path == 'file/sort') '_fetch_sub_dirs': 0,
        if (quark && path == 'file/sort') ...{
          'uc_param_str': '',
          'fetch_all_file': 1,
          'fetch_risk_file_name': 1,
        },
        if (quark && path == 'share/sharepage/detail') ...{
          'force': 0,
          '_fetch_banner': 0,
          '_fetch_share': 0,
          'fetch_relate_conversation': 0,
        },
        if (quark &&
            {
              'file/delete',
              'file/rename',
              'file/move',
              'share',
              'share/password',
            }.contains(path))
          'uc_param_str': '',
        ...extra,
      });

  @override
  Json success(HttpResult result) {
    if (_CookieCloudHttp.loginRequired(result)) {
      throw AccountLoginRequired('${platform.shortName} 登录已失效，请重新网页登录');
    }
    final json = result.json;
    final status = int.tryParse(json.str('status'));
    final code = int.tryParse(json.str('code'));
    require(
      result.successful &&
          (status == 200 || status == null && code == 0) &&
          (!json.containsKey('code') || code == 0),
      json
          .str('message')
          .ifEmpty('${platform.shortName} 请求失败（HTTP ${result.status}）'),
    );
    require(
      json['data'] is Map || json['data'] is List,
      '${platform.shortName} 响应缺少有效数据，请重试',
    );
    return json['data'] is Map ? json.obj('data') : {'data': json['data']};
  }

  /// Keep renewed cookies from candidate validation in the final login result;
  /// the login service remains responsible for atomically replacing the account.
  Future<LoginResult> authenticate(Credential credential) =>
      _sessions.run(credential, '', (session) async {
        CloudAccount account;
        try {
          account = await _account(credential);
        } on AccountLoginRequired {
          rethrow;
        } on AppException {
          _sessions.checkpoint();
          account = CloudAccount(
            credential.field('nickname').ifEmpty('${platform.shortName} 用户'),
          );
        }
        return LoginResult(
          credential.withFields({
            'primary': session.cookie,
            if (session.refreshedAt > 0)
              _sessions.refreshField: '${session.refreshedAt}',
          }),
          account,
        );
      });

  @override
  Future<CloudAccount> account(Credential credential) =>
      _sessions.run(credential, '', (_) => _account(credential));

  Future<CloudAccount> _account(Credential credential) async {
    final data = success(
      await http.get(
        url('member', {'fetch_subscribe': true, '_ch': 'home'}),
        headers(credential.primary),
      ),
    );
    final used = int.tryParse(data.str('use_capacity'));
    final total = int.tryParse(data.str('total_capacity'));
    require(
      used != null && used >= 0 && total != null && total > 0,
      '${platform.shortName} 未返回有效容量，请重试',
    );
    var nickname = data
        .str('nickname')
        .ifEmpty(data.str('username'))
        .ifEmpty(credential.field('nickname'));
    if (nickname.isEmpty) {
      try {
        final result = await http.get(
          '$origin/account/info',
          headers(credential.primary),
        );
        final json = result.json;
        if (result.successful && json.boolean('success')) {
          nickname = json.obj('data').str('nickname');
        }
      } on AppException {
        _sessions.checkpoint();
        // The cloud quota already authenticated the account. Web display-name
        // failures do not invalidate that successful cloud response.
      }
    }
    return CloudAccount(
      nickname.ifEmpty('${platform.shortName} 用户'),
      used: used!,
      total: total!,
    );
  }

  @override
  Future<BrowseSession> openPersonal(Credential credential) async {
    final cookie = LoginCredentials.normalize(platform, credential.primary);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: '我的${platform.shortName}网盘',
      rootId: '0',
      metadata: {'cookie': cookie},
    );
  }

  @override
  Future<BrowseSession> openShare(ParsedLink link, Credential? credential) =>
      _sessions.run(credential, '', (_) async {
        final session = await super.openShare(link, credential);
        require(
          session.meta('stoken').isNotEmpty,
          '${platform.shortName} 未返回分享凭证，请重新解析',
        );
        return session;
      });

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) => _sessions.run(credential, session.meta('cookie'), (_) async {
    if (session.mode == BrowseMode.personal && credential == null) {
      throw AccountLoginRequired('请先登录 ${platform.shortName} 网盘');
    }
    return super.list(session, parentId.ifEmpty('0'), credential);
  });

  @override
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) => _prepare(session, file, credential, forPlayback: false);

  @override
  Future<DownloadSpec> playback(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) => _prepare(session, file, credential, forPlayback: true);

  /// Share transfer still uses the web account, while a stream resolver owns
  /// its separate authorization, media size, and CDN headers.
  Future<DownloadSpec> prepareStream(
    BrowseSession session,
    CloudFile file,
    Credential credential,
    Future<DownloadSpec> Function(String fid) resolve, {
    bool forPlayback = true,
  }) => _sessions.run(credential, session.meta('cookie'), (_) async {
    require(!file.isDirectory, forPlayback ? '文件夹不能直接播放' : '文件夹不能直接下载');
    if (session.mode == BrowseMode.share) {
      require(
        session.meta('stoken').isNotEmpty && file.token.isNotEmpty,
        '${platform.shortName} 分享凭证已缺失，请重新打开分享列表',
      );
      await _sessions.ensureFresh();
    }
    final result = await super.prepareFile(
      session,
      file,
      credential,
      forPlayback: forPlayback,
      resolveStream: resolve,
    );
    _sessions.checkpoint();
    return result;
  });

  Future<DownloadSpec> _prepare(
    BrowseSession session,
    CloudFile file,
    Credential? credential, {
    required bool forPlayback,
  }) => _sessions.run(credential, session.meta('cookie'), (_) async {
    require(!file.isDirectory, '文件夹不能直接下载');
    if (session.mode == BrowseMode.personal && credential == null) {
      throw AccountLoginRequired('请先登录 ${platform.shortName} 网盘');
    }
    if (session.mode == BrowseMode.share) {
      require(
        session.meta('stoken').isNotEmpty && file.token.isNotEmpty,
        '${platform.shortName} 分享下载凭证已缺失，请重新打开分享列表',
      );
    }
    await _sessions.ensureFresh();
    final spec = await super.prepareFile(
      session,
      file,
      credential,
      forPlayback: forPlayback,
    );
    _sessions.checkpoint();
    final uri = Uri.tryParse(spec.url);
    require(
      uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty,
      '${platform.shortName} 未返回有效下载地址',
    );
    require(
      file.size <= 0 ||
          spec.expectedSize <= 0 ||
          file.size == spec.expectedSize,
      '${platform.shortName} 返回的文件大小与所选文件不一致，请刷新列表后重试',
    );
    var expectedSize = spec.expectedSize > 0 ? spec.expectedSize : file.size;
    // UC may return a valid MP4 containing a membership notice, with its own
    // matching MD5 but the original file's size and fid in JSON. A checksum
    // alone cannot establish that this is the selected media. Check length
    // before either playback or download; never accept a replacement object.
    if (!quark &&
        spec.checksumType == 'md5' &&
        RegExp(r'^[0-9a-f]{32}$').hasMatch(spec.checksumValue ?? '')) {
      final probe = await _sessions.transport.peek(
        spec.url,
        headers(''),
        maxBytes: 1,
      );
      _sessions.checkpoint();
      require(probe.successful, 'UC 文件长度检查失败（HTTP ${probe.status}），请重试');
      final encoding = probe.header('content-encoding').toLowerCase();
      final range = RegExp(
        r'^bytes 0-0/(\d+)$',
      ).firstMatch(probe.header('content-range'));
      final length = int.tryParse(probe.header('content-length'));
      final total =
          probe.status == 206 &&
              range != null &&
              (length == null || length == 1)
          ? int.tryParse(range.group(1)!)
          : probe.status == 200
          ? length
          : null;
      require(
        (encoding.isEmpty || encoding == 'identity') &&
            total != null &&
            total > 0,
        'UC 未返回可验证的文件长度，请稍后重试',
      );
      if (expectedSize > 0 && expectedSize != total) {
        throw const UcOriginalContentMismatch();
      }
      expectedSize = total!;
    }
    return DownloadSpec(
      url: spec.url,
      fileName: spec.fileName,
      expectedSize: expectedSize,
      checksumType: spec.checksumType,
      checksumValue: spec.checksumValue,
      headers: headers(''),
      cleanup: spec.cleanup,
    );
  });

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) => _sessions.run(c, '', (_) => super.createFolder(s, parent, name, c));
  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) => _sessions.run(
    c,
    '',
    (_) => super.upload(s, parent, source, c, onProgress: onProgress),
  );
  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) => _sessions.run(c, '', (_) => super.rename(s, f, name, c));
  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) => _sessions.run(c, '', (_) => super.move(s, files, target, c));
  @override
  Future<void> delete(BrowseSession s, List<CloudFile> files, Credential c) =>
      _sessions.run(c, '', (_) => super.delete(s, files, c));
  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) => _sessions.run(c, '', (_) => super.saveShare(s, files, target, c));
  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) => _sessions.run(c, '', (_) => super.createShare(s, files, options, c));
}

class _CookieCloudSession {
  _CookieCloudSession(this.cookie, this.owner, this.refreshedAt);
  String cookie;
  Credential? owner;
  int refreshedAt;
  bool refreshAttempted = false;
}

class _CookieCloudHttp extends JsonHttp {
  _CookieCloudHttp(
    this.transport,
    this.store,
    int Function()? now,
    this.platform,
    this.webUserAgent,
    this.apiUserAgent,
  ) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final CloudPlatform platform;
  final String webUserAgent, apiUserAgent;
  String get refreshField => platform == CloudPlatform.uc
      ? 'ucSessionRefreshedAt'
      : 'quarkSessionRefreshedAt';
  String get origin => platform == CloudPlatform.uc
      ? 'https://drive.uc.cn'
      : 'https://pan.quark.cn';
  String get config => platform == CloudPlatform.uc
      ? 'https://pc-api.uc.cn/1/clouddrive/config?pr=UCBrowser&fr=pc'
      : 'https://drive-pc.quark.cn/1/clouddrive/config?pr=ucpro&fr=pc';
  final JsonHttp transport;
  final CredentialStore? store;
  final int Function() now;
  final _zoneKey = Object();
  _CookieCloudSession? get current =>
      Zone.current[_zoneKey] as _CookieCloudSession?;
  static const _interval = 90 * 60 * 1000;

  Future<T> run<T>(
    Credential? credential,
    String fallback,
    Future<T> Function(_CookieCloudSession) action,
  ) async {
    final nested = current;
    if (nested != null) {
      checkpoint();
      return action(nested);
    }
    final raw = credential?.primary ?? fallback;
    final cookie = raw
        .trim()
        .replaceFirst(RegExp(r'^Cookie:', caseSensitive: false), '')
        .trim();
    if (credential != null && !LoginCredentials.plausible(platform, cookie)) {
      throw AccountLoginRequired('${platform.shortName} 登录信息不完整，请重新网页登录');
    }
    require(
      !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(cookie),
      '${platform.shortName} Cookie 格式无效',
    );
    final stored = store?.credential(platform);
    final owner = credential != null && stored?.sameAs(credential) == true
        ? stored
        : null;
    final session = _CookieCloudSession(
      cookie,
      owner,
      int.tryParse(credential?.field(refreshField) ?? '') ?? 0,
    );
    return runZoned(() => action(session), zoneValues: {_zoneKey: session});
  }

  static bool loginRequired(HttpResult response) {
    if (response.status == 401) return true;
    try {
      final json = response.json;
      return json.integer('status') == 401 || json.integer('code') == 31001;
    } on AppException {
      return false;
    }
  }

  void checkpoint() {
    if (RequestScope.current?.isCancelled == true) {
      throw const AppException('请求已取消');
    }
    final session = current, owner = current?.owner;
    if (session == null || owner == null) return;
    final latest = store!.credential(platform);
    require(
      latest != null && latest.updatedAt == owner.updatedAt,
      '${platform.shortName} 账号已变化，请重新打开文件列表',
    );
    if (!owner.sameAs(latest)) {
      session.cookie = latest!.primary;
      session.owner = latest;
      session.refreshedAt = int.tryParse(latest.field(refreshField)) ?? 0;
    }
  }

  Map<String, String> _cookieUpdates(HttpResult response) {
    final updates = <String, String>{};
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() != 'set-cookie') continue;
      for (final header in entry.value) {
        final pair = header.split(';').first.trim();
        final eq = pair.indexOf('=');
        if (eq <= 0 || eq >= pair.length - 1) continue;
        final name = pair.substring(0, eq).trim();
        final value = pair.substring(eq + 1).trim();
        if ({'__pus', '__puus'}.contains(name) &&
            value.isNotEmpty &&
            !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value)) {
          updates[name] = value;
        }
      }
    }
    return updates;
  }

  Future<bool> _accept(HttpResult response, Credential? sentOwner) async {
    final session = current!;
    checkpoint();
    if (!response.successful || loginRequired(response)) return false;
    final updates = _cookieUpdates(response);
    if (updates.isEmpty) return false;
    // A later response from a concurrent request must not undo a renewal that
    // another request already committed, or write into a replacement account.
    if (sentOwner != null && !sentOwner.sameAs(session.owner)) return false;
    final pairs = LoginCredentials.cookiePairs(session.cookie)..addAll(updates);
    final merged = pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
    final stamp = updates.containsKey('__puus') ? now() : session.refreshedAt;
    if (sentOwner != null) {
      final replacement = sentOwner.withFields({
        'primary': merged,
        refreshField: '$stamp',
      }, preserveRevision: true);
      final cancel = RequestScope.current;
      final committed = await store!.replaceCredential(
        platform,
        sentOwner,
        replacement,
        canCommit: () => cancel?.isCancelled != true,
      );
      checkpoint();
      if (!committed || !replacement.sameAs(session.owner)) return false;
    }
    session.cookie = merged;
    session.refreshedAt = stamp;
    return updates.containsKey('__puus');
  }

  Future<bool> _refresh() async {
    final session = current!;
    checkpoint();
    if (session.refreshAttempted) return false;
    session.refreshAttempted = true;
    final pairs = LoginCredentials.cookiePairs(session.cookie)
      ..remove('__puus');
    if (!pairs.containsKey('__pus')) return false;
    final owner = session.owner;
    try {
      final result = await transport.get(config, {
        'Cookie': pairs.entries.map((e) => '${e.key}=${e.value}').join('; '),
        'User-Agent': platform == CloudPlatform.quark
            ? apiUserAgent
            : webUserAgent,
        'Origin': origin,
        'Referer': '$origin/',
      });
      return await _accept(result, owner);
    } on AppException {
      checkpoint();
      // A temporary refresh failure can leave the existing session usable.
      return false;
    }
  }

  Future<void> ensureFresh() async {
    checkpoint();
    final stamp = current!.refreshedAt, time = now();
    if (stamp > 0 && time >= stamp && time - stamp < _interval) return;
    await _refresh();
  }

  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) async {
    final session = current;
    require(session != null, '${platform.shortName} 请求缺少账号上下文');
    final uri = Uri.parse(url);
    final domain = platform == CloudPlatform.quark ? 'quark.cn' : 'uc.cn';
    if (uri.host != domain && !uri.host.endsWith('.$domain')) {
      checkpoint();
      final result = await transport.request(
        method,
        url,
        body: body,
        headers: headers,
        followRedirects: followRedirects,
        contentType: contentType,
      );
      checkpoint();
      return result;
    }
    final cloud =
        platform == CloudPlatform.quark ||
        uri.path.endsWith('/member') ||
        uri.path.endsWith('/file/sort') ||
        uri.path.endsWith('/file/download') &&
            !uri.queryParameters.containsKey('entry');
    for (var attempt = 0; attempt < 2; attempt++) {
      checkpoint();
      final owner = session!.owner;
      final result = await transport.request(
        method,
        url,
        body: body,
        headers: {
          ...headers,
          'Cookie': session.cookie,
          'User-Agent': cloud ? apiUserAgent : webUserAgent,
        },
        followRedirects: followRedirects,
        contentType: contentType,
      );
      await _accept(result, owner);
      if (attempt == 0 && loginRequired(result) && await _refresh()) continue;
      return result;
    }
    throw AccountLoginRequired('${platform.shortName} 登录已失效，请重新网页登录');
  }
}
