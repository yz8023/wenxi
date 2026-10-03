import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'core/json.dart';
import 'diagnostics/app_log.dart';
import 'data/backup.dart';
import 'data/cleanup_outbox.dart';
import 'data/cloud_repository.dart';
import 'data/cloud_favorites.dart';
import 'data/http.dart';
import 'data/remote_control_http.dart';
import 'data/remote_control_service.dart';
import 'data/github_update_service.dart';
import 'data/providers/uc.dart';
import 'data/providers/quark.dart';
import 'data/providers/pan123.dart';
import 'data/providers/tianyi.dart';
import 'data/providers/xunlei.dart';
import 'data/providers/guangya.dart';
import 'data/providers/aliyun.dart';
import 'data/legacy_import.dart';
import 'data/state_store.dart';
import 'domain/auth.dart';
import 'domain/models.dart';
import 'domain/settings.dart';
import 'download/download_manager.dart';
import 'download/download_shutdown.dart';
import 'download/download_overlay.dart';
import 'download/transfer_http.dart';
import 'platform/file_access.dart';
import 'platform/clipboard_links.dart';
import 'platform/external_open.dart';
import 'platform/native_engine.dart';
import 'platform/windows_actions.dart';
import 'data/providers/ilanzou.dart';
import 'data/providers/weiyun.dart';
import 'data/providers/wopan.dart';
import 'data/providers/pan115.dart';

