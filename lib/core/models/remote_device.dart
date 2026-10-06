class RemoteDevice {
  const RemoteDevice({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  factory RemoteDevice.fromJson(Map<String, Object?> json) =>
      RemoteDevice(id: json['id']! as String, name: json['name']! as String);
}
