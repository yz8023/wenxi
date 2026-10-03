import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../../domain/models.dart';
import '../../domain/auth.dart';
import '../../domain/uploads.dart';
import '../../domain/links.dart';
import '../http.dart';
import '../uploads/upload_io.dart';
import '../../core/operation_progress.dart';
import '../login_cookies.dart';
import 'lanzou_protocol.dart';

part 'uploads/lanzou_upload.dart';

/// Public share parsing and authenticated personal file management.
class LanzouConnector extends CloudConnector {
  LanzouConnector(
    this.http, {
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
  }) : clock = clock ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed;
  final JsonHttp http;
  final DateTime Function() clock;
  final Future<void> Function(Duration) _delay;
  static const webUa = WebLoginTarget.desktopUserAgent;
  static const _cacheLifetime = Duration(minutes: 15);
  final _cache = <String, _LanzouShare>{};
  final _folders = <String, _LanzouFolder>{};

  @override
  CloudPlatform get platform => CloudPlatform.lanzou;

  String _key(ParsedLink link) => sha256
      .convert(utf8.encode(encoded([link.url, link.passcode ?? ''])))
      .toString();

  _LanzouShare? _cached(ParsedLink link) {
    _cache.removeWhere((_, share) => !clock().isBefore(share.expires));
    return _cache[_key(link)];
  }

  Future<_LanzouLanding> _landing(ParsedLink link) async {
    RequestScope.checkpoint();
    final uri = _shareUri(link.url);
    require(
      link.platform == platform &&
          link.shareId?.isNotEmpty == true &&
          LinkParser.shareId(platform, uri.toString()) == link.shareId,
      '蓝奏分享链接无效',
    );
    final transport = _LanzouTransport(http, uri, clock);
    final (pageUri, response) = await transport.page(uri, uri);
    final page = LanzouPage(response.body);
    return (uri: pageUri, page: page, transport: transport);
  }

