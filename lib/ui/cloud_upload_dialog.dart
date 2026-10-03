import 'dart:async';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../core/json.dart';
import '../data/cloud_repository.dart';
import '../data/http.dart';
import '../domain/models.dart';
import '../domain/uploads.dart';
import '../diagnostics/app_log.dart';
import 'common.dart';

class CloudUploadDialog extends StatefulWidget {
  const CloudUploadDialog({
    super.key,
    required this.cloud,
    required this.session,
    required this.parent,
    required this.files,
  });
  final CloudRepository cloud;
  final BrowseSession session;
  final String parent;
  final List<XFile> files;
  @override
  State<CloudUploadDialog> createState() => _CloudUploadDialogState();
}

class _CloudUploadDialogState extends State<CloudUploadDialog> {
  final _scope = RequestScope(), _clock = Stopwatch()..start();
  final _failures = <(String, String)>[];
  UploadProgress? _progress;
  int _index = 0, _completed = 0, _lastUpdate = 0;
  bool _running = true, _cancelled = false;
  late final _revision = widget.cloud
      .sessionCredential(widget.session)
      ?.updatedAt;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _scope.cancel();
    super.dispose();
  }

  void _cancel() {
    if (!_running || _cancelled) return;
    setState(() => _cancelled = true);
    _scope.cancel();
  }

  void _update(UploadProgress progress) {
    if (!mounted || _cancelled) return;
    if (_progress?.phase == progress.phase &&
        progress.sent < progress.total &&
        _clock.elapsedMilliseconds - _lastUpdate < 120) {
      return;
    }
    _lastUpdate = _clock.elapsedMilliseconds;
    setState(() => _progress = progress);
  }

  Future<void> _run() async {
    try {
      for (var i = 0; i < widget.files.length; i++) {
        if (!mounted || _cancelled) break;
        final file = widget.files[i];
        setState(() {
          _index = i;
          _progress = null;
        });
        try {
          require(
            widget.cloud.sessionCredential(widget.session)?.updatedAt ==
                _revision,
            '账号已变化，请重新选择上传文件',
          );
          final size = await file.length(),
              modified = await file.lastModified();
          DiagnosticLog.event(
            'upload.file.start',
            fields: {
              'platform': widget.session.platform.key,
              'index': i,
              'bytes': size,
            },
          );
          final source = UploadFile(
            name: file.name,
            size: size,
            mimeType: file.mimeType ?? 'application/octet-stream',
            modifiedAt: modified,
            read: (start, end) => file.openRead(start, end),
            validate: () async {
              require(
                await file.length() == size &&
                    await file.lastModified() == modified,
                '本地文件在上传期间发生变化，请重新选择',
              );
            },
          );
          await _scope.run(
            () => widget.cloud.upload(
              widget.session,
              widget.parent,
              source,
              onProgress: _update,
            ),
          );
          _completed++;
          DiagnosticLog.event(
            'upload.file.complete',
            fields: {'platform': widget.session.platform.key, 'index': i},
          );
        } catch (error, stack) {
          if (_cancelled) break;
          DiagnosticLog.error(
            'upload.file.failed',
            error,
            stack,
            fields: {
              'platform': widget.session.platform.key,
              'index': i,
              'phase': _progress?.phase.name ?? 'preparing',
            },
          );
          _failures.add((file.name, errorText(error)));
          if (widget.cloud.sessionCredential(widget.session)?.updatedAt !=
              _revision) {
            break;
          }
          try {
            widget.cloud.ensureAvailable(widget.session.platform);
          } catch (_) {
            break;
          }
        }
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final stage = switch (progress?.phase) {
      UploadPhase.uploading => '正在上传',
      UploadPhase.finishing => '正在等待网盘确认',
      _ => '正在读取和校验文件',
    };
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: AlertDialog(
        title: Text(
          _running
              ? '上传文件（${_index + 1}/${widget.files.length}）'
              : _cancelled
              ? '上传已取消'
              : _failures.isEmpty
              ? '上传完成'
              : '上传结果',
        ),
        content: SizedBox(
          width: 420,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .5,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_running) ...[
                    Text(
                      widget.files[_index].name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: progress?.phase == UploadPhase.finishing
                          ? null
                          : progress?.fraction,
                    ),
                    const SizedBox(height: 12),
                    Text(_cancelled ? '正在停止上传…' : stage),
                    if (progress != null &&
                        progress.phase == UploadPhase.uploading)
                      Text(
                        '${formatBytes(progress.sent)} / ${formatBytes(progress.total)}',
                      ),
                  ] else ...[
                    Text('成功上传 $_completed 个文件'),
                    if (_cancelled)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('已完成的文件会保留。若在网盘确认时取消，请刷新目录查看结果。'),
                      ),
                    for (final failure in _failures)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          '${failure.$1}\n${failure.$2}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          if (_running)
            TextButton(
              onPressed: _cancelled ? null : _cancel,
              child: const Text('取消上传'),
            )
          else
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
        ],
      ),
    );
  }
}
