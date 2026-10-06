import 'authorization_scope.dart';

class SessionAuthorization {
  SessionAuthorization({
    Set<AuthorizationScope> initialScopes = const {AuthorizationScope.session},
  }) : _scopes = {...initialScopes};

  final Set<AuthorizationScope> _scopes;

  Set<AuthorizationScope> get scopes => Set.unmodifiable(_scopes);

  bool allows(AuthorizationScope scope) => _scopes.contains(scope);

  void grant(AuthorizationScope scope) => _scopes.add(scope);

  void revoke(AuthorizationScope scope) => _scopes.remove(scope);
}
