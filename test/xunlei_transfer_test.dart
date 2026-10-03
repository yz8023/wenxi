import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/xunlei.dart';
import 'package:asterlink/data/providers/xunlei_protocol.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/download/download_request.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/auth.dart';
import 'support.dart';

class _Fixture {
  _Fixture({Future<void> Function(Duration)? wait, int retries = 3}) {
    http = FakeHttp(
      (request) async => await intercept?.call(request) ?? respond(request),
    );
    outbox = CleanupOutbox(store, http);
    repository = CloudRepository(
      http,
      vault,
      outbox,
      preparationRetries: () => retries,
      retryWait: wait,
    );
  }

  final store = StateStore.memory();
  late final vault = Vault(store);
  late final FakeHttp http;
  late final CleanupOutbox outbox;
  late final CloudRepository repository;
  FutureOr<HttpResult?> Function(RecordedRequest)? intercept;
  XunleiConnector get connector =>
      repository.connector(CloudPlatform.xunlei) as XunleiConnector;
  final credential = Credential('fixture', const {
    'primary': 'fixture-access',
    'deviceId': 'fixture-device',
    'clientId': XunleiProtocol.clientId,
    'clientSecret': 'fixture-client-secret',
    'clientVersion': XunleiProtocol.version,
    'refreshToken': 'fixture-refresh',
    'captchaToken': 'fixture-captcha',
  }, updatedAt: 42);
  final personal = BrowseSession(
    platform: CloudPlatform.xunlei,
    mode: BrowseMode.personal,
    title: 'personal',
    rootId: '',
  );
  final share = BrowseSession(
    platform: CloudPlatform.xunlei,
    mode: BrowseMode.share,
    title: 'share',
    rootId: '',
    metadata: const {'shareId': 'share', 'passCodeToken': 'fixture-pass-token'},
  );
  final file = const CloudFile(
    id: 'shared-file',
    name: 'example.zip',
    size: 4,
    hashType: 'md5',
    hashValue: '0123456789abcdef0123456789abcdef',
  );
  bool wrapped = true, dataEnvelope = false, failRestore = false;
  String folderName = '';
  int refreshes = 0;

  Future<void> login() => vault.putCredential(CloudPlatform.xunlei, credential);

  HttpResult respond(RecordedRequest request) {
    final path = request.uri.path;
    if (path == '/v1/auth/token') {
      refreshes++;
      return jsonResponse({
        'access_token': 'renewed-access',
        'refresh_token': 'renewed-refresh',
      });
    }
    if (path == '/v1/shield/captcha/init') {
      return jsonResponse({'captcha_token': 'refreshed-captcha'});
    }
    if (path == '/drive/v1/files' && request.method == 'POST') {
      expect(request.json['kind'], 'drive#folder');
      expect(request.json['space'], '');
      folderName = request.json.str('name');
      final folder = <String, dynamic>{
        'id': 'temporary-folder',
        'name': folderName,
        'kind': 'drive#folder',
        'parent_id': request.json['parent_id'],
        'phase': 'PHASE_TYPE_COMPLETE',
      };
      final response = wrapped ? <String, dynamic>{'file': folder} : folder;
      return jsonResponse(dataEnvelope ? {'data': response} : response, 201);
    }
    if (path == '/drive/v1/share/restore') {
      expect(request.json['parent_id'], 'temporary-folder');
      expect(request.json['file_ids'], ['shared-file']);
      expect(request.json['pass_code_token'], 'fixture-pass-token');
      expect(outbox.pendingCount, 1);
      if (failRestore) {
        return jsonResponse({
          'error': 'file_space_not_enough',
          'error_description': '云盘空间不足',
        }, 403);
      }
      return jsonResponse({
        'restore_status': 'RESTORE_COMPLETE',
        'params': {
          'trace_file_ids': encoded({'shared-file': 'saved-file'}),
        },
      });
    }
    if (path == '/drive/v1/files/saved-file') {
      expect(request.uri.queryParametersAll['with'], [
        'hdr10',
        'subtitle_files',
        'task',
        'public_share_tag',
      ]);
      return jsonResponse({
        'id': 'saved-file',
        'name': file.name,
        'kind': 'drive#file',
        'size': 4,
        'links': {
          'application/octet-stream': {
            'url': 'https://cdn.example/file?sign=a%2Bb',
          },
        },
      });
    }
    if (path == '/drive/v1/files:batchDelete') {
      expect(request.json['ids'], ['temporary-folder']);
      expect(request.json['space'], '');
      return jsonResponse({});
    }
    throw StateError('Unexpected request: ${request.method} $path');
  }
}

