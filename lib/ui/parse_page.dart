import 'dart:async';
import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import '../domain/torrent.dart';
import 'torrent_page.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../core/operation_progress.dart';
import '../diagnostics/app_log.dart';
import '../data/http.dart';
import '../domain/auth.dart';
import '../domain/links.dart';
import '../domain/models.dart';
import '../platform/file_access.dart';
import 'browser_page.dart';
import 'common.dart';
import 'login_page.dart';
import 'recent_playback_page.dart';
import 'cloud_favorites_page.dart';
import 'operation_progress_view.dart';

class ParsePage extends StatefulWidget {
  const ParsePage(this.services, {super.key, this.active = true});
  final AppServices services;
  final bool active;
  @override
  State<ParsePage> createState() => ParsePageState();
}

class ParsePageState extends State<ParsePage> {
  final input = TextEditingController(), code = TextEditingController();
  final focus = FocusNode(), codeFocus = FocusNode();
  final _manualCodes = <String, String>{};
  final _progress = OperationProgress();
  List<ParsedLink> links = [];
  int selected = 0, _generation = 0;
  bool working = false;
  String stage = '', error = '';
  String? _recognizedText;
  CloudPlatform? _loginPlatform;
  RequestScope? _request;
  ParsedLink? get current => links.elementAtOrNull(selected);

  @override
  void initState() {
    super.initState();
    input.addListener(_recognize);
    widget.services.sharedText.addListener(_shared);
    _shared();
  }