  Future<_LanzouShare> _resolve(
    ParsedLink link, {
    _LanzouLanding? landing,
  }) async {
    RequestScope.checkpoint();
    final opened = landing ?? await _landing(link);
    final pageUri = opened.uri,
        page = opened.page,
        transport = opened.transport;
    require(!page.unavailable, '蓝奏文件已取消分享或不存在');
    if (page.passwordRequired) {
      require(link.passcode?.isNotEmpty == true, '此蓝奏分享需要提取码，请填写后重新解析');
    }
    var downloadPage = page, referer = pageUri;
    if (!page.passwordRequired && page.iframe.isNotEmpty) {
      final frame = _shareUri(pageUri.resolve(page.iframe).toString());
      require(frame.origin == pageUri.origin, '蓝奏下载页面地址异常，请检查分享链接');
      final (frameUri, frameResponse) = await transport.page(frame, pageUri);
      downloadPage = LanzouPage(frameResponse.body);
      referer = frameUri;
      require(!downloadPage.unavailable, '蓝奏文件已取消分享或不存在');
    }
    final fields = downloadPage.parameters(passcode: link.passcode);
    final api = _downloadApiUri(referer, downloadPage.ajaxUrl);
    final result = await transport.request(
      'POST',
      api,
      referer,
      body: form(fields),
    );
    RequestScope.checkpoint();
    DiagnosticLog.event(
      'lanzou.download_api_response',
      fields: {
        'status': result.status,
        'apiHost': api.host,
        'userAgent': webUa,
        'bodyCharacters': result.body.length,
      },
    );
    require(result.status != 429, '蓝奏请求过于频繁，请稍后再试');
    require(result.successful, '蓝奏解析服务响应异常（HTTP ${result.status}），请稍后重试');
    require(result.body.length <= 65536, '蓝奏解析服务返回内容过大，请稍后重试');
    Json data;
    try {
      data = result.json;
    } on AppException {
      throw const AppException('蓝奏返回了验证页面，请稍后重试或在分享页完成验证');
    }
    if (data.integer('zt') != 1) {
      final info = data.str('inf');
      throw AppException(
        RegExp(r'密码|提取码').hasMatch(info)
            ? '蓝奏提取码错误，请检查后重新解析'
            : RegExp(r'不存在|取消|过期|删除').hasMatch(info)
            ? '蓝奏文件已取消分享或不存在'
            : RegExp(r'频繁|次数|稍后').hasMatch(info)
            ? '蓝奏请求过于频繁，请稍后再试'
            : '蓝奏解析失败，请确认分享链接和提取码后重试',
      );
    }
    final domain = _downloadUri(data.str('dom'));
    final path = data.str('url');
    require(
      domain.path.replaceAll('/', '').isEmpty &&
          !domain.hasQuery &&
          path.isNotEmpty &&
          path != '0' &&
          path.length <= 8192 &&
          !RegExp(r'[\s\x00-\x1f]').hasMatch(path) &&
          !path.startsWith('/') &&
          !path.contains('://'),
      '蓝奏未返回有效下载地址，请重新解析',
    );
    var name = data.str('inf').trim();
    if (name.isEmpty ||
        name.length > 1024 ||
        name.contains('<') ||
        name == '成功') {
      name = page.name.ifEmpty(downloadPage.name);
    }
    require(name.isNotEmpty, '蓝奏未返回文件名称，请重新解析');
    final share = _LanzouShare(
      link: link,
      name: name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ''),
      displaySize: page.displaySize,
      jump: _downloadUrl('${domain.origin}/file/$path'),
      referer: pageUri.resolve('/'),
      transport: transport,
      expires: clock().add(_cacheLifetime),
    );
    RequestScope.checkpoint();
    _cache.remove(_key(link));
    _cache.removeWhere((_, value) => !clock().isBefore(value.expires));
    while (_cache.length >= 32) {
      _cache.remove(_cache.keys.first);
    }
    _cache[_key(link)] = share;
    return share;
  }

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    // An explicit parse/refresh always revalidates the share and its password.
    RequestScope.checkpoint();
    final prefix = '${_key(link)}:';
    _folders.removeWhere((key, _) => key.startsWith(prefix));
    _cache.remove(_key(link));
    final landing = await _landing(link);
    if (landing.page.isFolder) {
      final root = _folderId(link);
      final folder = await _resolveFolder(
        link,
        link,
        initialList: true,
        landing: landing,
      );
      return BrowseSession(
        platform: platform,
        mode: BrowseMode.share,
        title: folder.name,
        rootId: root,
        sourceLink: link,
      );
    }
    final share = await _resolve(link, landing: landing);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: share.name,
      rootId: '0',
      sourceLink: link,
      metadata: {'fileName': share.name, 'displaySize': '${share.displaySize}'},
    );
  }

  String _folderId(ParsedLink link) {
    final uri = _shareUri(link.url);
    require(
      link.platform == platform &&
          link.shareId?.isNotEmpty == true &&
          LinkParser.shareId(platform, uri.toString()) == link.shareId,
      '蓝奏文件夹分享链接无效',
    );
    return _folderAddress(uri);
  }

  String _folderAddress(Uri uri) =>
      '${uri.origin}${uri.path.replaceFirst(RegExp(r'/+$'), '')}';

  ParsedLink _folderLink(BrowseSession session, String parent) {
    final root = session.sourceLink!;
    if (parent == session.rootId) return root;
    final uri = _shareUri(parent);
    final id = LinkParser.shareId(platform, uri.toString());
    require(id != null && !uri.hasQuery && !uri.hasFragment, '蓝奏目录信息无效，请重新解析');
    return ParsedLink(
      source: parent,
      url: parent,
      kind: LinkKind.cloudShare,
      platform: platform,
      shareId: id,
      passcode: root.passcode,
    );
  }

  String _folderKey(ParsedLink root, ParsedLink link) =>
      '${_key(root)}:${_key(link)}';

  _LanzouFolder? _cachedFolder(ParsedLink root, ParsedLink link) {
    _folders.removeWhere((_, value) => !clock().isBefore(value.expires));
    return _folders[_folderKey(root, link)];
  }

  Future<void> _folderPause(int retries) async {
    await Future.any([
      _delay(Duration(milliseconds: 600 * (retries + 1))),
      if (RequestScope.current != null) RequestScope.current!.whenCancel,
    ]);
    RequestScope.checkpoint();
  }

  Future<_LanzouFolder> _resolveFolder(
    ParsedLink root,
    ParsedLink link, {
    bool initialList = false,
    _LanzouLanding? landing,
  }) async {
    RequestScope.checkpoint();
    final parent = _folderId(link), key = _folderKey(root, link);
    // A failed or cancelled refresh must not expose an older partial result.
    _folders.remove(key);
    final opened = landing ?? await _landing(link);
    final pageUri = opened.uri,
        page = opened.page,
        transport = opened.transport;
    require(!page.unavailable, '蓝奏文件夹已取消分享或不存在');
    final fields = page.folderParameters(passcode: link.passcode);
    final entries = <String, CloudFile>{};
    for (final child in page.subfolders) {
      require(child.url.isNotEmpty, '蓝奏子文件夹信息不完整，请刷新列表');
      final childUri = _shareUri(pageUri.resolve(child.url).toString());
      final id = LinkParser.shareId(platform, childUri.toString());
      require(id != null, '蓝奏子文件夹地址无效，请刷新列表');
      final childId = _folderAddress(childUri);
      if (childId == parent) continue;
      entries[childId] = CloudFile(
        id: childId,
        name: _entryName(child.name),
        isDirectory: true,
        parentId: parent,
        token: childId,
      );
    }
    require(entries.length <= 10000, '蓝奏文件夹内容过多，请分批解析');
    var pg = 1, retries = 0, complete = false;
    while (pg <= 500) {
      if (pg > 1 || retries > 0) await _folderPause(retries);
      final result = await transport.request(
        'POST',
        pageUri.resolve('/filemoreajax.php'),
        pageUri,
        body: form({...fields, 'pg': '$pg'}),
      );
      require(result.status != 429, '蓝奏请求过于频繁，请稍后再试');
      require(
        result.successful && result.body.length <= 1024 * 1024,
        '蓝奏文件夹列表响应异常，请稍后重试',
      );
      Json data;
      try {
        data = result.json;
      } on AppException {
        throw const AppException('蓝奏返回了验证页面，请稍后重试或在分享页完成验证');
      }
      final status = data.integer('zt');
      if (status == 2) {
        complete = true;
        break;
      }
      if (status == 3) {
        throw const AppException('蓝奏提取码错误，请检查后重新解析');
      }
      if (status == 4) {
        require(++retries <= 2, '蓝奏请求过于频繁，请稍后再试');
        continue;
      }
      require(status == 1, '蓝奏文件夹解析失败，请确认分享链接和提取码后重试');
      require(data['text'] is List, '蓝奏文件夹列表格式异常，请刷新后重试');
      final rows = data['text'] as List;
      require(rows.length <= 10000, '蓝奏文件夹内容过多，请分批解析');
      if (rows.isEmpty) {
        complete = true;
        break;
      }
      final previousCount = entries.length;
      for (final row in rows) {
        require(row is Map, '蓝奏文件信息不完整，请刷新列表');
        final value = asJson(row);
        final id = value.str('id');
        require(RegExp(r'^i[A-Za-z0-9]+$').hasMatch(id), '蓝奏文件分享标识无效，请刷新列表');
        final file = CloudFile(
          id: id,
          name: _entryName(value.str('name_all', value.str('name'))),
          size: LanzouPage.sizeFromLabel(value.str('size')),
          parentId: parent,
          token: '${pageUri.origin}/$id',
          modifiedAt: value.str('time'),
        );
        final existing = entries[id];
        require(
          existing == null ||
              existing.name == file.name && existing.size == file.size,
          '蓝奏文件夹内容正在变化，请刷新后重试',
        );
        entries[id] = file;
      }
      require(entries.length <= 10000, '蓝奏文件夹内容过多，请分批解析');
      require(entries.length > previousCount, '蓝奏文件夹分页重复，请稍后刷新后重试');
      retries = 0;
      pg++;
    }
    require(complete, '蓝奏文件夹页数过多，请分批解析');
    RequestScope.checkpoint();
    final folder = _LanzouFolder(
      name: _entryName(page.folderName),
      files: List.unmodifiable(entries.values),
      expires: clock().add(_cacheLifetime),
      initialList: initialList,
    );
    _folders.removeWhere((_, value) => !clock().isBefore(value.expires));
    while (_folders.isNotEmpty &&
        (_folders.length >= 32 ||
            _folders.values.fold<int>(
                      0,
                      (count, item) => count + item.files.length,
                    ) +
                    folder.files.length >
                20000)) {
      _folders.remove(_folders.keys.first);
    }
    _folders[key] = folder;
    return folder;
  }

  static String _entryName(String value) {
    final name = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
    require(name.isNotEmpty && name.length <= 1024, '蓝奏未返回有效名称，请刷新列表');
    return name;
  }

  void _checkSession(BrowseSession session) {
    RequestScope.checkpoint();
    require(
      session.platform == platform &&
          session.mode == BrowseMode.share &&
          session.sourceLink?.platform == platform,
      '蓝奏分享会话已失效，请重新解析',
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async {
    if (session.mode == BrowseMode.personal) {
      return _personalList(session, parentId, credential);
    }
    _checkSession(session);
    final root = session.sourceLink!;
    if (session.rootId != '0') {
      final link = _folderLink(session, parentId);
      final cached = _cachedFolder(root, link);
      // openShare has already fetched and validated the first listing. All
      // later list calls revalidate so the browser's refresh is a real refresh.
      if (parentId == session.rootId && cached?.initialList == true) {
        cached!.initialList = false;
        return cached.files;
      }
      return (await _resolveFolder(root, link)).files;
    }
    require(parentId == session.rootId, '单文件分享没有子目录');
    return [
      CloudFile(
        id: session.sourceLink!.shareId!,
        name: session.meta('fileName'),
        parentId: session.rootId,
        size: int.tryParse(session.meta('displaySize')) ?? 0,
      ),
    ];
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) => OperationProgress.step(OperationStage.downloadLink, () async {
    if (session.mode == BrowseMode.personal) {
      require(credential != null, '请先登录蓝奏云');
      final link = await _personalShare(file, credential!);
      final share = await openShare(link, null);
      final sharedFiles = await list(share, share.rootId, null);
      require(
        sharedFiles.length == 1 && !sharedFiles.single.isDirectory,
        '蓝奏下载文件信息无效',
      );
      return (await download(
        share,
        sharedFiles.single,
        null,
      )).copyWith(fileName: file.name);
    }
    _checkSession(session);
    final root = session.sourceLink!;
    final fromFolder = session.rootId != '0';
    var link = root;
    require(!file.isDirectory, '请选择蓝奏文件夹中的文件下载');
    if (fromFolder) {
      final parentLink = _folderLink(session, file.parentId);
      final folder =
          _cachedFolder(root, parentLink) ??
          await _resolveFolder(root, parentLink);
      final member = folder.files
          .where((item) => !item.isDirectory && item.id == file.id)
          .firstOrNull;
      require(member != null, '蓝奏源文件已移动或失效，请刷新列表');
      require(
        file.size == 0 || member!.size == 0 || file.size == member.size,
        '蓝奏源文件已变化，请重新解析',
      );
      link = ParsedLink(
        source: member!.token,
        url: member.token,
        kind: LinkKind.cloudShare,
        platform: platform,
        shareId: member.id,
        passcode: root.passcode,
      );
    } else {
      require(file.id == link.shareId, '蓝奏分享文件不匹配，请刷新列表');
    }
    var share = _cached(link) ?? await _resolve(link);
    for (var attempt = 0; attempt < 2; attempt++) {
      require(
        fromFolder ||
            file.size == 0 ||
            share.displaySize == 0 ||
            file.size == share.displaySize,
        '蓝奏源文件已变化，请重新解析',
      );
      try {
        final (url, size) = await share.downloadTarget();
        RequestScope.checkpoint();
        return DownloadSpec(
          url: url,
          fileName: share.name,
          expectedSize: size,
          headers: share.transport.headers(Uri.parse(url), share.referer),
        );
      } on _LanzouLinkExpired {
        _cache.remove(_key(link));
        if (attempt == 1) {
          throw const AppException('蓝奏下载地址已失效，请稍后重新解析');
        }
        share = await _resolve(link);
      }
    }
    throw const AppException('蓝奏下载地址获取失败');
  });

  static String _downloadUrl(String value) {
    final uri = _downloadUri(value);
    final prefix = RegExp(
      r'^https?://[^/?#]+',
      caseSensitive: false,
    ).firstMatch(value)!;
    final suffix = value.substring(prefix.end).split('#').first;
    return LinkParser.normalize('${uri.origin}$suffix');
  }

  static Uri _downloadApiUri(Uri referer, String endpoint) {
    final uri = _downloadUri(referer.resolve(endpoint).toString());
    require(
      (uri.origin == referer.origin ||
              uri.origin == 'https://apifile.woozooo.com') &&
          {'/ajaxm.php', '/ajaxfile.php'}.contains(uri.path) &&
          !uri.hasFragment &&
          uri.queryParametersAll['file']?.length == 1,
      '蓝奏下载接口地址异常，请重新解析',
    );
    return uri;
  }

  static String _redirectUrl(String base, String location) {
    require(location.isNotEmpty, '蓝奏下载跳转信息不完整');
    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(location)) {
      return _downloadUrl(location);
    }
    if (location.startsWith('//')) return _downloadUrl('https:$location');
    require(
      !RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:').hasMatch(location),
      '蓝奏下载跳转地址无效',
    );
    final origin = Uri.parse(base).origin;
    final prefix = RegExp(r'^https?://[^/?#]+').firstMatch(base)!;
    final basePath = base.substring(prefix.end).split(RegExp(r'[?#]')).first;
    if (location.startsWith('?')) {
      return _downloadUrl('$origin$basePath$location');
    }
    if (location.startsWith('#')) return _downloadUrl(base);
    final tailIndex = location.indexOf(RegExp(r'[?#]'));
    final path = tailIndex < 0 ? location : location.substring(0, tailIndex);
    final tail = tailIndex < 0 ? '' : location.substring(tailIndex);
    final directory = basePath.contains('/')
        ? basePath.substring(0, basePath.lastIndexOf('/') + 1)
        : '/';
    final merged = path.startsWith('/') ? path : '$directory$path';
    final segments = <String>[];
    for (final segment in merged.split('/')) {
      if (segment == '..') {
        if (segments.length > 1) segments.removeLast();
      } else if (segment != '.') {
        segments.add(segment);
      }
    }
    if (merged.endsWith('/.') || merged.endsWith('/..')) segments.add('');
    return _downloadUrl('$origin${segments.join('/')}$tail');
  }

  static Uri _downloadUri(String value) {
    final uri = Uri.tryParse(value);
    require(
      uri != null &&
          ['https', 'http'].contains(uri.scheme) &&
          uri.host.contains('.') &&
          uri.userInfo.isEmpty &&
          (uri.port == 80 || uri.port == 443) &&
          !RegExp(r'[\x00-\x20\x7f]').hasMatch(value),
      '蓝奏返回了无效的下载地址',
    );
    return uri!.scheme == 'http'
        ? uri.replace(scheme: 'https', port: 443)
        : uri;
  }

  static Uri _shareUri(String value) {
    final uri = _downloadUri(value);
    require(
      CloudPlatform.fromHost(uri.host) == CloudPlatform.lanzou,
      '不是有效的蓝奏分享地址',
    );
    return uri.removeFragment();
  }

  @override
  Future<CloudAccount> account(Credential credential) async {
    await _personalContext(credential);
    return const CloudAccount('蓝奏云用户');
  }

  @override
  Future<BrowseSession> openPersonal(Credential credential) async {
    if (!LoginCredentials.plausible(platform, credential.primary)) {
      throw const AccountLoginRequired('请先登录蓝奏云');
    }
    return const BrowseSession(
      platform: CloudPlatform.lanzou,
      mode: BrowseMode.personal,
      title: '我的蓝奏云',
      rootId: '-1',
    );
  }

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) => _personalMkdir(s, parent, name, c);
  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) => _personalUpload(s, parent, source, c, onProgress);
  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) => _personalRename(s, f, name, c);
  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) => _personalMove(s, files, target, c);
  @override
  Future<void> delete(BrowseSession s, List<CloudFile> files, Credential c) =>
      _personalDelete(s, files, c);
  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) async {
    require(s.canManageFiles && files.length == 1, '蓝奏一次只能分享一个文件或文件夹');
    require(
      (options.expiryDays ?? 0) == 0 && (options.passcode ?? '').isEmpty,
      '蓝奏暂不支持在此修改分享期限或提取码，请使用官网',
    );
    final link = await _personalShare(files.single, c);
    return ShareCreation(link.url, link.passcode ?? '', options.title);
  }

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async => throw const AppException('蓝奏分享暂不支持直接转存，请下载后上传');
}

