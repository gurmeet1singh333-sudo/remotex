import 'dart:ui';

class RemoteScreenCoordinates {
  const RemoteScreenCoordinates._();

  static const minScale = 1.0;
  static const maxScale = 4.0;

  static RemoteScreenTransform zoomAt({
    required RemoteScreenTransform transform,
    required Offset anchorPoint,
    required Offset focalPoint,
    required double scaleFactor,
    required Size viewport,
    Size? contentSize,
  }) {
    if (!scaleFactor.isFinite || scaleFactor <= 0 || viewport.isEmpty) {
      return transform;
    }
    final nextScale = (transform.scale * scaleFactor)
        .clamp(minScale, maxScale)
        .toDouble();
    final ratio = nextScale / transform.scale;
    return RemoteScreenTransform(
      scale: nextScale,
      translation: Offset(
        focalPoint.dx - (anchorPoint.dx - transform.translation.dx) * ratio,
        focalPoint.dy - (anchorPoint.dy - transform.translation.dy) * ratio,
      ),
    ).constrained(viewport, contentSize: contentSize);
  }

  static RemoteScreenTransform panBy({
    required RemoteScreenTransform transform,
    required Offset delta,
    required Size viewport,
    Size? contentSize,
  }) => RemoteScreenTransform(
    scale: transform.scale,
    translation: transform.translation + delta,
  ).constrained(viewport, contentSize: contentSize);

  static Offset? mapToNormalized({
    required Offset point,
    required Size viewport,
    required int screenWidth,
    required int screenHeight,
  }) {
    if (viewport.isEmpty || screenWidth <= 0 || screenHeight <= 0) return null;
    final scale = (viewport.width / screenWidth).clamp(
      0.0,
      viewport.height / screenHeight,
    );
    final displayedWidth = screenWidth * scale;
    final displayedHeight = screenHeight * scale;
    final left = (viewport.width - displayedWidth) / 2;
    final top = (viewport.height - displayedHeight) / 2;
    final x = (point.dx - left) / displayedWidth;
    final y = (point.dy - top) / displayedHeight;
    if (x < 0 || x > 1 || y < 0 || y > 1) return null;
    return Offset(x, y);
  }

  static Offset? mapTransformedToNormalized({
    required Offset point,
    required Size viewport,
    required int screenWidth,
    required int screenHeight,
    required double scale,
    required Offset translation,
  }) {
    if (!scale.isFinite || scale < minScale || scale > maxScale) return null;
    return mapToNormalized(
      point: Offset(
        (point.dx - translation.dx) / scale,
        (point.dy - translation.dy) / scale,
      ),
      viewport: viewport,
      screenWidth: screenWidth,
      screenHeight: screenHeight,
    );
  }
}

class RemoteScreenTransform {
  const RemoteScreenTransform({
    this.scale = RemoteScreenCoordinates.minScale,
    this.translation = Offset.zero,
  });

  final double scale;
  final Offset translation;

  RemoteScreenTransform constrained(Size viewport, {Size? contentSize}) {
    if (scale <= RemoteScreenCoordinates.minScale || viewport.isEmpty) {
      return const RemoteScreenTransform();
    }
    final content = contentSize ?? viewport;
    final originX = (viewport.width - content.width) / 2;
    final originY = (viewport.height - content.height) / 2;
    final scaledWidth = content.width * scale;
    final scaledHeight = content.height * scale;
    final minX = scaledWidth <= viewport.width
        ? viewport.width / 2 - (originX + content.width / 2) * scale
        : viewport.width - (originX + content.width) * scale;
    final maxX = scaledWidth <= viewport.width ? minX : -originX * scale;
    final minY = scaledHeight <= viewport.height
        ? viewport.height / 2 - (originY + content.height / 2) * scale
        : viewport.height - (originY + content.height) * scale;
    final maxY = scaledHeight <= viewport.height ? minY : -originY * scale;
    return RemoteScreenTransform(
      scale: scale,
      translation: Offset(
        translation.dx.clamp(minX, maxX).toDouble(),
        translation.dy.clamp(minY, maxY).toDouble(),
      ),
    );
  }
}
