import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/crypto_box.dart';
import '../core/json.dart';
import '../domain/models.dart';

Uint8List _encryptSnapshot((Uint8List, String) args) =>
    CryptoBox.seal(args.$1, utf8.encode(args.$2));
Json _decryptSnapshot((Uint8List, Uint8List) args) =>
    asJson(jsonDecode(utf8.decode(CryptoBox.open(args.$1, args.$2))));

/// No plaintext accounts, cookies or signed URLs are written to state files.
class StateStore extends ChangeNotifier {
  StateStore._(this.file, this._key, this._data);
  final File? file;
  final Uint8List _key;
  Json _data;
  final _gate = AsyncGate();
  final _notificationZone = Zone.current;
  Json get data => _data;

  static Future<StateStore> open(
    Directory directory, {
    Uint8List? testKey,
  }) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}state-v1.enc');
    final backup = File('${file.path}.bak');
    final pending = File('${file.path}.tmp');
    Uint8List? key = testKey;
    if (key == null) {
      const storage = FlutterSecureStorage();
      final saved = await storage.read(key: 'asterlink.flutter.state-key.v1');
      if (saved != null) {
        key = base64Decode(saved);
      } else {
        require(
          !await file.exists() &&
              !await backup.exists() &&
              !await pending.exists(),
          '本地加密密钥缺失，请恢复备份；原文件已保留',
        );
        key = CryptoBox.random(32);
        await storage.write(
          key: 'asterlink.flutter.state-key.v1',
          value: base64Encode(key),
        );
      }
    }
    Json data = {};
    final candidates = [file, backup, pending];
    var found = false;
    var recovered = false;
    for (final candidate in candidates) {
      if (!await candidate.exists()) continue;
      found = true;
      try {
        data = await compute(_decryptSnapshot, (
          key,
          await candidate.readAsBytes(),
        ));
      } on AppException {
        continue;
      } on FormatException {
        continue;
      }
      require(data.integer('schema', 1) == 1, '本地数据来自更新版本，请更新应用');
      // Repair the primary before accepting edits. A corrupt primary must never
      // replace the sole authenticated backup during the next commit.
      if (candidate.path != file.path) {
        final repair = File('${file.path}.recovery');
        await repair.writeAsBytes(await candidate.readAsBytes(), flush: true);
        if (await file.exists()) {
          await file.rename(
            '${file.path}.corrupt-${DateTime.now().microsecondsSinceEpoch}',
          );
        }
        await repair.rename(file.path);
      }
      recovered = true;
      break;
    }
    require(!found || recovered, '无法解密本地数据，原文件已保留，请从备份恢复');
    return StateStore._(file, key, data);
  }

  factory StateStore.memory([Json? data]) => StateStore._(
    null,
    Uint8List(32),
    asJson(jsonDecode(jsonEncode(data ?? {}))),
  );

  Future<T> change<T>(T Function(Json draft) edit) => _gate.run(() async {
    final draft = asJson(jsonDecode(jsonEncode(_data)));
    final result = edit(draft);
    draft['schema'] = 1;
    if (file != null) {
      final bytes = await compute(_encryptSnapshot, (_key, jsonEncode(draft)));
      final temporary = File('${file!.path}.tmp');
      final backup = File('${file!.path}.bak');
      await temporary.writeAsBytes(bytes, flush: true);
      // Keep one previous authenticated snapshot until the next successful commit.
      if (await file!.exists()) {
        if (await backup.exists()) await backup.delete();
        await file!.rename(backup.path);
      }
      await temporary.rename(file!.path);
    }
    _data = draft;
    _notificationZone.run(notifyListeners);
    return result;
  });
  Future<void> put(String key, Object? value) => change((draft) {
    draft[key] = value;
  });
  Future<void> flush() => _gate.run(() async {});
}

