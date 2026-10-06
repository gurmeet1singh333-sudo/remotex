enum PairingSessionState {
  idle,
  awaitingConfirmation,
  pairing,
  paired,
  failed,
  cancelled,
}

class PairingSession {
  const PairingSession({required this.state, this.host, this.message});

  final PairingSessionState state;
  final String? host;
  final String? message;

  PairingSession copyWith({
    PairingSessionState? state,
    String? host,
    String? message,
  }) => PairingSession(
    state: state ?? this.state,
    host: host ?? this.host,
    message: message ?? this.message,
  );

  Map<String, Object?> toJson() => {
    'state': state.name,
    if (host != null) 'host': host,
    if (message != null) 'message': message,
  };

  factory PairingSession.fromJson(Map<String, Object?> json) {
    final stateName = json['state']! as String;
    final state = PairingSessionState.values.firstWhere(
      (value) => value.name == stateName,
      orElse: () => throw FormatException('Unknown pairing state: $stateName'),
    );
    return PairingSession(
      state: state,
      host: json['host'] as String?,
      message: json['message'] as String?,
    );
  }
}
