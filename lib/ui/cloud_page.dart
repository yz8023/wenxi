import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../domain/auth.dart';
import '../domain/models.dart';
import 'browser_page.dart';
import 'common.dart';
import 'login_page.dart';
import 'parse_page.dart';

Color quotaColor(int used, int total) {
  final ratio = total > 0 ? used / total : 0.0;
  if (ratio >= .9) return const Color(0xffff3b30);
  if (ratio >= .7) return const Color(0xffff9500);
  return const Color(0xff34c759);
}

const cloudEntries = <(String, String, CloudPlatform?)>[
  ('quark', '夸克网盘', CloudPlatform.quark),
  ('123', '123网盘', CloudPlatform.pan123),
  ('guangya', '光鸭云盘', CloudPlatform.guangya),
  ('baidu', '百度网盘', CloudPlatform.baidu),
  ('ali', '阿里云盘', CloudPlatform.aliyun),
  ('weiyun', '腾讯微云', CloudPlatform.weiyun),
  ('xunlei', '迅雷网盘', CloudPlatform.xunlei),
  ('uc', 'UC网盘', CloudPlatform.uc),
  ('yidong', '移动网盘', CloudPlatform.c139),
  ('tianyi', '天翼网盘', CloudPlatform.tianyi),
  ('115', '115网盘', CloudPlatform.pan115),
  ('wopan', '中国联通云盘', CloudPlatform.wopan),
  ('lanzous', '蓝奏云优享版', CloudPlatform.ilanzou),
  ('lanzous', '蓝奏云', CloudPlatform.lanzou),
];