abstract class CredentialStore {
  Credential? credential(CloudPlatform platform);
  String? secret(String key);
  Future<void> putCredential(CloudPlatform platform, Credential credential);
  Future<bool> replaceCredential(
    CloudPlatform platform,
    Credential? expected,
    Credential replacement, {
    bool Function()? canCommit,
  });
  Future<bool> putSecretForCredential(
    CloudPlatform platform,
    Credential expected,
    String key,
    String value,
  );
  Future<void> removeCredential(CloudPlatform platform);
  Future<void> putSecret(String key, String value);
  Future<void> removeSecret(String key);
}

class Vault implements CredentialStore {
  Vault(this.store);
  final StateStore store;
  final _accountScope = Object();

  String? activeAccountId(CloudPlatform platform) =>
      activeIdIn(store.data, platform);

  static String? activeIdIn(Json data, CloudPlatform platform) {
    final saved = data.obj('activeCloudAccounts').str(platform.key);
    if (saved.isNotEmpty) return saved;
    return data.obj('credentials')[platform.key] == null
        ? null
        : 'legacy-${platform.key}';
  }

  String? accountId(CloudPlatform platform) {
    final scope = Zone.current[_accountScope] as Map<CloudPlatform, String?>?;
    return scope?.containsKey(platform) == true
        ? scope![platform]
        : activeAccountId(platform);
  }

  T withAccount<T>(CloudPlatform platform, String? id, T Function() action) =>
      runZoned(
        action,
        zoneValues: {
          _accountScope: {
            ...?Zone.current[_accountScope] as Map<CloudPlatform, String?>?,
            platform: id,
          },
        },
      );

  static Credential? credentialIn(
    Json data,
    CloudPlatform platform,
    String? id,
  ) {
    if (id == null) return null;
    final value = id == activeIdIn(data, platform)
        ? data.obj('credentials')[platform.key]
        : data.obj('cloudAccounts').obj(platform.key).obj(id)['credential'];
    return value == null ? null : Credential.fromJson(asJson(value));
  }

  Credential? credentialFor(CloudPlatform platform, String? id) =>
      credentialIn(store.data, platform, id);

  static String customAccountName(Json record, Credential credential) {
    final name = record.str('name').trim();
    if (record.containsKey('nameIsCustom')) {
      return record.boolean('nameIsCustom') ? name : '';
    }
    // Older backups saved the displayed nickname in the custom-name field.
    return name == credential.field('nickname').trim() ||
            name == credential.label.trim()
        ? ''
        : name;
  }

  List<CloudAccountProfile> profiles(CloudPlatform platform) {
    final values = store.data.obj('cloudAccounts').obj(platform.key);
    final active = activeAccountId(platform);
    final ids = {...values.keys, ?active};
    return [
      for (final id in ids)
        if (credentialFor(platform, id) case final credential?)
          CloudAccountProfile(
            id,
            platform,
            customAccountName(
              values.obj(id),
              credential,
            ).ifEmpty(credential.field('nickname')).ifEmpty(credential.label),
            active: id == active,
            customName: customAccountName(values.obj(id), credential),
            nickname: credential.field('nickname'),
          ),
    ];
  }

  String? accountForRevision(CloudPlatform platform, int revision) {
    final matches = profiles(platform)
        .where((a) => credentialFor(platform, a.id)?.updatedAt == revision)
        .toList();
    return matches.length == 1 ? matches.single.id : null;
  }

  static bool accountSecret(CloudPlatform platform, String key) =>
      switch (platform) {
        CloudPlatform.pan123 => key.startsWith('pan123.'),
        CloudPlatform.xunlei => key.startsWith('xunlei.'),
        _ => false,
      };