class AppServices extends ChangeNotifier {
  AppServices({
    required this.store,
    required this.dataDirectory,
    required this.cacheDirectory,
    required NativeTransport transport,
    required this.files,
    JsonHttp? http,
    TransferHttp? transferHttp,
    this.platformFeatures = true,
    this.clock = DateTime.now,
    Future<String?> Function()? clipboardReader,
    String controlUrl = RemoteControlService.buildUrl,
    bool controlEnabled = RemoteControlService.buildEnabled,
    RemoteControlFetcher? controlFetcher,
    GitHubUpdateService? githubUpdates,
    WindowsActions? windowsActions,
    RandomAccessFile? instanceLock,
  }) : _instanceLock = instanceLock {
    vault = Vault(store);
    control = RemoteControlService(
      store,
      platform: Platform.operatingSystem,
      currentBuild: int.parse(applicationVersion.split('+').last),
      configUrl: controlUrl,
      enabled: controlEnabled,
      fetcher: controlFetcher,
      currentVersion: applicationVersion,
      githubUpdates:
          githubUpdates ??
          (platformFeatures && controlEnabled
              ? GitHubUpdateService(
                  platform: Platform.operatingSystem,
                  clock: clock,
                )
              : null),
      clock: clock,
    );
    _enabledClouds.addAll(CloudPlatform.values.where(control.cloudEnabled));
    clipboard = ClipboardLinks(
      store,
      read: clipboardReader ?? (platformFeatures ? null : () async => null),
    );
    cleanups = CleanupOutbox(store, http ?? DioJsonHttp());
    cloud = CloudRepository(
      cleanups.http,
      vault,
      cleanups,
      checkAccess: control.checkCloud,
      preparationRetries: () => settings.retries,
    );
    login = AccountLoginService(
      vault,
      (p, c) => cloud.connector(p).account(c),
      checkAccess: control.checkCloud,
      webAuthenticators: {
        CloudPlatform.pan115:
            (cloud.connector(CloudPlatform.pan115) as Pan115Connector)
                .authenticate,
        CloudPlatform.xunlei:
            (cloud.connector(CloudPlatform.xunlei) as XunleiConnector)
                .authenticate,
        CloudPlatform.ilanzou:
            (cloud.connector(CloudPlatform.ilanzou) as ILanzouConnector)
                .authenticate,
        CloudPlatform.weiyun:
            (cloud.connector(CloudPlatform.weiyun) as WeiyunConnector)
                .authenticate,
        CloudPlatform.wopan:
            (cloud.connector(CloudPlatform.wopan) as WopanConnector)
                .authenticate,
        CloudPlatform.guangya:
            (cloud.connector(CloudPlatform.guangya) as GuangyaConnector)
                .authenticate,
        CloudPlatform.aliyun:
            (cloud.connector(CloudPlatform.aliyun) as AliyunConnector)
                .authenticate,
        CloudPlatform.pan123:
            (cloud.connector(CloudPlatform.pan123) as Pan123Connector)
                .authenticate,
        CloudPlatform.quark:
            (cloud.connector(CloudPlatform.quark) as QuarkConnector)
                .authenticate,
        CloudPlatform.uc:
            (cloud.connector(CloudPlatform.uc) as UcConnector).authenticate,
        CloudPlatform.tianyi:
            (cloud.connector(CloudPlatform.tianyi) as TianyiConnector)
                .authenticate,
      },
    );
    favorites = CloudFavorites(store, cloud);
    backup = BackupRepository(store);
    engine = GopeedEngine(
      transport,
      store,
      vault,
      Directory(p.join(dataDirectory.path, 'gopeed')),
      cacheDirectory,
    );
    transfer = transferHttp ?? TransferHttp();
    downloads = DownloadManager(
      store: store,
      engine: engine,
      files: files,
      cleanups: cleanups,
      http: transfer,
      refreshSource: cloud.refresh,
      checkNewCloudTask: control.checkCloud,
      foreground: platformFeatures && (Platform.isAndroid || Platform.isWindows)
          ? (activity) async {
              try {
                await nativeChannel.invokeMethod<void>(
                  'foreground',
                  activity.toJson(),
                );
              } on PlatformException catch (e) {
                throw AppException(e.message ?? '后台下载服务启动失败');
              }
            }
          : null,
    );
    windows =
        windowsActions ??
        WindowsActions(supported: platformFeatures && Platform.isWindows);
    downloadShutdown = DownloadShutdown(
      supported: windows.supported,
      changes: downloads,
      tasks: () => downloads.tasks,
      busy: () => downloads.activeCount > 0,
      shutdown: windows.shutdown,
      flush: store.flush,
    );
    downloadOverlay = DownloadOverlay(
      supported: platformFeatures && Platform.isAndroid,
      changes: Listenable.merge([downloads, store]),
      tasks: () => downloads.tasks,
      pause: downloads.pause,
      resume: downloads.resume,
      pauseAll: downloads.pauseAll,
      resumeAll: downloads.resumeAll,
      openDownloads: requestDownloadManager,
      dark: () =>
          settings.theme == 'Dark' ||
          settings.theme == 'System' &&
              PlatformDispatcher.instance.platformBrightness == Brightness.dark,
    );
    control.addListener(_controlChanged);
  }
  final StateStore store;
  final Directory dataDirectory, cacheDirectory;
  final FileAccess files;
  final bool platformFeatures;
  final DateTime Function() clock;
  final RandomAccessFile? _instanceLock;
  late final Vault vault;
  late final RemoteControlService control;
  final _enabledClouds = <CloudPlatform>{};
  late final ClipboardLinks clipboard;
  late final CleanupOutbox cleanups;
  late final CloudRepository cloud;
  late final CloudFavorites favorites;
  late final AccountLoginService login;
  late final BackupRepository backup;
  late final GopeedEngine engine;
  late final DownloadManager downloads;
  late final WindowsActions windows;
  late final DownloadShutdown downloadShutdown;
  late final DownloadOverlay downloadOverlay;
  late final TransferHttp transfer;
  final accounts = <CloudPlatform, CloudAccount>{},
      accountErrors = <CloudPlatform, String>{};
  final accountLoading = <CloudPlatform>{},
      _revisions = <CloudPlatform, (String?, int?)>{};
  final accountNeedsLogin = <CloudPlatform>{};
  final sharedText = ValueNotifier<String?>(null);
  final downloadNavigation = ValueNotifier<int>(0);

  void requestDownloadManager() {
    if (!_closed) downloadNavigation.value++;
  }

