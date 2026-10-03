import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../data/providers/baidu.dart';
import '../data/providers/pan123.dart';
import '../data/providers/uc_tv.dart';
import '../data/providers/xunlei.dart';
import '../data/providers/xunlei_login.dart';
import '../data/providers/xunlei_protocol.dart';
import '../domain/auth.dart';
import '../domain/aliyun_web_password.dart';
import '../domain/models.dart';
import '../domain/weiyun_web_login.dart';
import '../domain/tianyi_web_login.dart';
import '../diagnostics/web_login_diagnostics.dart';
import 'common.dart';
import 'native_password_login_page.dart';
import 'guangya_sms_login_page.dart';
import 'login_webview.dart';
import 'uc_tv_authorization_page.dart';
import 'cloud_accounts_page.dart';
export 'native_password_login_page.dart';
export 'login_webview.dart' show webSettings, desktopLoginViewportScript;

Future<void> openLogin(
  BuildContext context,
  AppServices services,
  CloudPlatform platform, {
  bool addAccount = false,
  String? accountId,
}) async {
  if (!allowCloudAction(context, services.control, platform)) return;
  if (!platform.requiresAccount) {
    message(context, '支持不登录解析');
    return;
  }
  if (platform == CloudPlatform.baidu) {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('百度网盘使用提醒'),
        content: const Text('当前百度网盘风控较严格，暂时不推荐使用。\n\n仍需使用时，可以继续前往网页登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续网页登录'),
          ),
        ],
      ),
    );
    if (proceed != true || !context.mounted) return;
  }
  if (!allowCloudAction(context, services.control, platform)) return;
  final created =
      addAccount ||
      (accountId == null && services.vault.activeAccountId(platform) == null);
  final owner = created
      ? await services.vault.createAccount(platform)
      : accountId ?? services.vault.activeAccountId(platform);
  if (!context.mounted) {
    if (created && owner != null) {
      await services.vault.removeAccount(platform, owner, onlyIfEmpty: true);
    }
    return;
  }
  try {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => switch (platform) {
          CloudPlatform.xunlei ||
          CloudPlatform.pan123 ||
          CloudPlatform.tianyi ||
          CloudPlatform.aliyun ||
          CloudPlatform.ilanzou ||
          CloudPlatform.guangya => PasswordLoginFlow(
            services,
            platform,
            accountId: owner,
          ),
          _ => WebLoginPage(
            services,
            WebLoginTarget.targets[platform]!,
            accountId: owner,
          ),
        },
      ),
    );
  } finally {
    if (created && owner != null) {
      await services.vault.removeAccount(platform, owner, onlyIfEmpty: true);
    }
  }
}

// Keep both methods in one route so callers await the final login, including
// when the user switches methods while a previous request is still finishing.
class PasswordLoginFlow extends StatefulWidget {
  const PasswordLoginFlow(
    this.services,
    this.platform, {
    super.key,
    this.accountId,
  });
  final AppServices services;
  final CloudPlatform platform;
  final String? accountId;
  @override
  State<PasswordLoginFlow> createState() => _PasswordLoginFlowState();
}

enum _LoginMethod { password, sms, web, manual }

class _PasswordLoginFlowState extends State<PasswordLoginFlow> {
  late _LoginMethod _method = _defaultMethod;
  _LoginMethod get _defaultMethod => widget.platform == CloudPlatform.guangya
      ? _LoginMethod.sms
      : _LoginMethod.password;
  AliyunWebPassword? _webPassword;

  void _switch(_LoginMethod method) {
    _webPassword?.clear();
    setState(() {
      _webPassword = null;
      _method = method;
    });
  }

  @override
  void dispose() {
    _webPassword?.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (_method) {
    _LoginMethod.sms => GuangyaSmsLoginPage(
      widget.services,
      accountId: widget.accountId,
      onUsePassword: () => _switch(_LoginMethod.password),
      onUseWeb: () => _switch(_LoginMethod.web),
      onUseManual: () => _switch(_LoginMethod.manual),
    ),
    _LoginMethod.web => WebLoginPage(
      widget.services,
      WebLoginTarget.targets[widget.platform]!,
      accountId: widget.accountId,
      passwordLogin: _webPassword,
      onUsePassword: () => _switch(_defaultMethod),
      nativeLoginLabel: widget.platform == CloudPlatform.guangya
          ? '切换短信验证码登录'
          : '切换账号密码登录',
    ),
    _LoginMethod.manual => ManualLoginPage(
      widget.services,
      widget.platform,
      accountId: widget.accountId,
      onUsePassword: () => _switch(_defaultMethod),
      nativeLoginLabel: widget.platform == CloudPlatform.guangya
          ? '切换短信验证码登录'
          : '切换账号密码登录',
    ),
    _LoginMethod.password when widget.platform == CloudPlatform.xunlei =>
      XunleiLoginPage(
        widget.services,
        accountId: widget.accountId,
        onUseWeb: () => _switch(_LoginMethod.web),
      ),
    _LoginMethod.password => NativePasswordLoginPage(
      widget.services,
      widget.platform,
      accountId: widget.accountId,
      onUseWeb: () => _switch(_LoginMethod.web),
      onUseManual: () => _switch(_LoginMethod.manual),
      onUseSms: widget.platform == CloudPlatform.guangya
          ? () => _switch(_LoginMethod.sms)
          : null,
      onSubmitWebPassword: widget.platform == CloudPlatform.aliyun
          ? (username, password) {
              _webPassword?.clear();
              setState(() {
                _webPassword = AliyunWebPassword(username, password);
                _method = _LoginMethod.web;
              });
            }
          : null,
    ),
  };
}

Future<void> accountMenu(
  BuildContext context,
  AppServices services,
  CloudPlatform platform,
) async {
  if (!platform.requiresAccount) {
    message(context, '支持不登录解析');
    return;
  }
  final stored = LoginCredentials.stored(
    platform,
    services.vault.credential(platform),
  );
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: PlatformMark(platform: platform, size: 32),
              title: Text(platform.label),
            ),
            ListTile(
              leading: const Icon(CupertinoIcons.arrow_clockwise),
              title: const Text('刷新账号容量'),
              onTap: () => Navigator.pop(context, 'refresh'),
            ),
            ListTile(
              leading: const Icon(CupertinoIcons.person_crop_circle),
              title: Text(stored ? '重新登录当前账号' : '登录账号'),
              onTap: () => Navigator.pop(context, 'login'),
            ),
            ListTile(
              leading: const Icon(CupertinoIcons.person_2),
              title: const Text('多账号管理'),
              subtitle: Text(
                '已保存 ${services.vault.profiles(platform).length} 个账号',
              ),
              onTap: () => Navigator.pop(context, 'accounts'),
            ),
            ListTile(
              leading: const Icon(CupertinoIcons.doc_on_clipboard),
              title: const Text('手动填写登录信息'),
              onTap: () => Navigator.pop(context, 'manual'),
            ),
            if (platform == CloudPlatform.uc && stored)
              ListTile(
                leading: const Icon(CupertinoIcons.tv),
                title: const Text('TV 播放授权'),
                subtitle: Text(
                  UcTvService.status(services.vault.credential(platform)),
                ),
                onTap: () => Navigator.pop(context, 'ucTv'),
              ),
            if (stored)
              ListTile(
                leading: const Icon(
                  CupertinoIcons.square_arrow_right,
                  color: Colors.red,
                ),
                title: const Text('退出账号', style: TextStyle(color: Colors.red)),
                onTap: () => Navigator.pop(context, 'logout'),
              ),
          ],
        ),
      ),
    ),
  );
  if (!context.mounted) return;
  if (action != null &&
      action != 'logout' &&
      !allowCloudAction(context, services.control, platform)) {
    return;
  }
  switch (action) {
    case 'accounts':
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => CloudAccountsPage(services, platform: platform),
        ),
      );
    case 'refresh':
      await services.refreshAccount(platform);
    case 'login':
      await openLogin(context, services, platform);
    case 'manual':
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => ManualLoginPage(services, platform)),
      );
    case 'ucTv':
      if (await openUcTvAuthorization(context, services) && context.mounted) {
        message(context, 'UC TV 播放授权已完成');
      }
    case 'logout':
      if (await confirm(
            context,
            '退出${platform.shortName}账号',
            '已添加的下载仍保留；需要刷新地址的任务需重新登录后添加。',
          ) &&
          context.mounted) {
        await busy(context, () => services.login.remove(platform));
      }
  }
}