  static void migrateDraft(Json draft) {
    final all = draft.obj('cloudAccounts'),
        active = draft.obj('activeCloudAccounts');
    for (final platform in CloudPlatform.values) {
      final savedRecords = all.obj(platform.key);
      for (final entry in savedRecords.entries.toList()) {
        final record = asJson(entry.value);
        if (record.containsKey('nameIsCustom') ||
            record['credential'] == null) {
          continue;
        }
        final name = customAccountName(
          record,
          Credential.fromJson(record.obj('credential')),
        );
        savedRecords[entry.key] = {
          ...record,
          'name': name,
          'nameIsCustom': name.isNotEmpty,
        };
      }
      if (savedRecords.isNotEmpty) all[platform.key] = savedRecords;
      final credential = draft.obj('credentials')[platform.key];
      if (credential == null) continue;
      final id = activeIdIn(draft, platform)!;
      final records = all.obj(platform.key), previous = records.obj(id);
      records[id] = {
        ...previous,
        'credential': credential,
        'secrets': {
          for (final e in draft.obj('secrets').entries)
            if (accountSecret(platform, e.key)) e.key: e.value,
        },
      };
      all[platform.key] = records;
      active[platform.key] = id;
    }
    draft['cloudAccounts'] = all;
    draft['activeCloudAccounts'] = active;
  }

  Future<void> initializeAccounts() => store.change(migrateDraft);

  static void activateDraft(Json draft, CloudPlatform platform, String? id) {
    final record = id == null
        ? <String, dynamic>{}
        : draft.obj('cloudAccounts').obj(platform.key).obj(id);
    final credentials = draft.obj('credentials')..remove(platform.key);
    if (record['credential'] != null) {
      credentials[platform.key] = record['credential'];
    }
    draft['credentials'] = credentials;
    final active = draft.obj('activeCloudAccounts')..remove(platform.key);
    if (id != null) active[platform.key] = id;
    draft['activeCloudAccounts'] = active;
    final secrets = draft.obj('secrets')
      ..removeWhere((key, _) => accountSecret(platform, key));
    draft['secrets'] = {...secrets, ...record.obj('secrets')};
  }

  static void _writeRecord(
    Json draft,
    CloudPlatform platform,
    String id,
    Json record,
  ) {
    draft['cloudAccounts'] = {
      ...draft.obj('cloudAccounts'),
      platform.key: {
        ...draft.obj('cloudAccounts').obj(platform.key),
        id: record,
      },
    };
    if (activeIdIn(draft, platform) == id) activateDraft(draft, platform, id);
  }

  Future<String> createAccount(CloudPlatform platform) => store.change((draft) {
    migrateDraft(draft);
    final id = newId();
    _writeRecord(draft, platform, id, {
      'name': '',
      'nameIsCustom': false,
      'secrets': <String, dynamic>{},
    });
    return id;
  });

  Future<void> activate(
    CloudPlatform platform,
    String id, {
    bool Function()? canCommit,
  }) => store.change((draft) {
    require(canCommit?.call() ?? true, '登录已取消或账号发生变化');
    migrateDraft(draft);
    require(credentialIn(draft, platform, id) != null, '该账号已移除，请重新添加');
    activateDraft(draft, platform, id);
  });

  Future<void> renameAccount(CloudPlatform platform, String id, String name) =>
      store.change((draft) {
        migrateDraft(draft);
        final record = draft.obj('cloudAccounts').obj(platform.key).obj(id);
        require(record.isNotEmpty, '该账号已移除');
        _writeRecord(draft, platform, id, {
          ...record,
          'name': name.trim(),
          'nameIsCustom': name.trim().isNotEmpty,
        });
      });

  Future<bool> updateAccountNickname(
    CloudPlatform platform,
    String id,
    int revision,
    String nickname,
  ) async {
    final name = nickname.trim();
    final current = credentialFor(platform, id);
    if (current == null || current.updatedAt != revision || name.isEmpty) {
      return false;
    }
    if (current.field('nickname') == name) return true;
    return store.change((draft) {
      migrateDraft(draft);
      final credential = credentialIn(draft, platform, id);
      if (credential == null || credential.updatedAt != revision) return false;
      final record = draft.obj('cloudAccounts').obj(platform.key).obj(id);
      _writeRecord(draft, platform, id, {
        ...record,
        'credential': credential.withFields({
          'nickname': name,
        }, preserveRevision: true).toJson(),
      });
      return true;
    });
  }

