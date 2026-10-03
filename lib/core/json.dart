import 'dart:convert';

typedef Json = Map<String, dynamic>;

Json asJson(Object? value) => value is Map
    ? value.map((k, v) => MapEntry(k.toString(), v))
    : <String, dynamic>{};
List<Json> objects(Object? value) =>
    value is List ? value.whereType<Map>().map(asJson).toList() : <Json>[];
Map<String, String> strings(Object? value) =>
    asJson(value).map((k, v) => MapEntry(k, v?.toString() ?? ''));

extension JsonRead on Json {
  String str(String key, [String fallback = '']) =>
      this[key]?.toString() ?? fallback;
  int integer(String key, [int fallback = 0]) => this[key] is num
      ? (this[key] as num).toInt()
      : int.tryParse(str(key)) ?? fallback;
  double number(String key, [double fallback = 0]) => this[key] is num
      ? (this[key] as num).toDouble()
      : double.tryParse(str(key)) ?? fallback;
  bool boolean(String key, [bool fallback = false]) => switch (this[key]) {
    true || 'true' || 1 => true,
    false || 'false' || 0 => false,
    _ => fallback,
  };
  Json obj(String key) => asJson(this[key]);
  List<Json> list(String key) => objects(this[key]);
}

String encoded(Object? value) => jsonEncode(value);

extension TextFallback on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

String form(Map<String, Object?> values) => values.entries
    .expand(
      (e) => (e.value is List ? e.value as List : [e.value]).map(
        (v) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(v?.toString() ?? '')}',
      ),
    )
    .join('&');
String query(String base, Map<String, Object?> values) =>
    '$base${base.contains('?') ? '&' : '?'}${form(values)}';

class AppException implements Exception {
  const AppException(this.message);
  final String message;
  @override
  String toString() => message;
}

void require(bool condition, String message) {
  if (!condition) throw AppException(message);
}

/// Serializes mutations while allowing the next operation after a failure.
class AsyncGate {
  Future<void> _tail = Future.value();
  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
