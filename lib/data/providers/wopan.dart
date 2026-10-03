import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import '../../core/crypto_box.dart';
import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../http.dart';
import '../http_retry.dart';
import '../state_store.dart';
import '../uploads/upload_io.dart';
import 'personal_cloud.dart';
import 'token_session.dart';

class WopanProtocol {
  static const origin = 'https://panservice.mail.wo.cn';
  static const clientId = '1001000021';
  static const clientSecret = 'XFmi9GS2hzk98jGX';
  static const iv = 'wNSOYIB1k1DjY5lA';

  static String _key(String channel, String access) {
    if (channel == 'api-user') return clientSecret;
    require(access.length >= 16, '联通云盘访问令牌无效，请重新登录');
    return access.substring(0, 16);
  }

  static String encrypt(Json data, String channel, String access) =>
      base64Encode(
        CryptoBox.aesCbc(
          true,
          utf8.encode(jsonEncode(data)),
          utf8.encode(_key(channel, access)),
          utf8.encode(iv),
        ),
      );

  static Object decodeValue(Object? data, String channel, String access) {
    if (data is Map || data is List) return data!;
    require(data is String && data.isNotEmpty, '联通云盘返回的数据为空');
    try {
      final plain = utf8.decode(
        CryptoBox.aesCbc(
          false,
          base64Decode(data as String),
          utf8.encode(_key(channel, access)),
          utf8.encode(iv),
        ),
      );
      final value = jsonDecode(plain);
      require(value is Map || value is List, '联通云盘响应格式错误');
      return value as Object;
    } catch (_) {
      throw const AppException('联通云盘响应解密失败，请刷新或重新登录');
    }
  }

  static Json decode(Object? data, String channel, String access) {
    final value = decodeValue(data, channel, access);
    require(value is Map, '联通云盘响应格式错误');
    return asJson(value);
  }

  static Json header(
    String channel,
    String key,
    int milliseconds,
    int sequence,
  ) => {
    'key': key,
    'resTime': milliseconds,
    'reqSeq': sequence,
    'channel': channel,
    'sign': md5
        .convert(utf8.encode('$key$milliseconds$sequence$channel'))
        .toString(),
    'version': '',
  };
}

class WopanConnector extends PersonalCloudConnector {
  WopanConnector(this.http, CredentialStore store, {int Function()? now})
    : sessions = TokenSessions(CloudPlatform.wopan, store, now: now);
  final JsonHttp http;
  final TokenSessions sessions;
  @override
  CloudPlatform get platform => CloudPlatform.wopan;

  Future<Json> _shareLocation(ParsedLink link) async {
    var uri = Uri.parse(link.url);
    var passcode = link.passcode ?? '';
    final visited = <String>{};
    for (var hop = 0; hop < 6; hop++) {
      RequestScope.checkpoint();
      require(
        {'http', 'https'}.contains(uri.scheme) &&
            {'pan.wo.cn', 'panservice.mail.wo.cn'}.contains(uri.host) &&
            uri.userInfo.isEmpty &&
            uri.port == (uri.scheme == 'https' ? 443 : 80),
        '联通分享跳转到了非官方地址，已停止解析',
      );
      if (uri.scheme == 'http') uri = uri.replace(scheme: 'https', port: 443);
      // The short-link service also serves this path on the API origin. The
      // public pan.wo.cn host can reset connections before returning its 302.
      if (uri.host == 'pan.wo.cn' &&
          RegExp(r'^/s/[A-Za-z0-9_-]+/?$').hasMatch(uri.path)) {
        uri = uri.replace(host: Uri.parse(WopanProtocol.origin).host);
      }
      final fragment = Uri.tryParse(
        uri.fragment.startsWith('/') || uri.fragment.startsWith('?')
            ? uri.fragment
            : '?${uri.fragment}',
      );
      final params = {
        for (final part in [
          uri,
          if (fragment != null && !fragment.hasAuthority) fragment,
        ])
          for (final entry in part.queryParameters.entries)
            entry.key.toLowerCase(): entry.value,
      };
      if (passcode.isEmpty) passcode = params['sharecode'] ?? '';
      final shareId = params['shareid'] ?? params['surl'] ?? '';
      if (shareId.isNotEmpty) {
        require(
          RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(shareId),
          '联通分享标识无效',
        );
        final clientId = params['clientid'] ?? WopanProtocol.clientId;
        return {
          'shareId': shareId,
          'passcode': passcode,
          'clientId': RegExp(r'^\d{10}$').hasMatch(clientId)
              ? clientId
              : WopanProtocol.clientId,
        };
      }
      require(visited.add(uri.toString()), '联通分享链接发生循环跳转');
      Future<HttpResult> resolve() => http.readRequest(
        'GET',
        uri.toString(),
        headers: {'User-Agent': WebLoginTarget.desktopUserAgent},
        followRedirects: false,
      );
      final response = ReadRetryScope.current == null
          ? await ReadRetryScope(
              retries: 2,
              checkpoint: RequestScope.checkpoint,
            ).execute(resolve)
          : await resolve();
      final location = response.header('location');
      require(
        {301, 302, 303, 307, 308}.contains(response.status) &&
            location.isNotEmpty,
        '联通分享短链接无法解析，请确认链接是否有效',
      );
      uri = uri.resolve(location);
    }
    throw const AppException('联通分享跳转次数过多，请使用官网完整分享链接');
  }

