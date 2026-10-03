import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/github_update_service.dart';
import 'package:asterlink/data/remote_control_http.dart';
import 'package:asterlink/data/remote_control_service.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'github_update_support.dart';
import 'remote_control_support.dart';

void main() {
  late FakeControlFetcher primary, github;
  late StateStore store;
  late RemoteControlService control;
  late DateTime now;

  RemoteControlService create(
    StateStore state,
    FakeControlFetcher backup, {
    bool enabled = true,
    String endpoint = controlEndpoint,
  }) {
    return RemoteControlService(
      state,
      platform: 'android',
      currentBuild: 53,
      currentVersion: '0.5.0+53',
      configUrl: endpoint,
      enabled: enabled,
      fetcher: primary,
      clock: () => now,
      githubUpdates: GitHubUpdateService(
        repository: githubRepository,

        platform: 'android',
        architecture: 'arm64',
        fetcher: backup,
        clock: () => now,
      ),
    );
  }

  setUp(() {
    now = controlNow;
    primary = FakeControlFetcher();
    github = FakeControlFetcher(githubRelease());
    store = StateStore.memory();
    control = create(store, github);
  });
  tearDown(() async {
    control.close();
    await control.flushCache();
    store.dispose();
  });

  test(
    'A reachable primary remains authoritative even with no update or a lower revision',
    () async {
      for (final document in [
        controlJson(revision: 9, androidBuild: 60),
        controlJson(revision: 1),
        <String, dynamic>{},
        <String, dynamic>{
          'revision': 0,
          'updates': {
            'android': {'enabled': false},
          },
        },
      ]) {
        primary.text = jsonEncode(document);
        expect(
          await control.refresh(force: true),
          ControlRefreshResult.success,
        );
        expect(github.calls, isEmpty);
        expect(control.usingGithubUpdates, isFalse);
      }
      expect(control.availableUpdate, isNull);
    },
  );

  test(
    'GitHub is requested only after the primary request has actually failed',
    () async {
      final waiting = Completer<String>();
      primary.respond = (_) => waiting.future;
      final operation = control.refresh(force: true);
      expect(github.calls, isEmpty);
      expect(control.checking, isTrue);
      waiting.completeError(TimeoutException('Primary timed out'));
      expect(await operation, ControlRefreshResult.fallback);
      expect(github.calls, hasLength(1));
      expect(control.availableUpdate!.build, 54);
      expect(control.availableUpdate!.downloadUrl.host, 'github.com');
      expect(control.lastSuccess, isNull);
      expect(control.errorForSection('updates.android'), isNull);
      expect(control.errorForSection('announcement'), isNotNull);
    },
  );

  test(
    'HTTP access failure uses GitHub without replacing cached announcements or cloud rules',
    () async {
      primary.text = jsonEncode(
        controlJson(noticeId: 'existing', disabled: ['uc'], help: true),
      );
      await control.refresh(force: true);
      await control.flushCache();
      final cached = jsonEncode(store.data[RemoteControlService.cacheKey]);
      final lastSuccess = control.lastSuccess;
      primary.respond = (_) =>
          throw const ControlAccessException('HTTP error', statusCode: 503);
      expect(await control.refresh(force: true), ControlRefreshResult.fallback);
      expect(control.cloudEnabled(CloudPlatform.uc), isFalse);
      expect(control.config.announcement!.id, 'existing');
      expect(control.config.helpUrl, isNotNull);
      expect(control.config.updates, isEmpty);
      expect(control.lastSuccess, lastSuccess);
      expect(jsonEncode(store.data[RemoteControlService.cacheKey]), cached);
      expect(control.availableUpdate!.force, isFalse);
    },
  );

  test(
    'Reachable malformed or partial content never contacts GitHub',
    () async {
      for (final text in ['not JSON', '{"updates":{"android":"invalid"}}']) {
        primary.text = text;
        await control.refresh(force: true);
        expect(github.calls, isEmpty);
        expect(control.usingGithubUpdates, isFalse);
      }
      primary.respond = (_) =>
          throw const FormatException('Response exceeds the content limit');
      await control.refresh(force: true);
      expect(github.calls, isEmpty);
    },
  );

  test(
    'Primary recovery immediately removes a fallback, including after a format error',
    () async {
      primary.respond = (_) => throw StateError('offline');
      await control.refresh(force: true);
      expect(control.availableUpdate!.downloadUrl.host, 'github.com');
      primary.respond = null;
      primary.text = 'not JSON';
      expect(await control.refresh(force: true), ControlRefreshResult.failed);
      expect(control.availableUpdate, isNull);
      expect(control.usingGithubUpdates, isFalse);
      primary.text = jsonEncode(controlJson(androidBuild: 61));
      expect(await control.refresh(force: true), ControlRefreshResult.success);
      expect(control.availableUpdate!.build, 61);
      expect(
        control.availableUpdate!.downloadUrl.host,
        'download.example.test',
      );
      expect(github.calls, hasLength(1));
    },
  );

  test(
    'Failure of both sources is never a successful or up-to-date check',
    () async {
      primary.respond = (_) => throw StateError('offline');
      github.respond = (_) =>
          throw const ControlAccessException('Rate limited', statusCode: 403);
      expect(await control.refresh(force: true), ControlRefreshResult.failed);
      expect(control.usingGithubUpdates, isFalse);
      expect(control.errorForSection('updates.android'), isNotNull);
      expect(control.availableUpdate, isNull);
    },
  );

  test(
    'No matching release is a completed fallback check, not a fake update',
    () async {
      primary.respond = (_) => throw StateError('offline');
      github.text = jsonEncode(githubRelease(files: ['wenxi-windows-x64.exe']));
      expect(await control.refresh(force: true), ControlRefreshResult.fallback);
      expect(control.hasUpdateInformation, isFalse);
      expect(control.availableUpdate, isNull);
      expect(control.errorForSection('updates.android'), isNull);
    },
  );

  test('A cached required update cannot be withdrawn by GitHub', () async {
    primary.text = jsonEncode(controlJson(androidBuild: 60, force: true));
    await control.refresh(force: true);
    primary.respond = (_) => throw StateError('offline');
    await control.refresh(force: true);
    expect(control.requiredUpdate!.build, 60);
    expect(control.requiredUpdate!.downloadUrl.host, 'download.example.test');
    expect(control.requiredUpdate!.releaseKey, isNull);
  });

  test('Automatic primary retries reuse a recent GitHub result', () async {
    primary.respond = (_) => throw StateError('offline');
    await control.refresh();
    now = now.add(const Duration(seconds: 10));
    await control.refresh();
    expect(primary.calls, hasLength(2));
    expect(github.calls, hasLength(1));
    expect(control.availableUpdate!.build, 54);
  });

  test(
    'Ignored GitHub releases persist independently from primary build reminders',
    () async {
      primary.respond = (_) => throw StateError('offline');
      await control.refresh(force: true);
      final update = control.availableUpdate!;
      await control.ignoreUpdate(update.build, updateKey: update.key);
      expect(control.unreadUpdate, isNull);
      final reopenedState = StateStore.memory(
        asJson(jsonDecode(jsonEncode(store.data))),
      );
      final reopened = create(
        reopenedState,
        FakeControlFetcher(githubRelease()),
      );
      addTearDown(() async {
        reopened.close();
        await reopened.flushCache();
        reopenedState.dispose();
      });
      await reopened.refresh(force: true);
      expect(reopened.unreadUpdate, isNull);
      expect(reopened.availableUpdate, isNotNull);
      primary.respond = null;
      primary.text = jsonEncode(controlJson(androidBuild: 54));
      await control.refresh(force: true);
      expect(control.unreadUpdate!.build, 54);
      expect(control.unreadUpdate!.releaseKey, isNull);
    },
  );

  test(
    'Two version-only GitHub releases do not share a reminder or stale button identity',
    () async {
      primary.respond = (_) => throw StateError('offline');
      github.text = jsonEncode(
        githubRelease(tag: 'v0.6.0', files: ['app.apk']),
      );
      await control.refresh(force: true);
      final previous = control.availableUpdate!;
      expect(previous.build, 0);
      await control.ignoreUpdate(previous.build, updateKey: previous.key);
      github.text = jsonEncode(
        githubRelease(tag: 'v0.7.0', files: ['app.apk']),
      );
      await control.refresh(force: true);
      expect(control.unreadUpdate!.version, '0.7.0');
      await control.dismissUpdate(previous.build, updateKey: previous.key);
      expect(control.unreadUpdate!.version, '0.7.0');
      await control.dismissUpdate(0, updateKey: control.availableUpdate!.key);
      expect(control.unreadUpdate, isNull);
    },
  );

  test(
    'Disabled or invalid primary endpoints do not start either network source',
    () async {
      for (final disabled in [true, false]) {
        final alternate = FakeControlFetcher(githubRelease());
        final instance = create(
          store,
          alternate,
          enabled: !disabled,
          endpoint: disabled ? controlEndpoint : 'invalid://host',
        );
        expect(
          await instance.refresh(force: true),
          ControlRefreshResult.unconfigured,
        );
        expect(alternate.calls, isEmpty);
        instance.close();
      }
      expect(primary.calls, isEmpty);
    },
  );

  test('Closing during a fallback discards its late reply', () async {
    final waiting = Completer<String>(), entered = Completer<void>();
    primary.respond = (_) => throw StateError('offline');
    github.respond = (_) {
      entered.complete();
      return waiting.future;
    };
    final pending = control.refresh(force: true);
    await entered.future;
    control.close();
    waiting.complete(jsonEncode(githubRelease()));
    expect(await pending, ControlRefreshResult.closed);
    expect(control.availableUpdate, isNull);
    expect(github.closed, isTrue);
  });
}
