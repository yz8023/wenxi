import 'package:flutter/cupertino.dart';
import '../data/remote_control_service.dart';
import 'app_popup_menu.dart';
import 'remote_control_dialogs.dart';

class ParseMenuButton extends StatelessWidget {
  const ParseMenuButton({
    super.key,
    required this.control,
    required this.onDonate,
    this.linkLauncher,
  });

  final RemoteControlService control;
  final VoidCallback onDonate;
  final RemoteLinkLauncher? linkLauncher;

  @override
  Widget build(BuildContext context) => AppPopupMenuButton<String>(
    tooltip: '更多操作',
    icon: CupertinoIcons.ellipsis,
    actions: const [
      AppMenuAction(
        value: 'announcement',
        label: '软件公告',
        icon: CupertinoIcons.bell,
      ),
      AppMenuAction(value: 'donate', label: '打赏作者', icon: CupertinoIcons.gift),
    ],
    onSelected: (action) async {
      if (action == 'announcement') {
        await openLatestAnnouncement(context, control, launcher: linkLauncher);
      } else if (action == 'donate') {
        onDonate();
      }
    },
  );
}
