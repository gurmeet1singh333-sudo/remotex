import 'package:remotex/core/protocol/authorization_scope.dart';

class PairedDevice {
  PairedDevice({
    required this.id,
    required this.name,
    required this.hostId,
    required this.publicKey,
    required this.addedAt,
    Set<AuthorizationScope> authorizationScopes = const {
      AuthorizationScope.session,
    },
  }) : authorizationScopes = Set.unmodifiable(authorizationScopes);

  final String id;
  final String name;
  final String hostId;
  final String publicKey;
  final DateTime addedAt;
  final Set<AuthorizationScope> authorizationScopes;

  bool hasScope(AuthorizationScope scope) =>
      authorizationScopes.contains(scope);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'hostId': hostId,
    'publicKey': publicKey,
    'addedAt': addedAt.toUtc().toIso8601String(),
    'scopes': authorizationScopes.map((scope) => scope.name).toList(),
  };

  factory PairedDevice.fromJson(Map<String, Object?> json) => PairedDevice(
    id: json['id']! as String,
    name: json['name']! as String,
    hostId: json['hostId']! as String,
    publicKey: json['publicKey']! as String,
    addedAt: DateTime.parse(json['addedAt']! as String).toUtc(),
    authorizationScopes: _decodeScopes(json['scopes']),
  );

  static Set<AuthorizationScope> _decodeScopes(Object? value) {
    if (value == null) return const {AuthorizationScope.session};
    if (value is! List || value.any((item) => item is! String)) {
      throw const FormatException('Invalid paired device scopes.');
    }
    final result = <AuthorizationScope>{};
    for (final name in value.cast<String>()) {
      final scope = AuthorizationScope.values.where(
        (item) => item.name == name,
      );
      if (scope.isEmpty) throw const FormatException('Unknown device scope.');
      result.add(scope.first);
    }
    if (!result.contains(AuthorizationScope.session)) {
      throw const FormatException('Paired devices require session scope.');
    }
    return result;
  }
}
