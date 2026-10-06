import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/core/models/remote_screen_coordinates.dart';

void main() {
  test('maps points through centered aspect-ratio letterboxing', () {
    expect(
      RemoteScreenCoordinates.mapToNormalized(
        point: const Offset(500, 250),
        viewport: const Size(1000, 500),
        screenWidth: 1600,
        screenHeight: 900,
      ),
      const Offset(0.5, 0.5),
    );
    expect(
      RemoteScreenCoordinates.mapToNormalized(
        point: const Offset(10, 250),
        viewport: const Size(1000, 500),
        screenWidth: 1600,
        screenHeight: 900,
      ),
      isNull,
    );
  });

  test('rejects invalid dimensions and points beyond screen content', () {
    expect(
      RemoteScreenCoordinates.mapToNormalized(
        point: const Offset(500, 250),
        viewport: const Size(0, 500),
        screenWidth: 1600,
        screenHeight: 900,
      ),
      isNull,
    );
    expect(
      RemoteScreenCoordinates.mapToNormalized(
        point: const Offset(1001, 250),
        viewport: const Size(1000, 500),
        screenWidth: 800,
        screenHeight: 400,
      ),
      isNull,
    );
  });

  test(
    'zoom is bounded and preserves the point under the pinch focal point',
    () {
      const viewport = Size(400, 800);
      const fit = RemoteScreenTransform();
      final zoomed = RemoteScreenCoordinates.zoomAt(
        transform: fit,
        anchorPoint: const Offset(200, 400),
        focalPoint: const Offset(200, 400),
        scaleFactor: 2,
        viewport: viewport,
      );
      expect(zoomed.scale, 2);
      expect(
        RemoteScreenCoordinates.mapTransformedToNormalized(
          point: const Offset(200, 400),
          viewport: viewport,
          screenWidth: 1600,
          screenHeight: 900,
          scale: zoomed.scale,
          translation: zoomed.translation,
        ),
        const Offset(0.5, 0.5),
      );
      final capped = RemoteScreenCoordinates.zoomAt(
        transform: zoomed,
        anchorPoint: const Offset(200, 400),
        focalPoint: const Offset(200, 400),
        scaleFactor: 100,
        viewport: viewport,
      );
      expect(capped.scale, RemoteScreenCoordinates.maxScale);
      expect(
        RemoteScreenCoordinates.zoomAt(
          transform: fit,
          anchorPoint: const Offset(200, 400),
          focalPoint: const Offset(200, 400),
          scaleFactor: 0.01,
          viewport: viewport,
        ).scale,
        RemoteScreenCoordinates.minScale,
      );
    },
  );

  test('maps coordinates after pan and resets to fit', () {
    const viewport = Size(400, 800);
    final zoomed = RemoteScreenCoordinates.zoomAt(
      transform: const RemoteScreenTransform(),
      anchorPoint: const Offset(200, 400),
      focalPoint: const Offset(200, 400),
      scaleFactor: 2,
      viewport: viewport,
    );
    final panned = RemoteScreenCoordinates.panBy(
      transform: zoomed,
      delta: const Offset(-60, 40),
      viewport: viewport,
    );
    final sourceCenter = Offset(
      200 * panned.scale + panned.translation.dx,
      400 * panned.scale + panned.translation.dy,
    );
    expect(
      RemoteScreenCoordinates.mapTransformedToNormalized(
        point: sourceCenter,
        viewport: viewport,
        screenWidth: 1600,
        screenHeight: 900,
        scale: panned.scale,
        translation: panned.translation,
      ),
      const Offset(0.5, 0.5),
    );
    expect(
      const RemoteScreenTransform().constrained(viewport).scale,
      RemoteScreenCoordinates.minScale,
    );
  });
}
