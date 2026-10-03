part of '../weiyun.dart';

extension _WeiyunUpload on WeiyunConnector {
  Future<Json> _uploadCall(
    TokenSession session,
    String name,
    int cmd,
    Json data, {
    UploadFile? source,
    int start = 0,
    int length = 0,
    int completed = 0,
    UploadProgressCallback? onProgress,
  }) async {
    final payload = {
      'req_header': {
        'cmd': cmd,
        'appid': 30013,
        'major_version': 3,
        'minor_version': 0,
        'fix_version': 0,
        'version': 3,
        'user_flag': 0,
      },
      'req_body': {
        'ReqMsg_body': {'weiyun.${name}MsgReq_body': data},
      },
    };
    for (var attempt = 0; attempt < 2; attempt++) {
      sessions.checkpoint(session);
      final rejected = session.credential.primary;
      final url = query(
        source == null
            ? '${WeiyunConnector.web}/api/v3/ftn_pre_upload'
            : 'https://upload.weiyun.com/ftnup_v2/weiyun',
        {
          'g_tk': (_cookies(session)['wyctoken'] ?? '').ifEmpty(
            session.field('weiyunCsrf'),
          ),
          'cmd': cmd,
        },
      );
      final response = await http.request(
        'POST',
        url,
        headers: _headers(session),
        followRedirects: false,
        contentType: 'application/json',
        body: source == null
            ? jsonEncode(payload)
            : HttpUpload(
                open: () => source.openRead(start, start + length),
                length: length,
                fields: {'json': jsonEncode(payload)},
                fieldName: 'upload',
                fileName: 'blob',
                onProgress: (sent, total) => onProgress?.call(
                  UploadProgress(
                    UploadPhase.uploading,
                    completed + (total > 0 ? length * sent ~/ total : 0),
                    source.size,
                  ),
                ),
              ),
      );
      sessions.checkpoint(session);
      if ({401, 403}.contains(response.status)) {
        if (attempt == 0) {
          await _refresh(session, rejected: rejected);
          continue;
        }
        throw const AccountLoginRequired('微云登录已失效，请重新网页登录');
      }
      await _absorb(session, response);
      final raw = response.json;
      final result = _response(
        raw.containsKey('rsp_header')
            ? HttpResult(response.status, jsonEncode({'ret': 0, 'data': raw}))
            : response,
        name,
      );
      return source == null && result['weiyunPreUploadMsgRsp_body'] is Map
          ? result.obj('weiyunPreUploadMsgRsp_body')
          : result;
    }
    throw const AccountLoginRequired('微云登录已失效，请重新网页登录');
  }

  Future<CloudFile> _upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c,
    UploadProgressCallback? onProgress,
  ) async {
    final session = await _owner(s, c), io = UploadIO(http, source, onProgress);
    final directory = await _directory(session, parent);
    final hashes = await WeiyunHash.plan(source, onProgress);
    final pre = await _uploadCall(session, 'PreUpload', 247120, {
      'common_upload_req': {
        'ppdir_key': directory.str('pdir_key'),
        'pdir_key': parent,
        'file_size': source.size,
        'filename': source.name,
        'file_exist_option': 2,
        'use_mutil_channel': true,
      },
      'upload_scr': 0,
      'channel_count': 1,
      ...hashes,
    });
    final id = pre.obj('common_upload_rsp').str('file_id');
    if (!pre.boolean('file_exist')) {
      final uploadKey = pre.str('upload_key');
      var ex = pre.str('ex'), completed = pre.integer('uploaded_data_len');
      require(uploadKey.isNotEmpty, '微云未签发上传授权');
      final channels = pre.list('channel_list');
      require(
        channels.isNotEmpty || pre.integer('upload_state') == 2,
        '微云未返回上传通道',
      );
      final ranges = <(int, int)>[];
      var finished = pre.integer('upload_state') == 2;
      for (final initial in channels) {
        var channel = initial;
        for (var attempt = 0; attempt < 100000; attempt++) {
          final start = channel.integer('offset', -1),
              partSize = channel.integer('len', -1);
          require(
            start >= 0 && start < source.size && partSize > 0,
            '微云上传分段范围无效或重复',
          );
          // Later replies can omit len and retain the previous block size.
          // Both the final body's length and its channel metadata must match
          // the remaining file bytes.
          final length = partSize.clamp(1, source.size - start);
          require(
            !ranges.any((r) => start < r.$2 && start + length > r.$1),
            '微云上传分段范围无效或重复',
          );
          final result = await _uploadCall(
            session,
            'UploadPiece',
            247121,
            {
              'upload_key': uploadKey,
              'ex': ex,
              'channel': {...channel, 'len': length},
            },
            source: source,
            start: start,
            length: length,
            completed: completed,
            onProgress: onProgress,
          );
          completed += length;
          ranges.add((start, start + length));
          ex = result.str('ex').ifEmpty(ex);
          final state = result.integer('upload_state');
          require({1, 2, 3}.contains(state), '微云返回的上传状态无效');
          if (state == 2) {
            finished = true;
            break;
          }
          if (state == 3) break;
          channel = result.obj('channel');
          if (channel.integer('len') == 0) channel['len'] = length;
        }
        if (finished) break;
      }
      require(finished, '微云尚未确认全部分段上传完成，请刷新列表确认');
    }
    return io.confirm(() => list(s, parent, c), id: id);
  }
}
