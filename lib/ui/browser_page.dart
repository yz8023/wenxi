import 'dart:async';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../core/operation_progress.dart';
import '../data/http.dart';
import '../domain/models.dart';
import '../diagnostics/app_log.dart';
import 'app_popup_menu.dart';
import 'common.dart';
import 'cloud_thumbnail.dart';
import 'cloud_upload_dialog.dart';
import 'login_page.dart';
import 'preview_page.dart';
import 'cloud_favorites_page.dart';
import 'cleanup_progress.dart';
import 'loading_indicator.dart';

class BrowserPage extends StatefulWidget {
  const BrowserPage(
    this.services,
    this.session, {
    super.key,
    this.picking = false,
    this.excludedFolders = const {},
    this.initialItems,
    this.initialTrail,
    this.highlightedFileId,
  });
  final AppServices services;
  final BrowseSession session;
  final bool picking;
  final Set<String> excludedFolders;
  final List<CloudFile>? initialItems;
  final List<(String, String)>? initialTrail;
  final String? highlightedFileId;
  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  late BrowseSession session = widget.services.cloud.bindSession(
    widget.session,
  );
  late final stack = <(String, String)>[
    ...widget.initialTrail ?? [(session.rootId, '全部文件')],
  ];
  late int? accountRevision = widget.services.cloud
      .sessionCredential(session)
      ?.updatedAt;
  late String? highlight = widget.highlightedFileId;
  late List<CloudFile> items = List.of(widget.initialItems ?? const []);
  final selected = <String>{}, search = TextEditingController();
  final _progress = OperationProgress();
  late bool loading = widget.initialItems == null;
  bool ascending = true, changingAccount = false, pickingUpload = false;
  late String view = widget.services.settings.browserView;
  String error = '', sort = 'name';
  int generation = 0;
  RequestScope? request;
  late bool _available = widget.services.control.cloudEnabled(session.platform);
  @override
  void initState() {
    super.initState();
    if (highlight != null) {
      search.text =
          items.where((f) => f.id == highlight).firstOrNull?.name ?? '';
    }
    widget.services.control.addListener(_controlChanged);
    widget.services.store.addListener(_profileChanged);
    if (widget.initialItems == null) _load();
  }

  @override
  void dispose() {
    widget.services.control.removeListener(_controlChanged);
    widget.services.store.removeListener(_profileChanged);
    request?.cancel();
    _progress.dispose();
    search.dispose();
    super.dispose();
  }

  void _controlChanged() {
    final available = widget.services.control.cloudEnabled(session.platform);
    if (!mounted) return;
    if (available == _available) {
      if (!available) setState(() {});
      return;
    }
    _available = available;
    if (available) {
      unawaited(_load());
    } else {
      request?.cancel();
      _progress.close(cancelled: true);
      generation++;
      setState(() {
        loading = false;
        selected.clear();
      });
    }
  }

  void _profileChanged() {
    if (mounted) setState(() {});
  }

  void _checkAccount() {
    widget.services.control.checkCloud(session.platform);
    require(
      accountRevision ==
          widget.services.cloud.sessionCredential(session)?.updatedAt,
      '账号已变化，请重新打开文件列表',
    );
  }

  Credential? get _thumbnailCredential {
    final current = widget.services.cloud.sessionCredential(session);
    return current?.updatedAt == accountRevision ? current : null;
  }

  Future<void> _load() async {
    request?.cancel();
    final current = ++generation,
        scope = request = RequestScope(),
        parent = stack.last.$1;
    setState(() {
      loading = true;
      error = '';
      selected.clear();
    });
    try {
      _checkAccount();
      final files = await scope.run(
        () => _progress.run(() => widget.services.cloud.list(session, parent)),
      );
      _checkAccount();
      if (!mounted || current != generation) return;
      _progress.close();
      setState(() {
        items = files;
        loading = false;
      });
    } catch (e) {
      if (!mounted || current != generation) return;
      _progress.close();
      setState(() {
        loading = false;
        error = errorText(e);
        items = [];
      });
    }
  }

  void _enter(CloudFile file) {
    if (!allowCloudAction(context, widget.services.control, session.platform)) {
      return;
    }
    stack.add((widget.services.cloud.directoryId(session, file), file.name));
    highlight = null;
    search.clear();
    _load();
  }

