class RemoteCursorPosition {
  const RemoteCursorPosition({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.visible,
  });

  final int x;
  final int y;
  final int width;
  final int height;
  final bool visible;

  double get normalizedX => x / width;

  double get normalizedY => y / height;

  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'visible': visible,
  };

  factory RemoteCursorPosition.fromJson(Map<String, Object?> json) =>
      RemoteCursorPosition(
        x: json['x']! as int,
        y: json['y']! as int,
        width: json['width']! as int,
        height: json['height']! as int,
        visible: json['visible']! as bool,
      );
}
