class DeviceIdentity {
  const DeviceIdentity({required this.id, required this.publicKey});

  final String id;
  final String publicKey;

  Map<String, Object?> toJson() => {'id': id, 'publicKey': publicKey};

  factory DeviceIdentity.fromJson(Map<String, Object?> json) => DeviceIdentity(
    id: json['id']! as String,
    publicKey: json['publicKey']! as String,
  );
}