  @override
  void didUpdateWidget(ParsePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active && oldWidget.active) {
      if (working) _cancel();
      focus.unfocus();
      codeFocus.unfocus();
    }
  }

  void _shared() {
    final value = widget.services.sharedText.value;
    if (value?.isNotEmpty == true) {
      _replaceInput(value!);
      unawaited(widget.services.clipboard.acknowledgeText(value));
    }
  }

  void _replaceInput(String value) {
    _manualCodes.clear();
    _recognizedText = null;
    input.text = value;
    // Assigning the same clipboard text should also reset a manual override.
    _recognize();
  }

  void _recognize() {
    if (_recognizedText == input.text) return;
    _recognizedText = input.text;
    if (working) _cancel();
    _progress.clear();
    final previous = current?.url;
    final recognized = LinkParser.parse(input.text);
    _manualCodes.removeWhere((url, _) => !recognized.any((l) => l.url == url));
    setState(() {
      links = recognized
          .map(
            (link) => _manualCodes.containsKey(link.url)
                ? link.withPasscode(_manualCodes[link.url]!)
                : link,
          )
          .toList();
      final found = links.indexWhere((link) => link.url == previous);
      final firstShare = links.indexWhere((link) => link.isCloudShare);
      selected = found >= 0 ? found : (firstShare >= 0 ? firstShare : 0);
      code.text = current?.passcode ?? '';
      error = '';
      _loginPlatform = null;
    });
  }

  void _editCode(String value) {
    final link = current;
    if (link == null) return;
    setState(() {
      _manualCodes[link.url] = value;
      links[selected] = link.withPasscode(value);
      error = '';
    });
  }

  @override
  void dispose() {
    _generation++;
    _request?.cancel();
    _progress.dispose();
    widget.services.sharedText.removeListener(_shared);
    input.removeListener(_recognize);
    input.dispose();
    code.dispose();
    focus.dispose();
    codeFocus.dispose();
    super.dispose();
  }

  void focusInput() => focus.requestFocus();
  void acceptClipboard(String text) => _replaceInput(text);
  Future<void> paste() async {
    final value = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    if (value?.text?.isNotEmpty == true) {
      _replaceInput(value!.text!);
      await widget.services.clipboard.acknowledgeText(value.text!);
    } else {
      message(context, '剪贴板中没有文本');
    }
  }

  bool _current(int generation) =>
      mounted && widget.active && generation == _generation;

  void _cancel() {
    _generation++;
    _request?.cancel();
    _request = null;
    _progress.close(cancelled: true);
    setState(() {
      working = false;
      stage = '';
      error = '解析已取消，链接和提取码已保留';
    });
  }

  Future<bool> _offerLogin(CloudPlatform platform, int generation) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${platform.label}需要登录'),
        content: const Text(
          '该网盘尚未配置认证信息，解析前请先登录/设置。\n\n配置完成后继续解析，当前链接和提取码会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('去配置'),
          ),
        ],
      ),
    );
    if (proceed != true || !_current(generation) || !mounted) return false;
    await openLogin(context, widget.services, platform);
    return _current(generation) &&
        LoginCredentials.stored(
          platform,
          widget.services.vault.credential(platform),
        );
  }

  Future<void> _configure() async {
    final platform = _loginPlatform;
    if (platform == null || working) return;
    final revision = widget.services.vault.credential(platform)?.updatedAt;
    final originalInput = input.text;
    await openLogin(context, widget.services, platform);
    if (!mounted || !widget.active || input.text != originalInput) return;
    if (widget.services.vault.credential(platform)?.updatedAt != revision &&
        LoginCredentials.stored(
          platform,
          widget.services.vault.credential(platform),
        )) {
      await parse();
    }
  }

  Future<void> addTorrent() async {
    if (working) return;
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'BT 种子',
            extensions: ['torrent'],
            mimeTypes: ['application/x-bittorrent', 'application/octet-stream'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      require(await file.length() <= maxTorrentBytes, '种子文件不能超过 4 MiB');
      final data = await file.readAsBytes();
      if (!mounted) return;
      await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => TorrentPage(
            widget.services,
            '$torrentDataPrefix${base64Encode(data)}',
          ),
        ),
      );
    } catch (e) {
      if (mounted) message(context, e is AppException ? e.message : '无法读取种子文件');
    }
  }

  Future<void> parse() async {
    if (working) return;
    _progress.clear();
    final link = current;
    DiagnosticLog.event(
      'parse.start',
      fields: {'kind': link?.kind.name, 'platform': link?.platform?.name},
    );
    if (input.text.trim().isEmpty || link == null) {
      setState(
        () => error = input.text.trim().isEmpty ? '请输入内容' : '未识别到有效链接，请检查分享内容',
      );
      focus.requestFocus();
      return;
    }
    if (link.kind == LinkKind.unsupportedCloud) {
      setState(() => error = '已识别${link.cloudLabel ?? '网盘'}链接，当前版本暂未接入该网盘');
      return;
    }
    if (link.platform?.supportsShareParsing == false) {
      setState(() => error = link.platform!.shareUnavailableMessage);
      return;
    }
    if (link.kind == LinkKind.magnet || link.kind == LinkKind.torrent) {
      final added = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => TorrentPage(widget.services, link.url),
        ),
      );
      if (added == true && mounted) await widget.services.remember(link);
      return;
    }
    if (link.platform != null && link.kind != LinkKind.cloudShare) {
      setState(() => error = '请粘贴含分享编号的网盘链接');
      return;
    }
    focus.unfocus();
    codeFocus.unfocus();
    final generation = ++_generation;
    setState(() {
      working = true;
      error = '';
      _loginPlatform = null;
    });
    try {
      if (link.kind != LinkKind.cloudShare) {
        final added = await directDownloadDialog(
          context,
          widget.services,
          initial: link.url,
        );
        if (added && _current(generation)) await widget.services.remember(link);
        return;
      }
      final platform = link.platform!;
      widget.services.control.checkCloud(platform);
      if (platform.shareRequiresAccount &&
          !LoginCredentials.stored(
            platform,
            widget.services.vault.credential(platform),
          )) {
        if (!await _offerLogin(platform, generation)) {
          if (_current(generation)) {
            setState(() {
              error = '尚未完成登录，链接和提取码已保留';
              _loginPlatform = platform;
            });
          }
          return;
        }
      }
      if (!_current(generation)) return;
      final revision = widget.services.vault.credential(platform)?.updatedAt;
      final scope = _request = RequestScope();
      void checkpoint() {
        widget.services.control.checkCloud(platform);
        require(_current(generation) && !scope.token.isCancelled, '解析已取消');
        require(
          widget.services.vault.credential(platform)?.updatedAt == revision,
          '账号已变化，请点击开始解析重新读取',
        );
      }

      setState(() => stage = '正在验证分享链接…');
      final result = await scope
          .run(
            () => _progress.run(() async {
              final session = await widget.services.cloud.share(link);
              checkpoint();
              setState(() => stage = '正在读取文件列表…');
              final files = await widget.services.cloud.list(
                session,
                session.rootId,
              );
              checkpoint();
              return (session, files);
            }),
          )
          .timeout(
            const Duration(seconds: 90),
            onTimeout: () {
              scope.cancel();
              throw const AppException('解析超时，请检查网络后重试');
            },
          );
      checkpoint();
      await widget.services.remember(
        link,
        title: result.$1.title,
        itemCount: result.$2.length,
        canCommit: () => _current(generation),
      );
      checkpoint();
      _request = null;
      setState(() {
        working = false;
        stage = '';
      });
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              BrowserPage(widget.services, result.$1, initialItems: result.$2),
        ),
      );
    } catch (e, stack) {
      if (!_current(generation)) return;
      _progress.close(failed: true);
      DiagnosticLog.error(
        'parse.failed',
        e,
        stack,
        fields: {'kind': link.kind.name, 'platform': link.platform?.name},
      );
      final text = errorText(e);
      final passcodeError =
          e is! AccountLoginRequired &&
          RegExp(
            r'提取码|访问码|口令|分享密码|pass.?code|password|pwd',
            caseSensitive: false,
          ).hasMatch(text);
      setState(() {
        error = passcodeError ? '$text\n请在上方修改提取码，再点击开始解析。' : text;
        _loginPlatform = e is AccountLoginRequired ? link.platform : null;
      });
      if (passcodeError) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_current(generation)) codeFocus.requestFocus();
        });
      }
    } finally {
      if (_current(generation)) {
        _progress.close();
        _request = null;
        setState(() {
          working = false;
          stage = '';
        });
      }
    }
  }

  String _label(ParsedLink link) =>
      (link.kind == LinkKind.unsupportedCloud
          ? '${link.cloudLabel ?? '网盘'}（暂未接入）'
          : link.platform?.supportsShareParsing == false
          ? '${link.cloudLabel}（暂不支持分享解析）'
          : link.cloudLabel) ??
      switch (link.kind) {
        LinkKind.magnet => '磁力链接',
        LinkKind.torrent => '种子文件链接',
        _ => 'HTTP 文件链接',
      };

  Future<void> _history() async {
    final item = await showModalBottomSheet<Json>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: AnimatedBuilder(
            animation: widget.services.store,
            builder: (context, _) {
              final history =
                  widget.services.store.data.list('history').toList()..sort(
                    (a, b) => b
                        .integer('createdAt')
                        .compareTo(a.integer('createdAt')),
                  );
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '历史解析',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (history.isNotEmpty)
                          TextButton(
                            onPressed: () async {
                              if (await confirm(
                                    context,
                                    '清空解析历史',
                                    '将删除本机解析记录，下载任务仍保留。',
                                  ) &&
                                  context.mounted) {
                                await widget.services.store.put('history', []);
                              }
                            },
                            child: const Text('清空'),
                          ),
                        IconButton(
                          tooltip: '关闭历史',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(CupertinoIcons.xmark, size: 18),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: history.isEmpty
                        ? const Center(
                            child: EmptyPanel(
                              '暂无历史解析',
                              '成功解析的分享会保存在这里',
                              icon: CupertinoIcons.clock,
                            ),
                          )
                        : ListView.builder(
                            itemCount: history.length,
                            itemBuilder: (context, index) {
                              final item = history[index];
                              return ListTile(
                                leading: PlatformMark(
                                  platform: CloudPlatform.fromKey(
                                    item.str('platform'),
                                  ),
                                  size: 30,
                                ),
                                title: Text(
                                  item
                                      .str('fileName')
                                      .ifEmpty(item.str('normalizedUrl')),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${formatDate(item.integer('createdAt'))}${item['itemCount'] == null ? '' : ' · ${item.integer('itemCount')} 项'}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: secondary(context),
                                  ),
                                ),
                                trailing: IconButton(
                                  tooltip: '删除这条历史',
                                  icon: const Icon(
                                    CupertinoIcons.xmark,
                                    size: 16,
                                  ),
                                  onPressed: () =>
                                      widget.services.store.change((draft) {
                                        draft['history'] = draft
                                            .list('history')
                                            .where(
                                              (h) =>
                                                  h.str('normalizedUrl') !=
                                                  item.str('normalizedUrl'),
                                            )
                                            .toList();
                                      }),
                                ),
                                onTap: () => Navigator.pop(context, item),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    if (item == null || !mounted) return;
    final known = item['link'] is Map
        ? ParsedLink.fromJson(item.obj('link'))
        : null;
    _replaceInput(item.str('sourceText').ifEmpty(item.str('normalizedUrl')));
    if (known != null) {
      final index = links.indexWhere((link) => link.url == known.url);
      if (index >= 0) {
        setState(() {
          selected = index;
          code.text = known.passcode ?? '';
          _manualCodes[known.url] = code.text;
          links[index] = links[index].withPasscode(code.text);
        });
      }
    }
  }

  Widget _card(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(20),
    bool desktop = false,
  }) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(desktop ? 16 : 22),
      border: Border.all(color: border(context), width: .7),
      boxShadow: desktop
          ? const []
          : [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: Theme.of(context).brightness == Brightness.dark
                      ? .12
                      : .065,
                ),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
    ),
    child: child,
  );

  Widget _inputHeader(
    BuildContext context,
    String recognition, {
    bool desktop = false,
  }) {
    if (desktop) {
      final title = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '分享内容',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 7),
          Text(
            recognition,
            key: const Key('parse-recognition'),
            style: TextStyle(
              fontSize: 12,
              color: current == null ? secondary(context) : brandBlue,
            ),
          ),
        ],
      );
      final tools = Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          TextButton.icon(
            key: const Key('parse-history'),
            onPressed: working ? null : _history,
            icon: const Icon(CupertinoIcons.clock, size: 16),
            label: const Text('历史'),
          ),
          OutlinedButton.icon(
            key: const Key('parse-paste'),
            onPressed: working ? null : paste,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              side: BorderSide(color: border(context)),
            ),
            icon: const Icon(CupertinoIcons.doc_on_clipboard, size: 16),
            label: const Text('粘贴'),
          ),
        ],
      );
      return LayoutBuilder(
        builder: (context, bounds) {
          if (bounds.maxWidth < 430 ||
              MediaQuery.textScalerOf(context).scale(14) > 21) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, const SizedBox(height: 12), tools],
            );
          }
          return Row(
            children: [
              Expanded(child: title),
              const SizedBox(width: 12),
              tools,
            ],
          );
        },
      );
    }
    final pasteControl = InkWell(
      key: const Key('parse-paste'),
      onTap: working ? null : paste,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            const Icon(CupertinoIcons.doc_text, color: brandBlue, size: 27),
            const SizedBox(width: 17),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '粘贴内容',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    recognition,
                    key: const Key('parse-recognition'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: current == null ? secondary(context) : brandBlue,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final historyControl = TextButton.icon(
      key: const Key('parse-history'),
      onPressed: working ? null : _history,
      style: TextButton.styleFrom(
        backgroundColor: brandBlue.withValues(alpha: .11),
        foregroundColor: brandBlue,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        shape: const StadiumBorder(),
      ),
      icon: const Icon(CupertinoIcons.clock, size: 17),
      label: const Text(
        '历史',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        if (bounds.maxWidth < 275 ||
            MediaQuery.textScalerOf(context).scale(14) > 21) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              pasteControl,
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerRight, child: historyControl),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: pasteControl),
            const SizedBox(width: 8),
            historyControl,
          ],
        );
      },
    );
  }

  Widget _actions(BuildContext context, {bool desktop = false}) {
    if (desktop) {
      return Align(
        alignment: Alignment.centerRight,
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton.icon(
              key: const Key('parse-bt'),
              onPressed: working ? null : addTorrent,
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onSurface,
                side: BorderSide(color: border(context)),
                minimumSize: const Size(0, 44),
              ),
              icon: const Icon(CupertinoIcons.folder, size: 17),
              label: const Text('导入 BT 种子'),
            ),
            FilledButton.icon(
              key: const Key('parse-start'),
              onPressed: working || current == null ? null : parse,
              style: FilledButton.styleFrom(minimumSize: const Size(152, 44)),
              icon: const Icon(CupertinoIcons.arrow_right, size: 17),
              label: Text(working ? '解析中…' : '开始解析'),
            ),
          ],
        ),
      );
    }
    final add = Tooltip(
      message: '选择本地 BT 种子文件',
      child: FilledButton.tonalIcon(
        key: const Key('parse-bt'),
        onPressed: working ? null : addTorrent,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          disabledBackgroundColor: brandBlue.withValues(alpha: .09),
          disabledForegroundColor: brandBlue.withValues(alpha: .55),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(17),
          ),
        ),
        icon: const Icon(CupertinoIcons.add_circled_solid, size: 19),
        label: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '添加BT',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            Text('选择种子文件', style: TextStyle(fontSize: 9, height: 1.1)),
          ],
        ),
      ),
    );
    final submit = FilledButton(
      key: const Key('parse-start'),
      onPressed: working || current == null ? null : parse,
      style: FilledButton.styleFrom(
        backgroundColor: brandBlue,
        disabledBackgroundColor: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xff3a3a3c)
            : const Color(0xffd2d2d7),
        disabledForegroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
      ),
      child: Text(
        working ? '解析中…' : '开始解析',
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 275 ||
            MediaQuery.textScalerOf(context).scale(14) > 21) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [submit, const SizedBox(height: 10), add],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 2, child: add),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: submit),
            ],
          ),
        );
      },
    );
  }

  Widget _codeInput(
    BuildContext context,
    ParsedLink? link,
    Color hint, {
    required bool desktop,
  }) {
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: border(context)),
    );
    final field = TextField(
      key: const Key('parse-code'),
      controller: code,
      focusNode: codeFocus,
      enabled: !working && link?.isCloudShare == true,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.done,
      style: TextStyle(fontSize: desktop ? 14 : 16),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
        LengthLimitingTextInputFormatter(12),
      ],
      onChanged: _editCode,
      onSubmitted: (_) => parse(),
      decoration: InputDecoration(
        labelText: desktop ? '提取码' : null,
        floatingLabelBehavior: desktop ? FloatingLabelBehavior.always : null,
        hintText: desktop ? '自动识别' : '提取码（自动识别，可手动修改）',
        hintStyle: TextStyle(
          color: desktop ? secondary(context) : hint,
          fontSize: desktop ? 13 : 16,
        ),
        filled: false,
        isDense: desktop,
        contentPadding: desktop
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 14)
            : const EdgeInsets.symmetric(vertical: 17),
        border: desktop ? outline : InputBorder.none,
        enabledBorder: desktop ? outline : InputBorder.none,
        focusedBorder: desktop
            ? outline.copyWith(borderSide: const BorderSide(color: brandBlue))
            : InputBorder.none,
        disabledBorder: desktop ? outline : InputBorder.none,
      ),
    );
    if (!desktop) return field;
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 10),
      child: Row(
        children: [
          SizedBox(width: 152, child: field),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              link == null || link.isCloudShare
                  ? '自动识别提取码，也可手动补充。'
                  : '此类链接无需提取码。',
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: secondary(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _desktopSupport(BuildContext context) => _card(
    context,
    desktop: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '支持的网盘',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, bounds) => Wrap(
            spacing: 12,
            runSpacing: 16,
            children: [
              for (final platform in const [
                CloudPlatform.quark,
                CloudPlatform.baidu,
                CloudPlatform.uc,
                CloudPlatform.xunlei,
                CloudPlatform.tianyi,
                CloudPlatform.c139,
                CloudPlatform.pan123,
                CloudPlatform.guangya,
                CloudPlatform.aliyun,
                CloudPlatform.lanzou,
              ])
                SizedBox(
                  width: MediaQuery.textScalerOf(context).scale(13) > 20
                      ? bounds.maxWidth
                      : (bounds.maxWidth - 12) / 2,
                  child: Row(
                    children: [
                      PlatformMark(platform: platform, size: 22),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          platform == CloudPlatform.c139
                              ? '移动'
                              : platform.shortName,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text(
          '蓝奏云支持不登录解析',
          style: TextStyle(
            fontSize: 11,
            height: 1.6,
            color: secondary(context),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Divider(height: 1, color: border(context)),
        ),
        const Text(
          '其他链接',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'HTTP / HTTPS 文件\n磁力链接与 BT 种子',
          style: TextStyle(
            fontSize: 12,
            height: 1.8,
            color: secondary(context),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final link = current;
    final desktop = Theme.of(context).platform == TargetPlatform.windows;
    final hint = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xff77777c)
        : const Color(0xffc4c4c7);
    final recognition = link == null
        ? '等待粘贴链接'
        : '已识别：${_label(link)}${links.length > 1 ? ' · 共 ${links.length} 条' : ''}';
    return PopScope(
      canPop: !working,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && working) _cancel();
      },
      child: LayoutBuilder(
        builder: (context, bounds) {
          final form = _card(
            context,
            desktop: desktop,
            padding: EdgeInsets.all(desktop ? 24 : 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _inputHeader(context, recognition, desktop: desktop),
                SizedBox(height: desktop ? 22 : 23),
                TextField(
                  key: const Key('parse-input'),
                  controller: input,
                  focusNode: focus,
                  readOnly: working,
                  minLines: desktop ? 6 : 4,
                  maxLines: desktop ? 10 : 7,
                  style: TextStyle(fontSize: desktop ? 14 : 16, height: 1.6),
                  decoration: InputDecoration(
                    hintText: desktop ? '粘贴分享链接或包含提取码的完整文本' : '粘贴分享链接或包含链接的文本',
                    hintStyle: TextStyle(
                      color: desktop ? secondary(context) : hint,
                      fontSize: desktop ? 14 : 17,
                    ),
                    filled: desktop,
                    isDense: true,
                    contentPadding: desktop
                        ? const EdgeInsets.all(16)
                        : EdgeInsets.zero,
                    border: desktop
                        ? OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: border(context)),
                          )
                        : InputBorder.none,
                    enabledBorder: desktop
                        ? OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: border(context)),
                          )
                        : InputBorder.none,
                    focusedBorder: desktop
                        ? OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: brandBlue),
                          )
                        : InputBorder.none,
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 24,
                    ),
                    suffixIcon: input.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空输入',
                            onPressed: working ? null : () => _replaceInput(''),
                            icon: const Icon(
                              CupertinoIcons.xmark_circle_fill,
                              size: 16,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                if (!desktop)
                  Divider(height: 1, thickness: .6, color: border(context)),
                _codeInput(context, link, hint, desktop: desktop),
                if (links.length > 1) ...[
                  const SizedBox(height: 8),
                  Text(
                    '选择本次要解析的链接',
                    style: TextStyle(fontSize: 12, color: secondary(context)),
                  ),
                  for (var i = 0; i < links.length; i++)
                    ListTile(
                      key: ValueKey('parse-choice-$i'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        i == selected
                            ? CupertinoIcons.checkmark_circle_fill
                            : CupertinoIcons.circle,
                        color: i == selected ? brandBlue : secondary(context),
                        size: 22,
                      ),
                      title: Text(_label(links[i])),
                      subtitle: Text(
                        links[i].url,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                      onTap: working
                          ? null
                          : () => setState(() {
                              selected = i;
                              code.text = current?.passcode ?? '';
                              error = '';
                              _loginPlatform = null;
                            }),
                    ),
                ],
                if (stage.isNotEmpty ||
                    error.isNotEmpty && _progress.value.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: brandBlue.withValues(alpha: .055),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        OperationProgressView(
                          key: const Key('parse-stage'),
                          progress: _progress,
                          label: '分享加载流程',
                        ),
                        if (working)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              key: const Key('parse-cancel'),
                              onPressed: _cancel,
                              child: const Text('取消'),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (error.isNotEmpty)
                  Container(
                    key: const Key('parse-error'),
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.errorContainer.withValues(alpha: .45),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          error,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                            height: 1.5,
                            fontSize: 13,
                          ),
                        ),
                        if (_loginPlatform != null)
                          TextButton(
                            onPressed: working ? null : _configure,
                            child: const Text('去登录 / 配置'),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
                _actions(context, desktop: desktop),
              ],
            ),
          );
          final support = desktop
              ? _desktopSupport(context)
              : _card(
                  context,
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        CupertinoIcons.checkmark_seal_fill,
                        size: 25,
                        color: brandBlue,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '支持类型',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 9),
                            Text(
                              '${CloudPlatform.values.where((platform) => platform.supportsShareParsing).map((platform) => platform.label).join('、')}；支持带提取码文本、HTTP 文件、磁力链接和 BT 种子。',
                              style: TextStyle(
                                fontSize: 14,
                                height: 1.6,
                                color: secondary(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
          final favorites = _card(
            context,
            desktop: desktop,
            padding: EdgeInsets.zero,
            child: CloudFavoritesSummary(
              widget.services,
              desktop: desktop,
              enabled: !working,
            ),
          );
          final recent = _card(
            context,
            desktop: desktop,
            padding: EdgeInsets.zero,
            child: RecentPlaybackSummary(
              widget.services,
              desktop: desktop,
              enabled: !working,
            ),
          );
          if (desktop) {
            final roomy =
                bounds.maxWidth >= 900 &&
                MediaQuery.textScalerOf(context).scale(14) <= 21;
            return ListView(
              key: const PageStorageKey('parse'),
              padding: EdgeInsets.fromLTRB(
                bounds.maxWidth >= 800 ? 28 : 20,
                24,
                bounds.maxWidth >= 800 ? 28 : 20,
                28 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                if (roomy)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: form),
                      const SizedBox(width: 22),
                      SizedBox(
                        width: 252,
                        child: Column(
                          children: [
                            favorites,
                            const SizedBox(height: 18),
                            recent,
                            const SizedBox(height: 18),
                            support,
                          ],
                        ),
                      ),
                    ],
                  )
                else ...[
                  form,
                  const SizedBox(height: 18),
                  if (bounds.maxWidth >= 680 &&
                      MediaQuery.textScalerOf(context).scale(14) <= 21)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: favorites),
                        const SizedBox(width: 18),
                        Expanded(child: recent),
                      ],
                    )
                  else ...[
                    favorites,
                    const SizedBox(height: 18),
                    recent,
                  ],
                  const SizedBox(height: 18),
                  support,
                ],
              ],
            );
          }
          return ListView(
            key: const PageStorageKey('parse'),
            padding: EdgeInsets.fromLTRB(
              bounds.maxWidth > 720 ? (bounds.maxWidth - 680) / 2 : 18,
              18,
              bounds.maxWidth > 720 ? (bounds.maxWidth - 680) / 2 : 18,
              28 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              form,
              const SizedBox(height: 18),
              favorites,
              const SizedBox(height: 18),
              recent,
              const SizedBox(height: 18),
              support,
            ],
          );
        },
      ),
    );
  }
}

