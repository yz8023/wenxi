import '../../core/json.dart';
import '../../domain/models.dart';

String personalCloudDate(String value) {
  final compact = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$',
  ).firstMatch(value);
  if (compact != null) {
    return '${compact[1]}-${compact[2]}-${compact[3]} ${compact[4]}:${compact[5]}:${compact[6]}';
  }
  final milliseconds = int.tryParse(value);
  if (milliseconds != null &&
      milliseconds > 0 &&
      milliseconds <= 8640000000000000) {
    return DateTime.fromMillisecondsSinceEpoch(
      milliseconds,
    ).toIso8601String().replaceFirst('T', ' ').split('.').first;
  }
  return value;
}

abstract class PersonalCloudConnector extends CloudConnector {
  void personal(BrowseSession session) => require(
    session.platform == platform && session.mode == BrowseMode.personal,
    '请先打开${platform.shortName}个人网盘',
  );

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async => throw AppException(platform.shareUnavailableMessage);

  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) async => throw AppException('${platform.label}暂不支持创建分享');

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async => throw AppException('${platform.label}暂不支持转存分享');
}
