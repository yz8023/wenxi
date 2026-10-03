import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../data/state_store.dart';
import '../domain/models.dart';
import 'app_popup_menu.dart';
import 'common.dart';
import 'login_page.dart';
import 'uc_tv_authorization_page.dart';

class CloudAccountsPage extends StatelessWidget {
  const CloudAccountsPage(this.services, {super.key, this.platform});
  final AppServices services;
  final CloudPlatform? platform;

  Future<void> _action(
    BuildContext context,
    CloudAccountProfile account,
    String action,
  ) async {
    switch (action) {
      case 'rename':
        final name = await askText(
          context,
          '自定义账号名称',
          initial: account.customName,
          hint: '留空使用网盘昵称',
        );
        if (name != null && context.mounted) {
          await busy(
            context,
            () => services.vault.renameAccount(
              account.platform,
              account.id,
              name,
            ),
          );
        }
      case 'login':
        await openLogin(
          context,
          services,
          account.platform,
          accountId: account.id,
        );
      case 'tv':
        await openUcTvAuthorization(context, services, accountId: account.id);
      case 'remove':
        if (await confirm(
              context,
              '移除账号',
              '移除“${account.name}”及其本地收藏？网盘内的文件不会删除。该账号的下载和播放将无法再刷新链接。',
              action: '移除',
              destructive: true,
            ) &&
            context.mounted) {
          await busy(
            context,
            () => services.removeCloudAccount(account.platform, account.id),
          );
        }
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: platform == null ? '网盘账号管理' : '${platform!.shortName}账号管理',
    child: AnimatedBuilder(
      animation: services.store,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '点击账号切换使用，下载、播放和收藏保留各自的账号归属。',
            style: TextStyle(fontSize: 13, color: secondary(context)),
          ),
          const SizedBox(height: 16),
          for (final p in CloudPlatform.values.where(
            (p) => p.requiresAccount && (platform == null || platform == p),
          )) ...[
            Row(
              children: [
                PlatformMark(platform: p, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    p.label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton.icon(
                  key: ValueKey('account-add-${p.key}'),
                  onPressed: () =>
                      openLogin(context, services, p, addAccount: true),
                  icon: const Icon(CupertinoIcons.add, size: 16),
                  label: const Text('添加账号'),
                ),
              ],
            ),
            if (services.vault.profiles(p).isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(38, 4, 0, 16),
                child: Text(
                  '还没有保存的账号',
                  style: TextStyle(color: secondary(context), fontSize: 13),
                ),
              ),
            for (final account in services.vault.profiles(p))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: account.active
                      ? brandBlue.withValues(alpha: .07)
                      : Theme.of(context).colorScheme.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: border(context)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    key: ValueKey('account-${account.id}'),
                    leading: Icon(
                      account.active
                          ? CupertinoIcons.checkmark_circle_fill
                          : CupertinoIcons.person_crop_circle,
                      color: account.active ? brandBlue : secondary(context),
                    ),
                    title: Text(
                      account.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        if (account.customName.isNotEmpty &&
                            account.nickname.isNotEmpty)
                          '网盘昵称：${account.nickname}',
                        account.active ? '当前使用' : '点击切换到此账号',
                      ].join('\n'),
                    ),
                    onTap: account.active
                        ? null
                        : () async {
                            await busy(
                              context,
                              () => services.switchCloudAccount(p, account.id),
                            );
                          },
                    trailing: AppPopupMenuButton<String>(
                      tooltip: '${account.name}的账号操作',
                      icon: CupertinoIcons.ellipsis,
                      onSelected: (action) => _action(context, account, action),
                      actions: [
                        const AppMenuAction(
                          value: 'rename',
                          label: '自定义名称',
                          icon: CupertinoIcons.pencil,
                        ),
                        const AppMenuAction(
                          value: 'login',
                          label: '重新登录',
                          icon: CupertinoIcons.arrow_clockwise,
                        ),
                        if (p == CloudPlatform.uc)
                          const AppMenuAction(
                            value: 'tv',
                            label: 'TV 播放授权',
                            icon: CupertinoIcons.tv,
                          ),
                        const AppMenuAction(
                          value: 'remove',
                          label: '移除账号',
                          icon: CupertinoIcons.trash,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    ),
  );
}