Future<bool> directDownloadDialog(
  BuildContext context,
  AppServices services, {
  String initial = '',
  String fileName = '',
  Map<String, String> headers = const {},
}) async {
  final spec = await showDialog<DownloadSpec>(
    context: context,
    builder: (_) => _DirectDialog(initial, fileName, headers),
  );
  if (spec == null || !context.mounted) return false;
  final id = await busy(
    context,
    () => services.downloads.enqueue(spec),
    label: '添加下载…',
  );
  if (id != null && context.mounted) {
    message(context, '已添加到下载队列', onTap: services.requestDownloadManager);
  }
  return id != null;
}

class _DirectDialog extends StatefulWidget {
  const _DirectDialog(this.initial, this.fileName, this.headers);
  final String initial;
  final String fileName;
  final Map<String, String> headers;
  @override
  State<_DirectDialog> createState() => _DirectDialogState();
}

class _DirectDialogState extends State<_DirectDialog> {
  late final url = TextEditingController(text: widget.initial);
  late final name = TextEditingController(
    text: safeFileName(
      widget.fileName.isNotEmpty
          ? widget.fileName
          : Uri.tryParse(widget.initial)?.pathSegments.lastOrNull ??
                'download.bin',
    ),
  );
  late final headers = TextEditingController(text: jsonEncode(widget.headers));
  String error = '';
  bool advanced = false;
  @override
  void dispose() {
    for (final c in [url, name, headers]) {
      c.dispose();
    }
    super.dispose();
  }