class CloudPage extends StatelessWidget {
  const CloudPage(this.services, {super.key, this.onParseShare});
  final AppServices services;
  final VoidCallback? onParseShare;
  Future<void> _parseLanzou(BuildContext context) async {
    if (!allowCloudAction(context, services.control, CloudPlatform.lanzou)) {
      return;
    }
    if (onParseShare != null) {
      onParseShare!();
      message(context, '支持不登录解析');
    } else {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => PageFrame(title: '蓝奏云解析', child: ParsePage(services)),
        ),
      );
    }
  }

  Future<void> _open(BuildContext context, CloudPlatform? platform) async {
    if (platform == null) {
      message(context, '该网盘暂未开放');
      return;
    }
    if (!allowCloudAction(context, services.control, platform)) return;
    if (platform == CloudPlatform.lanzou &&
        !LoginCredentials.stored(
          platform,
          services.vault.credential(platform),
        )) {
      await _parseLanzou(context);
      return;
    }
    if (!LoginCredentials.stored(
          platform,
          services.vault.credential(platform),
        ) ||
        services.accountNeedsLogin.contains(platform)) {
      await openLogin(context, services, platform);
      return;
    }
    final session = await busy(
      context,
      () => services.cloud.personal(platform),
      label: '正在打开${platform.shortName}…',
    );
    if (session != null && context.mounted) {
      Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => BrowserPage(services, session)),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: services,
    builder: (context, _) => RefreshIndicator(
      onRefresh: services.refreshAccounts,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              constraints.maxWidth >= 800 &&
              MediaQuery.textScalerOf(context).scale(15) <= 21;
          final entries = cloudEntries
              .where((entry) => entry.$3 != null)
              .toList(growable: false);
          return CustomScrollView(
            key: const PageStorageKey('cloud-list'),
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (services.migrationError != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      services.migrationError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                sliver: wide
                    ? SliverGrid(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => _card(context, entries[index]),
                          childCount: entries.length,
                        ),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 16,
                              mainAxisExtent: 86,
                            ),
                      )
                    : SliverList.separated(
                        itemCount: entries.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) =>
                            _card(context, entries[index]),
                      ),
              ),
            ],
          );
        },
      ),
    ),
  );
  Widget _card(BuildContext context, (String, String, CloudPlatform?) entry) {
    final platform = entry.$3,
        credential = platform == null
            ? null
            : services.vault.credential(platform);
    final active =
        platform != null && LoginCredentials.stored(platform, credential);
    final paused = platform != null && !services.control.cloudEnabled(platform);
    final customName = platform == null
        ? ''
        : services.vault
                  .profiles(platform)
                  .where((a) => a.active)
                  .firstOrNull
                  ?.customName ??
              '';
    final account = services.accounts[platform],
        quota =
            active &&
            !paused &&
            (services.accounts[platform]?.total ?? 0) > 0 &&
            !services.accountErrors.containsKey(platform);
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border(context), width: .6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .085),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open(context, platform),
          onLongPress: platform == null || !platform.requiresAccount
              ? null
              : () => accountMenu(context, services, platform),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  PlatformMark(icon: entry.$1),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                entry.$2,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: platform == null || paused
                                      ? secondary(context)
                                      : null,
                                ),
                              ),
                            ),
                            if (platform == null || paused)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: fill(context),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  paused ? '暂停服务' : '暂未开放',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: secondary(context),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        if (customName.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(
                              customName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: brandBlue,
                              ),
                            ),
                          ),
                        if (paused)
                          Text(
                            services.control.config
                                .cloud(platform)
                                .reason(platform),
                            key: ValueKey('cloud-disabled-${platform.name}'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: secondary(context),
                            ),
                          )
                        else if (quota) ...[
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: formatBytes(account!.used),
                                  style: TextStyle(
                                    color: quotaColor(
                                      account.used,
                                      account.total,
                                    ),
                                  ),
                                ),
                                TextSpan(
                                  text: ' / ${formatBytes(account.total)}',
                                  style: TextStyle(color: secondary(context)),
                                ),
                              ],
                            ),
                            style: const TextStyle(fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 5),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: (account.used / account.total).clamp(0, 1),
                              minHeight: 3,
                              key: ValueKey('quota-${platform.key}'),
                              color: quotaColor(account.used, account.total),
                              semanticsLabel: '存储空间占用百分比',
                              semanticsValue:
                                  '${(account.used / account.total * 100).clamp(0, 100).round()}',
                              backgroundColor: fill(context),
                            ),
                          ),
                        ] else if (active &&
                            services.accountErrors.containsKey(platform) &&
                            !services.accountLoading.contains(platform))
                          InkWell(
                            key: ValueKey('quota-retry-${platform.key}'),
                            onTap: () =>
                                services.accountNeedsLogin.contains(platform)
                                ? openLogin(context, services, platform)
                                : services.refreshAccount(platform),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  const Icon(
                                    CupertinoIcons.arrow_clockwise,
                                    size: 13,
                                    color: brandBlue,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      services.accountErrors[platform]!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: brandBlue,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          Text(
                            platform == CloudPlatform.lanzou && !active
                                ? '支持不登录解析'
                                : active
                                ? services.accountLoading.contains(platform)
                                      ? '正在读取容量…'
                                      : services.accountErrors[platform] ??
                                            account?.nickname ??
                                            credential?.field('nickname') ??
                                            '已登录'
                                : '未登录',
                            style: TextStyle(
                              fontSize: 13,
                              color: secondary(context),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (platform == CloudPlatform.lanzou)
                    IconButton(
                      tooltip: '${entry.$2}解析',
                      onPressed: () => _parseLanzou(context),
                      icon: const Icon(
                        CupertinoIcons.link,
                        size: 17,
                        color: brandBlue,
                      ),
                    ),
                  IconButton(
                    tooltip: '${entry.$2}账号操作',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 40,
                    ),
                    icon: Icon(
                      CupertinoIcons.ellipsis,
                      size: 21,
                      color: secondary(context),
                    ),
                    onPressed: () => platform == null
                        ? message(context, '该网盘暂未开放')
                        : active
                        ? accountMenu(context, services, platform)
                        : openLogin(context, services, platform),
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
