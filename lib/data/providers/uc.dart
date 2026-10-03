import '../http.dart';
import '../state_store.dart';
import '../../domain/models.dart';
import '../../domain/auth.dart';
import '../../domain/file_types.dart';
import '../../diagnostics/app_log.dart';
import 'cookie_cloud.dart';
import 'uc_tv.dart';

class UcConnector extends CookieCloudConnector {
  UcConnector(
    JsonHttp http, {
    CredentialStore? store,
    Duration taskDelay = const Duration(milliseconds: 750),
    int Function()? now,
    Future<void> Function(DownloadCleanup)? stageCleanup,
  }) : tv = UcTvService(http, store: store, now: now),
       super(
         CloudPlatform.uc,
         http,
         store: store,
         taskDelay: taskDelay,
         now: now,
         stageCleanup: stageCleanup,
         webUserAgent: webUa,
         apiUserAgent: cloudUa,
       );

  final UcTvService tv;

  @override
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    Credential? authorized;
    var authorization = credential?.field('tv_status') == 'expired'
        ? 'expired'
        : 'not_configured';
    if (!file.isDirectory && UcTvService.authorized(credential)) {
      try {
        authorized = await tv.ensureAuthorized(credential!);
        authorization = 'available';
      } on UcTvAuthorizationRequired {
        RequestScope.checkpoint();
        authorization = 'refresh_rejected';
        // An expired optional grant must not prevent usable web downloads.
      }
    }
    DiagnosticLog.event(
      'uc.download_route',
      fields: {
        'platform': 'uc',
        'file': DiagnosticLog.reference(file.id),
        'route': authorized != null ? 'authorized_original' : 'web',
        'authorization': authorization,
      },
    );
    if (authorized != null) {
      final current = authorized;
      return prepareStream(
        session,
        file,
        current,
        (fid) => tv.download(current, fid, file),
        forPlayback: false,
      );
    }
    try {
      return await super.download(session, file, credential);
    } on UcOriginalContentMismatch catch (error) {
      throw UcTvAuthorizationRequired(
        '${error.message}。请点击「授权并继续」，或在 UC 账号菜单完成「TV 播放授权」后重试',
      );
    }
  }

  @override
  Future<DownloadSpec> playback(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    if (fileKind(file.name) != FileKind.video) {
      return super.playback(session, file, credential);
    }
    if (credential == null) {
      throw const AccountLoginRequired('请先完成 UC 网页登录，再授权 TV 播放');
    }
    // Check the grant before creating a temporary share-transfer directory.
    final current = await tv.ensureAuthorized(credential);
    return prepareStream(
      session,
      file,
      current,
      (fid) => tv.playback(current, fid, file.name),
    );
  }

  static const webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const cloudUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.6.1 Chrome/100.0.4896.160 Electron/18.3.5.16-b62cf9c50d Safari/537.36 Channel/ucpan_other_ch';
}