void _failureAndCleanupTests() {
  test('Create response envelope and task IDs never replace file.id', () async {
    final fixture = _Fixture();
    fixture.intercept = (request) {
      if (request.method == 'POST' && request.uri.path == '/drive/v1/files') {
        final response = fixture.respond(request).json;
        return jsonResponse({
          ...response,
          'id': 'not-a-folder',
          'task': {'id': 'not-a-folder'},
        });
      }
      return null;
    };
    await fixture.login();
    final spec = await fixture.repository.prepare(fixture.share, fixture.file);
    expect(spec.cleanup!.action!.str('folderId'), 'temporary-folder');
    expect(
      fixture.http.calls.any((r) => r.url.contains('not-a-folder')),
      isFalse,
    );
  });

  final invalidFolders = <String, Json>{
    'empty response': {},
    'null file with envelope ID': {'file': null, 'id': 'job'},
    'string file': {'file': 'folder', 'id': 'job'},
    'null ID': {
      'file': {'id': null},
    },
    'literal null ID': {
      'file': {'id': 'null'},
    },
    'blank ID': {
      'file': {'id': '  '},
    },
    'object ID': {
      'file': {
        'id': {'value': 'folder'},
      },
    },
    'nonfolder': {
      'file': {'id': 'file', 'kind': 'drive#file'},
    },
    'task object': {'id': 'job', 'kind': 'drive#task'},
    'envelope ID without file': {
      'id': 'job',
      'task': {'id': 'job'},
    },
    'pending directory': {
      'file': {'id': 'folder', 'phase': 'PHASE_TYPE_PENDING'},
    },
    'failed directory': {
      'file': {'id': 'folder', 'phase': 'PHASE_TYPE_ERROR'},
    },
    'failed task': {
      'file': {'id': 'folder'},
      'task': {'phase': 'PHASE_TYPE_ERROR'},
    },
    'wrong parent': {
      'file': {'id': 'folder', 'parent_id': 'another-parent'},
    },
    'wrong temporary name': {
      'file': {'id': 'folder', 'name': 'existing-user-folder'},
    },
  };
  for (final entry in invalidFolders.entries) {
    test(
      'Invalid create result (${entry.key}) cannot restore or stage deletion',
      () async {
        final fixture = _Fixture();
        fixture.intercept = (_) => jsonResponse(entry.value);
        await fixture.login();
        await expectLater(
          fixture.repository.prepare(fixture.share, fixture.file),
          throwsA(isA<AppException>()),
        );
        expect(fixture.http.calls, hasLength(1));
        expect(fixture.outbox.pendingCount, 0);
      },
    );
  }

  for (final status in [200, 403]) {
    test(
      'Create API error (HTTP $status) preserves the service explanation',
      () async {
        final fixture = _Fixture();
        fixture.intercept = (_) => jsonResponse({
          'error_code': 8,
          'error': 'file_space_not_enough',
          'error_description': '云盘空间不足',
        }, status);
        await fixture.login();
        await expectLater(
          fixture.repository.prepare(fixture.share, fixture.file),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              contains('空间不足'),
            ),
          ),
        );
        expect(fixture.outbox.pendingCount, 0);
        expect(fixture.http.calls, hasLength(1));
      },
    );
  }

  for (final reason in ['missing URL', 'invalid URL', 'wrong size']) {
    test(
      'Invalid personal link ($reason) releases only the created directory',
      () async {
        final fixture = _Fixture();
        fixture.intercept = (request) =>
            request.uri.path.endsWith('/saved-file')
            ? jsonResponse({
                'id': 'saved-file',
                'size': reason == 'wrong size' ? 40 : 4,
                'web_content_link': reason == 'missing URL'
                    ? ''
                    : reason == 'invalid URL'
                    ? 'file:///local-file'
                    : 'https://cdn.example/file',
              })
            : null;
        await fixture.login();
        await expectLater(
          fixture.repository.prepare(fixture.share, fixture.file),
          throwsA(isA<AppException>()),
        );
        expect(fixture.outbox.pendingCount, 1);
        expect(
          asJson(
            fixture.store.data.obj('cleanups').values.single,
          ).boolean('ready'),
          isTrue,
        );
        await fixture.outbox.drain();
        expect(fixture.outbox.pendingCount, 0);
      },
    );
  }

  test(
    'Cancellation after folder creation stops link lookup and releases cleanup',
    () async {
      final fixture = _Fixture(), scope = RequestScope();
      fixture.intercept = (request) {
        if (request.uri.path == '/drive/v1/share/restore') scope.cancel();
        return null;
      };
      await fixture.login();
      await expectLater(
        scope.run(
          () => fixture.repository.prepare(fixture.share, fixture.file),
        ),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('已取消'),
          ),
        ),
      );
      expect(
        fixture.http.calls.any((r) => r.uri.path.endsWith('/saved-file')),
        isFalse,
      );
      expect(fixture.outbox.pendingCount, 1);
      await fixture.outbox.drain();
      expect(fixture.outbox.pendingCount, 0);
    },
  );

  for (final changedDuringRestore in [false, true]) {
    test(
      'Account switch ${changedDuringRestore ? 'during restore' : 'after preparation'} '
      'defers cleanup without using new account',
      () async {
        final fixture = _Fixture();
        await fixture.login();
        Future<void> switchAccount() => fixture.vault.putCredential(
          CloudPlatform.xunlei,
          Credential('fixture', const {
            'primary': 'other-account',
          }, updatedAt: 99),
        );
        if (changedDuringRestore) {
          fixture.intercept = (request) async {
            if (request.uri.path == '/drive/v1/share/restore') {
              await switchAccount();
            }
            return null;
          };
          await expectLater(
            fixture.repository.prepare(fixture.share, fixture.file),
            throwsA(
              isA<AppException>().having(
                (e) => e.message,
                'message',
                contains('账号已变化'),
              ),
            ),
          );
        } else {
          final spec = await fixture.repository.prepare(
            fixture.share,
            fixture.file,
          );
          await fixture.outbox.release(spec.cleanup);
          await fixture.outbox.ready(spec.cleanup);
          await switchAccount();
        }
        final before = fixture.http.calls.length;
        await fixture.outbox.drain();
        expect(fixture.http.calls.length, before);
        expect(fixture.outbox.pendingCount, 1);
        await fixture.login();
        await fixture.outbox.drain();
        expect(fixture.outbox.pendingCount, 0);
      },
    );
  }

  for (final proactive in [false, true]) {
    test('Cleanup renews ${proactive ? 'expired JWT' : 'HTTP 401 token'} '
        'once and uses current credentials', () async {
      final fixture = _Fixture();
      await fixture.login();
      final spec = await fixture.repository.prepare(
        fixture.share,
        fixture.file,
      );
      expect(spec.cleanup!.headers, isEmpty);
      expect(
        encoded(spec.cleanup!.toJson()),
        isNot(contains('fixture-access')),
      );
      expect(
        fixture.http.calls.any((r) => r.uri.path.contains('/captcha/')),
        isFalse,
      );
      await fixture.outbox.release(spec.cleanup);
      await fixture.outbox.ready(spec.cleanup);
      if (proactive) {
        final token =
            'e30.${base64Url.encode(utf8.encode(encoded({'exp': 1})))}.sig';
        await fixture.vault.putCredential(
          CloudPlatform.xunlei,
          fixture.credential.withFields({
            'primary': token,
            'accessToken': token,
          }, preserveRevision: true),
        );
      }
      fixture.intercept = (request) {
        if (request.uri.path == '/drive/v1/files:batchDelete') {
          if (request.headers['Authorization'] != 'Bearer renewed-access') {
            return jsonResponse({'error': 'unauthenticated'}, 401);
          }
        }
        if (request.uri.path == '/v1/shield/captcha/init') {
          expect(request.json['action'], 'POST:/drive/v1/files:batchDelete');
        }
        return null;
      };
      await fixture.outbox.drain();
      expect(fixture.refreshes, 1);
      expect(fixture.outbox.pendingCount, 0);
      expect(
        fixture.vault.credential(CloudPlatform.xunlei)!.primary,
        'renewed-access',
      );
      expect(fixture.vault.credential(CloudPlatform.xunlei)!.updatedAt, 42);
    });
  }

  test('Cleanup refreshes expired captcha for the delete action', () async {
    final fixture = _Fixture();
    await fixture.login();
    final spec = await fixture.repository.prepare(fixture.share, fixture.file);
    await fixture.outbox.release(spec.cleanup);
    await fixture.outbox.ready(spec.cleanup);
    fixture.intercept = (request) {
      if (request.uri.path == '/drive/v1/files:batchDelete' &&
          request.headers['X-Captcha-Token'] != 'refreshed-captcha') {
        return jsonResponse({'error': 'captcha_invalid'}, 403);
      }
      if (request.uri.path == '/v1/shield/captcha/init') {
        expect(request.json['action'], 'POST:/drive/v1/files:batchDelete');
      }
      return null;
    };
    await fixture.outbox.drain();
    expect(fixture.outbox.pendingCount, 0);
    expect(
      fixture.http.calls.where((r) => r.uri.path.contains('/captcha/')),
      hasLength(1),
    );
  });

  test('A cleanup business error remains pending for retry', () async {
    final fixture = _Fixture();
    await fixture.login();
    final spec = await fixture.repository.prepare(fixture.share, fixture.file);
    await fixture.outbox.release(spec.cleanup);
    await fixture.outbox.ready(spec.cleanup);
    fixture.intercept = (request) => request.uri.path.endsWith('batchDelete')
        ? jsonResponse({'error_code': 8, 'error_description': '服务器忙'})
        : null;
    await fixture.outbox.drain();
    expect(fixture.outbox.pendingCount, 1);
    expect(
      asJson(
        fixture.store.data.obj('cleanups').values.single,
      ).integer('attempts'),
      1,
    );
    fixture.intercept = null;
    await fixture.outbox.drain();
    expect(fixture.outbox.pendingCount, 0);
  });

  test(
    'Old HTTP cleanup records keep their original identity and still work',
    () async {
      final fixture = _Fixture();
      final cleanup = DownloadCleanup(
        url: '${XunleiConnector.base}/drive/v1/files:batchDelete',
        body: encoded({
          'ids': ['temporary-folder'],
          'space': '',
        }),
        headers: const {'Authorization': 'Bearer legacy-access'},
      );
      await fixture.outbox.stage(cleanup);
      await fixture.outbox.ready(cleanup);
      await fixture.outbox.drain();
      expect(fixture.outbox.pendingCount, 0);
      expect(
        fixture.http.calls.single.headers['Authorization'],
        'Bearer legacy-access',
      );
      expect(cleanup.toJson().containsKey('action'), isFalse);
    },
  );
}

