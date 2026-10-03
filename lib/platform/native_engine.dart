import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../core/crypto_box.dart';
import '../core/json.dart';
import '../data/state_store.dart';

const nativeChannel = MethodChannel('com.asterlink.app/native');

abstract class NativeTransport {
  bool get connected;
  Future<Object?> call(String method, [Json args = const {}]);
  Future<void> dispose();
}

class AndroidGopeedTransport extends NativeTransport {
  bool _connected = false;
  @override
  bool get connected => _connected;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    try {
      final value = await nativeChannel.invokeMethod<Object?>('gopeed', {
        'method': method,
        'args': jsonEncode(args),
      });
      if (method == 'open') _connected = true;
      if (method == 'close') _connected = false;
      return value is String ? jsonDecode(value) : value;
    } on PlatformException catch (e) {
      throw AppException(e.message ?? '下载组件操作失败');
    }
  }

  @override
  Future<void> dispose() async {
    if (_connected) await call('close');
  }
}

class DesktopGopeedTransport extends NativeTransport {
  DesktopGopeedTransport({required this.executable, this.launchProcess});
  final String executable;
  final Future<Process> Function(String executable)? launchProcess;
  Process? _process;
  final _starting = AsyncGate(), _writer = AsyncGate();
  final _pending = <int, Completer<Object?>>{};
  int _sequence = 0;
  bool _disposed = false, _coreOpen = false;
  Future<void>? _disposeFuture;
  @override
  bool get connected => _process != null && _coreOpen;
  Future<Process> _start() => _starting.run(() async {
    require(!_disposed, '下载组件已经关闭');
    if (_process != null) return _process!;
    require(await File(executable).exists(), '缺少 Windows 下载组件，请安装完整版本');
    final process =
        await (launchProcess?.call(executable) ??
            Process.start(executable, const [], runInShell: false));
    _coreOpen = false;
    _process = process;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (!identical(_process, process)) return;
            try {
              final result = asJson(jsonDecode(line));
              final waiter = _pending.remove(result.integer('seq'));
              if (waiter == null) return;
              if (result.str('error').isNotEmpty) {
                waiter.completeError(AppException(result.str('error')));
              } else {
                waiter.complete(result['result']);
              }
            } catch (_) {
              _fail(const AppException('下载组件响应格式错误'));
            }
          },
          onError: (Object _) {
            if (identical(_process, process)) {
              _fail(const AppException('下载组件连接中断'));
            }
          },
        );
    unawaited(process.stderr.drain<void>());
    unawaited(
      process.exitCode.then((_) {
        if (!identical(_process, process)) return;
        _process = null;
        _coreOpen = false;
        _fail(const AppException('下载组件已退出，进度已保留，请重试'));
      }),
    );
    return process;
  });
  void _fail(AppException error) {
    final values = _pending.values.toList();
    _pending.clear();
    for (final waiter in values) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
  }

  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    final process = await _start();
    final seq = ++_sequence, waiter = Completer<Object?>();
    _pending[seq] = waiter;
    unawaited(
      _writer.run(() async {
        try {
          require(identical(process, _process), '下载组件连接已中断');
          process.stdin.writeln(
            jsonEncode({'seq': seq, 'method': method, 'args': args}),
          );
          await process.stdin.flush();
        } catch (_) {
          if (!waiter.isCompleted) {
            waiter.completeError(const AppException('下载组件通信失败'));
          }
        }
      }),
    );
    try {
      final result = await waiter.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () => throw const AppException('下载组件响应超时，进度已保留'),
      );
      if (identical(_process, process)) {
        if (method == 'open') _coreOpen = true;
        if (method == 'close') _coreOpen = false;
      }
      return result;
    } finally {
      _pending.remove(seq);
    }
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();
  Future<void> _dispose() async {
    if (_disposed) return;
    try {
      if (_process != null) await call('close');
    } finally {
      _disposed = true;
      _coreOpen = false;
      final process = _process;
      _process = null;
      try {
        if (process != null) {
          try {
            // A response can arrive before stdin.flush completes. Drain the
            // writer before closing the sink, including pending status polls.
            await _writer.run(() async => await process.stdin.close());
          } finally {
            process.kill();
            await process.exitCode;
          }
        }
      } finally {
        _fail(const AppException('下载组件已关闭'));
      }
    }
  }
}