typedef _LanzouLanding = ({
  Uri uri,
  LanzouPage page,
  _LanzouTransport transport,
});

class _LanzouFolder {
  _LanzouFolder({
    required this.name,
    required this.files,
    required this.expires,
    required this.initialList,
  });
  final String name;
  final List<CloudFile> files;
  final DateTime expires;
  bool initialList;
}

class _LanzouTransport {
  _LanzouTransport(this.http, Uri share, DateTime Function() clock)
    : cookies = LoginCookieJar({
        share.host,
        share.host.split('.').skip(share.host.split('.').length - 2).join('.'),
      }, clock: clock);
  final JsonHttp http;
  final LoginCookieJar cookies;

  Map<String, String> headers(Uri uri, Uri referer) {
    final cookie = cookies.header(uri);
    return {
      'User-Agent': LanzouConnector.webUa,
      'Referer': referer.toString(),
      if (cookie.isNotEmpty) 'Cookie': cookie,
    };
  }

  void cookie(Uri uri, String name, String value) {
    cookies.allowedDomains.add(uri.host);
    cookies.absorb(
      uri,
      HttpResult(200, '', {
        'set-cookie': ['$name=$value; Path=/; Secure'],
      }),
    );
  }

  Future<HttpResult> request(
    String method,
    Uri uri,
    Uri referer, {
    String? body,
    bool peek = false,
    String? rawUrl,
  }) async {
    RequestScope.checkpoint();
    cookies.allowedDomains.add(uri.host);
    final result = peek
        ? await http.peek(
            rawUrl ?? uri.toString(),
            headers(uri, referer),
            followRedirects: false,
          )
        : await (method == 'POST' &&
                  (uri.path.endsWith('/ajaxm.php') ||
                      uri.path.endsWith('/ajaxfile.php') ||
                      uri.path.endsWith('/filemoreajax.php'))
              ? http.readRequest
              : http.request)(
            method,
            rawUrl ?? uri.toString(),
            body: body,
            headers: {
              ...headers(uri, referer),
              if (body != null) 'Origin': referer.origin,
              if (body != null) 'X-Requested-With': 'XMLHttpRequest',
            },
            contentType: body == null
                ? null
                : 'application/x-www-form-urlencoded; charset=utf-8',
            followRedirects: false,
          );
    RequestScope.checkpoint();
    cookies.absorb(uri, result);
    return result;
  }

