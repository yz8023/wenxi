import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app_services.dart';
import '../diagnostics/app_log.dart';
import '../diagnostics/diagnostic_bundle.dart';
import '../domain/settings.dart';
import '../platform/native_engine.dart';
import 'common.dart';
import 'remote_control_dialogs.dart';
import 'diagnostics_page.dart';
import 'download_protection_page.dart';
import 'contact_author_dialog.dart';

class MinePage extends StatelessWidget {
  const MinePage(this.services, {super.key, this.linkLauncher});
  final AppServices services;
  final RemoteLinkLauncher? linkLauncher;
  Future<void> _number(
    BuildContext context,
    String title,
    String key,
    int initial,
    int min,
    int max,
  ) async {
    final text = await askText(
      context,
      title,
      initial: '$initial',
      hint: '$min–$max',
      numeric: true,
    );
    if (text == null || !context.mounted) return;
    final value = int.tryParse(text.trim());
    if (value == null || value < min || value > max) {
      message(context, '请输入 $min–$max 之间的整数');
      return;
    }
    await busy(context, () => services.updateSettings({key: value}));
  }

  Future<void> _threads(BuildContext context, String key) async {
    final profile = AppSettings.profiles[key]!;
    final current = services.settings.threadOverrides[key];
    final choice = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${profile.$1}连接数'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, -1),
            child: Text('平台预设（${profile.$2}）${current == null ? ' ✓' : ''}'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 0),
            child: Text(
              '跟随全局（${services.settings.threads}）${current == 0 ? ' ✓' : ''}',
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 1),
            child: const Text('自定义连接数…'),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    int? value;
    if (choice == 1) {
      final text = await askText(
        context,
        '自定义连接数',
        initial: '${current ?? profile.$2}',
        hint: '1–512',
        numeric: true,
      );
      if (text == null || !context.mounted) return;
      value = int.tryParse(text);
      if (value == null || value < 1 || value > 512) {
        message(context, '连接数范围为 1–512');
        return;
      }
    } else if (choice == 0) {
      value = 0;
    }
    final values = {...services.settings.threadOverrides};
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    await services.updateSettings({'downloadThreadOverrides': values});
  }

  Future<void> _saveBytes(
    BuildContext context,
    Uint8List bytes,
    String name,
  ) async {
    if (Platform.isAndroid && services.platformFeatures) {
      final result = await nativeChannel.invokeMethod<String>('saveDocument', {
        'name': name,
        'bytes': bytes,
        'mime': 'application/json',
      });
      if (result != null && context.mounted) message(context, '文件已导出');
      return;
    }
    final location = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (location == null) return;
    await XFile.fromData(
      bytes,
      name: name,
      mimeType: 'application/json',
    ).saveTo(location.path);
    if (context.mounted) message(context, '文件已导出');
  }

  Future<void> _export(BuildContext context) async {
    final password = await askText(
      context,
      '设置备份密码',
      hint: '至少 6 位，请妥善保管',
      secret: true,
    );
    if (password == null || !context.mounted) return;
    final bytes = await busy(
      context,
      () => services.backup.create(password),
      label: '正在加密备份…',
    );
    if (bytes != null && context.mounted) {
      await busy(
        context,
        () => _saveBytes(
          context,
          bytes,
          '文析助手-backup-${DateTime.now().millisecondsSinceEpoch}.json',
        ),
      );
    }
  }

