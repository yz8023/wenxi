import 'dart:async';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/uc.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'native_login_support.dart';
import 'support.dart';

const ucTvNow = 1789770000000;
const ucTvDevice = '0123456789abcdef0123456789abcdef';
const ucTvVideo = CloudFile(
  id: 'video-1',
  name: '视频.mp4',
  size: 400,
  parentId: '0',
  token: 'share-file-token',
);
const ucTvPersonal = BrowseSession(
  platform: CloudPlatform.uc,
  mode: BrowseMode.personal,
  title: 'UC',
  rootId: '0',
);
final ucTvShare = BrowseSession(
  platform: CloudPlatform.uc,
  mode: BrowseMode.share,
  title: '分享',
  rootId: '0',
  metadata: const {'shareId': 'share-id', 'stoken': 'share-token'},
  sourceLink: ParsedLink(
    source: 'https://drive.uc.cn/s/share-id',
    url: 'https://drive.uc.cn/s/share-id',
    kind: LinkKind.cloudShare,
    platform: CloudPlatform.uc,
    shareId: 'share-id',
  ),
);
Credential ucTvCredential({
  bool authorized = true,
  int expiresAt = ucTvNow + 3600000,
  int revision = 7,
}) => Credential('UC', {
  'primary': '__pus=web-owner; __puus=web-session',
  'nickname': 'UC 测试账号',
  'ucSessionRefreshedAt': '$ucTvNow',
  if (authorized) ...{
    'tv_device_id': ucTvDevice,
    'tv_access_token': 'tv-access-private',
    'tv_refresh_token': 'tv-refresh-private',
    'tv_access_token_expires_at': '$expiresAt',
    'tv_grant_id': 'grant-original',
    'tv_status': 'authorized',
  },
}, updatedAt: revision);
HttpResult ucTvOk(Json data) => jsonResponse({'status': 0, ...data});
HttpResult ucTvError(int code, {int http = 400}) =>
    jsonResponse({'status': -1, 'errno': code}, http);
HttpResult ucTvToken({
  String access = 'new-tv-access',
  String refresh = 'new-tv-refresh',
}) => jsonResponse({
  'code': 200,
  'data': {
    'status': 0,
    'errno': 0,
    'access_token': access,
    'refresh_token': refresh,
    'expires_in': 3600,
  },
});
HttpResult ucTvStream({String fid = 'video-1'}) => ucTvOk({
  'data': {
    'fid': fid,
    'default_resolution': 'normal',
    'video_info': [
      {
        'resolution': 'normal',
        'accessable': 1,
        'size': 22,
        'url': 'https://media.example/normal.mp4',
      },
      {
        'resolution': 'super',
        'accessable': 1,
        'size': 123,
        'url': 'https://media.example/video.mp4?sign=a%2Bb%2Fc&n=1',
      },
      {
        'resolution': '4k',
        'accessable': 0,
        'size': 256,
        'url': 'https://media.example/forbidden.mp4',
      },
    ],
  },
});

HttpResult ucTvOriginal({String fid = 'video-1', int size = 400}) => ucTvOk({
  'data': {
    'fid': fid,
    'file_name': 'original',
    'size': size,
    'download_url': 'https://media.example/original.mp4',
  },
});

class UcTvRecordingHttp extends FakeHttp {
  UcTvRecordingHttp(super.respond);
  final redirectPolicies = <bool>[];
  final contentTypes = <String?>[];
  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) {
    redirectPolicies.add(followRedirects);
    contentTypes.add(contentType);
    return super.request(
      method,
      url,
      body: body,
      headers: headers,
      followRedirects: followRedirects,
      contentType: contentType,
    );
  }
}

class UcTvFixture {
  UcTvFixture({Credential? credential}) {
    store = StateStore.memory({
      'credentials': {
        CloudPlatform.uc.key: (credential ?? ucTvCredential()).toJson(),
      },
    });
    vault = Vault(store);
    http = UcTvRecordingHttp(
      (request) => respond?.call(request) ?? normal(request),
    );
    cleanups = CleanupOutbox(store, http);
    repository = CloudRepository(http, vault, cleanups);
    connector = UcConnector(
      http,
      store: vault,
      now: () => now,
      taskDelay: Duration.zero,
      stageCleanup: (cleanup) async {
        staged.add(cleanup);
        await cleanups.stage(cleanup);
      },
    );
    repository.connectors[CloudPlatform.uc] = connector;
  }
  int now = ucTvNow;
  bool scanned = false;
  FutureOr<HttpResult>? Function(RecordedRequest)? respond;
  late final StateStore store;
  late final Vault vault;
  late final UcTvRecordingHttp http;
  late final CleanupOutbox cleanups;
  late final CloudRepository repository;
  late final UcConnector connector;
  final staged = <DownloadCleanup>[];
  Credential get credential => vault.credential(CloudPlatform.uc)!;
  List<RecordedRequest> calls(String path) =>
      http.calls.where((r) => r.uri.path == path).toList();
  HttpResult normal(RecordedRequest r) {
    if (r.uri.host == 'open-api-drive.uc.cn') {
      switch (r.uri.path) {
        case '/oauth/authorize':
          return ucTvOk({
            'query_token': 'qr-poll-private',
            'qr_data': loginTestPng(24, 24),
          });
        case '/oauth/code':
          return scanned
              ? ucTvOk({'code': 'one-time-private-code'})
              : ucTvError(11003);
        case '/user':
          return ucTvOk({
            'data': {'nickname': 'UC TV 测试账号'},
          });
        case '/file':
          if (r.uri.queryParameters['method'] == 'download') {
            return ucTvOriginal(fid: r.uri.queryParameters['fid'] ?? 'video-1');
          }
          return ucTvStream(fid: r.uri.queryParameters['fid'] ?? 'video-1');
      }
    }
    if (r.uri.host == 'api.extscreen.com') return ucTvToken();
    if (r.uri.host == 'media.example' && r.uri.path == '/original.mp4') {
      return const HttpResult(206, 'xx', {
        'content-range': ['bytes 0-1/400'],
        'content-length': ['2'],
      });
    }
    Json data = {};
    switch (r.uri.path) {
      case '/1/clouddrive/file/sort':
        data = {
          'list': [
            {'fid': 'base', 'file_name': '文析助手临时转存', 'dir': true},
            {
              'fid': ucTvVideo.id,
              'file_name': ucTvVideo.name,
              'size': ucTvVideo.size,
              'pdir_fid': '0',
            },
          ],
        };
      case '/1/clouddrive/file':
        data = {'fid': 'temporary'};
      case '/1/clouddrive/share/sharepage/save':
        data = {'task_id': 'save-task'};
      case '/1/clouddrive/task':
        data = {
          'status': 2,
          'save_as': {
            'save_as_top_fids': ['saved-video'],
          },
        };
      case '/1/clouddrive/file/download':
        return jsonResponse({
          'status': 200,
          'code': 0,
          'data': [
            {
              'fid': r.json['fids'][0],
              'file_name': ucTvVideo.name,
              'size': 400,
              'download_url': 'https://media.example/original.mp4',
            },
          ],
        });
      case '/1/clouddrive/member':
        data = {
          'nickname': 'UC 测试账号',
          'use_capacity': 25,
          'total_capacity': 100,
        };
    }
    return jsonResponse({'status': 200, 'code': 0, 'data': data});
  }
}
