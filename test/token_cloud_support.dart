import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

const tokenClock = 1790200000000;
const accessToken = 'fixture-access-token-0123456789';
const refreshToken = 'fixture-refresh-token-0123456789';
const renewedAccess = 'renewed-access-token-0123456789';
const renewedRefresh = 'renewed-refresh-token-0123456789';

Credential tokenCredential(
  CloudPlatform p, {
  int revision = 42,
  bool expired = false,
  Map<String, String> fields = const {},
}) => Credential(p.label, {
  'primary': p == CloudPlatform.aliyun ? refreshToken : accessToken,
  'accessToken': accessToken,
  'refreshToken': refreshToken,
  'authType': 'webToken',
  'userId': 'user-1',
  'deviceId': 'device-1',
  'nickname': '测试账号',
  'expiresAt': '${tokenClock + (expired ? -1000 : 3600000)}',
  if (p == CloudPlatform.guangya) 'deviceSign': 'wdi10.${'1' * 32}${'2' * 32}',
  if (p == CloudPlatform.aliyun) ...{
    'defaultDriveId': 'backup',
    'backupDriveId': 'backup',
    'resourceDriveId': 'resource',
    'devicePrivateKey': '1'.padLeft(64, '0'),
    'signature': 'fixture-signature',
    'sessionExpiresAt': '${tokenClock + 1800000}',
  },
  ...fields,
}, updatedAt: revision);

Future<Vault> tokenVault(
  CloudPlatform platform, [
  Credential? credential,
]) async {
  final vault = Vault(StateStore.memory());
  await vault.putCredential(platform, credential ?? tokenCredential(platform));
  return vault;
}

BrowseSession tokenPersonal(
  CloudPlatform platform, {
  String drive = 'resource',
}) => BrowseSession(
  platform: platform,
  mode: BrowseMode.personal,
  title: '测试文件',
  rootId: 'root',
  metadata: {
    if (platform == CloudPlatform.aliyun) 'driveId': drive,
    if (platform == CloudPlatform.aliyun)
      'driveName': drive == 'backup' ? '备份盘' : '资源库',
  },
);

BrowseSession tokenShare(CloudPlatform platform) {
  final link = ParsedLink(
    source: 'fixture',
    url: platform == CloudPlatform.aliyun
        ? 'https://www.alipan.com/s/Share123'
        : 'https://www.guangyapan.com/s/Share123',
    kind: LinkKind.cloudShare,
    platform: platform,
    shareId: 'Share123',
    passcode: 'a123',
  );
  return BrowseSession(
    platform: platform,
    mode: BrowseMode.share,
    title: '测试分享',
    rootId: 'root',
    metadata: {'shareId': 'Share123', 'passcode': 'a123'},
    sourceLink: link,
  );
}

const tokenFile = CloudFile(
  id: 'file-1',
  name: 'movie.mp4',
  size: 4,
  parentId: 'root',
);

HttpResult guangyaResponse(Json data, {int code = 0, String message = ''}) =>
    jsonResponse({'code': code, 'msg': message, 'data': data});

HttpResult guangyaAssetsResponse() => jsonResponse({
  'msg': 'success',
  'data': {'totalSpaceSize': 2199023255552, 'usedSpaceSize': 564090134},
});

HttpResult aliDefaultResponse(RecordedRequest request) {
  switch (request.uri.path) {
    case '/v2/user/get':
      return jsonResponse({
        'user_id': 'user-1',
        'nick_name': '阿里测试账号',
        'default_drive_id': 'backup',
        'backup_drive_id': 'backup',
        'resource_drive_id': 'resource',
      });
    case '/v2/databox/get_personal_info':
      return jsonResponse({
        'personal_space_info': {'used_size': 200, 'total_size': 1000},
      });
    case '/users/v1/users/device/create_session':
      return jsonResponse({'result': true});
    case '/v2/account/token':
      return jsonResponse({
        'access_token': renewedAccess,
        'refresh_token': renewedRefresh,
        'expires_in': 7200,
        'user_id': 'user-1',
        'default_drive_id': 'backup',
        'resource_drive_id': 'resource',
        'backup_drive_id': 'backup',
      });
    case '/v2/share_link/get_share_token':
      return jsonResponse({'share_token': 'fixture-share-token'});
    case '/adrive/v3/share_link/get_share_by_anonymous':
      return jsonResponse({'share_name': '旅行影像', 'creator_id': 'owner'});
    default:
      throw StateError('Unexpected Aliyun endpoint ${request.uri.path}');
  }
}

Json aliFile(
  String id, {
  String name = 'movie.mp4',
  String parent = 'root',
  bool folder = false,
}) => {
  'file_id': id,
  'name': name,
  'parent_file_id': parent,
  'size': folder ? 0 : 4,
  'type': folder ? 'folder' : 'file',
};
