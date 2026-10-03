import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../data/providers/uc.dart';
import '../data/providers/uc_tv.dart';
import '../domain/auth.dart';
import '../domain/downloads.dart';
import '../domain/models.dart';
import 'common.dart';

Future<bool> openUcTvAuthorization(
  BuildContext context,
  AppServices services, {
  String? accountId,
  bool forDownload = false,
}) async {
  if (!allowCloudAction(context, services.control, CloudPlatform.uc)) {
    return false;
  }
  return await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => UcTvAuthorizationPage(
            services,
            accountId:
                accountId ?? services.vault.activeAccountId(CloudPlatform.uc),
            forDownload: forDownload,
          ),
        ),
      ) ??
      false;
}

Future<void> authorizeUcDownload(
  BuildContext context,
  AppServices services,
  String id,
) async {
  final task = services.downloads.task(id);
  if (task == null || !task.needsUcAuthorization) return;
  require(task.spec.source != null, '下载来源已缺失，请重新添加任务');
  final origin = DownloadOrigin.fromJson(task.spec.source!);
  require(
    origin.session.platform == CloudPlatform.uc && origin.file.id.isNotEmpty,
    '下载来源无效，请从网盘文件列表重新添加任务',
  );
  final revision = origin.accountRevision;
  final accountId =
      origin.session.accountId ??
      (revision == null
          ? null
          : services.vault.accountForRevision(CloudPlatform.uc, revision));
  final owner = services.vault.credentialFor(CloudPlatform.uc, accountId);
  require(
    accountId != null &&
        owner != null &&
        revision != null &&
        owner.updatedAt == revision,
    '原下载账号已退出或重新登录，请从网盘文件列表重新添加任务',
  );
  final tv = (services.cloud.connector(CloudPlatform.uc) as UcConnector).tv;
  var ready = false;
  if (UcTvService.authorized(owner)) {
    try {
      await services.vault.withAccount(
        CloudPlatform.uc,
        accountId,
        () => tv.ensureAuthorized(owner!),
      );
      ready = true;
    } on UcTvAuthorizationRequired {
      // Show a new QR only when the saved grant cannot be renewed.
    }
  }
  if (!context.mounted) return;
  if (!ready &&
      !await openUcTvAuthorization(
        context,
        services,
        accountId: accountId,
        forDownload: true,
      )) {
    return;
  }
  if (!context.mounted) return;
  final currentTask = services.downloads.task(id);
  if (currentTask == null || !currentTask.needsUcAuthorization) return;
  final currentOrigin = DownloadOrigin.fromJson(currentTask.spec.source!);
  final currentOwner = services.vault.credentialFor(
    CloudPlatform.uc,
    accountId,
  );
  require(
    currentOrigin.accountRevision == revision &&
        currentOrigin.session.accountId == origin.session.accountId &&
        currentOrigin.file.id == origin.file.id &&
        currentOwner?.updatedAt == revision &&
        UcTvService.authorized(currentOwner),
    '下载任务或账号已变化，请重新打开任务',
  );
  await services.downloads.resume(id);
}

class UcTvAuthorizationPage extends StatefulWidget {
  const UcTvAuthorizationPage(
    this.services, {
    super.key,
    this.accountId,
    this.forDownload = false,
  });
  final AppServices services;
  final String? accountId;
  final bool forDownload;
  @override
  State<UcTvAuthorizationPage> createState() => _UcTvAuthorizationPageState();
}

