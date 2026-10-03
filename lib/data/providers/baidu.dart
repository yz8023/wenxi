import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../http.dart';
import '../uploads/upload_io.dart';
import '../../core/operation_progress.dart';

class BaiduConnector extends CloudConnector {
  BaiduConnector(this.http, {this.stageCleanup});
  final JsonHttp http;
  final Future<void> Function(DownloadCleanup)? stageCleanup;
  @override
  CloudPlatform get platform => CloudPlatform.baidu;
  // Public web-client identifier used by the supplied YunX Baidu implementation.
  static const defaultAppId = '250528';
  static const webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const netdiskUa =
      'netdisk;12.24.6;piano;android-android;16;JSbridge4.4.0;jointBridge;1.1.0';
  String appId(Credential c) {
    final id = c
        .field('appId')
        .trim()
        .ifEmpty(c.secondary.trim())
        .ifEmpty(defaultAppId);
    require(RegExp(r'^\d+$').hasMatch(id), '百度应用 ID 格式无效，可清空后使用默认值');
    return id;
  }

  String cookie(Credential c) {
    if (!LoginCredentials.plausible(CloudPlatform.baidu, c.primary)) {
      throw const AccountLoginRequired('百度登录信息不完整，请重新网页登录');
    }
    return LoginCredentials.normalize(CloudPlatform.baidu, c.primary);
  }

  Map<String, String> webHeaders(String cookie) => {
    'Cookie': cookie,
    'User-Agent': webUa,
  };
  Map<String, String> diskHeaders(String cookie) => {
    'Cookie': cookie,
    'User-Agent': netdiskUa,
    'Referer': 'https://yun.baidu.com/disk/main',
    'X-Requested-With': 'XMLHttpRequest',
  };
  Json check(
    HttpResult result, {
    bool allowExisting = false,
    bool allowMissingCode = false,
    bool missingShareKey = false,
  }) {
    if (result.status == 401) {
      throw const AccountLoginRequired('百度登录已失效，请重新网页登录');
    }
    final j = result.json;
    final rawCode = j['errno'] ?? j['error_code'];
    final errno =
        int.tryParse(rawCode?.toString() ?? '') ??
        (rawCode == null && allowMissingCode && result.successful ? 0 : -1);
    if (errno == -6) {
      throw const AccountLoginRequired('百度登录已失效，请重新网页登录');
    }
    if (errno == 8888) {
      throw const AppException('百度文件接口返回异常（8888），请稍后重试或重新网页登录');
    }
    if (missingShareKey && {2, -12}.contains(errno)) {
      throw const AppException('该百度分享需要提取码，请补充后重新解析');
    }
    final message = j
        .str('err_msg')
        .ifEmpty(j.str('show_msg'))
        .ifEmpty(j.str('errmsg'))
        .ifEmpty(j.str('error_msg'));
    require(
      result.successful &&
          (errno == 0 || allowExisting && {-8, 12}.contains(errno)),
      message.ifEmpty(switch (errno) {
        -12 => '百度提取码错误，请重新输入',
        -9 || 31066 => '百度文件或分享已失效',
        403 => '百度分享已失效或无权访问',
        _ => '百度请求失败（errno=$errno）',
      }),
    );
    // A successful batch envelope can still contain failed file operations.
    for (final item in j.list('info')) {
      if (item.containsKey('errno')) {
        require(
          item.integer('errno', -1) == 0,
          item.str('errmsg').ifEmpty('百度部分文件操作失败，请刷新列表后重试'),
        );
      }
    }
    return j;
  }

