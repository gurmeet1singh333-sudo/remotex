import 'package:remotex/core/protocol/authorization_scope.dart';

class AuthorizationChange {
  const AuthorizationChange({
    required this.deviceId,
    required this.scope,
    required this.enabled,
  });

  final String deviceId;
  final AuthorizationScope scope;
  final bool enabled;
}