  List<CloudFile> get displayed {
    final query = search.text.trim().toLowerCase();
    final result = items
        .where(
          (f) =>
              f.name.toLowerCase().contains(query) &&
              (!widget.picking ||
                  f.isDirectory &&
                      !widget.excludedFolders.contains(
                        widget.services.cloud.directoryId(session, f),
                      )),
        )
        .toList();
    result.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      final order = switch (sort) {
        'size' => a.size.compareTo(b.size),
        'date' => a.modifiedAt.compareTo(b.modifiedAt),
        _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      };
      return ascending ? order : -order;
    });
    return result;
  }

  Future<void> _download(List<CloudFile> files) async {
    final added = await busy<int>(context, () async {
      _checkAccount();
      final collected = await widget.services.cloud.collect(session, files);
      _checkAccount();
      if (collected.isEmpty) return 0;
      final specs = [
        for (final item in collected)
          widget.services.cloud
              .planDownload(session, item.$1)
              .copyWith(relativePath: item.$2),
      ];
      final ids = await widget.services.downloads.enqueueAll(specs);
      return ids.length;
    }, label: '正在添加下载任务…');
    if (mounted && added != null && added > 0) {
      setState(() => selected.clear());
      message(
        context,
        '已添加 $added 个下载任务',
        onTap: widget.services.requestDownloadManager,
      );
    }
  }

  Future<String?> _destination(List<CloudFile> files) async {
    final personal = await busy(
      context,
      () => session.mode == BrowseMode.personal
          ? widget.services.cloud.reopenSpace(session)
          : widget.services.cloud.personal(
              session.platform,
              accountId: session.accountId,
            ),
      label: '读取目标目录…',
    );
    if (personal == null || !mounted) return null;
    return Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => BrowserPage(
          widget.services,
          personal,
          picking: true,
          excludedFolders: session.mode == BrowseMode.personal
              ? files
                    .where((f) => f.isDirectory)
                    .map((f) => widget.services.cloud.directoryId(session, f))
                    .toSet()
              : {},
        ),
      ),
    );
  }

  Future<void> _operate(String action, List<CloudFile> files) async {
    if (files.isEmpty) return;
    if (!allowCloudAction(context, widget.services.control, session.platform)) {
      return;
    }
    final connector = widget.services.cloud.connector(session.platform);
    if (action == 'favorite') {
      final saved = await busy(context, () async {
        _checkAccount();
        return widget.services.favorites.toggle(session, files.first, stack);
      });
      if (mounted && saved != null) {
        setState(() {});
        message(context, saved ? '已添加到网盘收藏' : '已取消收藏');
      }
      return;
    }
    if (action == 'download') {
      await _download(files);
      return;
    }
    if (action == 'preview') {
      _checkAccount();
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => PreviewPage(
            widget.services,
            session,
            files.first,
            playlist: displayed,
          ),
        ),
      );
      return;
    }
    if (action == 'copy') {
      await busy(context, () async {
        _checkAccount();
        final spec = await widget.services.cloud.prepare(session, files.first);
        await widget.services.copyText(spec.url);
        await widget.services.cleanups.release(spec.cleanup);
        // Copied temporary links stay valid until the next application start.
        if (mounted) message(context, '下载链接已复制；临时链接请及时使用');
      });
      return;
    }
    String? target, name;
    ShareOptions? options;
    if (action == 'rename') {
      name = await askText(context, '重命名', initial: files.first.name);
      if (name == null || name.trim().isEmpty || !mounted) return;
    }
    if (action == 'move' || action == 'save') {
      target = await _destination(files);
      if (target == null || !mounted) return;
    }
    if (action == 'delete') {
      if (!await confirm(
            context,
            '删除网盘文件',
            '确认删除选中的 ${files.length} 项？\n${files.take(3).map((f) => f.name).join('\n')}',
            action: '删除',
            destructive: true,
          ) ||
          !mounted) {
        return;
      }
    }
    if (action == 'share') {
      options = await showDialog<ShareOptions>(
        context: context,
        builder: (_) => _ShareOptionsDialog(files, session.platform),
      );
      if (options == null || !mounted) return;
    }
    final result = await busy<Object>(
      context,
      () => widget.services.cloud.withSession(session, () async {
        _checkAccount();
        final c = widget.services.cloud.credential(session.platform);
        switch (action) {
          case 'rename':
            require(
              name!.trim().isNotEmpty &&
                  !RegExp(r'[/\\\x00-\x1f]').hasMatch(name),
              '文件名不能包含路径分隔符',
            );
            await connector.rename(session, files.first, name.trim(), c);
          case 'move':
            await connector.move(session, files, target!, c);
          case 'delete':
            await connector.delete(session, files, c);
          case 'save':
            await OperationProgress.step(
              OperationStage.transfer,
              () => connector.saveShare(session, files, target!, c),
            );
          case 'share':
            return connector.createShare(session, files, options!, c);
        }
        return true;
      }),
    );
    if (!mounted) return;
    if (result is ShareCreation) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('分享已创建'),
          content: SelectableText(result.text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
            TextButton(
              onPressed: () async {
                await widget.services.copyText(result.text);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('复制分享'),
            ),
          ],
        ),
      );
    } else if (result == true) {
      message(context, action == 'save' ? '转存完成' : '操作完成');
      await _load();
    }
  }

  Future<void> _menu(CloudFile file) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: FileGlyph(file.name, directory: file.isDirectory),
                title: Text(file.name, maxLines: 2),
                subtitle: Text(
                  file.isDirectory ? '文件夹' : formatBytes(file.size),
                ),
              ),
              if (!file.isDirectory)
                ListTile(
                  leading: const Icon(CupertinoIcons.eye),
                  title: const Text('预览 / 文件详情'),
                  onTap: () => Navigator.pop(context, 'preview'),
                ),
              ListTile(
                leading: Icon(
                  widget.services.favorites.contains(session, file)
                      ? CupertinoIcons.star_fill
                      : CupertinoIcons.star,
                  color: const Color(0xffe6a23c),
                ),
                title: Text(
                  widget.services.favorites.contains(session, file)
                      ? '取消收藏'
                      : '收藏',
                ),
                onTap: () => Navigator.pop(context, 'favorite'),
              ),
              ListTile(
                leading: const Icon(CupertinoIcons.arrow_down_circle),
                title: const Text('下载'),
                onTap: () => Navigator.pop(context, 'download'),
              ),
              if (!file.isDirectory)
                ListTile(
                  leading: const Icon(CupertinoIcons.link),
                  title: const Text('复制下载链接'),
                  onTap: () => Navigator.pop(context, 'copy'),
                ),
              if (session.mode == BrowseMode.share &&
                  session.platform != CloudPlatform.lanzou &&
                  session.platform.requiresAccount &&
                  session.platform.supportsSharing)
                ListTile(
                  leading: const Icon(CupertinoIcons.folder_badge_plus),
                  title: const Text('转存到我的网盘'),
                  onTap: () => Navigator.pop(context, 'save'),
                )
              else if (session.canManageFiles) ...[
                ListTile(
                  leading: const Icon(CupertinoIcons.pencil),
                  title: const Text('重命名'),
                  onTap: () => Navigator.pop(context, 'rename'),
                ),
                ListTile(
                  leading: const Icon(CupertinoIcons.folder),
                  title: const Text('移动'),
                  onTap: () => Navigator.pop(context, 'move'),
                ),
                if (session.platform.supportsSharing)
                  ListTile(
                    leading: const Icon(CupertinoIcons.share),
                    title: const Text('创建分享'),
                    onTap: () => Navigator.pop(context, 'share'),
                  ),
                ListTile(
                  leading: const Icon(CupertinoIcons.trash, color: Colors.red),
                  title: const Text('删除', style: TextStyle(color: Colors.red)),
                  onTap: () => Navigator.pop(context, 'delete'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (action != null && mounted) await _operate(action, [file]);
  }

  Future<void> _newFolder() async {
    if (!allowCloudAction(context, widget.services.control, session.platform)) {
      return;
    }
    final name = await askText(context, '新建文件夹', hint: '文件夹名称');
    if (name == null || name.trim().isEmpty || !mounted) return;
    final result = await busy(context, () async {
      _checkAccount();
      return widget.services.cloud.createFolder(
        session,
        stack.last.$1,
        name.trim(),
      );
    });
    if (result != null && mounted) await _load();
  }

  Future<void> _upload() async {
    if (pickingUpload) return;
    if (!allowCloudAction(context, widget.services.control, session.platform)) {
      return;
    }
    final parent = stack.last.$1, activeSession = session;
    final revision = accountRevision;
    setState(() => pickingUpload = true);
    try {
      _checkAccount();
      DiagnosticLog.event(
        'upload.pick.start',
        fields: {'platform': activeSession.platform.key},
      );
      final files = await busy(context, () async {
        try {
          return await openFiles();
        } catch (error, stack) {
          DiagnosticLog.error(
            'upload.pick.failed',
            error,
            stack,
            fields: {'platform': activeSession.platform.key},
          );
          throw const AppException('无法读取所选文件，请重新选择，并检查文件权限和可用空间');
        }
      }, label: '正在读取所选文件…');
      if (!mounted || files == null || files.isEmpty) return;
      DiagnosticLog.event(
        'upload.pick.ready',
        fields: {'platform': activeSession.platform.key, 'count': files.length},
      );
      if (!identical(session, activeSession) || accountRevision != revision) {
        throw const AppException('账号或网盘已变化，请重新选择上传文件');
      }
      _checkAccount();
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CloudUploadDialog(
          cloud: widget.services.cloud,
          session: activeSession,
          parent: parent,
          files: files,
        ),
      );
      if (mounted) await _load();
    } catch (error) {
      if (mounted) message(context, errorText(error));
    } finally {
      if (mounted) setState(() => pickingUpload = false);
    }
  }

  Future<void> _accountAction(String action) async {
    if (changingAccount) return;
    if (!allowCloudAction(context, widget.services.control, session.platform)) {
      return;
    }
    setState(() => changingAccount = true);
    try {
      if (action == 'login') {
        await _login();
      } else if (action == 'add') {
        final before = widget.services.vault.activeAccountId(session.platform);
        await openLogin(
          context,
          widget.services,
          session.platform,
          addAccount: true,
        );
        if (!mounted) return;
        final owner = widget.services.vault.activeAccountId(session.platform);
        if (owner != null && owner != before) await _switchAccount(owner);
      } else if (action.startsWith('account:')) {
        final owner = action.substring('account:'.length);
        if (owner != session.accountId ||
            widget.services.vault
                    .credentialFor(session.platform, owner)
                    ?.updatedAt !=
                accountRevision) {
          await _switchAccount(owner);
        }
      }
    } finally {
      if (mounted) setState(() => changingAccount = false);
    }
  }

  Future<(BrowseSession, List<CloudFile>, int?)> _readAccountSession(
    String owner, {
    bool keepSpace = false,
  }) async {
    final previous = session.withAccount(owner);
    final value = await widget.services.cloud.withSession(previous, () async {
      if (previous.mode == BrowseMode.share) {
        final link = previous.sourceLink;
        require(link != null, '原分享信息缺失，请返回首页重新解析');
        return widget.services.cloud.share(link!);
      }
      return keepSpace
          ? widget.services.cloud.reopenSpace(previous)
          : widget.services.cloud.personal(previous.platform, accountId: owner);
    });
    final files = await widget.services.cloud.list(value, value.rootId);
    RequestScope.checkpoint();
    return (
      value,
      files,
      widget.services.cloud.sessionCredential(value)?.updatedAt,
    );
  }

  Future<void> _switchAccount(String owner) async {
    final previous = session;
    final result = await busy(
      context,
      () => _readAccountSession(owner, keepSpace: owner == session.accountId),
      label: '正在切换账号…',
    );
    if (result == null || !mounted || session != previous) return;
    if (widget.services.cloud.sessionCredential(result.$1)?.updatedAt !=
        result.$3) {
      message(context, '账号信息已变化，请重新切换');
      return;
    }
    try {
      await widget.services.switchCloudAccount(session.platform, owner);
      if (!mounted) return;
      await _replaceSession(result.$1, initialItems: result.$2);
    } catch (error) {
      if (mounted) message(context, errorText(error));
    }
  }

  Future<void> _login() async {
    final before = widget.services.cloud.sessionCredential(session)?.updatedAt;
    await openLogin(
      context,
      widget.services,
      session.platform,
      accountId: session.accountId?.isNotEmpty == true
          ? session.accountId
          : null,
    );
    if (!mounted) return;
    final owner = session.accountId?.isNotEmpty == true
        ? session.accountId!
        : widget.services.vault.activeAccountId(session.platform);
    if (owner == null ||
        widget.services.vault
                .credentialFor(session.platform, owner)
                ?.updatedAt ==
            before) {
      return;
    }
    final result = await busy(
      context,
      () => _readAccountSession(owner, keepSpace: true),
      label: '正在更新账号并读取文件…',
    );
    if (result != null && mounted) {
      await _replaceSession(result.$1, initialItems: result.$2);
    }
  }

  Future<void> _replaceSession(
    BrowseSession value, {
    List<CloudFile>? initialItems,
  }) async {
    request?.cancel();
    generation++;
    setState(() {
      session = value;
      accountRevision = widget.services.cloud
          .sessionCredential(value)
          ?.updatedAt;
      highlight = null;
      stack
        ..clear()
        ..add((session.rootId, '全部文件'));
      search.clear();
      items = List.of(initialItems ?? const []);
      selected.clear();
      error = '';
      loading = initialItems == null;
    });
    if (initialItems == null) await _load();
  }

  Future<void> _switchPersonal() async {
    if (!session.isFamily) return;
    final value = await busy(context, () async {
      _checkAccount();
      return widget.services.cloud.personal(
        session.platform,
        accountId: session.accountId,
      );
    }, label: '正在切换个人网盘…');
    if (value != null && mounted) await _replaceSession(value);
  }

  Future<void> _chooseFamily() async {
    final spaces = await busy(context, () async {
      _checkAccount();
      return widget.services.cloud.familySpaces(
        session.platform,
        accountId: session.accountId,
      );
    }, label: '正在读取家庭云…');
    if (spaces == null || !mounted) return;
    if (spaces.isEmpty) {
      message(context, '当前账号还没有家庭云，请先在官方网盘创建或加入家庭');
      return;
    }
    final choice = await showModalBottomSheet<CloudSpace>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  '选择家庭云',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: spaces.length,
                  itemBuilder: (context, index) {
                    final space = spaces[index],
                        active = session.familyId == space.id;
                    return ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      selected: active,
                      selectedTileColor: brandBlue.withValues(alpha: .07),
                      leading: const Icon(
                        CupertinoIcons.person_2,
                        color: brandBlue,
                      ),
                      title: Text(
                        space.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: active
                          ? const Icon(
                              CupertinoIcons.checkmark,
                              color: brandBlue,
                              size: 18,
                            )
                          : null,
                      onTap: () => Navigator.pop(context, space),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted || choice.id == session.familyId) return;
    final value = await busy(context, () async {
      _checkAccount();
      return widget.services.cloud.family(
        session.platform,
        choice.id,
        accountId: session.accountId,
      );
    }, label: '正在切换家庭云…');
    if (value != null && mounted) await _replaceSession(value);
  }

  Future<void> _choosePersonalSpace() async {
    final previous = session;
    final spaces = await busy(context, () async {
      _checkAccount();
      return widget.services.cloud.personalSpaces(
        session.platform,
        accountId: session.accountId,
      );
    }, label: '正在读取存储空间…');
    if (spaces == null || !mounted || session != previous) return;
    final choice = await showModalBottomSheet<CloudSpace>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '选择存储空间',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
            for (final space in spaces)
              ListTile(
                leading: const Icon(CupertinoIcons.cloud, color: brandBlue),
                title: Text(space.name),
                selected: space.id == session.personalSpaceId,
                trailing: space.id == session.personalSpaceId
                    ? const Icon(CupertinoIcons.checkmark, color: brandBlue)
                    : null,
                onTap: () => Navigator.pop(context, space),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (choice == null ||
        !mounted ||
        session != previous ||
        choice.id == session.personalSpaceId) {
      return;
    }
    final value = await busy(context, () async {
      _checkAccount();
      return widget.services.cloud.personal(
        session.platform,
        accountId: session.accountId,
        spaceId: choice.id,
      );
    }, label: '正在切换存储空间…');
    if (value != null && mounted && session == previous) {
      await _replaceSession(value);
    }
  }

  Future<void> _changeView(String value) async {
    if (view == value) return;
    try {
      await widget.services.updateSettings({'browserView': value});
      if (mounted) setState(() => view = value);
    } catch (_) {
      if (mounted) message(context, '显示方式保存失败，请重试');
    }
  }

  Widget _spaceSelector() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: fill(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (final family in [false, true])
            Expanded(
              child: Tooltip(
                message: family ? '切换家庭云' : '切换个人网盘',
                child: TextButton(
                  key: ValueKey(family ? 'family-space' : 'personal-space'),
                  style: TextButton.styleFrom(
                    foregroundColor: family == session.isFamily
                        ? brandBlue
                        : secondary(context),
                    backgroundColor: family == session.isFamily
                        ? Theme.of(context).colorScheme.surface
                        : Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                  ),
                  onPressed: family ? _chooseFamily : _switchPersonal,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (MediaQuery.textScalerOf(context).scale(13) <= 18) ...[
                        Icon(
                          family
                              ? CupertinoIcons.person_2
                              : CupertinoIcons.person,
                          size: 17,
                        ),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          family
                              ? session.isFamily
                                    ? session.meta('familyName').ifEmpty('家庭云')
                                    : '家庭云'
                              : '个人网盘',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (family) ...[
                        const SizedBox(width: 6),
                        const Icon(CupertinoIcons.chevron_down, size: 10),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  void _toggle(CloudFile file) => setState(() {
    if (!selected.add(file.id)) selected.remove(file.id);
  });

  void _open(CloudFile file) {
    if (selected.isNotEmpty) {
      _toggle(file);
    } else if (file.isDirectory) {
      _enter(file);
    } else {
      _operate('preview', [file]);
    }
  }

  Widget _fileList(List<CloudFile> files, BoxConstraints constraints) {
    final key = ValueKey(
      '${session.platform.name}:${session.mode.name}:${session.familyId}:${session.personalSpaceId}:${stack.last.$1}:$view',
    );
    if (view == 'grid' && !widget.picking) {
      final columns = ((constraints.maxWidth - 20) / 180).round().clamp(1, 8);
      final width = (constraints.maxWidth - 32 - (columns - 1) * 12) / columns;
      final mediaHeight = (width - 16) * .72;
      final scaler = MediaQuery.textScalerOf(context);
      final titleHeight = scaler.scale(14) * 1.35 * 2;
      return GridView.builder(
        key: key,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 20),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          mainAxisExtent:
              mediaHeight + titleHeight + scaler.scale(11) * 1.3 + 30,
        ),
        itemCount: files.length,
        itemBuilder: (context, index) => _gridCard(
          files[index],
          width,
          mediaHeight,
          titleHeight,
          constraints.maxWidth >= 750,
        ),
      );
    }
    return ListView.builder(
      key: key,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: files.length,
      itemBuilder: (context, index) =>
          _listRow(files[index], constraints.maxWidth >= 750),
    );
  }

  Widget _listRow(CloudFile file, bool wide) {
    final checked = selected.contains(file.id);
    return GestureDetector(
      onSecondaryTap: widget.picking ? null : () => _menu(file),
      child: ListTile(
        dense: true,
        minVerticalPadding: 11,
        selected: checked || file.id == highlight,
        selectedTileColor: brandBlue.withValues(alpha: .07),
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if ((selected.isNotEmpty || wide) && !widget.picking)
              Checkbox(value: checked, onChanged: (_) => _toggle(file)),
            CloudThumbnail(
              file,
              session.platform,
              credential: _thumbnailCredential,
            ),
          ],
        ),
        title: Text(
          file.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14),
        ),
        subtitle: Text(
          file.isDirectory ? '文件夹' : formatBytes(file.size),
          style: TextStyle(fontSize: 11, color: secondary(context)),
        ),
        trailing: widget.picking
            ? const Icon(CupertinoIcons.chevron_right, size: 14)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (wide)
                    SizedBox(
                      width: 150,
                      child: Text(
                        file.modifiedAt,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: secondary(context),
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: '${file.name}操作',
                    icon: const Icon(CupertinoIcons.ellipsis, size: 20),
                    onPressed: () => _menu(file),
                  ),
                ],
              ),
        onLongPress: widget.picking ? null : () => _toggle(file),
        onTap: () => _open(file),
      ),
    );
  }

  Widget _gridCard(
    CloudFile file,
    double width,
    double mediaHeight,
    double titleHeight,
    bool wide,
  ) {
    final checked = selected.contains(file.id);
    return Semantics(
      selected: checked,
      child: GestureDetector(
        onSecondaryTap: () => _menu(file),
        child: Material(
          color: checked || file.id == highlight
              ? brandBlue.withValues(alpha: .07)
              : Theme.of(context).colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: checked
                  ? brandBlue
                  : border(context).withValues(alpha: .7),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _open(file),
            onLongPress: () => _toggle(file),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      CloudThumbnail(
                        file,
                        session.platform,
                        credential: _thumbnailCredential,
                        width: width - 16,
                        height: mediaHeight,
                        large: true,
                      ),
                      if (wide || selected.isNotEmpty)
                        Positioned(
                          left: 2,
                          top: 2,
                          child: Material(
                            color: Theme.of(
                              context,
                            ).colorScheme.surface.withValues(alpha: .92),
                            borderRadius: BorderRadius.circular(8),
                            child: Checkbox(
                              value: checked,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onChanged: (_) => _toggle(file),
                            ),
                          ),
                        ),
                      Positioned(
                        right: 0,
                        top: 0,
                        child: IconButton(
                          tooltip: '${file.name}操作',
                          icon: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surface.withValues(alpha: .92),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              CupertinoIcons.ellipsis,
                              size: 18,
                            ),
                          ),
                          onPressed: () => _menu(file),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: titleHeight,
                    child: Text(
                      file.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, height: 1.35),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    file.isDirectory ? '文件夹' : formatBytes(file.size),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.3,
                      color: secondary(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _browserToolbar(List<CloudFile> files) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 8, 10),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final field = TextField(
          controller: search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: '搜索当前文件夹',
            prefixIcon: const Icon(CupertinoIcons.search, size: 18),
            suffixIcon: search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除搜索，显示全部文件',
                    icon: const Icon(
                      CupertinoIcons.xmark_circle_fill,
                      size: 18,
                    ),
                    onPressed: () => setState(() {
                      search.clear();
                      highlight = null;
                    }),
                  ),
            isDense: true,
          ),
        );
        final controls = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppPopupMenuButton<String>(
              tooltip: '排序',
              icon: CupertinoIcons.sort_down,
              onSelected: (value) => setState(() {
                if (sort == value) {
                  ascending = !ascending;
                } else {
                  sort = value;
                  ascending = true;
                }
              }),
              actions: [
                for (final option in [
                  ('name', '名称', CupertinoIcons.textformat_abc),
                  ('size', '大小', CupertinoIcons.doc),
                  ('date', '时间', CupertinoIcons.clock),
                ])
                  AppMenuAction(
                    value: option.$1,
                    label: option.$2,
                    icon: option.$3,
                    selected: sort == option.$1,
                    detail: sort == option.$1
                        ? ascending
                              ? '↑ 升序'
                              : '↓ 降序'
                        : null,
                  ),
              ],
            ),
            if (!widget.picking)
              AppPopupMenuButton<String>(
                tooltip: '显示方式',
                icon: view == 'grid'
                    ? CupertinoIcons.square_grid_2x2
                    : CupertinoIcons.list_bullet,
                onSelected: _changeView,
                actions: [
                  AppMenuAction(
                    value: 'list',
                    label: '列表',
                    icon: CupertinoIcons.list_bullet,
                    selected: view == 'list',
                  ),
                  AppMenuAction(
                    value: 'grid',
                    label: '大图标',
                    icon: CupertinoIcons.square_grid_2x2,
                    selected: view == 'grid',
                  ),
                ],
              ),
            if (!widget.picking)
              IconButton(
                tooltip: selected.length == files.length ? '取消全选' : '全选',
                icon: const Icon(CupertinoIcons.checkmark_circle, size: 22),
                onPressed: files.isEmpty
                    ? null
                    : () => setState(() {
                        if (selected.length == files.length) {
                          selected.clear();
                        } else {
                          selected.addAll(files.map((f) => f.id));
                        }
                      }),
              ),
          ],
        );
        if (constraints.maxWidth < 360 &&
            MediaQuery.textScalerOf(context).scale(14) > 18) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field,
              const SizedBox(height: 4),
              Align(alignment: Alignment.centerRight, child: controls),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: field),
            controls,
          ],
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.services.control.cloudEnabled(session.platform)) {
      return PageFrame(
        title: session.platform.label,
        child: EmptyPanel(
          '网盘暂时停用',
          widget.services.control.config
              .cloud(session.platform)
              .reason(session.platform),
          icon: CupertinoIcons.pause_circle,
        ),
      );
    }
    final files = displayed,
        selection = items.where((f) => selected.contains(f.id)).toList();
    return PopScope(
      canPop: stack.length == 1 && selected.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (selected.isNotEmpty) {
          setState(selected.clear);
        } else if (stack.length > 1) {
          stack.removeLast();
          _load();
        }
      },
      child: PageFrame(
        title: widget.picking
            ? '选择目标文件夹'
            : session.title.ifEmpty(session.platform.label),
        actions: [
          if (!widget.picking &&
              session.mode == BrowseMode.share &&
              session.sourceLink != null)
            AnimatedBuilder(
              animation: widget.services.store,
              builder: (context, _) {
                final saved = widget.services.favorites.containsShare(session);
                return IconButton(
                  key: const Key('browser-favorite-share'),
                  tooltip: saved ? '取消收藏分享链接' : '收藏分享链接',
                  icon: Icon(
                    saved ? CupertinoIcons.star_fill : CupertinoIcons.star,
                    color: saved ? const Color(0xffe6a23c) : null,
                    size: 21,
                  ),
                  onPressed: () async {
                    final result = await busy(
                      context,
                      () => widget.services.favorites.toggleShare(session),
                    );
                    if (!context.mounted || result == null) return;
                    message(
                      context,
                      result ? '分享链接已收藏，可从首页网盘收藏打开' : '已取消收藏分享链接',
                    );
                  },
                );
              },
            ),
          if (!widget.picking)
            IconButton(
              tooltip: '网盘收藏',
              icon: Icon(
                session.mode == BrowseMode.share
                    ? CupertinoIcons.square_list
                    : CupertinoIcons.star,
                size: 21,
              ),
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => CloudFavoritesPage(
                    widget.services,
                    platform: session.platform,
                    accountId: session.accountId,
                  ),
                ),
              ),
            ),
          if (!widget.picking &&
              session.platform.requiresAccount &&
              (session.mode == BrowseMode.personal ||
                  session.platform != CloudPlatform.lanzou))
            AnimatedBuilder(
              animation: widget.services.store,
              builder: (context, _) => IgnorePointer(
                ignoring: changingAccount,
                child: AppPopupMenuButton<String>(
                  key: const Key('browser-account-menu'),
                  tooltip: '切换或更新账号',
                  icon: CupertinoIcons.person_crop_circle,
                  onSelected: _accountAction,
                  actions: [
                    for (final account in widget.services.vault.profiles(
                      session.platform,
                    ))
                      AppMenuAction(
                        value: 'account:${account.id}',
                        label: account.name,
                        icon: CupertinoIcons.person,
                        selected: account.id == session.accountId,
                      ),
                    const AppMenuAction(
                      value: 'login',
                      label: '更新当前账号',
                      icon: CupertinoIcons.arrow_clockwise,
                    ),
                    const AppMenuAction(
                      value: 'add',
                      label: '添加账号',
                      icon: CupertinoIcons.person_badge_plus,
                    ),
                  ],
                ),
              ),
            ),
          IconButton(
            tooltip: '刷新文件',
            onPressed: loading ? null : _load,
            icon: const Icon(CupertinoIcons.arrow_clockwise, size: 20),
          ),
          if (session.canManageFiles && session.platform.canCreateFolder)
            if (widget.picking)
              IconButton(
                tooltip: '新建文件夹',
                onPressed: _newFolder,
                icon: const Icon(CupertinoIcons.folder_badge_plus, size: 21),
              )
            else
              AppPopupMenuButton<String>(
                key: const Key('browser-add-menu'),
                tooltip: '上传或新建',
                icon: CupertinoIcons.plus,
                onSelected: (action) {
                  if (action == 'upload') {
                    _upload();
                  } else {
                    _newFolder();
                  }
                },
                actions: const [
                  AppMenuAction(
                    value: 'upload',
                    label: '上传文件',
                    icon: CupertinoIcons.cloud_upload,
                  ),
                  AppMenuAction(
                    value: 'folder',
                    label: '新建文件夹',
                    icon: CupertinoIcons.folder_badge_plus,
                  ),
                ],
              ),
        ],
        child: Column(
          children: [
            if (!widget.picking &&
                session.mode == BrowseMode.personal &&
                session.platform.supportsFamilyCloud)
              _spaceSelector(),
            if (session.mode == BrowseMode.personal &&
                session.platform.supportsPersonalSpaces)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('personal-space-selector'),
                    onPressed: changingAccount ? null : _choosePersonalSpace,
                    icon: const Icon(CupertinoIcons.cloud, size: 18),
                    label: Text(
                      '${session.meta('driveName').ifEmpty('存储空间')} ▾',
                    ),
                  ),
                ),
              ),
            CleanupProgress(widget.services.cleanups),
            SizedBox(
              height: 42,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: [
                  for (var i = 0; i < stack.length; i++)
                    Row(
                      children: [
                        if (i > 0)
                          Icon(
                            CupertinoIcons.chevron_right,
                            size: 11,
                            color: secondary(context),
                          ),
                        TextButton(
                          onPressed: i == stack.length - 1
                              ? null
                              : () {
                                  stack.removeRange(i + 1, stack.length);
                                  _load();
                                },
                          child: Text(
                            stack[i].$2,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            _browserToolbar(files),
            if (selection.isNotEmpty)
              Container(
                color: fill(context),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '取消选择',
                        onPressed: () => setState(selected.clear),
                        icon: const Icon(CupertinoIcons.xmark, size: 16),
                      ),
                      Text(
                        '已选 ${selection.length} 项',
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => _operate('download', selection),
                        child: const Text('下载'),
                      ),
                      if (session.mode == BrowseMode.share &&
                          session.platform != CloudPlatform.lanzou &&
                          session.platform.requiresAccount &&
                          session.platform.supportsSharing)
                        TextButton(
                          onPressed: () => _operate('save', selection),
                          child: const Text('转存'),
                        )
                      else if (session.canManageFiles) ...[
                        TextButton(
                          onPressed: () => _operate('move', selection),
                          child: const Text('移动'),
                        ),
                        if (session.platform.supportsSharing)
                          TextButton(
                            onPressed: () => _operate('share', selection),
                            child: const Text('分享'),
                          ),
                        TextButton(
                          onPressed: () => _operate('delete', selection),
                          child: const Text(
                            '删除',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            Expanded(
              child: loading
                  ? Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const AppLoadingIndicator(size: 40),
                              const SizedBox(height: 16),
                              Text(
                                '正在加载网盘文件…',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.5,
                                  color: secondary(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  : error.isNotEmpty
                  ? EmptyPanel(
                      '文件列表读取失败',
                      error,
                      action: TextButton(
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    )
                  : files.isEmpty
                  ? EmptyPanel(
                      search.text.isEmpty ? '文件夹为空' : '没有匹配的文件',
                      widget.picking ? '可选择当前文件夹作为目标' : '下拉刷新文件列表',
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: LayoutBuilder(
                        builder: (context, constraints) =>
                            _fileList(files, constraints),
                      ),
                    ),
            ),
            if (widget.picking)
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: loading || error.isNotEmpty
                        ? null
                        : () => Navigator.pop(
                            context,
                            widget.services.cloud
                                .connector(session.platform)
                                .destinationId(session, stack.last.$1),
                          ),
                    child: Text('选择“${stack.last.$2}”'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ShareOptionsDialog extends StatefulWidget {
  const _ShareOptionsDialog(this.files, this.platform);
  final List<CloudFile> files;
  final CloudPlatform platform;
  @override
  State<_ShareOptionsDialog> createState() => _ShareOptionsDialogState();
}

class _ShareOptionsDialogState extends State<_ShareOptionsDialog> {
  late final title = TextEditingController(
    text: widget.files.length == 1
        ? widget.files.first.name
        : '${widget.files.first.name} 等 ${widget.files.length} 项',
  );
  final passcode = TextEditingController();
  int days = 7;
  @override
  void dispose() {
    title.dispose();
    passcode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('创建分享'),
    content: SizedBox(
      width: 380,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              decoration: const InputDecoration(labelText: '分享标题'),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              initialValue: days,
              decoration: const InputDecoration(labelText: '有效期'),
              items: [
                const DropdownMenuItem(value: 1, child: Text('1 天')),
                const DropdownMenuItem(value: 7, child: Text('7 天')),
                if (widget.platform != CloudPlatform.tianyi)
                  const DropdownMenuItem(value: 30, child: Text('30 天')),
                const DropdownMenuItem(value: 0, child: Text('永久')),
              ],
              onChanged: (v) => days = v ?? 7,
            ),
            const SizedBox(height: 16),
            if (widget.platform == CloudPlatform.c139)
              const Text('提取码由移动云盘自动生成')
            else if (widget.platform == CloudPlatform.tianyi)
              const Text('访问码由天翼云盘自动生成')
            else
              TextField(
                controller: passcode,
                decoration: const InputDecoration(labelText: '提取码（可选）'),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(
          context,
          ShareOptions(
            title.text.trim(),
            expiryDays: days == 0 ? null : days,
            passcode: passcode.text.trim().isEmpty
                ? null
                : passcode.text.trim(),
          ),
        ),
        child: const Text('创建'),
      ),
    ],
  );
}