  Future<void> removeAccount(
    CloudPlatform platform,
    String id, {
    bool onlyIfEmpty = false,
  }) => store.change((draft) {
    migrateDraft(draft);
    if (onlyIfEmpty && credentialIn(draft, platform, id) != null) return;
    final records = draft.obj('cloudAccounts').obj(platform.key)..remove(id);
    draft['cloudAccounts'] = {
      ...draft.obj('cloudAccounts'),
      platform.key: records,
    };
    if (activeIdIn(draft, platform) == id) {
      activateDraft(
        draft,
        platform,
        records.entries
            .where((e) => asJson(e.value)['credential'] != null)
            .firstOrNull
            ?.key,
      );
    }
    draft['cloudFavorites'] = draft
        .list('cloudFavorites')
        .where(
          (f) => f.str('platform') != platform.key || f.str('accountId') != id,
        )
        .toList();
  });

  @override
  Credential? credential(CloudPlatform platform) =>
      credentialFor(platform, accountId(platform));

  @override
  String? secret(String key) {
    final platform = CloudPlatform.values
        .where((p) => accountSecret(p, key))
        .firstOrNull;
    if (platform == null) return store.data.obj('secrets')[key]?.toString();
    final id = accountId(platform);
    if (id == activeAccountId(platform)) {
      return store.data.obj('secrets')[key]?.toString();
    }
    return store.data
        .obj('cloudAccounts')
        .obj(platform.key)
        .obj(id ?? '')
        .obj('secrets')[key]
        ?.toString();
  }

  @override
  Future<void> putCredential(
    CloudPlatform platform,
    Credential credential,
  ) async {
    final owner = accountId(platform);
    await store.change((draft) {
      migrateDraft(draft);
      final id = owner ?? newId();
      final record = draft.obj('cloudAccounts').obj(platform.key).obj(id);
      require(owner == null || record.isNotEmpty, '该账号已移除');
      _writeRecord(draft, platform, id, {
        ...record,
        'credential': credential.toJson(),
      });
      if (owner == null) activateDraft(draft, platform, id);
    });
  }

  @override
  Future<bool> replaceCredential(
    CloudPlatform platform,
    Credential? expected,
    Credential replacement, {
    bool Function()? canCommit,
  }) {
    final owner = accountId(platform);
    return store.change((draft) {
      if (canCommit != null && !canCommit()) return false;
      migrateDraft(draft);
      final current = credentialIn(draft, platform, owner);
      if (expected == null ? current != null : !expected.sameAs(current)) {
        return false;
      }
      final id = owner ?? newId();
      final record = draft.obj('cloudAccounts').obj(platform.key).obj(id);
      if (owner != null && record.isEmpty) return false;
      final secrets = record.obj('secrets');
      if (platform == CloudPlatform.pan123) {
        secrets.remove('pan123.access_token');
      }
      _writeRecord(draft, platform, id, {
        ...record,
        'credential': replacement.toJson(),
        'secrets': secrets,
      });
      if (owner == null) activateDraft(draft, platform, id);
      return true;
    });
  }

  static String _loginUserId(Credential value) => value.field('userId').trim();
  static String _loginUsername(Credential value) {
    final name = value.field('loginUsername').ifEmpty(value.field('username'));
    return (name.isNotEmpty
            ? name
            : value.field('authType') == 'password'
            ? value.primary
            : '')
        .trim()
        .toLowerCase();
  }

  static bool sameLoginOwner(Credential left, Credential right) {
    final a = _loginUserId(left), b = _loginUserId(right);
    if (a.isNotEmpty && b.isNotEmpty) return a == b;
    final username = _loginUsername(left);
    return username.isNotEmpty && username == _loginUsername(right);
  }