void _readRetryTests() {
  test(
    'Transient link failure retries the read without duplicating folder creation or share restore',
    () async {
      final delays = <Duration>[];
      final fixture = _Fixture(wait: (delay) async => delays.add(delay));
      await fixture.login();
      var links = 0;
      fixture.intercept = (request) {
        if (request.uri.path.endsWith('/saved-file') && ++links < 3) {
          return const HttpResult(503, '<html>unavailable</html>');
        }
        return null;
      };
      final log = DiagnosticLog.open(null);
      final previousLog = DiagnosticLog.active;
      DiagnosticLog.active = log;
      addTearDown(() {
        DiagnosticLog.active = previousLog;
        log.close();
      });
      const context = DownloadRequestContext(
        id: 'download-fixture',
        retries: 2,
      );
      final spec = await context.run(
        () => fixture.repository.prepare(fixture.share, fixture.file),
      );
      expect(spec.url, 'https://cdn.example/file?sign=a%2Bb');
      expect(links, 3);
      expect(delays, [const Duration(seconds: 2), const Duration(seconds: 5)]);
      expect(
        fixture.http.calls.where(
          (r) => r.method == 'POST' && r.uri.path == '/drive/v1/files',
        ),
        hasLength(1),
      );
      expect(
        fixture.http.calls.where((r) => r.uri.path.endsWith('/share/restore')),
        hasLength(1),
      );
      final events = log
          .entries()
          .where((e) => e.event.startsWith('download.prepare.'))
          .toList();
      expect(
        events.map((e) => e.event),
        containsAll([
          'download.prepare.start',
          'download.prepare.retry',
          'download.prepare.ready',
        ]),
      );
      expect(
        events.every(
          (e) =>
              e.data.obj('fields').str('ref') ==
              DiagnosticLog.reference(context.id),
        ),
        isTrue,
      );
      final retries = events.where((e) => e.event.endsWith('.retry'));
      expect(retries, hasLength(2));
      expect(
        retries.every(
          (e) => e.data.obj('fields').str('stage') == 'downloadLink',
        ),
        isTrue,
      );
      final diagnostic = events.map((e) => e.detail).join();
      for (final private in [
        fixture.file.name,
        fixture.credential.primary,
        'fixture-pass-token',
        'https://cdn.example',
      ]) {
        expect(diagnostic, isNot(contains(private)));
      }
    },
  );

  test(
    'Exhausted link retries retain exactly one owned folder for cleanup',
    () async {
      final fixture = _Fixture(wait: (_) async {}, retries: 2);
      await fixture.login();
      fixture.intercept = (request) => request.uri.path.endsWith('/saved-file')
          ? const HttpResult(503, '{}')
          : null;
      await expectLater(
        fixture.repository.prepare(fixture.share, fixture.file),
        throwsA(isA<HttpRequestFailure>()),
      );
      expect(
        fixture.http.calls.where((r) => r.uri.path.endsWith('/saved-file')),
        hasLength(3),
      );
      expect(
        fixture.http.calls.where((r) => r.uri.path.endsWith('/share/restore')),
        hasLength(1),
      );
      expect(fixture.store.data.obj('cleanups').values, hasLength(1));
      expect(
        asJson(
          fixture.store.data.obj('cleanups').values.single,
        ).boolean('ready'),
        isTrue,
      );
      await fixture.outbox.drain();
      expect(fixture.outbox.pendingCount, 0);
      expect(
        fixture.http.calls.where((r) => r.uri.path.endsWith('batchDelete')),
        hasLength(1),
      );
    },
  );

  for (final path in ['/drive/v1/files', '/drive/v1/share/restore']) {
    test(
      'Transient mutation failure at $path is never automatically resubmitted',
      () async {
        final fixture = _Fixture(wait: (_) async {});
        await fixture.login();
        fixture.intercept = (request) =>
            request.method == 'POST' && request.uri.path == path
            ? const HttpResult(503, '<html>unavailable</html>')
            : null;
        await expectLater(
          fixture.repository.prepare(fixture.share, fixture.file),
          throwsA(isA<AppException>()),
        );
        expect(
          fixture.http.calls.where(
            (r) => r.method == 'POST' && r.uri.path == path,
          ),
          hasLength(1),
        );
        expect(
          fixture.http.calls.where((r) => r.uri.path.endsWith('/saved-file')),
          isEmpty,
        );
      },
    );
  }

  test(
    'Cancellation during Retry-After preserves the staged cleanup and sends no extra read',
    () async {
      final waiting = Completer<void>();
      final fixture = _Fixture(
        wait: (delay) async {
          waiting.complete();
          await RequestScope.wait(delay);
        },
      );
      await fixture.login();
      fixture.intercept = (request) => request.uri.path.endsWith('/saved-file')
          ? const HttpResult(429, '{}', {
              'retry-after': ['3600'],
            })
          : null;
      final scope = RequestScope();
      final work = scope.run(
        () => fixture.repository.prepare(fixture.share, fixture.file),
      );
      final checked = expectLater(work, throwsA(isA<AppException>()));
      await waiting.future;
      scope.cancel();
      await checked.timeout(const Duration(seconds: 1));
      expect(
        fixture.http.calls.where((r) => r.uri.path.endsWith('/saved-file')),
        hasLength(1),
      );
      expect(
        asJson(
          fixture.store.data.obj('cleanups').values.single,
        ).boolean('ready'),
        isTrue,
      );
      await fixture.outbox.drain();
      expect(fixture.outbox.pendingCount, 0);
    },
  );

  test(
    'Account replacement during retry stops the read and cannot clean with the new account',
    () async {
      late _Fixture fixture;
      fixture = _Fixture(
        wait: (_) => fixture.vault.putCredential(
          CloudPlatform.xunlei,
          Credential('replacement', const {
            'primary': 'different-account',
          }, updatedAt: 99),
        ),
      );
      await fixture.login();
      fixture.intercept = (request) => request.uri.path.endsWith('/saved-file')
          ? const HttpResult(503, '{}')
          : null;
      await expectLater(
        fixture.repository.prepare(fixture.share, fixture.file),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('账号已变化'),
          ),
        ),
      );
      expect(
        fixture.http.calls.where((r) => r.uri.path.endsWith('/saved-file')),
        hasLength(1),
      );
      final sent = fixture.http.calls.length;
      await fixture.outbox.drain();
      expect(fixture.http.calls.length, sent);
      expect(fixture.outbox.pendingCount, 1);
    },
  );

  for (final initial in [true, false]) {
    test(
      '${initial ? 'Initial queued preparation' : 'Expired link refresh'} shares retries across origin restoration and link reads',
      () async {
        final delays = <Duration>[];
        final fixture = _Fixture(
          wait: (delay) async => delays.add(delay),
          retries: 2,
        );
        await fixture.login();
        var lists = 0, links = 0;
        fixture.intercept = (request) {
          if (request.method == 'GET' &&
              request.uri.path == '/drive/v1/files') {
            if (++lists == 1) return const HttpResult(503, '{}');
            return jsonResponse({
              'files': [
                {
                  'id': fixture.file.id,
                  'name': fixture.file.name,
                  'size': 4,
                  'kind': 'drive#file',
                },
              ],
            });
          }
          if (request.uri.path.endsWith('/shared-file')) {
            if (++links == 1) return const HttpResult(503, '{}');
            return jsonResponse({
              'id': fixture.file.id,
              'name': fixture.file.name,
              'size': 4,
              'web_content_link': 'https://cdn.example/renewed',
            });
          }
          return null;
        };
        final planned = fixture.repository.planDownload(
          fixture.personal,
          fixture.file,
        );
        final previous = initial
            ? planned
            : DownloadSpec.fromJson({
                ...planned.toJson(),
                'url': 'https://cdn.example/expired',
              });
        final ready = await fixture.repository.refresh(previous);
        expect(ready.url, 'https://cdn.example/renewed');
        expect(lists, 2);
        expect(links, 2);
        expect(delays, [
          const Duration(seconds: 2),
          const Duration(seconds: 5),
        ]);
        expect(fixture.http.calls.every((r) => r.method == 'GET'), isTrue);
      },
    );
  }
}

