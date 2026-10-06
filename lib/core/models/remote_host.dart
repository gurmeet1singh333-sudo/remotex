class RemoteHost {
  const RemoteHost({
    required this.id,
    required this.name,
    required this.port,
    required this.protocolVersion,
    required this.addresses,
  });

  final String id;
  final String name;
  final int port;
  final int protocolVersion;
  final List<String> addresses;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'port': port,
    'protocolVersion': protocolVersion,
    'addresses': addresses,
  };

  factory RemoteHost.fromJson(Map<String, Object?> json) => RemoteHost(
    id: json['id']! as String,
    name: json['name']! as String,
    port: json['port']! as int,
    protocolVersion: json['protocolVersion']! as int,
    addresses: List<String>.from(json['addresses']! as List<Object?>),
  );
}
