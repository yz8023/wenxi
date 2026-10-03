part of '../lanzou.dart';

const _lanzouPersonalBase = 'https://pc.woozooo.com';

class _LanzouAccountContext {
  _LanzouAccountContext(this.cookie);
  String cookie;
  Map<String, String> parameters = {};
  Map<String, String> get headers => {
    'Cookie': cookie,
    'User-Agent': WebLoginTarget.desktopUserAgent,
    'Referer': '$_lanzouPersonalBase/mydisk.php',
    'Origin': _lanzouPersonalBase,
  };
}

extension _LanzouPersonal on LanzouConnector {
  Future<HttpResult> _accountRequest(
    _LanzouAccountContext context,
    String method,
    String url, {
    Object? body,
    String? contentType,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      RequestScope.checkpoint();
      final response = await http.request(
        method,
        url,
        body: body,
        headers: context.headers,
        contentType: contentType,
        followRedirects: false,
      );
      final challenge = lanzouChallengeCookie(response.body);
      if (challenge == null) return response;
      require(attempt == 0, '蓝奏需要网页验证，请重新网页登录');
      context.cookie = LoginCredentials.mergeCookies([
        context.cookie,
        'acw_sc__v2=$challenge',
      ]);
    }
    throw const AppException('蓝奏请求失败');
  }

  Future<_LanzouAccountContext> _personalContext(Credential c) async {
    final cookie = LoginCredentials.normalize(CloudPlatform.lanzou, c.primary);
    final context = _LanzouAccountContext(cookie);
    final response = await _accountRequest(
      context,
      'GET',
      '$_lanzouPersonalBase/mydisk.php?item=files&action=index',
    );
    if (!response.successful) {
      throw const AccountLoginRequired('蓝奏登录已过期，请重新网页登录');
    }
    try {
      context.parameters = LanzouPage(response.body).accountParameters;
    } on AppException {
      throw const AccountLoginRequired('蓝奏登录已过期或尚未进入文件页，请重新网页登录');
    }
    return context;
  }

  Json _accountChecked(HttpResult response, {bool listing = false}) {
    if (response.status == 401 || response.status == 403) {
      throw const AccountLoginRequired('蓝奏登录已过期，请重新网页登录');
    }
    final data = response.json, status = data.integer('zt');
    if (status == 9 || response.status == 401) {
      throw const AccountLoginRequired('蓝奏登录已过期，请重新网页登录');
    }
    require(
      response.successful && (status == 1 || listing && status == 2),
      status == 4 ? '蓝奏请求频繁，请稍后重试' : '蓝奏文件操作失败（$status），请在官网检查权限和文件类型',
    );
    return data;
  }

  Future<Json> _accountCall(
    _LanzouAccountContext context,
    Json fields, {
    bool listing = false,
  }) async => _accountChecked(
    await _accountRequest(
      context,
      'POST',
      query('$_lanzouPersonalBase/doupload.php', context.parameters),
      body: form(fields),
      contentType: 'application/x-www-form-urlencoded; charset=utf-8',
    ),
    listing: listing,
  );

  String _personalId(String value) {
    final id = value.replaceFirst(RegExp(r'^[df]:'), '');
    require(RegExp(r'^(?:-1|[0-9]{1,24})$').hasMatch(id), '蓝奏目录或文件标识无效');
    return id;
  }

  CloudFile _accountFile(Json value, String parent, {bool folder = false}) {
    final id = value.str(folder ? 'fol_id' : 'id').ifEmpty(value.str('id'));
    final name = value
        .str(folder ? 'name' : 'name_all')
        .ifEmpty(value.str('name'));
    require(id.isNotEmpty && name.isNotEmpty, '蓝奏文件信息不完整');
    final raw = value.str('size').trim();
    final match = RegExp(
      r'^([\d.]+)\s*([KMGT]?)',
      caseSensitive: false,
    ).firstMatch(raw);
    final size = match == null
        ? 0
        : ((double.tryParse(match[1]!) ?? 0) *
                  math.pow(
                    1024,
                    math.max(
                      0,
                      ['', 'K', 'M', 'G', 'T'].indexOf(match[2]!.toUpperCase()),
                    ),
                  ))
              .round();
    return CloudFile(
      id: '${folder ? 'd' : 'f'}:${_personalId(id)}',
      name: name,
      isDirectory: folder,
      size: folder ? 0 : size,
      parentId: parent,
      modifiedAt: value.str('time'),
    );
  }