class WebLoginPage extends StatefulWidget {
  const WebLoginPage(
    this.services,
    this.target, {
    this.onUsePassword,
    this.nativeLoginLabel = '切换账号密码登录',
    this.passwordLogin,
    this.accountId,
    super.key,
  });
  final AppServices services;
  final WebLoginTarget target;
  final String? accountId;
  final VoidCallback? onUsePassword;
  final String nativeLoginLabel;
  final AliyunWebPassword? passwordLogin;
  @override
  State<WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginWindow {
  _WebLoginWindow(this.id);
  final int id;
  InAppWebViewController? controller;
}

class _WebLoginPageState extends State<WebLoginPage>
    with WidgetsBindingObserver {
  WebViewEnvironment? environment;
  InAppWebViewController? controller;
  InAppWebViewController? checkingWeb;
  CookieManager? cookies;
  Timer? timer;
  final clock = Stopwatch()..start(), policy = LoginPollingPolicy();
  final _storageSession = newId();
  final _windows = <_WebLoginWindow>[];
  String _weiyunCaptureState = '';
  String _tianyiBrowserId = '', _tianyiCaptureState = '';
  bool ready = false,
      completed = false,
      leaving = false,
      manualOpen = false,
      visible = true,
      passwordDocumentReady = false,
      passwordUnavailable = false,
      passwordSent = false,
      passwordFallback = false;
  double progress = 0;
  String status = '完成网页登录后将自动保存登录信息', error = '';
  bool get active => mounted && !leaving && !completed;
  bool get checking => checkingWeb != null;
  late final diagnostics = WebLoginDiagnostics(widget.target.platform);
  // Creation and event callbacks can wrap the same native controller twice.
  bool _sameWeb(InAppWebViewController? left, InAppWebViewController? right) =>
      left != null && right != null && identical(left.platform, right.platform);
  bool _current(InAppWebViewController web) =>
      active &&
      ready &&
      (_sameWeb(controller, web) ||
          _windows.any((window) => _sameWeb(window.controller, web)));

  Future<void> _forgetBrowserCookies({bool logFailure = true}) async {
    final manager = cookies;
    if (manager == null) return;
    try {
      await manager.deleteAllCookies();
    } catch (error, stack) {
      if (!logFailure) return;
      diagnostics.record(
        'cookie_cleanup_failed',
        level: 'warning',
        stage: 'cleanup',
        error: error,
        stack: stack,
      );
    }
  }

  void _cancel() {
    if (leaving || completed) return;
    leaving = true;
    widget.passwordLogin?.clear();
    timer?.cancel();
    widget.services.login.invalidate(widget.target.platform);
    unawaited(_forgetBrowserCookies(logFailure: false));
  }

  void _switchToPassword() {
    if (!active || widget.onUsePassword == null) return;
    _cancel();
    widget.onUsePassword!();
  }

  @override
  void initState() {
    super.initState();
    if (widget.passwordLogin != null) status = '正在打开官方密码登录，出现安全验证时请按网页提示完成';
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    visible = state == AppLifecycleState.resumed;
    if (visible) unawaited(_poll());
  }

  Future<void> _initialize() async {
    timer?.cancel();
    diagnostics.record('initialize_started', stage: 'initialize');
    try {
      widget.services.control.checkCloud(widget.target.platform);
      environment = await widget.services.webEnvironment();
      if (!active) return;
      widget.services.control.checkCloud(widget.target.platform);
      cookies = CookieManager.instance(webViewEnvironment: environment);
      // SSO cookies may live on authentication hosts that are not part of the
      // provider API domain list. Clear the whole browser jar before rendering
      // so adding an account can never silently reuse the previous login.
      await cookies!.deleteAllCookies();
      if (!active) return;
      _tianyiBrowserId = '';
      _tianyiCaptureState = '';
      setState(() => ready = true);
      timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    } catch (e, stack) {
      if (active) {
        diagnostics.record(
          'initialize_failed',
          level: 'error',
          stage: 'initialize',
          error: e,
          stack: stack,
        );
        setState(
          () => error = e is AppException ? e.message : '网页登录组件初始化失败，可使用手动登录',
        );
      }
    }
  }

  Future<String> _readCredentials(InAppWebViewController web) async {
    final target = widget.target;
    final readCookies =
        target.localStorageKey == null ||
        target.platform == CloudPlatform.ilanzou ||
        target.platform == CloudPlatform.wopan;
    String? page;
    try {
      page = (await web.getUrl().timeout(
        const Duration(seconds: 3),
      ))?.toString();
    } catch (_) {
      if (!readCookies) rethrow;
    }
    Object? storage;
    if (target.localStorageKey != null && target.canReadLocalStorage(page)) {
      final preparation = await web
          .evaluateJavascript(
            source: target.prepareStorageScript(_storageSession),
          )
          .timeout(const Duration(seconds: 5));
      if (!_current(web) || manualOpen) return '';
      if (preparation == 'cleared') {
        // Fallback for older WebViews without document-start injection. Reset
        // the page's in-memory state once, before accepting this new session.
        await web.reload();
        return '';
      }
      if (preparation != 'ready') {
        throw const AppException('网页登录存储尚未就绪，请稍候再检测或刷新网页');
      }
      if (_sameWeb(web, controller)) await _submitWebPassword(web);
      if (!_current(web) || manualOpen) return '';
      if (widget.passwordLogin != null && !passwordSent && !passwordFallback) {
        return '';
      }
      storage = await web
          .evaluateJavascript(source: target.readStorageScript)
          .timeout(const Duration(seconds: 5));
      if (!target.canReadLocalStorage(
        (await web.getUrl().timeout(const Duration(seconds: 3)))?.toString(),
      )) {
        return '';
      }
    }
    if (target.platform == CloudPlatform.tianyi) {
      if (TianyiWebLogin.trusted(page)) {
        try {
          await web
              .evaluateJavascript(source: TianyiWebLogin.bootstrapScript)
              .timeout(const Duration(seconds: 3));
          final captured = TianyiWebLogin.decode(
            await web
                .evaluateJavascript(source: TianyiWebLogin.readScript)
                .timeout(const Duration(seconds: 3)),
          );
          final id = TianyiWebLogin.browserId(captured['browserId']);
          if (id.isNotEmpty) {
            final currentPage = (await web.getUrl().timeout(
              const Duration(seconds: 3),
            ))?.toString();
            if (_current(web) &&
                !manualOpen &&
                TianyiWebLogin.trusted(currentPage)) {
              _tianyiBrowserId = id;
            }
          }
        } catch (_) {
          // A redirect can replace the page after the login iframe was read.
        }
      }
      storage = {'browserId': _tianyiBrowserId};
    }
    if (target.platform == CloudPlatform.weiyun &&
        WeiyunWebLogin.trusted(page)) {
      try {
        await web
            .evaluateJavascript(source: WeiyunWebLogin.bootstrapScript)
            .timeout(const Duration(seconds: 3));
        storage = await web
            .evaluateJavascript(source: WeiyunWebLogin.readScript)
            .timeout(const Duration(seconds: 3));
        if (!WeiyunWebLogin.trusted(
          (await web.getUrl().timeout(const Duration(seconds: 3)))?.toString(),
        )) {
          storage = null;
        }
      } catch (_) {
        // Navigation can replace the document. Native cookies are still read.
        storage = null;
      }
    }
    if (!_current(web) || manualOpen) return '';
    final stored = LoginCredentials.fromBrowser(
      target.platform,
      storage: storage,
    );
    if (stored.isNotEmpty && target.platform != CloudPlatform.weiyun) {
      return stored;
    }
    final values = <String>[];
    if (readCookies) {
      Object? readError;
      var successfulReads = 0;
      for (final url in target.cookieUrls(page)) {
        try {
          final pairs = await cookies!
              .getCookies(url: WebUri(url), webViewController: web)
              .timeout(const Duration(seconds: 3));
          successfulReads++;
          values.add(pairs.map((c) => '${c.name}=${c.value}').join('; '));
        } catch (e) {
          readError = e;
        }
        if (!_current(web) || manualOpen) return '';
      }
      if (successfulReads == 0 && readError != null && stored.isEmpty) {
        throw const AppException('网页登录信息读取失败，请稍候再检测或刷新网页');
      }
    }
    if (target.platform == CloudPlatform.tianyi) {
      final native = LoginCredentials.cookiePairs(
        LoginCredentials.mergeCookies(values),
      );
      final fields = <String, Object?>{
        'nativeEntryCount': native.length,
        'hasBrowserBinding': _tianyiBrowserId.isNotEmpty,
        'hasPersistentSession': native.containsKey('COOKIE_LOGIN_USER'),
        'hasPortalSession': native.containsKey('LOGIN_USER'),
      };
      final state = jsonEncode(fields);
      if (state != _tianyiCaptureState) {
        _tianyiCaptureState = state;
        diagnostics.record(
          'capture_state',
          stage: 'read_credentials',
          fields: fields,
        );
      }
    }
    if (target.platform == CloudPlatform.weiyun) {
      final captured = WeiyunWebLogin.decode(storage);
      final native = LoginCredentials.cookiePairs(
        LoginCredentials.mergeCookies(values),
      );
      final fields = <String, Object?>{
        'nativeEntryCount': native.length,
        'pageEntryCount': LoginCredentials.cookiePairs(
          captured.str('cookie'),
        ).length,
        'hasRequestIdentity': WeiyunWebLogin.tokenInfo(
          captured['tokenInfo'],
        ).isNotEmpty,
        'hasRequestCsrf': WeiyunWebLogin.csrf(captured['csrf']).isNotEmpty,
        'hasQqOpenId': native.containsKey('weiyun_qq_openid'),
        'hasLegacyQqKey': native.containsKey('p_skey'),
      };
      final state = jsonEncode(fields);
      if (state != _weiyunCaptureState) {
        _weiyunCaptureState = state;
        diagnostics.record(
          'capture_state',
          stage: 'read_credentials',
          fields: fields,
        );
      }
    }
    return LoginCredentials.fromBrowser(
      target.platform,
      storage: storage,
      cookies: values,
    );
  }

  Future<void> _poll({bool userInitiated = false}) async {
    if (!active ||
        !visible ||
        manualOpen ||
        !ready ||
        completed ||
        checking ||
        controller == null) {
      return;
    }
    var web = controller!;
    checkingWeb = web;
    var candidate = '';
    var stage = 'read_credentials';
    try {
      if (userInitiated) setState(() => status = '正在检测登录信息…');
      final target = widget.target;
      final browsers = [
        for (final window in _windows.reversed)
          if (window.controller != null) window.controller!,
        controller!,
      ];
      Object? readError;
      StackTrace? readStack;
      for (final browser in browsers) {
        if (!_current(browser) || manualOpen) continue;
        web = browser;
        checkingWeb = web;
        try {
          candidate = await _readCredentials(web);
        } catch (e, stack) {
          readError = e;
          readStack = stack;
          candidate = '';
        }
        if (candidate.isNotEmpty && _current(web)) break;
      }
      if (!_current(web) || manualOpen) return;
      if (candidate.isEmpty && readError != null) {
        Error.throwWithStackTrace(readError, readStack!);
      }
      if (!LoginCredentials.plausible(target.platform, candidate)) {
        if (userInitiated) {
          diagnostics.record('credentials_pending', stage: 'read_credentials');
          setState(
            () => status = switch (target.platform) {
              CloudPlatform.weiyun => '暂未读取到完整凭据，请刷新网页中的文件列表后再检测',
              CloudPlatform.tianyi => '天翼登录尚未完成，请在网页完成验证码或安全验证后再检测',
              _ => '尚未读取到完整登录信息，请进入网盘首页后再检测',
            },
          );
        }
        return;
      }
      if (target.platform == CloudPlatform.c139 &&
          !LoginCredentials.c139WebReady(candidate)) {
        setState(() => status = '正在等待云盘完成登录，请在网页进入网盘首页…');
        return;
      }
      if (!userInitiated &&
          !policy.canAttempt(candidate, clock.elapsedMilliseconds)) {
        return;
      }
      stage = 'validation';
      policy.started(clock.elapsedMilliseconds);
      diagnostics.record('validation_started', stage: 'validation');
      if (mounted) setState(() => status = '正在验证登录信息…');
      await widget.services.login.submitWeb(
        target.platform,
        candidate,
        accountId: widget.accountId,
        rememberedLogin: passwordSent
            ? widget.passwordLogin?.rememberedLogin ?? const {}
            : const {},
      );
      // Closing an SSO popup does not cancel its parent login. The account
      // service has already checked cancellation and account ownership.
      if (!active || !ready || manualOpen) return;
      diagnostics.record('validation_succeeded', stage: 'validation');
      await _forgetBrowserCookies();
      if (!active || !ready || manualOpen) return;
      completed = true;
      widget.passwordLogin?.clear();
      timer?.cancel();
      if (mounted && !leaving && !manualOpen) {
        message(context, '${target.platform.shortName}登录成功');
        Navigator.pop(context);
      }
    } catch (e, stack) {
      if ((stage == 'validation' ? active && ready : _current(web)) &&
          !manualOpen) {
        policy.failed(candidate, clock.elapsedMilliseconds);
        diagnostics.record(
          stage == 'validation'
              ? 'validation_failed'
              : 'credential_read_failed',
          level: 'warning',
          stage: stage,
          error: e,
          stack: stack,
        );
        setState(() => status = errorText(e));
      }
    } finally {
      if (_sameWeb(checkingWeb, web)) {
        checkingWeb = null;
        if (active) setState(() {});
      }
    }
  }

  Future<void> _submitWebPassword(InAppWebViewController web) async {
    final attempt = widget.passwordLogin;
    if (attempt == null ||
        passwordUnavailable ||
        passwordFallback ||
        !passwordDocumentReady ||
        !_current(web) ||
        manualOpen) {
      return;
    }
    void unavailable() {
      attempt.clear();
      passwordUnavailable = true;
      passwordSent = false;
      if (_current(web) && !manualOpen) {
        setState(() => status = '自动填入未完成，可在网页继续登录，或返回账号密码页面重试');
      }
    }

    if (attempt.pending && attempt.expired) {
      unavailable();
      return;
    }
    try {
      if (!widget.target.canReadLocalStorage(
        (await web.getUrl())?.toString(),
      )) {
        return;
      }
      final state = await web.evaluateJavascript(source: attempt.statusScript);
      if (!_current(web) || manualOpen) return;
      if (state == 'ready' && attempt.pending) {
        final script = attempt.takeSubmissionScript();
        if (script == null) {
          unavailable();
          return;
        }
        final result = await web.evaluateJavascript(source: script);
        if (!_current(web) || manualOpen) return;
        if (result != 'sent') {
          unavailable();
          return;
        }
        passwordSent = true;
        setState(() => status = '已填入账号密码，请按官方页面提示完成登录或安全验证');
      } else if (state == 'unavailable') {
        unavailable();
      }
    } catch (_) {
      // A navigating frame can disappear between readiness and submission.
      // A consumed password is never automatically replayed into a new page.
      if (!attempt.pending) unavailable();
    }
  }

  void _continueWebLogin() {
    if (!active) return;
    widget.passwordLogin?.clear();
    widget.services.login.invalidate(widget.target.platform);
    setState(() {
      passwordFallback = true;
      status = '完成网页登录后将自动保存登录信息';
    });
  }

  Future<void> _loaded(InAppWebViewController web, WebUri? uri) async {
    if (!_current(web)) return;
    diagnostics.pageLoaded();
    try {
      if (widget.target.desktopMode) {
        await web.evaluateJavascript(source: desktopLoginViewportScript);
      }
      if (widget.target.platform == CloudPlatform.tianyi && _current(web)) {
        await web.evaluateJavascript(source: TianyiWebLogin.mobileFormScript);
      }
      final attempt = widget.passwordLogin;
      if (attempt != null && _current(web)) {
        await web.evaluateJavascript(source: attempt.bootstrapScript);
      }
    } catch (_) {
      // A navigation can replace the document; cookie detection can still run.
    }
    if (!_current(web)) return;
    if (_sameWeb(web, controller)) passwordDocumentReady = true;
    await _poll();
  }

  void _rendererGone(
    InAppWebViewController web,
    RenderProcessGoneDetail detail,
  ) {
    if (!_current(web)) return;
    diagnostics.rendererGone(
      didCrash: detail.didCrash,
      priority: detail.rendererPriorityAtExit?.toNativeValue(),
    );
    final popup = _windows
        .where((window) => _sameWeb(window.controller, web))
        .firstOrNull;
    if (popup != null) {
      _closeWindow(popup.id);
      setState(() => status = '授权页面已关闭，请在登录页重新打开');
      return;
    }
    timer?.cancel();
    widget.services.login.invalidate(widget.target.platform);
    // A dead Android renderer cannot be reused. Removing the platform view
    // lets the explicit retry create a fresh one instead of reloading it.
    controller = null;
    checkingWeb = null;
    _windows.clear();
    setState(() {
      ready = false;
      error = '登录页面已停止运行，请重试或切换登录方式';
    });
  }

  void _closeWindow(int id) {
    if (!active) return;
    final index = _windows.indexWhere((window) => window.id == id);
    if (index < 0) return;
    setState(() => _windows.removeRange(index, _windows.length));
    unawaited(_poll());
  }

  Widget _webView({_WebLoginWindow? popup}) => InAppWebView(
    key: ValueKey(popup?.id ?? 'main-login-window'),
    webViewEnvironment: environment,
    windowId: popup?.id,
    initialUrlRequest: popup == null
        ? URLRequest(url: WebUri(widget.target.url))
        : null,
    initialSettings:
        webSettings(
            userAgent: widget.target.userAgent,
            desktopMode: widget.target.desktopMode,
            isPopup: popup != null,
          )
          ..useOnRenderProcessGone = true
          ..supportMultipleWindows = true
          ..javaScriptCanOpenWindowsAutomatically = true,
    initialUserScripts: UnmodifiableListView([
      if (widget.target.desktopMode) desktopLoginUserScript(),
      if (widget.target.platform == CloudPlatform.tianyi)
        UserScript(
          source: TianyiWebLogin.mobileFormScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
          allowedOriginRules: const {'https://open.e.189.cn'},
        ),
      if (widget.target.platform == CloudPlatform.tianyi)
        UserScript(
          source: TianyiWebLogin.bootstrapScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
          allowedOriginRules: TianyiWebLogin.origins,
        ),
      if (widget.target.platform == CloudPlatform.weiyun)
        UserScript(
          source: WeiyunWebLogin.bootstrapScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
          allowedOriginRules: WeiyunWebLogin.origins,
        ),
      if (widget.target.localStorageKey != null)
        UserScript(
          source: widget.target.prepareStorageScript(_storageSession),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
          allowedOriginRules: widget.target.storageOriginRules,
        ),
      if (widget.passwordLogin != null && popup == null)
        UserScript(
          source: widget.passwordLogin!.bootstrapScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
          allowedOriginRules: AliyunWebPassword.origins,
        ),
    ]),
    onWebViewCreated: (web) {
      if (!active || !ready) return;
      if (popup == null) {
        controller = web;
      } else if (_windows.contains(popup)) {
        popup.controller = web;
      }
    },
    onCreateWindow: (web, action) async {
      if (!_current(web) || _windows.length >= 3) return false;
      final url = action.request.url;
      if (url != null && !{'http', 'https', 'about'}.contains(url.scheme)) {
        return false;
      }
      setState(() => _windows.add(_WebLoginWindow(action.windowId)));
      diagnostics.record('authorization_window_opened');
      return true;
    },
    onCloseWindow: (web) {
      if (popup != null) _closeWindow(popup.id);
    },
    onLoadStart: (web, _) {
      if (_current(web)) {
        if (_sameWeb(web, controller)) passwordDocumentReady = false;
        diagnostics.pageStarted();
      }
    },
    onLoadStop: _loaded,
    onUpdateVisitedHistory: (web, _, _) {
      if (_current(web)) unawaited(_poll());
    },
    onProgressChanged: (web, value) {
      if (_current(web)) setState(() => progress = value / 100);
    },
    onReceivedError: (web, request, error) {
      if (!_current(web)) return;
      diagnostics.resourceFailed(
        isMainFrame: request.isForMainFrame,
        type: error.type.toValue(),
        code: error.type.toNativeValue(),
      );
      if (request.isForMainFrame == true && active) {
        setState(() => status = '网页加载失败，可刷新后重试');
      }
    },
    onReceivedHttpError: (web, request, response) {
      if (!_current(web)) return;
      diagnostics.httpFailed(
        isMainFrame: request.isForMainFrame,
        status: response.statusCode,
      );
      if (request.isForMainFrame == true) {
        setState(() => status = '登录页面暂时不可用，可刷新后重试');
      }
    },
    onRenderProcessGone: _rendererGone,
    shouldOverrideUrlLoading: (web, action) async {
      final url = action.request.url;
      if (_current(web) &&
          widget.target.platform == CloudPlatform.tianyi &&
          action.isForMainFrame &&
          TianyiWebLogin.isCompletionLanding(url?.toString())) {
        // The official mobile SSO callback has already stored its HttpOnly
        // cookies. Its home/redirect document would send this mobile UA to a
        // client promotion page. Validate the native jar before that hop.
        diagnostics.record('completion_redirect', stage: 'read_credentials');
        unawaited(_poll(userInitiated: true));
        return NavigationActionPolicy.CANCEL;
      }
      return active &&
              url != null &&
              {'http', 'https', 'about'}.contains(url.scheme)
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL;
    },
  );

  Future<void> _refresh() async {
    if (!active) return;
    if (error.isNotEmpty) {
      setState(() {
        error = '';
        ready = false;
        progress = 0;
        status = '完成网页登录后将自动保存登录信息';
      });
      await _initialize();
      return;
    }
    try {
      final web = _windows.isEmpty ? controller : _windows.last.controller;
      if (widget.target.platform == CloudPlatform.tianyi) {
        await web?.loadUrl(
          urlRequest: URLRequest(url: WebUri(widget.target.url)),
        );
      } else {
        await web?.reload();
      }
    } catch (e, stack) {
      if (active) {
        diagnostics.record(
          'page_script_failed',
          level: 'warning',
          stage: 'reload',
          error: e,
          stack: stack,
        );
        setState(() => status = '网页刷新失败，请返回后重新打开登录页面');
      }
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _cancel();
    diagnostics.close(completed: completed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _windows.isEmpty,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) {
        _cancel();
      } else if (_windows.isNotEmpty) {
        _closeWindow(_windows.last.id);
      }
    },
    child: PageFrame(
      title:
          '${widget.target.platform.shortName}${widget.passwordLogin == null || passwordFallback ? '网页登录' : '登录验证'}',
      actions: [
        IconButton(
          tooltip: '刷新网页',
          onPressed: _refresh,
          icon: const Icon(CupertinoIcons.arrow_clockwise, size: 20),
        ),
        TextButton(
          onPressed: () async {
            if (manualOpen || !active) return;
            manualOpen = true;
            widget.passwordLogin?.clear();
            widget.services.login.invalidate(widget.target.platform);
            try {
              final result = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => ManualLoginPage(
                    widget.services,
                    widget.target.platform,
                    accountId: widget.accountId,
                  ),
                ),
              );
              if (result == true && context.mounted && !leaving) {
                await _forgetBrowserCookies();
                if (!context.mounted || leaving) return;
                completed = true;
                timer?.cancel();
                Navigator.pop(context);
              }
            } finally {
              manualOpen = false;
            }
          },
          child: const Text('手动'),
        ),
      ],
      child: Column(
        children: [
          if (progress < 1 && ready) LinearProgressIndicator(value: progress),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Row(
              children: [
                Icon(
                  checking ? CupertinoIcons.clock : CupertinoIcons.lock_shield,
                  size: 16,
                  color: brandBlue,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status,
                    style: TextStyle(fontSize: 12, color: secondary(context)),
                  ),
                ),
                TextButton(
                  onPressed: checking ? null : () => _poll(userInitiated: true),
                  child: const Text('检测登录', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          if (widget.onUsePassword != null ||
              widget.passwordLogin != null && !passwordFallback)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                children: [
                  if (widget.onUsePassword != null)
                    TextButton.icon(
                      key: const ValueKey('web-login-password'),
                      onPressed: _switchToPassword,
                      icon: const Icon(CupertinoIcons.keyboard, size: 18),
                      label: Text(widget.nativeLoginLabel),
                    ),
                  if (widget.passwordLogin != null && !passwordFallback)
                    TextButton.icon(
                      key: const ValueKey('web-login-continue-web'),
                      onPressed: _continueWebLogin,
                      icon: const Icon(CupertinoIcons.globe, size: 18),
                      label: const Text('继续网页登录'),
                    ),
                ],
              ),
            ),
          Expanded(
            child: error.isNotEmpty
                ? EmptyPanel(
                    '无法打开登录页面',
                    error,
                    icon: CupertinoIcons.globe,
                    action: TextButton(
                      onPressed: _refresh,
                      child: const Text('重试'),
                    ),
                  )
                : !ready
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      Positioned.fill(child: _webView()),
                      for (final popup in _windows)
                        Positioned.fill(
                          key: ValueKey('login-popup-${popup.id}'),
                          child: ColoredBox(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            child: Column(
                              children: [
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    onPressed: () => _closeWindow(popup.id),
                                    icon: const Icon(
                                      CupertinoIcons.back,
                                      size: 18,
                                    ),
                                    label: const Text('返回登录页面'),
                                  ),
                                ),
                                Expanded(child: _webView(popup: popup)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    ),
  );
}

class ManualLoginPage extends StatefulWidget {
  const ManualLoginPage(
    this.services,
    this.platform, {
    super.key,
    this.accountId,
    this.onUsePassword,
    this.nativeLoginLabel = '切换账号密码登录',
  });
  final AppServices services;
  final CloudPlatform platform;
  final String? accountId;
  final VoidCallback? onUsePassword;
  final String nativeLoginLabel;
  @override
  State<ManualLoginPage> createState() => _ManualLoginPageState();
}

class _ManualLoginPageState extends State<ManualLoginPage> {
  final primary = TextEditingController(),
      secondaryInput = TextEditingController(),
      appId = TextEditingController(),
      deviceId = TextEditingController(),
      clientId = TextEditingController(),
      clientSecret = TextEditingController();
  bool working = false,
      visible = false,
      passwordMode = false,
      completed = false;
  String error = '';
  @override
  void initState() {
    super.initState();
    final old = widget.services.vault.credentialFor(
      widget.platform,
      widget.accountId ??
          widget.services.vault.activeAccountId(widget.platform),
    );
    appId.text = (old?.field('appId') ?? '').ifEmpty(
      widget.platform == CloudPlatform.baidu ? old?.secondary ?? '' : '',
    );
    clientId.text = old?.field('clientId') ?? XunleiProtocol.clientId;
    clientSecret.text =
        old?.field('clientSecret') ?? XunleiProtocol.clientSecret;
    deviceId.text = old?.field('deviceId') ?? '';
  }

  @override
  void dispose() {
    if (!completed) widget.services.login.invalidate(widget.platform);
    for (final c in [
      primary,
      secondaryInput,
      appId,
      deviceId,
      clientId,
      clientSecret,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (working) return;
    setState(() {
      working = true;
      error = '';
    });
    try {
      final p = widget.platform, services = widget.services;
      if (p == CloudPlatform.pan123 && passwordMode) {
        await services.login.submit(p, (_) async {
          require(
            primary.text.trim().isNotEmpty && secondaryInput.text.isNotEmpty,
            '请输入账号和密码',
          );
          return (services.cloud.connector(p) as Pan123Connector).password(
            primary.text.trim(),
            secondaryInput.text,
          );
        }, accountId: widget.accountId);
      } else if (p == CloudPlatform.xunlei) {
        await services.login.submit(p, (_) async {
          require(primary.text.trim().isNotEmpty, '请输入 Access Token');
          final c = Credential(p.label, {
            'primary': primary.text.trim(),
            'accessToken': primary.text.trim(),
            'refreshToken': secondaryInput.text.trim(),
            'secondary': secondaryInput.text.trim(),
            'deviceId': deviceId.text.trim(),
            'clientId': clientId.text.trim(),
            'clientSecret': clientSecret.text.trim(),
            'clientVersion': XunleiProtocol.version,
          });
          return (services.cloud.connector(p) as XunleiConnector).authenticate(
            c,
          );
        }, accountId: widget.accountId);
      } else {
        var value = primary.text.trim();
        if (p == CloudPlatform.c139 && secondaryInput.text.trim().isNotEmpty) {
          final pairs = LoginCredentials.cookiePairs(value)
            ..['authorization'] = secondaryInput.text.trim();
          value = pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
        }
        await services.login.submitWeb(
          p,
          value,
          appId: appId.text.trim(),
          accountId: widget.accountId,
        );
      }
      completed = true;
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: controller,
      enabled: !working,
      obscureText: secret && !visible,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: secret
            ? IconButton(
                tooltip: visible ? '隐藏' : '显示',
                icon: Icon(
                  visible ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                  size: 20,
                ),
                onPressed: () => setState(() => visible = !visible),
              )
            : null,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final platform = widget.platform;
    return PageFrame(
      title: '${platform.shortName}登录信息',
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: 560,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Row(
                children: [
                  PlatformMark(platform: platform),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      '登录信息加密保存在本机',
                      style: TextStyle(fontSize: 13, color: secondary(context)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (platform == CloudPlatform.pan123)
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('网页登录 Token')),
                      ButtonSegment(value: true, label: Text('账号密码')),
                    ],
                    selected: {passwordMode},
                    onSelectionChanged: working
                        ? null
                        : (v) => setState(() {
                            passwordMode = v.first;
                            primary.clear();
                            secondaryInput.clear();
                          }),
                  ),
                ),
              _field(
                primary,
                platform == CloudPlatform.xunlei
                    ? 'Access Token'
                    : platform == CloudPlatform.pan123
                    ? passwordMode
                          ? '账号'
                          : 'authorToken'
                    : platform == CloudPlatform.aliyun
                    ? 'Refresh Token 或登录凭据 JSON'
                    : platform == CloudPlatform.wopan
                    ? 'Refresh Token 或登录凭据 JSON'
                    : platform == CloudPlatform.ilanzou
                    ? 'appToken 或登录凭据 JSON'
                    : platform == CloudPlatform.guangya
                    ? '登录凭据 JSON 或 Access Token'
                    : '完整 Cookie',
                secret: !passwordMode,
              ),
              if (platform == CloudPlatform.pan123 && passwordMode)
                _field(secondaryInput, '密码', secret: true),
              if (platform == CloudPlatform.baidu)
                _field(appId, '应用 ID（可选，默认 ${BaiduConnector.defaultAppId}）'),
              if (platform == CloudPlatform.c139)
                _field(
                  secondaryInput,
                  'Authorization（Cookie 中缺失时填写）',
                  secret: true,
                ),
              if (platform == CloudPlatform.xunlei) ...[
                _field(secondaryInput, 'Refresh Token（可选）', secret: true),
                _field(deviceId, 'Device ID（可选）'),
                _field(clientId, 'Client ID'),
                _field(clientSecret, 'Client Secret', secret: true),
              ],
              Text(
                platform == CloudPlatform.xunlei ||
                        platform == CloudPlatform.pan123 && passwordMode
                    ? '验证成功后会保存账号信息。'
                    : LoginCredentials.hint(platform),
                style: TextStyle(fontSize: 12, color: secondary(context)),
              ),
              const SizedBox(height: 20),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(error, style: const TextStyle(color: Colors.red)),
                ),
              FilledButton(
                onPressed: working ? null : _save,
                child: Text(working ? '正在验证…' : '验证并保存'),
              ),
              if (widget.onUsePassword != null)
                TextButton.icon(
                  key: const ValueKey('manual-login-password'),
                  onPressed: () {
                    widget.services.login.invalidate(platform);
                    widget.onUsePassword!();
                  },
                  icon: const Icon(CupertinoIcons.keyboard, size: 18),
                  label: Text(widget.nativeLoginLabel),
                ),
              if (working)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class XunleiLoginPage extends StatefulWidget {
  const XunleiLoginPage(
    this.services, {
    super.key,
    this.accountId,
    required this.onUseWeb,
  });
  final AppServices services;
  final String? accountId;
  final VoidCallback onUseWeb;
  @override
  State<XunleiLoginPage> createState() => _XunleiLoginPageState();
}

class _XunleiLoginPageState extends State<XunleiLoginPage> {
  final username = TextEditingController(),
      password = TextEditingController(),
      mobile = TextEditingController(),
      code = TextEditingController();
  bool working = false, visible = false, smsMode = false, completed = false;
  bool leaving = false;
  String error = '';
  SmsChallenge? challenge;
  XunleiVerificationRequired? verification;
  int cooldown = 0;
  Timer? timer;
  RequestScope? request;
  @override
  void initState() {
    super.initState();
    final saved = widget.services.vault.credentialFor(
      CloudPlatform.xunlei,
      widget.accountId ??
          widget.services.vault.activeAccountId(CloudPlatform.xunlei),
    );
    if (LoginCredentials.hasXunleiPassword(saved)) {
      username.text = saved!.field('username');
      password.text = saved.field('password');
    }
  }

  void _cancel() {
    if (completed || leaving) return;
    leaving = true;
    request?.cancel();
    timer?.cancel();
    widget.services.login.invalidate(CloudPlatform.xunlei);
  }

  void _useWeb() {
    if (completed || leaving) return;
    _cancel();
    password.clear();
    code.clear();
    FocusScope.of(context).unfocus();
    widget.onUseWeb();
  }

  @override
  void dispose() {
    _cancel();
    timer?.cancel();
    for (final c in [username, password, mobile, code]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _action(Future<void> Function() action) async {
    if (working || leaving || completed) return;
    setState(() {
      working = true;
      error = '';
    });
    request = RequestScope();
    try {
      widget.services.control.checkCloud(CloudPlatform.xunlei);
      await widget.services.vault.withAccount(
        CloudPlatform.xunlei,
        widget.accountId ??
            widget.services.vault.activeAccountId(CloudPlatform.xunlei),
        () => request!.run(action),
      );
    } on XunleiVerificationRequired catch (e) {
      if (mounted && !leaving) {
        setState(() {
          verification = e;
          smsMode = true;
          challenge = null;
          code.clear();
          if (XunleiLoginService.isMobile(username.text)) {
            mobile.text = username.text;
          }
          error = e.message;
        });
      }
    } catch (e) {
      if (mounted && !leaving) setState(() => error = errorText(e));
    } finally {
      if (mounted && !leaving) setState(() => working = false);
    }
  }

  Future<void> _login({bool sms = false}) => _action(() async {
    await widget.services.login.submit(
      CloudPlatform.xunlei,
      (_) => sms
          ? widget.services.cloud.xunleiLogin.verifySms(challenge!, code.text)
          : widget.services.cloud.xunleiLogin.password(
              username.text,
              password.text,
              rememberPassword: true,
            ),
      accountId: widget.accountId,
    );
    if (!mounted || leaving) return;
    completed = true;
    password.clear();
    code.clear();
    if (mounted) Navigator.pop(context);
  });
  Future<void> _send() => _action(() async {
    challenge = await widget.services.cloud.xunleiLogin.sendSms(mobile.text);
    code.clear();
    cooldown = 60;
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || cooldown <= 0) {
        t.cancel();
        return;
      }
      setState(() => cooldown--);
    });
  });
  Future<void> _verifyWeb() async {
    final value = verification;
    if (value == null || !XunleiProtocol.trustedPage(value.url)) return;
    final verified = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => XunleiVerificationPage(widget.services, value),
      ),
    );
    if (verified == true && mounted) await _login();
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '迅雷网盘登录',
    actions: [
      TextButton(
        key: const ValueKey('xunlei-login-web'),
        onPressed: _useWeb,
        child: const Text('网页登录'),
      ),
    ],
    child: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: 560,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Row(
              children: [
                PlatformMark(platform: CloudPlatform.xunlei),
                SizedBox(width: 14),
                Expanded(
                  child: Text(
                    '登录后浏览和管理网盘文件',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('账号密码')),
                ButtonSegment(value: true, label: Text('短信登录')),
              ],
              selected: {smsMode},
              onSelectionChanged: working
                  ? null
                  : (v) => setState(() {
                      smsMode = v.first;
                      error = '';
                    }),
            ),
            const SizedBox(height: 24),
            if (!smsMode) ...[
              TextField(
                key: const ValueKey('xunlei-login-username'),
                controller: username,
                enabled: !working,
                decoration: const InputDecoration(labelText: '手机号 / 邮箱'),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('xunlei-login-password'),
                controller: password,
                enabled: !working,
                obscureText: !visible,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: '密码',
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => visible = !visible),
                    icon: Icon(
                      visible ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const ValueKey('xunlei-login-submit'),
                onPressed: working ? null : _login,
                child: const Text('登录'),
              ),
            ] else ...[
              TextField(
                controller: mobile,
                enabled: !working,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: '账号绑定的手机号'),
                onChanged: (_) {
                  challenge = null;
                  code.clear();
                },
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: working || cooldown > 0 ? null : _send,
                child: Text(cooldown > 0 ? '$cooldown 秒后重新发送' : '发送验证码'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: code,
                enabled: !working,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '短信验证码'),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: working || challenge == null
                    ? null
                    : () => _login(sms: true),
                child: const Text('验证并登录'),
              ),
              if (verification?.url.isNotEmpty == true)
                OutlinedButton(
                  onPressed: working ? null : _verifyWeb,
                  child: const Text('打开网页安全验证'),
                ),
            ],
            if (working)
              const Padding(
                padding: EdgeInsets.only(top: 20),
                child: LinearProgressIndicator(),
              ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Text(error, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 20),
            Text(
              smsMode ? '短信需由你主动发送并填写验证码。' : '账号密码加密保存，下次自动保持登录，需要安全验证时会提示你完成。',
              style: TextStyle(fontSize: 12, color: secondary(context)),
            ),
          ],
        ),
      ),
    ),
  );
}

class XunleiVerificationPage extends StatefulWidget {
  const XunleiVerificationPage(this.services, this.challenge, {super.key});
  final AppServices services;
  final XunleiVerificationRequired challenge;
  @override
  State<XunleiVerificationPage> createState() => _XunleiVerificationPageState();
}

class _XunleiVerificationPageState extends State<XunleiVerificationPage> {
  InAppWebViewController? controller;
  WebViewEnvironment? environment;
  Timer? timer;
  bool ready = false, finished = false, polling = false;
  String error = '';
  late final sign = XunleiProtocol.deviceSign(widget.challenge.deviceId);
  late final url = XunleiProtocol.withDeviceSign(widget.challenge.url, sign);
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      environment = await widget.services.webEnvironment();
      if (mounted) setState(() => ready = true);
      timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _poll());
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    }
  }

  void _finish() {
    if (!finished && mounted) {
      finished = true;
      Navigator.pop(context, true);
    }
  }

  Future<void> _poll() async {
    if (!mounted || finished || polling || controller == null) return;
    polling = true;
    try {
      if (!XunleiProtocol.trustedPage(
        (await controller!.getUrl())?.toString(),
      )) {
        return;
      }
      final signal = await controller!.evaluateJavascript(
        source: "window.__asterVerifySignal || ''",
      );
      if (!XunleiProtocol.trustedPage(
        (await controller!.getUrl())?.toString(),
      )) {
        return;
      }
      if (signal == 'verified') _finish();
      if (signal == 'closed' && mounted) {
        finished = true;
        Navigator.pop(context, false);
      }
    } catch (_) {
      /* Navigation may replace the document during polling. */
    } finally {
      polling = false;
    }
  }

  String get script =>
      '''
    (function(){
      if(window.__asterVerificationInstalled)return;
      window.__asterVerificationInstalled=true; window.__asterVerifySignal='';
      window.XLJSWebViewBridge={onVerifyResult:function(){window.__asterVerifySignal='verified';},close:function(){window.__asterVerifySignal='closed';}};
      window.env='android'; window.appid='40'; window.appName='ANDROID-com.xunlei.downloadprovider';
      window.clientVersion=${jsonEncode(XunleiProtocol.version)}; window.deviceid=${jsonEncode(sign)};
      window.platformVersion='10'; window.event='login3';
      function initialize(){
        if(!window.XlCaptcha||typeof window.XlCaptcha.init!=='function')return false;
        try{
          if(typeof window.XlCaptcha.isMobileSDK!=='function')window.XlCaptcha.isMobileSDK=function(){return false;};
          window.XlCaptcha.init({appid:'40',appName:window.appName,clientVersion:window.clientVersion,
            deviceid:window.deviceid,event:'login3',platformVersion:'10',IFRAME_BOX_ID:'captch-wrap',
            VERTIFYSUCCFUNC:function(){window.XLJSWebViewBridge.onVerifyResult();}});
          return true;
        }catch(e){return false;}
      }
      if(!initialize()){var t=setInterval(function(){if(initialize())clearInterval(t);},120);setTimeout(function(){clearInterval(t);},10000);}
    })();
  ''';
  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '迅雷安全验证',
    actions: [TextButton(onPressed: _finish, child: const Text('已完成验证'))],
    child: error.isNotEmpty
        ? EmptyPanel('验证页面不可用', error)
        : !ready
        ? const Center(child: CircularProgressIndicator())
        : InAppWebView(
            webViewEnvironment: environment,
            initialUrlRequest: URLRequest(url: WebUri(url)),
            initialSettings: webSettings(),
            initialUserScripts: UnmodifiableListView([
              desktopLoginUserScript(),
            ]),
            onWebViewCreated: (web) => controller = web,
            onLoadStop: (web, page) async {
              if (XunleiProtocol.trustedPage(page?.toString()) &&
                  XunleiProtocol.trustedPage(
                    (await web.getUrl())?.toString(),
                  )) {
                await web.evaluateJavascript(
                  source: desktopLoginViewportScript,
                );
                await web.evaluateJavascript(source: script);
              }
            },
            shouldOverrideUrlLoading: (web, action) async {
              final target = action.request.url?.toString();
              if (action.isForMainFrame &&
                  XunleiProtocol.trustedCallback(target)) {
                if (XunleiProtocol.trustedPage(
                  (await web.getUrl())?.toString(),
                )) {
                  _finish();
                }
                return NavigationActionPolicy.CANCEL;
              }
              return XunleiProtocol.trustedPage(target)
                  ? NavigationActionPolicy.ALLOW
                  : NavigationActionPolicy.CANCEL;
            },
          ),
  );
}
