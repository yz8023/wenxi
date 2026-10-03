import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class UsageMetricsStatus {
  const UsageMetricsStatus({
    this.consent,
    this.initialized = false,
    this.restartRequired = false,
  });

  final bool? consent;
  final bool initialized;
  final bool restartRequired;

  factory UsageMetricsStatus.fromMap(Map<String, dynamic> value) =>
      UsageMetricsStatus(
        consent: value['consent'] as bool?,
        initialized: value['initialized'] == true,
        restartRequired: value['restartRequired'] == true,
      );
}

class UsageMetrics {
  const UsageMetrics({this.platform});

  final TargetPlatform? platform;
  static const channel = MethodChannel('com.asterlink.app/analytics');
  bool get supported =>
      !kIsWeb && (platform ?? defaultTargetPlatform) == TargetPlatform.android;

  Future<UsageMetricsStatus> status() => _invoke('status');
  Future<UsageMetricsStatus> setConsent(bool granted) =>
      _invoke('setConsent', {'granted': granted});

  Future<UsageMetricsStatus> _invoke(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    if (!supported) return const UsageMetricsStatus(consent: false);
    final value = await channel.invokeMapMethod<String, dynamic>(
      method,
      arguments,
    );
    if (value == null) {
      throw PlatformException(
        code: 'analytics_unavailable',
        message: '暂时无法读取统计设置',
      );
    }
    return UsageMetricsStatus.fromMap(value);
  }
}