void _shareParentTests() {
  final link = ParsedLink(
    source: 'https://pan.xunlei.com/s/fixture?pwd=pass',
    url: 'https://pan.xunlei.com/s/fixture?pwd=pass',
    kind: LinkKind.cloudShare,
    platform: CloudPlatform.xunlei,
    shareId: 'share',
    passcode: 'pass',
  );
  _Fixture fixture({
    String rootId = 'shared-file',
    int rootSize = 4,
    AppException? outsideError,
  }) {
    final f = _Fixture();
    f.intercept = (request) {
      final path = request.uri.path;
      if (path == '/drive/v1/share') {
        return jsonResponse({
          'pass_code_token': 'fixture-pass-token',
          'files': [
            {
              'id': rootId,
              'name': f.file.name,
              'size': rootSize,
              'parent_id': 'owner-only-folder',
              'kind': 'drive#file',
            },
          ],
        });
      }
      if (path == '/drive/v1/share/detail') {
        if (request.uri.queryParameters['parent_id'] == 'shared-folder') {
          return jsonResponse({
            'files': [
              {
                'id': f.file.id,
                'name': f.file.name,
                'size': 4,
                'parent_id': 'shared-folder',
                'kind': 'drive#file',
              },
            ],
          });
        }
        if (outsideError != null) throw outsideError;
        return jsonResponse({
          'error': 'permission_denied',
          'error_description': '无权访问',
        }, 403);
      }
      return null;
    };
    return f;
  }

  Future<DownloadSpec> legacyPlan(_Fixture f) async {
    await f.login();
    final session = await f.repository.share(link);
    return f.repository.planDownload(
      session,
      CloudFile(
        id: f.file.id,
        name: f.file.name,
        size: 4,
        parentId: 'owner-only-folder',
      ),
    );
  }

  test(
    'Xunlei root share download never accesses the owner-only parent',
    () async {
      final f = fixture();
      await f.login();
      final session = await f.repository.share(link);
      final file = (await f.repository.list(session, session.rootId)).single;
      expect(file.parentId, session.rootId);
      final spec = await f.repository.refresh(
        f.repository.planDownload(session, file),
      );
      expect(spec.expectedSize, 4);
      expect(spec.needsPreparation, false);
      expect(
        f.http.calls.where((r) => r.uri.path == '/drive/v1/share/detail'),
        isEmpty,
      );
      expect(DownloadOrigin.fromJson(spec.source!).file.parentId, '');
    },
  );
  test(
    'A shared subfolder retains its own parent during origin refresh',
    () async {
      final f = fixture();
      await f.login();
      final session = await f.repository.share(link);
      final file = (await f.repository.list(session, 'shared-folder')).single;
      expect(file.parentId, 'shared-folder');
      final restored = await f.repository.restoreOrigin(
        DownloadOrigin.fromJson(
          f.repository.planDownload(session, file).source!,
        ),
      );
      expect(restored.file.parentId, 'shared-folder');
      expect(
        f.http.calls
            .where((r) => r.uri.path == '/drive/v1/share/detail')
            .map((r) => r.uri.queryParameters['parent_id']),
        ['shared-folder', 'shared-folder'],
      );
    },
  );
  test(
    'Old Xunlei failed tasks recover the exact root file and persist the correction',
    () async {
      final f = fixture();
      final spec = await f.repository.refresh(await legacyPlan(f));
      expect(DownloadOrigin.fromJson(spec.source!).file.parentId, '');
      await f.outbox.release(spec.cleanup);
      await f.outbox.ready(spec.cleanup);
      await f.outbox.drain();
      await f.repository.refresh(spec);
      expect(
        f.http.calls.where((r) => r.uri.path == '/drive/v1/share/detail'),
        hasLength(1),
      );
    },
  );
  test(
    'Xunlei legacy recovery rejects same-name files with a different ID',
    () async {
      final f = fixture(rootId: 'different-file');
      await expectLater(
        f.repository.refresh(await legacyPlan(f)),
        throwsA(isA<XunleiShareParentUnavailable>()),
      );
      expect(f.http.calls.where((r) => r.method == 'POST'), isEmpty);
    },
  );
  test('Xunlei legacy recovery validates content before copying', () async {
    final f = fixture(rootSize: 5);
    await expectLater(
      f.repository.refresh(await legacyPlan(f)),
      throwsA(
        isA<AppException>().having(
          (e) => e.message,
          'message',
          contains('内容已变化'),
        ),
      ),
    );
    expect(f.http.calls.where((r) => r.method == 'POST'), isEmpty);
  });
  for (final error in [
    const AppException('网络暂时不可用'),
    const AccountLoginRequired('请重新登录'),
    const AppException('请求已取消'),
  ]) {
    test('Xunlei legacy recovery does not hide ${error.message}', () async {
      final f = fixture(outsideError: error);
      await expectLater(
        f.repository.refresh(await legacyPlan(f)),
        throwsA(same(error)),
      );
      expect(
        f.http.calls.where((r) => r.uri.path == '/drive/v1/share'),
        hasLength(2),
      );
      expect(f.http.calls.where((r) => r.method == 'POST'), isEmpty);
    });
  }
  test('Personal Xunlei file parents still use the actual cloud directory', () {
    final f = _Fixture();
    final files = f.connector.files({
      'files': [
        {
          'id': 'personal-file',
          'name': 'personal.bin',
          'parent_id': 'actual-parent',
          'kind': 'drive#file',
        },
      ],
    }, 'requested-parent');
    expect(files.single.parentId, 'actual-parent');
  });
}