  /// Commits an explicit login without overwriting a different remembered account.
  Future<String?> commitLogin(
    CloudPlatform platform,
    String pendingId,
    Credential? expected,
    Credential replacement, {
    required bool Function() canCommit,
  }) => store.change((draft) {
    if (!canCommit()) return null;
    migrateDraft(draft);
    final current = credentialIn(draft, platform, pendingId);
    if (expected == null ? current != null : !expected.sameAs(current)) {
      return null;
    }
    final records = draft.obj('cloudAccounts').obj(platform.key);
    if (!records.containsKey(pendingId)) return null;
    final match = records.entries.where((entry) {
      final record = asJson(entry.value);
      return record['credential'] != null &&
          sameLoginOwner(
            Credential.fromJson(record.obj('credential')),
            replacement,
          );
    }).firstOrNull;
    final different =
        current != null &&
        (_loginUserId(current).isNotEmpty &&
                _loginUserId(replacement).isNotEmpty &&
                _loginUserId(current) != _loginUserId(replacement) ||
            (_loginUserId(current).isEmpty ||
                    _loginUserId(replacement).isEmpty) &&
                _loginUsername(current).isNotEmpty &&
                _loginUsername(replacement).isNotEmpty &&
                _loginUsername(current) != _loginUsername(replacement));
    final id = match?.key ?? (different ? newId() : pendingId);
    final record = records.obj(id);
    final old = record['credential'] == null
        ? null
        : Credential.fromJson(record.obj('credential'));
    final remembered = <String, String>{};
    if (old != null && sameLoginOwner(old, replacement)) {
      for (final key in ['loginUsername', 'loginPassword']) {
        if (replacement.field(key).isEmpty && old.field(key).isNotEmpty) {
          remembered[key] = old.field(key);
        }
      }
    }
    final secrets = record.obj('secrets');
    if (platform == CloudPlatform.pan123) secrets.remove('pan123.access_token');
    _writeRecord(draft, platform, id, {
      'name': '',
      'nameIsCustom': false,
      ...record,
      'credential':
          (remembered.isEmpty
                  ? replacement
                  : replacement.withFields(remembered, preserveRevision: true))
              .toJson(),
      'secrets': secrets,
    });
    if (id != pendingId && current == null) {
      final updated = draft.obj('cloudAccounts').obj(platform.key)
        ..remove(pendingId);
      draft['cloudAccounts'] = {
        ...draft.obj('cloudAccounts'),
        platform.key: updated,
      };
    }
    return id;
  });

  @override
  Future<bool> putSecretForCredential(
    CloudPlatform platform,
    Credential expected,
    String key,
    String value,
  ) {
    final owner = accountId(platform);
    return store.change((draft) {
      migrateDraft(draft);
      final current = credentialIn(draft, platform, owner);
      if (owner == null || !expected.sameAs(current)) {
        return false;
      }
      _putSecretDraft(draft, platform, owner, key, value);
      return true;
    });
  }

  @override
  Future<void> removeCredential(CloudPlatform platform) async {
    final id = accountId(platform);
    if (id != null) await removeAccount(platform, id);
  }

  static void _putSecretDraft(
    Json draft,
    CloudPlatform? platform,
    String? id,
    String key,
    String? value,
  ) {
    if (platform == null || id == null) {
      final secrets = draft.obj('secrets')..remove(key);
      if (value != null) secrets[key] = value;
      draft['secrets'] = secrets;
      return;
    }
    final record = draft.obj('cloudAccounts').obj(platform.key).obj(id);
    require(record.isNotEmpty, '该账号已移除');
    final secrets = record.obj('secrets')..remove(key);
    if (value != null) secrets[key] = value;
    _writeRecord(draft, platform, id, {...record, 'secrets': secrets});
  }

  Future<void> _secretChange(String key, String? value) {
    final platform = CloudPlatform.values
        .where((p) => accountSecret(p, key))
        .firstOrNull;
    final id = platform == null ? null : accountId(platform);
    return store.change((draft) {
      migrateDraft(draft);
      _putSecretDraft(draft, platform, id, key, value);
    });
  }

  @override
  Future<void> putSecret(String key, String value) => _secretChange(key, value);
  @override
  Future<void> removeSecret(String key) => _secretChange(key, null);
}

class CloudAccountProfile {
  const CloudAccountProfile(
    this.id,
    this.platform,
    this.name, {
    required this.active,
    this.customName = '',
    this.nickname = '',
  });
  final String id, name, customName, nickname;
  final CloudPlatform platform;
  final bool active;
}
