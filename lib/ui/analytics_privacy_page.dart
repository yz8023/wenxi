import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../diagnostics/app_log.dart';
import '../platform/usage_metrics.dart';
import 'common.dart';

const _purpose =
    '为了解应用的使用情况、改进产品体验，文析助手在 Android 端使用友盟+移动统计 SDK，'
    '统计应用启动、活跃设备和前台使用时长。';
const _collection =
    '开启后，友盟 SDK 会收集设备标识符（如 Android ID、OAID、广告标识符）、'
    '设备型号、系统与应用版本、网络类型、IP 地址及应用使用统计，并发送至友盟服务器。';
const _choice =
    '是否开启由你选择，拒绝不影响解析、下载和播放。'
    '你可以在“我的 → 隐私与使用统计”中修改选择。';
const _policyUrl = 'https://www.umeng.com/page/policy';

Future<bool?> _requestConsent(BuildContext context, UsageMetrics analytics) =>
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('使用统计与隐私'),
          scrollable: true,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('$_purpose\n\n$_collection\n\n$_choice'),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AnalyticsPrivacyPage(
                      analytics: analytics,
                      showControls: false,
                    ),
                  ),
                ),
                child: const Text('查看统计与隐私说明'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('不同意并继续'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('同意并开启'),
            ),
          ],
        ),
      ),
    );

class AnalyticsConsentGate extends StatefulWidget {
  const AnalyticsConsentGate({
    super.key,
    required this.enabled,
    required this.child,
    this.analytics = const UsageMetrics(),
  });

  final bool enabled;
  final Widget child;
  final UsageMetrics analytics;

  @override
  State<AnalyticsConsentGate> createState() => _AnalyticsConsentGateState();
}

class _AnalyticsConsentGateState extends State<AnalyticsConsentGate> {
  @override
  void initState() {
    super.initState();
    if (widget.enabled && widget.analytics.supported) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkConsent());
    }
  }

  Future<void> _checkConsent() async {
    try {
      final status = await widget.analytics.status();
      if (!mounted || status.consent != null) return;
      final granted = await _requestConsent(context, widget.analytics);
      if (granted == null) return;
      final updated = await widget.analytics.setConsent(granted);
      if (mounted && granted && !updated.initialized) {
        message(context, '选择已保存，统计将在下次启动时重试开启');
      }
    } catch (error, stack) {
      DiagnosticLog.error('analytics.consent_failed', error, stack);
      if (mounted) message(context, '无法读取或保存统计设置，可在“我的 → 隐私与使用统计”中重试');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class AnalyticsPrivacyPage extends StatefulWidget {
  const AnalyticsPrivacyPage({
    super.key,
    this.analytics = const UsageMetrics(),
    this.showControls = true,
  });

  final UsageMetrics analytics;
  final bool showControls;

  @override
  State<AnalyticsPrivacyPage> createState() => _AnalyticsPrivacyPageState();
}

class _AnalyticsPrivacyPageState extends State<AnalyticsPrivacyPage> {
  UsageMetricsStatus? _status;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.showControls) _load();
  }

  Future<void> _load() async {
    try {
      final status = await widget.analytics.status();
      if (mounted) {
        setState(() {
          _status = status;
          _error = null;
        });
      }
    } catch (error, stack) {
      DiagnosticLog.error('analytics.status_failed', error, stack);
      if (mounted) setState(() => _error = '暂时无法读取统计设置，请重试');
    }
  }

  Future<void> _setConsent(bool granted) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await widget.analytics.setConsent(granted);
      if (mounted) setState(() => _status = status);
    } catch (error, stack) {
      DiagnosticLog.error('analytics.settings_failed', error, stack);
      if (mounted) setState(() => _error = '统计设置保存失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPolicy() async {
    try {
      if (await launchUrl(
        Uri.parse(_policyUrl),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (error, stack) {
      DiagnosticLog.error('analytics.policy_open_failed', error, stack);
    }
    if (mounted) message(context, '无法打开浏览器，可复制下方地址查看');
  }

  String get _statusText {
    final status = _status!;
    if (status.restartRequired) {
      return status.consent == true
          ? '选择已保存，下次启动应用时开启统计。'
          : '已停止新增使用统计。重启应用后完全停用统计组件；此前已提交的数据不会自动删除。';
    }
    if (status.initialized) return '使用统计已开启。';
    return '使用统计未开启。';
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '隐私与使用统计',
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('使用目的', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text(_purpose),
        const SizedBox(height: 20),
        Text('第三方服务与信息收集', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text(
          'SDK 名称：友盟+移动统计 SDK\n'
          '服务提供方：友盟同欣（北京）科技有限公司、北京锐讯灵通科技有限公司',
        ),
        const SizedBox(height: 12),
        const Text(_collection),
        const SizedBox(height: 12),
        const Text(
          '本应用关闭了 SDK 的 IMEI、IMSI、ICCID、Wi-Fi MAC 和应用列表采集。'
          '不会向友盟提交网盘账号、密码、Cookie、分享链接、文件名或播放内容；'
          '故障日志继续保存在本机，不交由友盟自动上传。',
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _openPolicy,
            child: const Text('查看友盟隐私政策'),
          ),
        ),
        const SelectableText(_policyUrl),
        const SizedBox(height: 20),
        Text('你的选择', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text(_choice),
        if (widget.showControls) ...[
          const SizedBox(height: 16),
          if (_status != null) ...[
            Text(_statusText),
            const SizedBox(height: 12),
            if (_status!.consent == true)
              OutlinedButton(
                onPressed: _busy ? null : () => _setConsent(false),
                child: const Text('关闭使用统计'),
              )
            else
              FilledButton(
                onPressed: _busy ? null : () => _setConsent(true),
                child: const Text('同意以上说明并开启统计'),
              ),
          ] else if (_error == null)
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          if (_error != null) ...[
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            if (_status == null)
              TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ],
      ],
    ),
  );
}