  Future<List<CloudFile>> _personalList(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async {
    require(s.canManageFiles, '请在个人网盘中浏览文件');
    if (c == null) throw const AccountLoginRequired('请先登录蓝奏云');
    final context = await _personalContext(c), folderId = _personalId(parent);
    final folders = await _accountCall(context, {
      'task': 47,
      'folder_id': folderId,
    }, listing: true);
    final result = [
      for (final item in folders.list('text'))
        _accountFile(item, parent, folder: true),
    ];
    final seen = result.map((e) => e.id).toSet();
    for (var page = 1; page <= 1000; page++) {
      final response = await _accountCall(context, {
        'task': 5,
        'folder_id': folderId,
        'pg': page,
      }, listing: true);
      final entries = response.list('text');
      if (entries.isEmpty) return result;
      var count = 0;
      for (final item in entries) {
        final file = _accountFile(item, parent);
        if (seen.add(file.id)) {
          result.add(file);
          count++;
        }
      }
      require(count > 0, '蓝奏文件分页重复，请刷新后重试');
    }
    throw const AppException('蓝奏目录文件过多，请分目录打开');
  }

  Future<CloudFile> _personalMkdir(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    require(s.canManageFiles, '请在个人网盘中新建文件夹');
    final context = await _personalContext(c);
    final result = await _accountCall(context, {
      'task': 2,
      'parent_id': _personalId(parent),
      'folder_name': name,
      'folder_description': '',
    });
    final id = result.str('text');
    require(RegExp(r'^\d+$').hasMatch(id), '蓝奏未返回新文件夹信息');
    return CloudFile(
      id: 'd:$id',
      name: name,
      parentId: parent,
      isDirectory: true,
    );
  }

  Future<CloudFile> _personalUpload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c,
    UploadProgressCallback? onProgress,
  ) async {
    require(s.canManageFiles, '请在个人网盘中上传文件');
    final context = await _personalContext(c),
        io = UploadIO(http, source, onProgress);
    io.progress(UploadPhase.preparing);
    final result = _accountChecked(
      await _accountRequest(
        context,
        'POST',
        '$_lanzouPersonalBase/html5up.php',
        body: HttpUpload(
          open: () => source.openRead(),
          length: source.size,
          fileName: source.name,
          fieldName: 'upload_file',
          fields: {
            'task': '1',
            'vie': '2',
            've': '2',
            'id': 'WU_FILE_0',
            'name': source.name,
            'folder_id_bb_n': _personalId(parent),
          },
          onProgress: (sent, total) => io.progress(
            UploadPhase.uploading,
            total > 0 ? source.size * sent ~/ total : 0,
          ),
        ),
      ),
    );
    final uploaded = result.list('text').firstOrNull;
    final id = uploaded?.str('id') ?? '';
    return io.confirm(
      () => list(s, parent, c),
      id: id.isEmpty ? '' : 'f:$id',
      exactSize: false,
    );
  }

  Future<void> _personalRename(
    BrowseSession s,
    CloudFile file,
    String name,
    Credential c,
  ) async {
    require(s.canManageFiles, '请在个人网盘中修改文件');
    final context = await _personalContext(c);
    await _accountCall(
      context,
      file.isDirectory
          ? {
              'task': 4,
              'folder_id': _personalId(file.id),
              'folder_name': name,
              'folder_description': '',
            }
          : {
              'task': 46,
              'file_id': _personalId(file.id),
              'file_name': name,
              'type': 2,
            },
    );
  }

  Future<void> _personalMove(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    require(s.canManageFiles, '请在个人网盘中移动文件');
    require(files.every((f) => !f.isDirectory), '蓝奏暂不支持移动文件夹，请在官网操作');
    final context = await _personalContext(c);
    for (final file in files) {
      await _accountCall(context, {
        'task': 20,
        'folder_id': _personalId(target),
        'file_id': _personalId(file.id),
      });
    }
  }

  Future<void> _personalDelete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    require(
      s.canManageFiles && files.every((f) => f.id != s.rootId),
      '不能删除网盘根目录',
    );
    final context = await _personalContext(c);
    for (final file in files) {
      await _accountCall(context, {
        'task': file.isDirectory ? 3 : 6,
        file.isDirectory ? 'folder_id' : 'file_id': _personalId(file.id),
      });
    }
  }

  Future<ParsedLink> _personalShare(CloudFile file, Credential c) async {
    final context = await _personalContext(c);
    final info = (await _accountCall(context, {
      'task': file.isDirectory ? 18 : 22,
      'file_id': _personalId(file.id),
    })).obj('info');
    final raw = info.str(file.isDirectory ? 'new_url' : 'f_id');
    require(raw.isNotEmpty, '蓝奏未返回文件访问链接');
    var base = info.str('is_newd').ifEmpty('https://pan.lanzoui.com');
    if (!base.contains('://')) base = 'https://$base';
    final url = raw.startsWith('https://') || raw.startsWith('http://')
        ? raw
        : '${LanzouConnector._shareUri(base).origin}/${raw.replaceFirst(RegExp(r'^/'), '')}';
    final uri = LanzouConnector._shareUri(url);
    final links = LinkParser.parse(uri.toString());
    require(
      links.length == 1 && links.single.platform == CloudPlatform.lanzou,
      '蓝奏返回的文件链接无效',
    );
    return links.single.withPasscode(info.str('pwd'));
  }
}
