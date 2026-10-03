import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../core/operation_progress.dart';
import '../data/http.dart';
import '../domain/models.dart';
import '../download/image_preview_loader.dart';
import '../playback/playback_controller.dart';
import '../playback/playback_sources.dart';
import 'common.dart';
import 'operation_progress_view.dart';
import 'player_page.dart';
import 'uc_tv_authorization_page.dart';

class PreviewPage extends StatefulWidget {
  const PreviewPage(
    this.services,
    this.session,
    this.file, {
    super.key,
    this.playlist = const [],
  });
  final AppServices services;
  final BrowseSession session;
  final CloudFile file;
  final List<CloudFile> playlist;
  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  // Keep a bounded in-memory preview, but allow photographs larger than the
  // old 25 MiB limit used by several cloud providers.
  static const _maxImagePreviewBytes = 64 * 1024 * 1024;
  final scope = RequestScope();
  final progress = OperationProgress();
  DownloadSpec? spec;
  PlaybackController? playback;
  Uint8List? image;
  String? text;
  bool loading = true, adding = false;
  String error = '';
  late final kind = fileKind(widget.file.name);
  @override
  void initState() {
    super.initState();
    if (kind == FileKind.video || kind == FileKind.audio) {
      playback = cloudPlayback(
        widget.services,
        widget.session,
        widget.file,
        widget.playlist,
      );
    } else {
      _load();
    }
  }

  Future<void> _release(DownloadSpec value) async {
    await widget.services.cleanups.release(value.cleanup);
    await widget.services.cleanups.ready(value.cleanup);
    await widget.services.cleanups.drain();
  }

  Future<void> _load() async {
    if (!{FileKind.image, FileKind.text}.contains(kind)) {
      setState(() => loading = false);
      return;
    }
    try {
      final value = await scope.run(
        () => progress.run(
          () => widget.services.cloud.prepare(widget.session, widget.file),
        ),
      );
      if (!mounted) {
        await _release(value);
        return;
      }
      spec = value;
      if (kind == FileKind.image) {
        image = await scope.run(
          () => ImagePreviewLoader(widget.services.transfer).load(
            value,
            limit: _maxImagePreviewBytes,
            connections: widget.services.settings.connectionsFor(
              widget.session.platform,
              value.profile,
            ),
          ),
        );
      } else if (kind == FileKind.text) {
        text = await scope.run(
          () => widget.services.transfer.text(value.url, value.headers),
        );
      }
      if (mounted) setState(() => loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = errorText(e);
          loading = false;
        });
      }
    }
  }

  Future<void> _download() async {
    if (adding) return;
    setState(() => adding = true);
    try {
      var value = spec;
      if (value == null) {
        value = await widget.services.cloud.prepare(
          widget.session,
          widget.file,
        );
      } else {
        widget.services.cleanups.retain(value.cleanup);
      }
      try {
        await widget.services.downloads.enqueue(value);
      } catch (_) {
        await widget.services.cleanups.release(value.cleanup);
        await widget.services.cleanups.ready(value.cleanup);
        rethrow;
      }
      if (mounted) {
        message(
          context,
          '已添加到下载队列',
          onTap: widget.services.requestDownloadManager,
        );
      }
    } catch (e) {
      if (mounted) message(context, errorText(e));
    } finally {
      if (mounted) setState(() => adding = false);
    }
  }

  @override
  void dispose() {
    scope.cancel();
    progress.dispose();
    final current = spec;
    unawaited(
      () async {
        if (current != null) await _release(current);
      }().catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (playback != null) {
      return PlayerPage(
        playback!,
        onAuthorizeUcTv: widget.session.platform == CloudPlatform.uc
            ? () => openUcTvAuthorization(
                context,
                widget.services,
                accountId: widget.session.accountId,
              )
            : null,
        subtitleDirectory: Directory(
          '${widget.services.cacheDirectory.path}/playback-subtitles',
        ),
        onDownload: (source) async {
          await widget.services.downloads.enqueue(source);
        },
      );
    }
    return PageFrame(
      title: widget.file.name,
      actions: [
        IconButton(
          tooltip: '下载文件',
          onPressed: adding ? null : _download,
          icon: const Icon(CupertinoIcons.arrow_down_circle),
        ),
      ],
      child: Column(
        children: [
          Expanded(
            child: loading
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 360),
                        child: OperationProgressView(
                          progress: progress,
                          label: '正在加载预览…',
                        ),
                      ),
                    ),
                  )
                : error.isNotEmpty
                ? EmptyPanel(
                    '暂时无法预览',
                    error,
                    icon: CupertinoIcons.doc,
                    action: FilledButton(
                      onPressed: adding ? null : _download,
                      child: const Text('下载文件'),
                    ),
                  )
                : image != null
                ? InteractiveViewer(
                    minScale: .5,
                    maxScale: 6,
                    child: Center(
                      // Decode very large photographs to a bounded preview
                      // size.  Keeping the compressed bytes while asking the
                      // codec for the full source dimensions can exceed the
                      // Android bitmap budget even when the download itself
                      // succeeded.
                      child: Image.memory(
                        image!,
                        fit: BoxFit.contain,
                        cacheWidth: 4096,
                        cacheHeight: 4096,
                      ),
                    ),
                  )
                : text != null
                ? SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SelectableText(
                        text!,
                        style: const TextStyle(fontSize: 14, height: 1.6),
                      ),
                    ),
                  )
                : EmptyPanel(
                    widget.file.name,
                    '${formatBytes(widget.file.size)}\n此类型文件可下载后查看',
                    icon: CupertinoIcons.doc,
                    action: FilledButton.icon(
                      onPressed: adding ? null : _download,
                      icon: const Icon(CupertinoIcons.arrow_down, size: 17),
                      label: const Text('下载文件'),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