void main() {
  _shareParentTests();
  _readRetryTests();
  _failureAndCleanupTests();
  for (final wrapped in [true, false]) {
    for (final dataEnvelope in [false, true]) {
      test('Create folder reads ${wrapped ? 'file.id' : 'legacy id'} '
          'with data envelope $dataEnvelope', () async {
        final fixture = _Fixture()
          ..wrapped = wrapped
          ..dataEnvelope = dataEnvelope;
        await fixture.login();
        final folder = await fixture.connector.createFolder(
          fixture.personal,
          'parent',
          '新文件夹',
          fixture.credential,
        );
        expect(folder.id, 'temporary-folder');
        expect(folder.name, '新文件夹');
        expect(folder.parentId, 'parent');
        expect(folder.isDirectory, isTrue);
        expect(fixture.http.calls, hasLength(1));
      });
    }
  }

  test('Official create response reaches restore and personal download link; '
      'temporary folder stays until released', () async {
    final fixture = _Fixture();
    await fixture.login();
    final spec = await fixture.repository.prepare(fixture.share, fixture.file);
    expect(spec.url, 'https://cdn.example/file?sign=a%2Bb');
    expect(spec.fileName, fixture.file.name);
    expect(spec.expectedSize, 4);
    expect(spec.headers, {'User-Agent': XunleiProtocol.appUa});
    expect(spec.checksumValue, fixture.file.hashValue);
    expect(spec.source!.obj('file').str('id'), 'shared-file');
    expect(fixture.folderName, startsWith('AsterLink临时转存_'));
    expect(spec.cleanup, isNotNull);
    await fixture.outbox.ready(spec.cleanup);
    await fixture.outbox.drain();
    expect(fixture.outbox.pendingCount, 1);
    expect(
      fixture.http.calls.where((r) => r.uri.path.endsWith('batchDelete')),
      isEmpty,
    );
    await fixture.outbox.release(spec.cleanup);
    await fixture.outbox.ready(spec.cleanup);
    await fixture.outbox.drain();
    expect(fixture.outbox.pendingCount, 0);
    expect(
      fixture.http.calls.where((r) => r.uri.path.endsWith('batchDelete')),
      hasLength(1),
    );
  });

  test(
    'Restore failure keeps the created folder registered for cleanup',
    () async {
      final fixture = _Fixture()..failRestore = true;
      await fixture.login();
      await expectLater(
        fixture.repository.prepare(fixture.share, fixture.file),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('空间不足'),
          ),
        ),
      );
      expect(fixture.outbox.pendingCount, 1);
      expect(
        asJson(
          fixture.store.data.obj('cleanups').values.single,
        ).boolean('ready'),
        isTrue,
      );
      expect(
        fixture.http.calls.any((r) => r.uri.path.endsWith('/saved-file')),
        isFalse,
      );
      await fixture.outbox.drain();
      expect(fixture.outbox.pendingCount, 0);
    },
  );
}