  Future<List<Json>> _shareRoot(BrowseSession share) async {
    final key = 'ShareFileDetail';
    final response = await http.postJsonRead(
      '${WopanProtocol.origin}/wohome/dispatcher',
      {
        'header': WopanProtocol.header(
          '100002',
          key,
          sessions.now(),
          100000 + Random.secure().nextInt(89999),
        ),
        'body': {
          'clientId': share.meta('clientId').ifEmpty(WopanProtocol.clientId),
          'secret': true,
          'secretType': 'ClientSecret',
          'param': WopanProtocol.encrypt(
            {
              'shareId': share.meta('shareId'),
              'shareCode': share.meta('passcode'),
            },
            'api-user',
            '',
          ),
        },
      },
      {
        'User-Agent': WebLoginTarget.desktopUserAgent,
        'Origin': WopanProtocol.origin,
        'Referer': '${WopanProtocol.origin}/h5/wocloudshare/',
      },
    );
    final data = response.json, rsp = data.obj('RSP');
    final code = rsp.str('RSP_CODE');
    require(
      response.successful && data.str('STATUS') == '200' && code == '0000',
      code == '130013'
          ? '联通分享文件已删除或分享已取消，请使用有效链接'
          : rsp.str('RSP_DESC').ifEmpty('联通分享解析失败（$code），请检查链接和提取码'),
    );
    final raw = WopanProtocol.decodeValue(rsp['DATA'], 'api-user', '');
    require(raw is List && raw.every((item) => item is Map), '联通未返回有效分享文件列表');
    return objects(raw);
  }

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    final location = await _shareLocation(link);
    final share = BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: '联通云盘分享',
      rootId: '0',
      sourceLink: link,
      metadata: location.map((key, value) => MapEntry(key, '$value')),
    );
    await _shareRoot(share);
    return share;
  }

  static CloudFile _file(Json entry, String parent) {
    final id = entry.str('id').ifEmpty(entry.str('fileId')),
        name = entry.str('name').ifEmpty(entry.str('fileName')),
        type = entry.integer('type', -1);
    require(
      id.isNotEmpty && name.isNotEmpty && {0, 1}.contains(type),
      '联通云盘文件信息不完整',
    );
    return CloudFile(
      id: id,
      name: name,
      parentId: parent,
      isDirectory: type == 0,
      size: entry.integer('size', entry.integer('fileSize')),
      modifiedAt: personalCloudDate(entry.str('createTime')),
      thumbnailUrl: entry.str('thumbUrl'),
      token: jsonEncode({
        'fid': entry.str('fid'),
        'fileType': entry.str('fileType'),
      }),
    );
  }

  Future<List<CloudFile>> _shareFiles(
    BrowseSession share,
    String parent,
    Credential? credential,
  ) async {
    List<Json> entries;
    if (parent == share.rootId) {
      entries = await _shareRoot(share);
    } else {
      if (credential == null) {
        throw const AccountLoginRequired('浏览联通分享子目录需要先登录中国联通云盘');
      }
      final data = await _call(await _session(credential), 'QueryShareFiles', {
        'directoryId': parent,
        'id': share.meta('shareId'),
      }, read: true);
      final raw = data['files'];
      require(raw is List && raw.every((item) => item is Map), '联通未返回有效分享文件列表');
      entries = objects(raw);
    }
    final ids = <String>{};
    return [
      for (final entry in entries)
        if (ids.add(entry.str('id').ifEmpty(entry.str('fileId'))))
          _file(entry, parent),
    ];
  }

  Future<(HttpResult, Json, String)> _request(
    TokenSession session,
    String channel,
    String key,
    Json param, {
    bool read = false,
    bool classify = false,
  }) async {
    sessions.checkpoint(session);
    final access = session.access;
    final body = {
      'header': WopanProtocol.header(
        channel,
        key,
        sessions.now(),
        100000 + Random.secure().nextInt(8999),
      ),
      'body': {
        if (channel == 'api-user') 'clientId': WopanProtocol.clientId,
        if (classify) 'key': true else 'secret': true,
        'param': WopanProtocol.encrypt(param, channel, access),
      },
    };
    final response = await (read ? http.readRequest : http.request)(
      'POST',
      '${WopanProtocol.origin}/$channel/dispatcher',
      body: jsonEncode(body),
      headers: {
        'User-Agent': WebLoginTarget.desktopUserAgent,
        'Origin': 'https://pan.wo.cn',
        'Referer': 'https://pan.wo.cn/',
        if (access.isNotEmpty) 'Accesstoken': access,
      },
      contentType: 'application/json; charset=utf-8',
      followRedirects: false,
    );
    sessions.checkpoint(session);
    if ({401, 403}.contains(response.status)) {
      return (response, <String, dynamic>{}, access);
    }
    return (response, response.json, access);
  }

  bool _unauthorized(HttpResult response, Json data) {
    final rsp = data.obj('RSP'), message = rsp.str('RSP_DESC');
    return {401, 403}.contains(response.status) ||
        rsp.str('RSP_CODE') != '0000' &&
            RegExp(r'token|登录|令牌|鉴权', caseSensitive: false).hasMatch(message);
  }

  Json _checked(
    HttpResult response,
    Json data,
    String channel,
    String access, {
    bool listResult = false,
  }) {
    final rsp = data.obj('RSP');
    if (_unauthorized(response, data)) {
      throw const AccountLoginRequired('联通云盘登录已失效，请重新登录');
    }
    require(
      response.successful &&
          data.str('STATUS') == '200' &&
          rsp.str('RSP_CODE') == '0000',
      '联通云盘请求失败（${rsp.str('RSP_CODE').ifEmpty(data.str('STATUS')).ifEmpty('${response.status}')}），请稍后重试',
    );
    final payload = rsp['DATA'];
    if (payload == null || payload == '') return {};
    final decoded = WopanProtocol.decodeValue(payload, channel, access);
    if (listResult && decoded is List) return {'list': decoded};
    require(decoded is Map, '联通云盘响应格式错误');
    return asJson(decoded);
  }

  Future<void> _renew(TokenSession session) async {
    final (response, data, access) = await _request(
      session,
      'api-user',
      'AppRefreshToken',
      {
        'refreshToken': session.refresh,
        'clientSecret': WopanProtocol.clientSecret,
      },
    );
    if (!response.successful ||
        data.str('STATUS') != '200' ||
        data.obj('RSP').str('RSP_CODE') != '0000') {
      throw const AccountLoginRequired('联通云盘续期凭据已失效，请重新网页登录');
    }
    final tokens = _checked(response, data, 'api-user', access);
    await sessions.update(session, sessions.refreshedFields(session, tokens));
  }

  Future<TokenSession> _session(Credential c, {bool candidate = false}) async {
    final session = sessions.open(c, candidate: candidate);
    await sessions.fresh(session, _renew);
    return session;
  }

  Future<Json> _call(
    TokenSession session,
    String key,
    Json param, {
    String channel = 'wohome',
    bool read = false,
  }) async {
    await sessions.fresh(session, _renew);
    for (var attempt = 0; attempt < 2; attempt++) {
      final (response, data, access) = await _request(
        session,
        channel,
        key,
        {
          ...param,
          if (channel == 'wohome' && key != 'ClassifyRule')
            'clientId': WopanProtocol.clientId,
          if (key == 'AppQueryUser') 'accessToken': session.access,
        },
        read: read,
        classify: const {'ClassifyRule', 'GetZoneInfo'}.contains(key),
      );
      if (_unauthorized(response, data) && attempt == 0) {
        await sessions.fresh(
          session,
          _renew,
          force: true,
          rejectedAccess: access,
        );
        continue;
      }
      return _checked(
        response,
        data,
        channel,
        access,
        listResult: key == 'GetDownloadUrl',
      );
    }
    throw const AccountLoginRequired('联通云盘登录已失效，请重新网页登录');
  }

  Future<CloudAccount> _account(TokenSession session) async {
    final user = await _call(
      session,
      'AppQueryUser',
      {},
      channel: 'api-user',
      read: true,
    );
    require(user.str('userId').isNotEmpty, '联通云盘未返回有效账号信息');
    await sessions.update(session, {'userId': user.str('userId')});
    final quota = (await _call(session, 'QueryCloudUsageInfo', {
      'phoneNum': user.str('userId'),
    }, read: true)).obj('usageInfo');
    return CloudAccount(
      user.str('userName').ifEmpty('联通云盘用户'),
      total: quota.integer('byteTotalSize'),
      used: quota.integer('byteUsedSize'),
    );
  }

  Future<LoginResult> authenticate(Credential c) async {
    final session = await _session(c, candidate: true);
    final account = await _account(session);
    return LoginResult(session.credential, account);
  }

  @override
  Future<CloudAccount> account(Credential c) async =>
      _account(await _session(c));
  @override
  Future<BrowseSession> openPersonal(Credential c) async {
    await _session(c);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: '我的联通云盘',
      rootId: '0',
    );
  }

  Future<Json> _family(TokenSession session) async {
    final data = await _call(
      session,
      'FamilyUserCurrentEncode',
      {},
      read: true,
    );
    final id = data.str('defaultHomeId');
    require(id.isNotEmpty, '联通云盘未返回家庭空间信息');
    await sessions.update(session, {'defaultFamilyId': id});
    return data;
  }

  @override
  Future<List<CloudSpace>> familySpaces(Credential credential) async {
    final data = await _family(await _session(credential));
    final id = data.str('defaultHomeId');
    return id == '0'
        ? []
        : [
            CloudSpace(
              id,
              data
                  .str('defaultHomeName')
                  .ifEmpty(data.str('groupName'))
                  .ifEmpty('家庭云'),
            ),
          ];
  }

  @override
  Future<BrowseSession> openFamily(
    CloudSpace space,
    Credential credential,
  ) async {
    require(
      (await familySpaces(credential)).any((item) => item.id == space.id),
      '联通家庭空间已变化，请重新选择',
    );
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: space.name,
      rootId: '0',
      metadata: {'familyId': space.id, 'familyName': space.name},
    );
  }

  Future<TokenSession> _owner(
    BrowseSession s,
    Credential? c, {
    bool manage = false,
  }) async {
    personal(s);
    if (manage) require(s.canManageFiles, '请在个人网盘中执行文件管理操作');
    if (c == null) throw const AccountLoginRequired('请先登录中国联通云盘');
    return _session(c);
  }

  Json _space(BrowseSession s) => {
    'spaceType': s.isFamily ? '1' : '0',
    if (s.isFamily) 'familyId': s.familyId,
  };

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parentId,
    Credential? c,
  ) async {
    if (s.mode == BrowseMode.share) return _shareFiles(s, parentId, c);
    final session = await _owner(s, c), files = <CloudFile>[], ids = <String>{};
    for (var page = 0; page < 1000; page++) {
      final data = await _call(session, 'QueryAllFiles', {
        ..._space(s),
        'parentDirectoryId': parentId,
        'pageNum': page,
        'pageSize': 100,
        'sortRule': 1,
      }, read: true);
      final raw = data['files'];
      require(raw is List, '联通云盘未返回有效文件列表');
      final entries = objects(raw);
      require(entries.length == (raw as List).length, '联通云盘文件列表包含无效项目');
      var added = 0;
      for (final entry in entries) {
        final file = _file(entry, parentId);
        if (!ids.add(file.id)) continue;
        added++;
        files.add(file);
      }
      if (entries.length < 100) return files;
      require(added > 0, '联通云盘分页重复，请刷新重试');
    }
    throw const AppException('联通云盘目录项目过多，请分目录打开');
  }

  static Json _fileData(CloudFile file) {
    try {
      return asJson(jsonDecode(file.token));
    } catch (_) {
      return {};
    }
  }

  static const _downloadHeaders = {
    'User-Agent': WebLoginTarget.desktopUserAgent,
    'Referer': 'https://pan.wo.cn/',
  };

  Future<bool?> _downloadAvailable(String address, int size) async {
    try {
      // A probe gets one attempt; the real transfer owns its retry budget.
      final probe = await ReadRetryScope(
        retries: 0,
        checkpoint: RequestScope.checkpoint,
      ).run(() => http.peek(address, _downloadHeaders, maxBytes: 1));
      RequestScope.checkpoint();
      final range = probe.header('content-range').trim();
      if (probe.status == 206) {
        final match = RegExp(
          r'^bytes 0-0/(\d+)$',
          caseSensitive: false,
        ).firstMatch(range);
        return match != null && int.tryParse(match.group(1)!) == size;
      }
      if (probe.status == 200) {
        return int.tryParse(probe.header('content-length')) == size;
      }
      return size == 0 && probe.status == 416 && range == 'bytes */0';
    } on HttpRequestFailure catch (error) {
      RequestScope.checkpoint();
      if (!error.retryable) rethrow;
      // No HTTP response means the signed link was not proven invalid.
      // Let the downloader/player validate it and recover the real request.
      return error.status == null ? null : false;
    }
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    require(!f.isDirectory, '请选择要下载的文件');
    if (s.mode == BrowseMode.share && c == null) {
      throw const AccountLoginRequired('联通分享下载需要先登录中国联通云盘');
    }
    final session = s.mode == BrowseMode.share
        ? await _session(c!)
        : await _owner(s, c);
    var fid = _fileData(f).str('fid');
    if (fid.isEmpty && f.parentId.isNotEmpty) {
      final current = (await list(
        s,
        f.parentId,
        c,
      )).where((item) => item.id == f.id && !item.isDirectory).firstOrNull;
      if (current != null) fid = _fileData(current).str('fid');
    }
    require(fid.isNotEmpty, '联通云盘文件下载标识缺失，请刷新列表');
    final data = await _call(session, 'GetDownloadUrlV2', {
      'type': '1',
      'fidList': [fid],
    }, read: true);
    final result = data
        .list('list')
        .where((item) => item.str('fid') == fid)
        .firstOrNull;
    require(result != null, '联通云盘未返回该文件的下载地址');
    var address = checkedCloudUrl(result!.str('downloadUrl'), '联通云盘下载地址无效');
    if (Uri.parse(address).host.endsWith('.pan.wo.cn') &&
        await _downloadAvailable(address, f.size) == false) {
      final alternative = (await _call(
        session,
        'GetDownloadUrl',
        {
          ..._space(s),
          'fidList': [fid],
        },
        read: true,
      )).list('list').where((item) => item.str('fid') == fid).firstOrNull;
      require(alternative != null, '联通下载节点暂时不可用，请稍后重试');
      address = checkedCloudUrl(alternative!.str('downloadUrl'), '联通云盘下载地址无效');
      if (await _downloadAvailable(address, f.size) == false) {
        require(
          Uri.parse(address).host == 'hydownload.pan.wo.cn',
          '联通下载节点暂时不可用，请稍后重试',
        );
        final candidate = Uri.parse(
          address,
        ).replace(host: 'tjdownload.pan.wo.cn', port: 443).toString();
        require(
          await _downloadAvailable(candidate, f.size) != false,
          '联通下载节点暂时不可用，请稍后重试',
        );
        address = candidate;
      }
    }
    return DownloadSpec(
      url: address,
      fileName: f.name,
      expectedSize: f.size,
      profile: 'wopan',
      headers: _downloadHeaders,
    );
  }

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    final session = await _owner(s, c, manage: true),
        io = UploadIO(http, source, onProgress);
    io.progress(UploadPhase.preparing);
    final zone = (await _call(session, 'GetZoneInfo', {
      'appId': '10000001',
    }, read: true)).str('url');
    final advertised = Uri.tryParse(zone.ifEmpty('https://tjupload.pan.wo.cn'));
    var endpoint = advertised?.host == 'gxupload.pan.wo.cn'
        ? Uri.parse('https://tjupload.pan.wo.cn')
        : advertised;
    require(
      endpoint != null &&
          endpoint.scheme == 'https' &&
          endpoint.userInfo.isEmpty &&
          (endpoint.host.endsWith('.pan.wo.cn') ||
              endpoint.host.endsWith('.mail.wo.cn')),
      '联通云盘返回的上传地址无效',
    );
    if (endpoint!.host != 'tjupload.pan.wo.cn') {
      // Check the advertised zone before sending any file bytes. Some regions
      // still return retired or unavailable hosts; the SDK supplies this default.
      try {
        final probe = await http.request(
          'HEAD',
          endpoint.resolve('/openapi/client/upload2C').toString(),
          headers: {'User-Agent': WebLoginTarget.desktopUserAgent},
          followRedirects: false,
        );
        if (probe.status >= 500) {
          endpoint = Uri.parse('https://tjupload.pan.wo.cn');
        }
      } on HttpRequestFailure catch (error) {
        RequestScope.checkpoint();
        if (!error.retryable) rethrow;
        endpoint = Uri.parse('https://tjupload.pan.wo.cn');
      }
    }
    final types = (await _call(
      session,
      'ClassifyRule',
      {},
      read: true,
    )).obj('fileTypes');
    final fileType = types
        .obj(source.name.split('.').last.toLowerCase())
        .str('type')
        .ifEmpty('5');
    final now = DateTime.now();
    String two(int v) => '$v'.padLeft(2, '0');
    final batch =
        '${now.year}${two(now.month)}${two(now.day)}${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final unique = '${now.millisecondsSinceEpoch}';
    const partSize = 8 * 1024 * 1024;
    final count = max(1, source.size ~/ partSize);
    for (var i = 0; i < count; i++) {
      sessions.checkpoint(session);
      final start = i * partSize,
          end = i == count - 1 ? source.size : (i + 1) * partSize;
      final response = await io.send(
        endpoint.resolve('/openapi/client/upload2C').toString(),
        method: 'POST',
        start: start,
        end: end,
        fields: {
          'uniqueId': unique,
          'accessToken': session.access,
          'fileName': source.name,
          'psToken': 'undefined',
          'fileSize': '${source.size}',
          'totalPart': '$count',
          'channel': 'wocloud',
          'directoryId': parent,
          'partSize': '${end - start}',
          'partIndex': '${i + 1}',
          'fileInfo': WopanProtocol.encrypt(
            {
              'spaceType': '0',
              'directoryId': parent,
              'batchNo': batch,
              'fileName': source.name,
              'fileSize': source.size,
              'fileType': fileType,
            },
            'wohome',
            session.access,
          ),
        },
        headers: {
          'Origin': 'https://pan.wo.cn',
          'Referer': 'https://pan.wo.cn/',
          'User-Agent': WebLoginTarget.desktopUserAgent,
        },
      );
      final result = response.json;
      require(
        result.str('code') == '0000',
        '联通上传失败（${result.str('code')}），请稍后重试',
      );
    }
    // upload2C may return a storage fid rather than the listing's file id.
    return io.confirm(() => list(s, parent, c));
  }

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    cloudFileName(name);
    final session = await _owner(s, c, manage: true);
    if (session.field('defaultFamilyId').isEmpty) await _family(session);
    final data = await _call(session, 'CreateDirectory', {
      ..._space(s),
      'familyId': session.field('defaultFamilyId'),
      'parentDirectoryId': parent,
      'directoryName': name,
    });
    require(data.str('id').isNotEmpty, '联通云盘未返回新文件夹信息，请刷新确认');
    return CloudFile(
      id: data.str('id'),
      name: name,
      isDirectory: true,
      parentId: parent,
    );
  }

  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) async {
    cloudFileName(name);
    require(f.id.isNotEmpty && f.id != s.rootId, '不能重命名网盘根目录');
    final session = await _owner(s, c, manage: true);
    var fileType = '0';
    if (!f.isDirectory) {
      final types = (await _call(
        session,
        'ClassifyRule',
        {},
        read: true,
      )).obj('fileTypes');
      fileType = types
          .obj(name.split('.').last.toLowerCase())
          .str('type')
          .ifEmpty('5');
    }
    await _call(session, 'RenameFileOrDirectory', {
      ..._space(s),
      'type': f.isDirectory ? 0 : 1,
      'fileType': fileType,
      'id': f.id,
      'name': name,
    });
  }

  Json _ids(BrowseSession s, List<CloudFile> files) {
    require(
      files.every((f) => f.id.isNotEmpty && f.id != s.rootId),
      '不能操作网盘根目录',
    );
    return {
      'dirList': files.where((f) => f.isDirectory).map((f) => f.id).toList(),
      'fileList': files.where((f) => !f.isDirectory).map((f) => f.id).toList(),
    };
  }

  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    final session = await _owner(s, c, manage: true);
    if (files.isEmpty) return;
    require(
      target.isNotEmpty && !files.any((f) => f.isDirectory && f.id == target),
      '不能移动到文件夹自身',
    );
    await _call(session, 'MoveFile', {
      ..._ids(s, files),
      'targetDirId': target,
      'sourceType': '0',
      'targetType': '0',
      'secret': false,
    });
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    final session = await _owner(s, c, manage: true);
    if (files.isEmpty) return;
    await _call(session, 'DeleteFile', {
      ..._space(s),
      ..._ids(s, files),
      'vipLevel': '0',
    });
  }
}