  Future<void> _restore(BuildContext context) async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '文析助手备份',
          extensions: ['json', 'bak'],
          mimeTypes: ['application/json', 'application/octet-stream'],
        ),
      ],
    );
    if (file == null || !context.mounted) return;
    if (await file.length() > 16 * 1024 * 1024) {
      if (context.mounted) message(context, '备份文件过大');
      return;
    }
    if (!context.mounted ||
        !await confirm(context, '恢复备份', '备份中的账号和设置将覆盖本机对应项目，下载文件不会被删除。') ||
        !context.mounted) {
      return;
    }
    final password = await askText(context, '输入备份密码', secret: true);
    if (password == null || !context.mounted) return;
    final count = await busy(
      context,
      () async => services.backup.restore(await file.readAsBytes(), password),
      label: '正在验证并恢复备份…',
    );
    if (count != null && context.mounted) {
      await services.downloads.settingsChanged();
      if (context.mounted) message(context, '已恢复 $count 个账号及下载设置');
    }
  }

  Widget _settingIcon(BuildContext context, IconData icon) => Container(
    width: 34,
    height: 34,
    decoration: BoxDecoration(
      color: brandBlue.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Icon(icon, size: 19, color: brandBlue),
  );

  Widget _tile(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    VoidCallback action, {
    String? value,
  }) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    minLeadingWidth: 34,
    horizontalTitleGap: 12,
    minVerticalPadding: 12,
    leading: _settingIcon(context, icon),
    title: Text(
      title,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    ),
    subtitle: subtitle.isEmpty
        ? null
        : Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: secondary(context),
            ),
          ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value != null) ...[
          Text(
            value,
            style: TextStyle(fontSize: 13, color: secondary(context)),
          ),
          const SizedBox(width: 8),
        ],
        Icon(CupertinoIcons.chevron_right, size: 13, color: secondary(context)),
      ],
    ),
    onTap: action,
  );

  Widget _section(
    BuildContext context,
    String title,
    List<Widget> children, {
    String? footer,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      Material(
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: border(context), width: .7),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0)
                Divider(
                  height: 1,
                  thickness: .6,
                  indent: 62,
                  endIndent: 16,
                  color: border(context),
                ),
              children[index],
            ],
          ],
        ),
      ),
      if (footer != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
          child: Text(
            footer,
            style: TextStyle(
              fontSize: 11,
              height: 1.6,
              color: secondary(context),
            ),
          ),
        ),
    ],
  );

  static const _themes = [
    ('System', '跟随系统', CupertinoIcons.device_desktop),
    ('Light', '浅色', CupertinoIcons.sun_max),
    ('Dark', '深色', CupertinoIcons.moon),
  ];

  Future<void> _chooseTheme(BuildContext context) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text(
                  '外观模式',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              for (final choice in _themes)
                ListTile(
                  leading: _settingIcon(context, choice.$3),
                  title: Text(choice.$2),
                  trailing: services.settings.theme == choice.$1
                      ? const Icon(
                          CupertinoIcons.check_mark,
                          color: brandBlue,
                          size: 20,
                        )
                      : null,
                  onTap: () => Navigator.pop(context, choice.$1),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) await services.updateSettings({'theme': selected});
  }

  Widget _appearance(
    BuildContext context,
    AppSettings settings,
    bool desktop,
  ) => _section(context, '外观', [
    if (desktop)
      Padding(
        padding: const EdgeInsets.all(16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final choice in _themes)
                ChoiceChip(
                  key: ValueKey('settings-theme-${choice.$1}'),
                  label: Text(choice.$2),
                  avatar: Icon(
                    choice.$3,
                    size: 16,
                    color: settings.theme == choice.$1
                        ? brandBlue
                        : secondary(context),
                  ),
                  selected: settings.theme == choice.$1,
                  showCheckmark: false,
                  selectedColor: brandBlue.withValues(alpha: .1),
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  labelStyle: TextStyle(
                    fontSize: 12,
                    color: settings.theme == choice.$1
                        ? brandBlue
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                  side: BorderSide(
                    color: settings.theme == choice.$1
                        ? brandBlue.withValues(alpha: .3)
                        : border(context),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  onSelected: (selected) async {
                    if (selected) {
                      await services.updateSettings({'theme': choice.$1});
                    }
                  },
                ),
            ],
          ),
        ),
      )
    else
      _tile(
        context,
        CupertinoIcons.paintbrush,
        '外观模式',
        '',
        () => _chooseTheme(context),
        value: _themes
            .firstWhere(
              (item) => item.$1 == settings.theme,
              orElse: () => _themes.first,
            )
            .$2,
      ),
  ]);

  Widget _platformThreads(BuildContext context, AppSettings settings) =>
      ExpansionTile(
        key: const PageStorageKey('mine-platform-connections'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        shape: const Border(),
        collapsedShape: const Border(),
        iconColor: brandBlue,
        collapsedIconColor: secondary(context),
        leading: _settingIcon(context, CupertinoIcons.slider_horizontal_3),
        title: const Text(
          '各网盘连接数',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          '为不同网盘单独设置',
          style: TextStyle(fontSize: 12, color: secondary(context)),
        ),
        children: [
          for (final entry in AppSettings.profiles.entries)
            ListTile(
              contentPadding: const EdgeInsets.only(left: 62, right: 18),
              title: Text(entry.value.$1, style: const TextStyle(fontSize: 13)),
              trailing: Text(
                settings.threadOverrides[entry.key] == null
                    ? '预设 ${entry.value.$2}'
                    : settings.threadOverrides[entry.key] == 0
                    ? '跟随全局'
                    : '${settings.threadOverrides[entry.key]}',
                style: const TextStyle(fontSize: 12, color: brandBlue),
              ),
              onTap: () => _threads(context, entry.key),
            ),
        ],
      );

  Widget _linkRecognition(
    BuildContext context,
    AppSettings settings,
  ) => _section(context, '链接识别', [
    SwitchListTile.adaptive(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      secondary: _settingIcon(context, CupertinoIcons.doc_on_clipboard),
      title: const Text('自动识别剪贴板链接', style: TextStyle(fontSize: 14)),
      subtitle: Text(
        '启动或返回应用时识别分享、磁力和种子链接，点击后填入解析。',
        style: TextStyle(fontSize: 12, height: 1.5, color: secondary(context)),
      ),
      value: settings.clipboardRecognition,
      onChanged: (value) =>
          services.updateSettings({'clipboardRecognition': value}),
    ),
  ]);

  Widget _downloads(BuildContext context, AppSettings settings) =>
      _section(context, '下载设置', [
        _tile(
          context,
          CupertinoIcons.arrow_down_circle,
          'HTTP 下载连接数',
          '单个下载的连接上限',
          () => _number(context, '全局连接数', 'threads', settings.threads, 1, 512),
          value: '${settings.threads}',
        ),
        _platformThreads(context, settings),
        _tile(
          context,
          CupertinoIcons.arrow_2_circlepath,
          '失败重试次数',
          '',
          () => _number(context, '失败重试次数', 'retries', settings.retries, 0, 3),
          value: '${settings.retries} 次',
        ),
        _tile(
          context,
          CupertinoIcons.speedometer,
          '单任务限速',
          '',
          () async {
            final text = await askText(
              context,
              '限速（KB/s）',
              initial: '${settings.speedLimit ~/ 1024}',
              hint: '0 表示不限速',
              numeric: true,
            );
            if (text == null || !context.mounted) return;
            final value = int.tryParse(text);
            if (value == null || value < 0 || value > 10000000) {
              message(context, '请输入有效的速度');
              return;
            }
            await services.updateSettings({'speedLimit': value * 1024});
          },
          value: settings.speedLimit == 0
              ? '不限速'
              : '${formatBytes(settings.speedLimit)}/s',
        ),
        _tile(
          context,
          CupertinoIcons.folder,
          '下载保存目录',
          settings.destination ?? '系统下载目录',
          () async {
            final directory = await busy(
              context,
              services.files.chooseDirectory,
              label: '选择下载目录…',
            );
            if (directory != null) {
              await services.updateSettings({'destination': directory});
            }
          },
        ),
        if (settings.destination != null)
          Padding(
            padding: const EdgeInsets.only(left: 54, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => services.updateSettings({'destination': null}),
                child: const Text('恢复默认目录'),
              ),
            ),
          ),
        if (services.platformFeatures &&
            (Platform.isAndroid || Platform.isWindows))
          _tile(
            context,
            CupertinoIcons.shield_lefthalf_fill,
            '后台下载保护',
            Platform.isWindows ? '托盘下载与自动休眠保护' : '锁屏下载、通知与系统后台设置',
            () => Navigator.push<void>(
              context,
              MaterialPageRoute(builder: (_) => const DownloadProtectionPage()),
            ),
          ),
      ], footer: '设置用于新添加的任务。实际连接数由文件大小与服务器决定；BT 最多连接 80 个对等节点。');

  Widget _data(BuildContext context) => _section(context, '备份与数据', [
    _tile(
      context,
      CupertinoIcons.lock_shield,
      '导出加密备份',
      '保存账号与应用设置',
      () => _export(context),
    ),
    _tile(
      context,
      CupertinoIcons.arrow_up_doc,
      '恢复备份',
      '从已有备份中导入',
      () => _restore(context),
    ),
    if (services.migrationError != null)
      _tile(
        context,
        CupertinoIcons.arrow_2_squarepath,
        '旧版数据导入',
        services.migrationError!,
        () => busy(context, services.retryLegacyImport, label: '读取旧版数据…'),
      ),
  ]);

  Widget _help(BuildContext context) => _section(context, '帮助与诊断', [
    _tile(
      context,
      CupertinoIcons.arrow_down_circle,
      '检查更新',
      services.control.checking
          ? '正在检查…'
          : services.control.availableUpdate != null
          ? '发现新版本 ${services.control.availableUpdate!.version}'
          : '当前版本 ${applicationVersion.split('+').first}',
      () =>
          checkForAppUpdate(context, services.control, launcher: linkLauncher),
    ),
    _tile(
      context,
      CupertinoIcons.question_circle,
      '使用帮助',
      services.control.config.helpUrl?.host ?? '暂未提供帮助链接',
      () {
        final url = services.control.config.helpUrl;
        if (url == null) {
          message(context, '暂未提供帮助链接');
        } else {
          openRemoteLink(context, url, launcher: linkLauncher);
        }
      },
    ),
    _tile(
      context,
      CupertinoIcons.link,
      '项目地址',
      'github.com/z7786/wenxi',
      () => openRemoteLink(
        context,
        Uri.parse('https://github.com/z7786/wenxi'),
        launcher: linkLauncher,
      ),
    ),
    _tile(
      context,
      CupertinoIcons.doc_text_search,
      '日志与故障排查',
      '查看、导出崩溃与操作日志',
      () => Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => DiagnosticsPage(
            DiagnosticBundle(
              DiagnosticLog.active ?? DiagnosticLog.open(null),
              snapshot: services.diagnostics,
              nativeEnabled: services.platformFeatures,
            ),
            linkLauncher: linkLauncher,
          ),
        ),
      ),
    ),
    _tile(
      context,
      CupertinoIcons.envelope,
      '联系作者/侵权投诉',
      authorEmail,
      () => showContactAuthorDialog(context),
    ),
  ]);

  Widget _identity(BuildContext context, bool desktop) => Row(
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.asset('assets/icons/app.png', width: 44, height: 44),
      ),
      const SizedBox(width: 13),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '文析助手',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '版本 ${applicationVersion.split('+').first}',
              style: TextStyle(fontSize: 12, color: secondary(context)),
            ),
          ],
        ),
      ),
      if (desktop)
        Text('应用设置', style: TextStyle(fontSize: 12, color: secondary(context))),
    ],
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([services.store, services]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, bounds) {
        final settings = services.settings;
        final desktop = Theme.of(context).platform == TargetPlatform.windows;
        final columns =
            desktop &&
            bounds.maxWidth >= 880 &&
            MediaQuery.textScalerOf(context).scale(14) <= 21;
        final downloads = _downloads(context, settings);
        final appearance = _appearance(context, settings, desktop);
        final recognition = _linkRecognition(context, settings);
        final data = _data(context);
        final help = _help(context);
        return ListView(
          key: const PageStorageKey('mine'),
          padding: EdgeInsets.fromLTRB(
            desktop ? 28 : 18,
            desktop ? 24 : 18,
            desktop ? 28 : 18,
            28 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            _identity(context, desktop),
            SizedBox(height: desktop ? 26 : 24),
            if (columns)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: downloads),
                  const SizedBox(width: 22),
                  Expanded(
                    flex: 2,
                    child: Column(
                      children: [
                        appearance,
                        const SizedBox(height: 24),
                        recognition,
                        const SizedBox(height: 24),
                        data,
                        const SizedBox(height: 24),
                        help,
                      ],
                    ),
                  ),
                ],
              )
            else ...[
              appearance,
              const SizedBox(height: 24),
              recognition,
              const SizedBox(height: 24),
              downloads,
              const SizedBox(height: 24),
              data,
              const SizedBox(height: 24),
              help,
            ],
          ],
        );
      },
    ),
  );
}