/// Cold deletion records a marker; it never loads JNI just to remove a row.
class GopeedEngine {
  GopeedEngine(
    this.transport,
    this.store,
    this.vault,
    this.storage,
    this.cache,
  );
  final NativeTransport transport;
  final StateStore store;
  final CredentialStore vault;
  final Directory storage, cache;
  final _gate = AsyncGate();
  bool _started = false;
  void validateId(String id) =>
      require(RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id), '无效的下载任务编号');
  Future<void> _start() async {
    if (!_started || !transport.connected) {
      await storage.create(recursive: true);
      await cache.create(recursive: true);
      var key = vault.secret('flutter.gopeed.key');
      if (key == null) {
        key = base64Encode(CryptoBox.random(32));
        await vault.putSecret('flutter.gopeed.key', key);
      }
      await transport.call('open', {
        'storageDir': storage.path,
        'cacheDir': cache.path,
        'key': key,
      });
      _started = true;
    }
    final pending = (store.data['nativeRemovals'] as List? ?? [])
        .map((e) => e.toString())
        .toList();
    for (final id in pending) {
      validateId(id);
      try {
        await transport.call('remove', {'id': id});
      } catch (_) {
        // A forgotten history row must not prevent unrelated downloads from
        // starting. Its durable removal marker remains available for retry.
        continue;
      }
      await _forgetRemoval(id);
    }
  }

  Future<void> _forgetRemoval(String id) async {
    if (!(store.data['nativeRemovals'] as List? ?? []).contains(id)) return;
    await store.change((draft) {
      draft['nativeRemovals'] = (draft['nativeRemovals'] as List? ?? [])
          .where((value) => value != id)
          .toList();
    });
  }

  Future<Json> torrentCall(String method, Json args) => _gate.run(() async {
    validateId(args.str('id'));
    require(
      {
        'torrentResolve',
        'torrentMetadata',
        'torrentCancel',
        'torrentStreamStart',
        'torrentStreamStatus',
        'torrentStreamStop',
        'torrentStreamInterrupt',
      }.contains(method),
      '无效的 BT 操作',
    );
    if (method == 'torrentResolve' || method == 'torrentStreamStart') {
      await _start();
    }
    if ({
          'torrentCancel',
          'torrentStreamStop',
          'torrentStreamInterrupt',
        }.contains(method) &&
        (!_started || !transport.connected)) {
      return <String, dynamic>{};
    }
    require(_started && transport.connected, '下载组件连接已中断');
    return asJson(await transport.call(method, args));
  });

  Future<Json> httpProbeCall(String method, Json args) => _gate.run(() async {
    validateId(args.str('id'));
    require(
      {'httpProbeStart', 'httpProbeStatus', 'httpProbeStop'}.contains(method),
      '无效的下载连接检查',
    );
    if (method == 'httpProbeStart') await _start();
    if (method == 'httpProbeStop' && (!_started || !transport.connected)) {
      return <String, dynamic>{};
    }
    require(_started && transport.connected, '下载组件连接已中断');
    return asJson(await transport.call(method, args));
  });

  Future<void> begin(Json request) => _gate.run(() async {
    validateId(request.str('id'));
    await _start();
    require(
      !(store.data['nativeRemovals'] as List? ?? []).contains(
        request.str('id'),
      ),
      '此任务的旧下载缓存尚未清理，请重试',
    );
    await transport.call('begin', request);
  });
  Future<Json> snapshot(String id) => _gate.run(() async {
    validateId(id);
    require(_started && transport.connected, '下载组件连接中断，请继续任务');
    return asJson(await transport.call('snapshot', {'id': id}));
  });
  Future<void> pause(String id) => _gate.run(() async {
    validateId(id);
    if (_started && transport.connected) {
      await transport.call('pause', {'id': id});
    }
  });
  Future<void> remove(String id) => _gate.run(() async {
    validateId(id);
    if (_started && transport.connected) {
      await transport.call('remove', {'id': id});
      await _forgetRemoval(id);
    } else {
      await store.change((draft) {
        draft['nativeRemovals'] = <String>{
          ...(draft['nativeRemovals'] as List? ?? []).map((e) => '$e'),
          id,
        }.toList();
      });
    }
  });
  Future<void> close() => _gate.run(() async {
    await transport.dispose();
    _started = false;
  });
  Directory taskDirectory(String id) {
    validateId(id);
    final path = p.normalize(p.join(cache.path, id));
    require(p.equals(p.dirname(path), p.normalize(cache.path)), '无效的缓存路径');
    return Directory(path);
  }
}
