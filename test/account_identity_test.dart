import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';

Credential credential(
  String uid, {
  String token = 'fixture',
  int revision = 1,
}) => Credential('fixture', {
  'primary': token,
  'userId': uid,
  'nickname': uid,
}, updatedAt: revision);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [
    CloudPlatform.pan115,
    CloudPlatform.aliyun,
    CloudPlatform.pan123,
    CloudPlatform.quark,
  ]) {
    test(
      '${platform.key} adding an existing identity updates its original account and name',
      () async {
        final vault = Vault(StateStore.memory());
        await vault.putCredential(platform, credential('user-1'));
        final id = vault.activeAccountId(platform)!;
        await vault.renameAccount(platform, id, '工作账号');
        final pending = await vault.createAccount(platform);
        final service = AccountLoginService(
          vault,
          (_, _) async => const CloudAccount('新昵称'),
        );
        await service.submit(
          platform,
          (_) async => LoginResult(
            credential('user-1', token: 'new-token'),
            const CloudAccount('新昵称'),
          ),
          accountId: pending,
        );
        expect(vault.profiles(platform), hasLength(1));
        expect(vault.activeAccountId(platform), id);
        expect(vault.profiles(platform).single.customName, '工作账号');
        expect(vault.credential(platform)!.primary, 'new-token');
      },
    );
    test(
      '${platform.key} logging into a different identity keeps the previous account intact',
      () async {
        final vault = Vault(StateStore.memory());
        await vault.putCredential(platform, credential('old-user'));
        final id = vault.activeAccountId(platform)!;
        await vault.renameAccount(platform, id, '保留名称');
        final service = AccountLoginService(
          vault,
          (_, _) async => const CloudAccount('新用户'),
        );
        await service.submit(
          platform,
          (_) async => LoginResult(
            credential('different-user'),
            const CloudAccount('新用户'),
          ),
          accountId: id,
        );
        expect(vault.profiles(platform), hasLength(2));
        expect(vault.activeAccountId(platform), isNot(id));
        expect(vault.credentialFor(platform, id)!.field('userId'), 'old-user');
        expect(
          vault.profiles(platform).firstWhere((p) => p.id == id).name,
          '保留名称',
        );
        expect(
          vault.profiles(platform).firstWhere((p) => p.active).customName,
          isEmpty,
        );
      },
    );
  }
  test(
    'Nickname metadata refresh during cookie login does not cancel authentication',
    () async {
      final vault = Vault(StateStore.memory());
      const platform = CloudPlatform.quark;
      await vault.putCredential(platform, credential('user'));
      final id = vault.activeAccountId(platform)!;
      final pending = Completer<LoginResult>();
      final service = AccountLoginService(
        vault,
        (_, _) async => const CloudAccount('new'),
      );
      final login = service.submit(
        platform,
        (_) => pending.future,
        accountId: id,
      );
      await Future<void>.delayed(Duration.zero);
      await vault.updateAccountNickname(platform, id, 1, '刷新昵称');
      pending.complete(
        LoginResult(credential('user'), const CloudAccount('登录昵称')),
      );
      await login;
      expect(vault.profiles(platform).single.nickname, '登录昵称');
    },
  );
}