  void submit() {
    try {
      final normalized = LinkParser.normalize(url.text),
          decoded = jsonDecode(headers.text);
      require(
        decoded is Map && decoded.values.every((v) => v is String),
        '请求头应为 JSON 字符串对象',
      );
      final parsed = strings(decoded);
      require(
        parsed.entries.every(
          (e) => !RegExp(r'[\r\n]').hasMatch(e.key + e.value),
        ),
        '请求头不能包含换行',
      );
      Navigator.pop(
        context,
        DownloadSpec(
          url: normalized,
          fileName: safeFileName(name.text),
          headers: parsed,
        ),
      );
    } catch (e) {
      setState(() => error = e is AppException ? e.message : '请检查链接和请求头格式');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新建下载'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: url,
              decoration: const InputDecoration(labelText: 'HTTP / HTTPS 链接'),
              maxLines: 3,
              minLines: 1,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '保存文件名'),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自定义请求头', style: TextStyle(fontSize: 13)),
              value: advanced,
              onChanged: (v) => setState(() => advanced = v),
            ),
            if (advanced)
              TextField(
                controller: headers,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'JSON 请求头',
                  hintText: '{"Referer": "https://…"}',
                ),
              ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(error, style: const TextStyle(color: Colors.red)),
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
      FilledButton(onPressed: submit, child: const Text('添加下载')),
    ],
  );
}