  Future<(Uri, HttpResult)> page(Uri start, Uri referer) async {
    var uri = start;
    final challenges = <String>{};
    for (var attempt = 0; attempt < 8; attempt++) {
      final response = await request('GET', uri, referer);
      if (_redirect(response)) {
        require(response.header('location').isNotEmpty, '蓝奏页面跳转信息不完整');
        uri = LanzouConnector._shareUri(
          uri.resolve(response.header('location')).toString(),
        );
        continue;
      }
      require(response.body.length <= 1024 * 1024, '蓝奏分享页面过大或异常');
      final challenge = lanzouChallengeCookie(response.body);
      if (challenge != null) {
        require(challenges.add(uri.host), '蓝奏需要进一步验证，请在分享页完成验证后重试');
        cookie(uri, 'acw_sc__v2', challenge);
        continue;
      }
      require(response.status != 429, '蓝奏请求过于频繁，请稍后再试');
      require(response.successful, '蓝奏分享页面无法访问，请确认链接后重试');
      return (uri, response);
    }
    throw const AppException('蓝奏页面跳转次数过多，请重新解析');
  }

  static bool _redirect(HttpResult response) =>
      {301, 302, 303, 307, 308}.contains(response.status);
}

class _LanzouLinkExpired implements Exception {}

class _LanzouShare {
  _LanzouShare({
    required this.link,
    required this.name,
    required this.displaySize,
    required this.jump,
    required this.referer,
    required this.transport,
    required this.expires,
  });
  final ParsedLink link;
  final String name;
  final int displaySize;
  final String jump;
  final Uri referer;
  final _LanzouTransport transport;
  final DateTime expires;

