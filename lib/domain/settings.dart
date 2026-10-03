import '../core/json.dart';
import 'models.dart';

class AppSettings {
  const AppSettings({
    this.theme = 'System',
    this.threads = 64,
    this.concurrent = 3,
    this.retries = 3,
    this.speedLimit = 0,
    this.threadOverrides = const {},
    this.destination,
    this.browserView = 'list',
    this.clipboardRecognition = true,
  });
  final String theme;
  final int threads, concurrent, retries, speedLimit;
  final Map<String, int> threadOverrides;
  final String? destination;
  final String browserView;
  final bool clipboardRecognition;
  static const profiles = {
    'baidu': ('百度网盘', 64),
    'quark_route_1': ('夸克 · 直链', 512),
    'quark_route_2': ('夸克 · 快传', 64),
    'uc': ('UC网盘', 512),
    'xunlei': ('迅雷网盘', 64),
    'pan123': ('123网盘', 64),
    'guangya': ('光鸭云盘', 64),
    'aliyun': ('阿里云盘', 64),
    'yidong': ('中国移动云盘', 64),
    'tianyi': ('天翼云盘', 64),
    'ilanzou': ('蓝奏云优享版', 64),
    'weiyun': ('腾讯微云', 64),
    'pan115': ('115网盘', 16),
    'wopan': ('中国联通云盘', 64),
  };
  String? connectionProfileFor(CloudPlatform? platform, [String? profile]) =>
      profiles.containsKey(profile)
      ? profile
      : switch (platform) {
          CloudPlatform.baidu => 'baidu',
          CloudPlatform.quark => 'quark_route_1',
          CloudPlatform.uc => 'uc',
          CloudPlatform.xunlei => 'xunlei',
          CloudPlatform.pan123 => 'pan123',
          CloudPlatform.guangya => 'guangya',
          CloudPlatform.aliyun => 'aliyun',
          CloudPlatform.c139 => 'yidong',
          CloudPlatform.tianyi => 'tianyi',
          CloudPlatform.ilanzou => 'ilanzou',
          CloudPlatform.weiyun => 'weiyun',
          CloudPlatform.pan115 => 'pan115',
          CloudPlatform.wopan => 'wopan',
          CloudPlatform.lanzou || null => null,
        };
  int connectionsFor(CloudPlatform? platform, [String? profile]) {
    final key = connectionProfileFor(platform, profile);
    if (key == null) return threads.clamp(1, 512);
    final override = threadOverrides[key];
    final configured =
        (override == null
                ? profiles[key]!.$2
                : override == 0
                ? threads
                : override)
            .clamp(1, 512);
    return configured;
  }

  Json toJson() => {
    'theme': theme,
    'threads': threads,
    'concurrent': concurrent,
    'retries': retries,
    'speedLimit': speedLimit,
    'downloadThreadOverrides': threadOverrides,
    'destination': destination,
    'browserView': browserView,
    'clipboardRecognition': clipboardRecognition,
  };
  factory AppSettings.fromJson(Json j) => AppSettings(
    theme: ['System', 'Light', 'Dark'].contains(j.str('theme'))
        ? j.str('theme')
        : 'System',
    threads: j.integer('threads', 64).clamp(1, 512),
    concurrent: j.integer('concurrent', 3).clamp(1, 3),
    retries: j.integer('retries', 3).clamp(0, 3),
    speedLimit: j.integer('speedLimit').clamp(0, 1 << 50),
    threadOverrides: {
      for (final e in j.obj('downloadThreadOverrides').entries)
        if (profiles.containsKey(e.key))
          e.key: (int.tryParse('${e.value}') ?? 0).clamp(0, 512),
    },
    destination: j['destination']?.toString(),
    browserView: j.str('browserView') == 'grid' ? 'grid' : 'list',
    clipboardRecognition: j.boolean('clipboardRecognition', true),
  );
  AppSettings update(Json fields) =>
      AppSettings.fromJson({...toJson(), ...fields});
}