class _UcTvAuthorizationPageState extends State<UcTvAuthorizationPage>
    with WidgetsBindingObserver {
  late final tv =
      (widget.services.cloud.connector(CloudPlatform.uc) as UcConnector).tv;
  late final String? _accountId =
      widget.accountId ??
      widget.services.vault.activeAccountId(CloudPlatform.uc);
  Credential? get account =>
      widget.services.vault.credentialFor(CloudPlatform.uc, _accountId);
  T _withAccount<T>(T Function() action) =>
      widget.services.vault.withAccount(CloudPlatform.uc, _accountId, action);
  UcTvAuthorization? _authorization;
  RequestScope? _scope;
  Timer? _pollTimer, _clock;
  int _epoch = 0;
  int? _ownerRevision;
  bool _loading = false, _polling = false, _visible = true, _completed = false;
  String _error = '';
  int get remaining => _authorization == null
      ? 0
      : ((_authorization!.qr.expiresAt - tv.protocol.now()) / 1000)
            .ceil()
            .clamp(0, 600);

  @override
  void initState() {
    super.initState();
    _ownerRevision = account?.updatedAt;
    WidgetsBinding.instance.addObserver(this);
    widget.services.store.addListener(_accountChanged);
    widget.services.control.addListener(_controlChanged);
    if (!UcTvService.authorized(account)) unawaited(_start());
  }

  void _cancel() {
    _epoch++;
    _pollTimer?.cancel();
    _clock?.cancel();
    _scope?.cancel();
    tv.cancelAuthorization();
  }

  void _controlChanged() {
    if (!mounted || widget.services.control.cloudEnabled(CloudPlatform.uc)) {
      return;
    }
    _cancel();
    setState(() {
      _authorization = null;
      _loading = false;
      _error = widget.services.control.config
          .cloud(CloudPlatform.uc)
          .reason(CloudPlatform.uc);
    });
  }

  void _accountChanged() {
    if (!mounted) return;
    if (account?.updatedAt != _ownerRevision) {
      _cancel();
      setState(() {
        _authorization = null;
        _loading = false;
        _error = 'UC 网页账号已变化，请为当前账号重新获取二维码';
      });
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.services.store.removeListener(_accountChanged);
    widget.services.control.removeListener(_controlChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    _pollTimer?.cancel();
    if (_visible && _completed) {
      _finish();
    } else if (_visible && _authorization != null && _error.isEmpty) {
      unawaited(_poll());
    }
  }

  Future<void> _start() async {
    _cancel();
    final epoch = _epoch, scope = _scope = RequestScope();
    _ownerRevision = account?.updatedAt;
    setState(() {
      _loading = true;
      _authorization = null;
      _error = '';
      _completed = false;
      _polling = false;
    });
    try {
      widget.services.control.checkCloud(CloudPlatform.uc);
      final authorization = await _withAccount(
        () => scope.run(tv.beginAuthorization),
      );
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _authorization = authorization;
        _loading = false;
      });
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || epoch != _epoch || _completed) return;
        if (remaining == 0) {
          _cancel();
          setState(() => _error = '二维码已超时，请重新获取');
        } else if (_visible) {
          setState(() {});
        }
      });
      _schedule();
    } catch (error) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _loading = false;
        _error = errorText(error);
      });
    }
  }

  void _schedule() {
    _pollTimer?.cancel();
    if (_visible && mounted && !_completed && _error.isEmpty) {
      _pollTimer = Timer(const Duration(seconds: 2), () => unawaited(_poll()));
    }
  }

  Future<void> _poll() async {
    final authorization = _authorization, scope = _scope;
    if (!mounted ||
        !_visible ||
        _polling ||
        _completed ||
        authorization == null ||
        scope == null) {
      return;
    }
    final epoch = _epoch;
    _polling = true;
    try {
      widget.services.control.checkCloud(CloudPlatform.uc);
      final done = await _withAccount(
        () => scope.run(() => tv.pollAuthorization(authorization)),
      );
      if (!mounted || epoch != _epoch) return;
      if (done) {
        _completed = true;
        _clock?.cancel();
        _pollTimer?.cancel();
        if (_visible) _finish();
      } else {
        _schedule();
      }
    } catch (error) {
      if (!mounted || epoch != _epoch) return;
      _pollTimer?.cancel();
      _clock?.cancel();
      setState(() => _error = errorText(error));
    } finally {
      if (epoch == _epoch) _polling = false;
    }
  }

  void _finish() {
    if (!mounted) return;
    if (Navigator.canPop(context)) {
      Navigator.pop(context, true);
    } else {
      setState(() => _authorization = null);
    }
  }

  Future<void> _remove() async {
    _cancel();
    try {
      await _withAccount(tv.removeAuthorization);
      if (mounted) {
        setState(() {
          _authorization = null;
          _completed = false;
          _error = '';
        });
        message(context, '已解除 TV 播放授权');
      }
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final granted = UcTvService.authorized(account);
    final qr = _authorization?.qr;
    final showQr = qr != null && _error.isEmpty && !_completed;
    final nickname = account?.field('nickname') ?? '';
    return PopScope<bool>(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _cancel();
      },
      child: PageFrame(
        title: widget.forDownload ? 'UC 下载授权' : 'UC TV 播放授权',
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const PlatformMark(platform: CloudPlatform.uc, size: 42),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              nickname.isEmpty ? '当前 UC 网页账号' : nickname,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              UcTvService.status(account),
                              style: TextStyle(
                                color: secondary(context),
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text(
                    showQr || _loading
                        ? '使用 UC 网盘 App 扫码'
                        : granted
                        ? widget.forDownload
                              ? '原文件下载授权已就绪'
                              : 'TV 播放已就绪'
                        : widget.forDownload
                        ? '为原下载账号扫码授权'
                        : '为当前账号授权 TV 播放',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '请使用与网页登录相同的 UC 账号扫码并确认。授权后支持原文件下载和在线播放；播放时自动选择最高可用画质，授权到期后自动续期。',
                    textAlign: TextAlign.center,
                    style: TextStyle(height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '扫码由 UC 提供，TV 播放凭据由 Extscreen 服务换取和续期。网页登录 Cookie 仅发送至 UC。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: secondary(context),
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(72),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (showQr) ...[
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: border(context)),
                        ),
                        child: Image.memory(
                          qr.image,
                          width: 230,
                          height: 230,
                          semanticLabel: 'UC TV 授权二维码',
                          gaplessPlayback: false,
                          errorBuilder: (_, _, _) => const SizedBox(
                            width: 230,
                            height: 230,
                            child: Center(
                              child: Text(
                                '二维码显示失败，请重新获取',
                                style: TextStyle(color: Colors.black),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '等待扫码确认 · ${remaining}s',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: secondary(context)),
                    ),
                  ] else if (_error.isNotEmpty)
                    Text(
                      _error,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        height: 1.5,
                      ),
                    )
                  else if (granted)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 28),
                      child: Icon(
                        CupertinoIcons.checkmark_circle_fill,
                        size: 60,
                        color: brandBlue,
                      ),
                    ),
                  const SizedBox(height: 24),
                  if (!_loading)
                    FilledButton.icon(
                      onPressed: account == null ? null : _start,
                      icon: const Icon(
                        CupertinoIcons.qrcode_viewfinder,
                        size: 20,
                      ),
                      label: Text(
                        showQr || _error.isNotEmpty
                            ? '重新获取二维码'
                            : granted
                            ? '重新扫码授权'
                            : '获取授权二维码',
                      ),
                    ),
                  if (granted && !_loading)
                    TextButton(
                      onPressed: _remove,
                      child: const Text('解除 TV 播放授权'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