  @override
  Future<CloudAccount> account(Credential credential) async {
    final id = appId(credential), ck = cookie(credential);
    final quota = check(
      await http.get(
        query('https://yun.baidu.com/api/quota', {
          'clienttype': 0,
          'app_id': id,
          'web': 1,
          'channel': 'chunlei',
          'version': DateTime.now().millisecondsSinceEpoch,
        }),
        diskHeaders(ck),
      ),
    );
    final used = int.tryParse(quota.str('used')),
        total = int.tryParse(quota.str('total'));
    require(
      used != null && used >= 0 && total != null && total > 0,
      '百度未返回有效容量，请重试',
    );
    var nickname = credential.field('nickname').ifEmpty('百度用户');
    try {
      nickname = check(
        await http.get(
          query('https://pan.baidu.com/api/gettemplatevariable', {
            'clienttype': 0,
            'app_id': id,
            'web': 1,
            'fields': '["username"]',
          }),
          webHeaders(ck),
        ),
      ).obj('result').str('username').ifEmpty(nickname);
    } on AccountLoginRequired {
      rethrow;
    } on AppException {
      // Quota is usable even if the optional display-name endpoint is unavailable.
    }
    return CloudAccount(nickname, used: used!, total: total!);
  }

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    final id = link.shareId;
    require(id?.isNotEmpty == true, '百度分享链接缺少短链接 ID');
    final ck = credential?.primary ?? '';
    var sekey = '';
    if (link.passcode?.isNotEmpty == true) {
      sekey = check(
        await http.postForm(
          query('https://pan.baidu.com/share/verify', {'surl': id}),
          form({'pwd': link.passcode, 'vcode_str': '', 'vcode': ''}),
          {...webHeaders(ck), 'Referer': 'https://pan.baidu.com/s/1$id'},
        ),
      ).str('randsk');
      require(sekey.isNotEmpty, '百度没有返回分享凭证');
    }
    final result = await _shareList(id!, sekey, '/', ck, 1);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: result.str('title').ifEmpty('百度分享'),
      rootId: '/',
      metadata: {
        'shortId': id,
        'sekey': sekey,
        'shareId': result.str('share_id'),
        'uk': result.str('uk'),
        'cookie': ck,
      },
      sourceLink: link,
    );
  }

  @override
  Future<BrowseSession> openPersonal(Credential credential) async {
    final ck = cookie(credential);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: '我的百度网盘',
      rootId: '/',
      metadata: {'cookie': ck},
    );
  }

  String _shareKey(String value) {
    try {
      // randsk is already URL-encoded. query() performs the single wire encoding.
      final key = Uri.decodeComponent(value);
      require(!RegExp(r'[\x00-\x1f\x7f]').hasMatch(key), '百度分享凭证无效，请重新解析');
      return key;
    } on FormatException {
      throw const AppException('百度分享凭证无效，请重新解析');
    } on ArgumentError {
      throw const AppException('百度分享凭证无效，请重新解析');
    }
  }

  String _shareCookie(String ck, String sekey) {
    final pairs = LoginCredentials.cookiePairs(ck)
      ..removeWhere((name, _) => name.toLowerCase() == 'bdclnd');
    if (sekey.isNotEmpty) {
      pairs['BDCLND'] = Uri.encodeComponent(_shareKey(sekey));
    }
    return pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Future<Json> _shareList(
    String id,
    String sekey,
    String directory,
    String ck,
    int page,
  ) async => check(
    await http.get(
      query('https://pan.baidu.com/rest/2.0/xpan/share', {
        'method': 'list',
        'shorturl': id,
        'page': page,
        'num': 100,
        'root': directory.isEmpty || directory == '/' ? 1 : 0,
        'dir': directory.ifEmpty('/'),
        if (sekey.isNotEmpty) 'sekey': _shareKey(sekey),
      }),
      {
        ...webHeaders(_shareCookie(ck, sekey)),
        'Referer': 'https://pan.baidu.com/s/1$id',
      },
    ),
    missingShareKey: sekey.isEmpty,
  );
  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async {
    final share = s.mode == BrowseMode.share;
    if (!share && c == null) throw const AccountLoginRequired('请先登录百度网盘');
    final ck = share
        ? (c?.primary ?? '').ifEmpty(s.meta('cookie'))
        : cookie(c!);
    final files = <CloudFile>[];
    final seen = <String>{};
    for (var page = 1; page <= 100; page++) {
      final j = share
          ? await _shareList(
              s.meta('shortId'),
              s.meta('sekey'),
              parent,
              ck,
              page,
            )
          : check(
              await http.get(
                query('https://pan.baidu.com/api/list', {
                  'channel': 'chunlei',
                  'clienttype': 0,
                  'app_id': appId(c!),
                  'web': 1,
                  'order': 'time',
                  'desc': 1,
                  'dir': parent.ifEmpty('/'),
                  'num': 100,
                  'page': page,
                }),
                {
                  ...webHeaders(ck),
                  'Referer': 'https://pan.baidu.com/disk/main',
                },
              ),
            );
      require(j['list'] is List, '百度文件列表响应不完整，请刷新重试');
      final batch = j.list('list');
      var fresh = 0;
      for (final item in batch) {
        final directory = item.integer('isdir') == 1 || item.boolean('isdir');
        final path = item.str('path');
        final id = item.str('fs_id').ifEmpty(directory ? path : '');
        require(
          id.isNotEmpty && (!directory || path.startsWith('/')),
          '百度文件信息不完整，请刷新列表',
        );
        if (!seen.add(id)) continue;
        fresh++;
        // Both personal and shared folders retain fs_id; traversal uses the path token.
        files.add(
          CloudFile(
            id: id,
            name: item.str('server_filename'),
            size: item.integer('size'),
            isDirectory: directory,
            parentId: parent,
            token: path,
            modifiedAt: item.str('server_mtime'),
            thumbnailUrl: item
                .obj('thumbs')
                .str('url3')
                .ifEmpty(item.obj('thumbs').str('url2'))
                .ifEmpty(item.obj('thumbs').str('url1')),
          ),
        );
      }
      if (batch.length < 100 || fresh == 0) break;
      require(page < 100, '目录文件过多，请缩小范围后重试');
    }
    return files;
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile file,
    Credential? c,
  ) async {
    require(!file.isDirectory, '文件夹不能直接下载');
    if (c == null) throw const AccountLoginRequired('百度下载需要登录账号');
    final account = c, ck = cookie(c), id = appId(c);
    DownloadCleanup? cleanup;
    String direct;
    if (s.mode == BrowseMode.share) {
      const root = '/文析助手临时转存';
      final token = await _bdstoken(account);
      final directory = '$root/tr_${newId()}';
      await OperationProgress.step(OperationStage.createTemporary, () async {
        await _mkdir(root, account, allowExisting: true, token: token);
        await _mkdir(directory, account, token: token);
      });
      // Delete only the unique directory created by this request, never the shared root.
      cleanup = DownloadCleanup(
        url: _managerUrl('delete', id, token),
        body: form({
          'filelist': encoded([directory]),
        }),
        headers: {
          ...diskHeaders(ck),
          'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
        },
      );
      try {
        await stageCleanup?.call(cleanup);
        final transferred = await OperationProgress.step(
          OperationStage.transfer,
          () => _transfer(s, file, directory, account, token: token),
        );
        final path = transferred.str('to');
        require(
          path.startsWith('$directory/') && path != '$directory/',
          '百度转存未返回完整文件路径',
        );
        direct = await OperationProgress.step(
          OperationStage.downloadLink,
          () => _downloadUrl(path, transferred.str('to_fs_id'), account),
        );
      } catch (_) {
        final pending = cleanup;
        try {
          await OperationProgress.step(OperationStage.cleanup, () async {
            check(
              await http.postForm(pending.url, pending.body!, pending.headers),
            );
          });
        } catch (_) {}
        rethrow;
      }
    } else {
      final path = file.token.ifEmpty(file.id.startsWith('/') ? file.id : '');
      direct = await OperationProgress.step(
        OperationStage.downloadLink,
        () => _downloadUrl(path, file.id, account),
      );
    }
    require(direct.isNotEmpty, '百度没有返回可用下载链接');
    return DownloadSpec(
      url: direct,
      fileName: file.name,
      expectedSize: file.size,
      checksumType: file.hashType,
      checksumValue: file.hashValue,
      headers: {
        'Cookie': ck,
        'User-Agent': netdiskUa,
        'Referer': 'https://pan.baidu.com/',
      },
      cleanup: cleanup,
    );
  }

  bool _httpUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        {'https', 'http'}.contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  Future<String> _downloadUrl(String path, String fsId, Credential c) async {
    if (path.startsWith('/')) {
      try {
        return await _locate(path, cookie(c), appId(c));
      } on AccountLoginRequired {
        rethrow;
      } on AppException {
        if (RequestScope.current?.isCancelled == true ||
            !RegExp(r'^\d+$').hasMatch(fsId)) {
          rethrow;
        }
      }
    }
    require(RegExp(r'^\d+$').hasMatch(fsId), '百度文件标识已失效，请刷新列表后重试');
    final j = check(
      await http.get(
        query('https://pan.baidu.com/api/filemetas', {
          'dlink': 1,
          'fsids': encoded([fsId]),
          'bdstoken': await _bdstoken(c),
          'clienttype': 0,
          'app_id': appId(c),
          'web': 1,
        }),
        webHeaders(cookie(c)),
      ),
    );
    final direct = j.list('info').firstOrNull?.str('dlink') ?? '';
    require(_httpUrl(direct), '百度没有返回可用下载链接');
    return direct;
  }

  Future<String> _locate(String path, String ck, String id) async {
    require(path.isNotEmpty, '百度转存未返回路径');
    final j = check(
      await http.postFormRead(
        query('https://d.pcs.baidu.com/rest/2.0/pcs/file', {
          'method': 'locatedownload',
          'app_id': id,
          'clienttype': 17,
          'ver': '4.0',
          'ant': 1,
          'check_blue': 1,
          'es': 1,
          'esl': 1,
          'apn_id': '1_-1',
          'freeisp': 0,
          'queryfree': 0,
          'use': 1,
          'dtype': 1,
          'eck': 1,
          'ehps': 1,
          'err_ver': '1.0',
          'network_type': 'WIFI',
          'channel': 0,
          'path': path,
          'time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'rand': '5ed606e9da222cde0474cdf70eda884b',
          'devuid': '0F1E9FC2E084472DA5A61C4CF4C759AF',
          'cuid': '0F1E9FC2E084472DA5A61C4CF4C759AF',
          'deviceid': '348642637967375013',
          'psign': '860a071f77c860e8cea06e4e54c518f3',
          'version': '2.2.111.34',
          'version_app': '12.24.6',
          'vip': 0,
        }),
        '0',
        {'Cookie': ck, 'User-Agent': netdiskUa},
      ),
      allowMissingCode: true,
    );
    final urls = j
        .list('urls')
        .where((u) => u.integer('encrypt', 1) == 0 && _httpUrl(u.str('url')))
        .toList();
    final candidate =
        urls.where((u) => u.str('url').startsWith('https:')).firstOrNull ??
        urls.firstOrNull;
    require(candidate != null, '百度未返回可直接下载的链接，请稍后重试');
    return candidate!.str('url');
  }

  Future<String> _bdstoken(Credential c) async {
    final token = check(
      await http.get(
        query('https://pan.baidu.com/api/gettemplatevariable', {
          'clienttype': 0,
          'app_id': appId(c),
          'web': 1,
          'fields': '["bdstoken"]',
        }),
        webHeaders(cookie(c)),
      ),
    ).obj('result').str('bdstoken');
    require(token.isNotEmpty, '无法获取百度会话令牌');
    return token;
  }

  Future<Json> _mkdir(
    String path,
    Credential c, {
    bool allowExisting = false,
    String? token,
  }) async {
    return check(
      await http.postForm(
        query('https://pan.baidu.com/api/create', {
          'a': 'commit',
          'channel': 'chunlei',
          'web': 1,
          'app_id': appId(c),
          'clienttype': 0,
          'bdstoken': token ?? await _bdstoken(c),
        }),
        form({
          'path': path,
          'isdir': 1,
          'size': '',
          'block_list': '[]',
          'method': 'post',
          'dataType': 'json',
        }),
        diskHeaders(cookie(c)),
      ),
      allowExisting: allowExisting,
    );
  }

  String _managerUrl(String op, String id, String token) => query(
    'https://${op == 'rename' ? 'yun' : 'pan'}.baidu.com/api/filemanager',
    {
      'async': op == 'rename' ? 0 : 2,
      'onnest': 'fail',
      'opera': op,
      'bdstoken': token,
      if (op == 'delete') 'newVerify': 1,
      'clienttype': 0,
      'app_id': id,
      'web': 1,
    },
  );
  Future<void> _manage(String op, List<Object?> files, Credential c) async {
    check(
      await http.postForm(
        _managerUrl(op, appId(c), await _bdstoken(c)),
        form({'filelist': encoded(files)}),
        diskHeaders(cookie(c)),
      ),
    );
  }

  void personal(BrowseSession s) =>
      require(s.mode == BrowseMode.personal, '请在个人网盘中执行此操作');
  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    personal(s);
    require(source.size > 0, '百度网盘不支持上传空文件');
    final io = UploadIO(http, source, onProgress), ck = cookie(c);
    final token = await _bdstoken(c);
    final path = '${parent.replaceFirst(RegExp(r'/+$'), '')}/${source.name}';
    const chunkSize = 4 * 1024 * 1024;
    final count = (source.size / chunkSize).ceil(), blocks = <String>[];
    for (var i = 0; i < count; i++) {
      blocks.add(
        await io.digest(
          md5,
          start: i * chunkSize,
          end: math.min(source.size, (i + 1) * chunkSize),
        ),
      );
    }
    final whole = await io.digest(md5),
        prefix = await io.digest(md5, end: math.min(source.size, 256 * 1024));
    final params = <String, Object?>{
      'channel': 'chunlei',
      'web': 1,
      'app_id': appId(c),
      'clienttype': 0,
      'bdstoken': token,
    };
    final pre = check(
      await http.postForm(
        query('https://pan.baidu.com/api/precreate', params),
        form({
          'path': path,
          'isdir': 0,
          'size': source.size,
          'autoinit': 1,
          'block_list': encoded(blocks),
          'rtype': 0,
          'content-md5': whole,
          'slice-md5': prefix,
        }),
        diskHeaders(ck),
      ),
    );
    if (pre.integer('return_type') != 2) {
      final uploadId = pre.str('uploadid');
      require(uploadId.isNotEmpty, '百度未创建上传任务');
      final needed = pre['block_list'];
      require(needed is List, '百度未返回待上传分段');
      final uploaded = <int>{};
      for (final raw in needed as List) {
        final index = int.tryParse('$raw');
        require(
          index != null && index >= 0 && index < count && uploaded.add(index),
          '百度返回的上传分段序号无效',
        );
        final result = check(
          await io.send(
            query('https://d.pcs.baidu.com/rest/2/pcs/superfile2', {
              ...params,
              'method': 'upload',
              'type': 'tmpfile',
              'path': path,
              'uploadid': uploadId,
              'partseq': index,
            }),
            method: 'POST',
            start: index! * chunkSize,
            end: math.min(source.size, (index + 1) * chunkSize),
            fields: const {},
            headers: webHeaders(ck),
            retry: false,
          ),
          allowMissingCode: true,
        );
        require(result.str('md5').toLowerCase() == blocks[index], '百度上传分段校验失败');
      }
      io.progress(UploadPhase.finishing, source.size);
      final completed = check(
        await http.postForm(
          query('https://pan.baidu.com/api/create', {...params, 'a': 'commit'}),
          form({
            'path': path,
            'isdir': 0,
            'size': source.size,
            'uploadid': uploadId,
            'block_list': encoded(blocks),
            'rtype': 0,
            'local_mtime': source.modifiedAt.millisecondsSinceEpoch ~/ 1000,
          }),
          diskHeaders(ck),
        ),
      );
      return io.confirm(() => list(s, parent, c), id: completed.str('fs_id'));
    }
    return io.confirm(
      () => list(s, parent, c),
      id: pre.obj('info').str('fs_id'),
    );
  }

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    personal(s);
    final path = '${parent.replaceFirst(RegExp(r'/+$'), '')}/$name';
    final created = await _mkdir(path, c);
    return CloudFile(
      id: created.str('fs_id').ifEmpty(path),
      name: name,
      isDirectory: true,
      parentId: parent,
      token: path,
    );
  }

  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) async {
    personal(s);
    await _manage('rename', [
      {'path': f.token.ifEmpty(f.id), 'newname': name},
    ], c);
  }

  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    personal(s);
    await _manage(
      'move',
      files
          .map(
            (f) => {
              'path': f.token.ifEmpty(f.id),
              'dest': target,
              'newname': f.token.ifEmpty(f.id).split('/').last,
            },
          )
          .toList(),
      c,
    );
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    personal(s);
    await _manage(
      'delete',
      files.map((f) => f.token.ifEmpty(f.id)).toList(),
      c,
    );
  }

  Future<Json> _transfer(
    BrowseSession s,
    CloudFile file,
    String target,
    Credential c, {
    String? token,
  }) async {
    final ck = cookie(c), sekey = s.meta('sekey');
    require(RegExp(r'^\d+$').hasMatch(file.id), '百度文件标识缺失，请重新打开分享列表');
    var shareId = s.meta('shareId'), uk = s.meta('uk');
    if (shareId.isEmpty || uk.isEmpty) {
      final root = await _shareList(s.meta('shortId'), sekey, '/', ck, 1);
      shareId = root.str('share_id');
      uk = root.str('uk');
    }
    require(shareId.isNotEmpty && uk.isNotEmpty, '百度分享信息不完整，请重新解析链接');
    final j = check(
      await http.postForm(
        query('https://pan.baidu.com/share/transfer', {
          'shareid': shareId,
          'from': uk,
          'channel': 'chunlei',
          if (sekey.isNotEmpty) 'sekey': _shareKey(sekey),
          'ondup': 'newcopy',
          'web': 1,
          'app_id': appId(c),
          'bdstoken': token ?? await _bdstoken(c),
          'clienttype': 0,
        }),
        form({
          'fsidlist': encoded([file.id]),
          'path': target,
        }),
        {
          ...webHeaders(_shareCookie(ck, sekey)),
          'Origin': 'https://pan.baidu.com',
          'Referer': 'https://pan.baidu.com/s/',
        },
      ),
    );
    final item = j.obj('extra').list('list').firstOrNull;
    require(item != null && item.str('to_fs_id').isNotEmpty, '百度转存未返回文件信息');
    return item!;
  }

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    require(s.mode == BrowseMode.share, '请打开分享链接');
    for (final file in files) {
      await _transfer(s, file, target, c);
    }
  }

  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) async {
    personal(s);
    final password = options.passcode ?? '';
    require(
      files.isNotEmpty && files.every((f) => RegExp(r'^\d+$').hasMatch(f.id)),
      '百度文件标识缺失，请刷新列表后重试',
    );
    final j = check(
      await http.postForm(
        query('https://pan.baidu.com/share/set', {
          'channel': 'chunlei',
          'web': 1,
          'app_id': appId(c),
          'bdstoken': await _bdstoken(c),
          'clienttype': 0,
        }),
        form({
          'fid_list': encoded(
            files.map((f) => int.tryParse(f.id) ?? f.id).toList(),
          ),
          'schannel': 4,
          'channel_list': '[]',
          'period': {1, 7, 30}.contains(options.expiryDays)
              ? options.expiryDays
              : 0,
          'pwd': password,
        }),
        diskHeaders(cookie(c)),
      ),
    );
    final url = j.str('shorturl').ifEmpty(j.str('link'));
    require(url.isNotEmpty, '百度没有返回分享链接');
    return ShareCreation(url, password, options.title);
  }
}