  Future<(String, int)> downloadTarget() async {
    var url = jump;
    final visited = <String>{},
        challenges = <String>{},
        confirmations = <String>{};
    transport.cookie(Uri.parse(jump), 'down_ip', '1');
    for (var attempt = 0; attempt < 8; attempt++) {
      final uri = Uri.parse(url);
      require(visited.add(url), '蓝奏下载地址循环跳转，请重新解析');
      var response = await transport.request('HEAD', uri, referer, rawUrl: url);
      require(response.status != 429, '蓝奏下载请求过于频繁，请稍后再试');
      if (!_LanzouTransport._redirect(response) &&
          (!response.successful ||
              _html(response) ||
              response.header('content-type').isEmpty)) {
        // Some landing/CDN servers reject HEAD. Dio's streaming peek stops at
        // 8 KiB even if the server ignores Range and starts returning a file.
        response = await transport.request(
          'GET',
          uri,
          referer,
          peek: true,
          rawUrl: url,
        );
      }
      if (_LanzouTransport._redirect(response)) {
        require(response.header('location').isNotEmpty, '蓝奏下载跳转信息不完整');
        url = LanzouConnector._redirectUrl(url, response.header('location'));
        continue;
      }
      if ({403, 404, 410}.contains(response.status)) throw _LanzouLinkExpired();
      require(response.status != 429, '蓝奏下载请求过于频繁，请稍后再试');
      require(response.successful, '蓝奏下载地址暂时不可用，请稍后重试');
      final challenge = lanzouChallengeCookie(response.body);
      if (challenge != null) {
        require(challenges.add(uri.host), '蓝奏需要进一步验证，请在分享页完成验证后重试');
        transport.cookie(uri, 'acw_sc__v2', challenge);
        visited.remove(url);
        continue;
      }
      if (_html(response)) {
        final fields = LanzouPage(response.body).downloadConfirmation;
        require(
          fields != null && confirmations.add(uri.host),
          '蓝奏返回的是验证页面，未创建下载任务，请在分享页完成验证后重试',
        );
        // The node's page reveals this button after two seconds. Respect the
        // same delay instead of submitting its time-bound form immediately.
        await Future.any([
          Future<void>.delayed(const Duration(seconds: 2)),
          if (RequestScope.current != null) RequestScope.current!.whenCancel,
        ]);
        RequestScope.checkpoint();
        final confirmation = await transport.request(
          'POST',
          uri.resolve('ajax.php'),
          uri,
          body: form(fields!),
        );
        require(
          confirmation.successful && confirmation.body.length <= 65536,
          '蓝奏下载验证服务暂时不可用，请稍后重试',
        );
        Json checked;
        try {
          checked = confirmation.json;
        } on AppException {
          throw const AppException('蓝奏需要进一步验证，请在分享页完成验证后重试');
        }
        require(
          checked.integer('zt') == 1 && checked.str('url').isNotEmpty,
          '蓝奏需要进一步验证，请在分享页完成验证后重试',
        );
        require(checked.str('url') != '?SignError', '蓝奏下载验证已过期，请重新解析');
        url = LanzouConnector._redirectUrl(url, checked.str('url'));
        continue;
      }
      final range = RegExp(
        r'^bytes\s+\d+-\d+/(\d+)$',
        caseSensitive: false,
      ).firstMatch(response.header('content-range'));
      final size = range != null
          ? int.tryParse(range[1]!) ?? 0
          : response.status == 200
          ? int.tryParse(response.header('content-length')) ?? 0
          : 0;
      return (url, size > 0 ? size : 0);
    }
    throw const AppException('蓝奏下载跳转次数过多，请重新解析');
  }

  static bool _html(HttpResult response) =>
      !RegExp(
        r'attachment|filename\s*=',
        caseSensitive: false,
      ).hasMatch(response.header('content-disposition')) &&
      (response.header('content-type').toLowerCase().contains('text/html') ||
          RegExp(
            r'^\s*(?:<!doctype\s+html|<html|<script)',
            caseSensitive: false,
          ).hasMatch(response.body));
}