  final externalOpens = ExternalOpenInbox();
  String? migrationError;
  bool _closed = false;
  WebViewEnvironment? _webEnvironment;
  Future<WebViewEnvironment?>? _webStarting;
  AppSettings get settings => AppSettings.fromJson(store.data.obj('settings'));

  static Future<AppServices> open() async {
    Directory data, cache, destination;
    NativeTransport transport;
    if (Platform.isAndroid) {
      final paths = asJson(await nativeChannel.invokeMethod<Object?>('paths'));
      require(
        paths.str('data').isNotEmpty && paths.str('cache').isNotEmpty,
        '无法读取应用存储路径',
      );
      data = Directory(paths.str('data'));
      cache = Directory(paths.str('cache'));
      destination = cache;
      transport = AndroidGopeedTransport();
    } else {
      require(Platform.isWindows, '当前版本支持 Android 和 Windows');
      data = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'AsterLink'),
      );
      cache = Directory(p.join(data.path, 'downloads'));
      destination = Directory(
        p.join(
          (await getDownloadsDirectory() ??
                  await getApplicationDocumentsDirectory())
              .path,
          'AsterLink',
        ),
      );
      transport = DesktopGopeedTransport(
        executable: p.join(
          p.dirname(Platform.resolvedExecutable),
          'asterlink_gopeed.exe',
        ),
      );
    }
    await data.create(recursive: true);
    await cache.create(recursive: true);
    final lock = await File(
      p.join(data.path, 'instance.lock'),
    ).open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } on FileSystemException {
      await lock.close();
      throw const AppException('文析助手已在运行，请打开已有窗口');
    }
    try {
      final store = await StateStore.open(data);
      final result = AppServices(
        store: store,
        dataDirectory: data,
        cacheDirectory: cache,
        transport: transport,
        files: PlatformFileAccess(transport, destination),
        instanceLock: lock,
      );
      await result.initialize();
      return result;
    } catch (error, stack) {
      DiagnosticLog.error('app.initialize_failed', error, stack);
      await lock.close();
      rethrow;
    }
  }

  Future<void> initialize() async {
    if (platformFeatures && Platform.isAndroid) {
      await importLegacy();
      nativeChannel.setMethodCallHandler((call) async {
        if (call.method == 'downloadOverlayState') {
          downloadOverlay.stateChanged(asJson(call.arguments));
        }
        if (call.method == 'downloadOverlayAction') {
          await downloadOverlay.action(asJson(call.arguments));
        }
        if (call.method == 'exportProgress' && files is PlatformFileAccess) {
          (files as PlatformFileAccess).exportProgress(asJson(call.arguments));
        }
        if (call.method == 'sharedText') {
          sharedText.value = call.arguments as String?;
        }
        if (call.method == 'externalOpenAvailable') {
          await externalOpens.refresh();
        }
        if (call.method == 'pauseAll' ||
            call.method == 'serviceTimeout' ||
            call.method == 'downloadServiceStalled') {
          await downloads.pauseAll(
            reason: switch (call.method) {
              'serviceTimeout' => '系统已暂停长时间后台下载，返回应用后可继续',
              'downloadServiceStalled' => '后台下载状态已中断，请返回应用继续',
              _ => '',
            },
          );
        }
        if (call.method == 'downloadServiceRestarted') {
          await downloads.recoverInterrupted();
        }
        if (call.method == 'downloadDiscardRecovery') {
          await downloads.discardInterrupted();
        }
      });
      await externalOpens.refresh();
    }
    await vault.initializeAccounts();
    await downloads.initialize();
    if (platformFeatures && Platform.isAndroid) {
      final recoveryExpected = await nativeChannel.invokeMethod<bool>(
        'downloadsReady',
      );
      if (recoveryExpected != true) await downloads.discardInterrupted();
    }
    store.addListener(_changed);
    _changed();
  }

  Future<void> importLegacy() async {
    if (store.data.boolean('legacyImported')) return;
    try {
      final raw = await nativeChannel.invokeMethod<String>('legacySnapshot');
      require(raw != null, '无法读取旧版数据');
      await LegacyImporter(store).import(asJson(jsonDecode(raw!)));
      migrationError = null;
    } catch (error, stack) {
      DiagnosticLog.error('app.legacy_import_failed', error, stack);
      migrationError = '旧版数据未能导入，原数据已保留。可在“我的”中重试导入。';
    }
  }

  Future<void> retryLegacyImport() async {
    await downloads.importPausedQueue(importLegacy);
    notifyListeners();
  }

  void _changed() {
    for (final platform in CloudPlatform.values) {
      final credential = vault.credential(platform),
          revision = (vault.activeAccountId(platform), credential?.updatedAt);
      if (_revisions.containsKey(platform) &&
          _revisions[platform] == revision) {
        if ({
              CloudPlatform.pan123,
              CloudPlatform.tianyi,
              CloudPlatform.xunlei,
            }.contains(platform) &&
            credential?.field('autoLoginBlocked') == '1') {
          accounts.remove(platform);
          accountNeedsLogin.add(platform);
          accountErrors[platform] = switch (platform) {
            CloudPlatform.pan123 => Pan123Connector.autoLoginFailureMessage,
            CloudPlatform.xunlei => XunleiConnector.autoLoginFailureMessage,
            _ => TianyiConnector.autoLoginFailureMessage,
          };
        }
        continue;
      }
      _revisions[platform] = revision;
      accounts.remove(platform);
      accountErrors.remove(platform);
      accountNeedsLogin.remove(platform);
      if (LoginCredentials.stored(platform, credential)) {
        unawaited(refreshAccount(platform));
      }
    }
    notifyListeners();
  }

  Future<void> refreshAccount(CloudPlatform platform) async {
    final owner = vault.activeAccountId(platform);
    final credential = vault.credential(platform);
    if (!control.cloudEnabled(platform) ||
        !LoginCredentials.stored(platform, credential) ||
        !accountLoading.add(platform)) {
      return;
    }
    notifyListeners();
    try {
      final account = await vault.withAccount(
        platform,
        owner,
        () => cloud.connector(platform).account(credential!),
      );
      if (vault.activeAccountId(platform) == owner &&
          vault.credential(platform)?.updatedAt == credential!.updatedAt) {
        if (owner != null) {
          await vault.updateAccountNickname(
            platform,
            owner,
            credential.updatedAt,
            account.nickname,
          );
        }
        if (vault.activeAccountId(platform) != owner ||
            vault.credential(platform)?.updatedAt != credential.updatedAt) {
          return;
        }
        accounts[platform] = account;
        accountErrors.remove(platform);
        accountNeedsLogin.remove(platform);
      }
    } catch (e, stack) {
      DiagnosticLog.error(
        'cloud.account_failed',
        e,
        stack,
        fields: {'platform': platform.key},
      );
      if (vault.activeAccountId(platform) == owner &&
          vault.credential(platform)?.updatedAt == credential?.updatedAt) {
        if (e is AccountLoginRequired) {
          accounts.remove(platform);
          accountNeedsLogin.add(platform);
          accountErrors[platform] = e.message;
        } else {
          accountNeedsLogin.remove(platform);
          accountErrors[platform] = '容量读取失败，点击重试';
        }
      }
    } finally {
      accountLoading.remove(platform);
      if (!_closed) {
        notifyListeners();
        if (vault.activeAccountId(platform) != owner ||
            vault.credential(platform)?.updatedAt != credential?.updatedAt) {
          unawaited(refreshAccount(platform));
        }
      }
    }
  }

  Future<void> refreshAccounts() async =>
      Future.wait(CloudPlatform.values.map(refreshAccount));

  Future<void> switchCloudAccount(CloudPlatform platform, String id) async {
    login.invalidate(platform);
    if (platform == CloudPlatform.uc) {
      (cloud.connector(platform) as UcConnector).tv.cancelAuthorization();
    }
    await vault.activate(platform, id);
  }

  Future<void> removeCloudAccount(CloudPlatform platform, String id) async {
    login.invalidate(platform);
    if (platform == CloudPlatform.uc) {
      (cloud.connector(platform) as UcConnector).tv.cancelAuthorization();
    }
    await vault.removeAccount(platform, id);
  }

  void _controlChanged() {
    if (_closed) return;
    for (final platform in CloudPlatform.values) {
      if (control.cloudEnabled(platform)) {
        if (_enabledClouds.add(platform)) unawaited(refreshAccount(platform));
      } else if (_enabledClouds.remove(platform)) {
        login.invalidate(platform);
        if (platform == CloudPlatform.uc) {
          final connector = cloud.connector(platform);
          if (connector is UcConnector) connector.tv.cancelAuthorization();
        }
      }
    }
    notifyListeners();
  }

  Future<void> updateSettings(Json changes) async {
    await store.put('settings', settings.update(changes).toJson());
    await downloads.settingsChanged();
  }

  Future<void> copyText(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    await clipboard.acknowledgeText(value);
  }

  Future<void> remember(
    ParsedLink link, {
    String? title,
    int? itemCount,
    bool Function()? canCommit,
  }) => store.change((draft) {
    if (canCommit?.call() == false) return;
    final existing = draft.list('history');
    draft['history'] = [
      {
        'id': link.id,
        'platform': link.platform?.key,
        'sourceText': link.source,
        'normalizedUrl': link.url,
        'fileName': title,
        'link': link.toJson(),
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'status': 'parsed',
        'itemCount': itemCount,
      },
      ...existing.where((e) => e.str('normalizedUrl') != link.url).take(299),
    ];
  });
  Future<WebViewEnvironment?> webEnvironment() async {
    if (!Platform.isWindows) return null;
    if (_webEnvironment != null) return _webEnvironment;
    return _webStarting ??= (() async {
      try {
        require(
          (await WebViewEnvironment.getAvailableVersion())?.isNotEmpty == true,
          '未找到 Microsoft Edge WebView2 Runtime，请安装后重新打开应用，或使用手动登录',
        );
        _webEnvironment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: p.join(dataDirectory.path, 'webview'),
          ),
        );
        return _webEnvironment;
      } catch (_) {
        _webStarting = null;
        rethrow;
      }
    })();
  }

  Json diagnostics() => {
    'application': '文析助手',
    'version': applicationVersion,
    'engine': 'Gopeed 1.8.1',
    'os': Platform.operatingSystem,
    'date': DateTime.now().toUtc().toIso8601String(),
    'legacyImported': store.data.boolean('legacyImported'),
    'settings': settings.toJson()..remove('destination'),
    'remoteControl': control.diagnostics(),
    'accounts': {
      for (final platform in CloudPlatform.values)
        platform.key: LoginCredentials.stored(
          platform,
          vault.credential(platform),
        ),
    },
    'taskCount': downloads.tasks.length,
    'tasksTruncated': downloads.tasks.length > 100,
    'tasks': [
      for (final task in downloads.tasks.take(100))
        {
          'status': task.status.name,
          'total': task.total,
          'downloaded': task.downloaded,
          'connections': task.connections,
          'hasSource': task.spec.source != null,
          'hasExport': task.savedPath != null,
          'hasError': task.error.isNotEmpty,
        },
    ],
    'pendingCleanups': cleanups.pendingCount,
    'pendingDownloadRemovals':
        (store.data['downloadRemovals'] as List? ?? []).length,
  };
  Future<void> close() async {
    if (_closed) return;
    downloadShutdown.close();
    await downloadOverlay.close();
    control.removeListener(_controlChanged);
    control.close();
    await control.flushCache();
    await downloads.close();
    cleanups.progress.close();
    _closed = true;
    clipboard.dispose();
    externalOpens.dispose();
    downloadNavigation.dispose();
    store.removeListener(_changed);
    await _webEnvironment?.dispose();
    await _instanceLock?.close();
  }
}
