enum MouseButton { left, right }

abstract interface class MouseService {
  Future<void> move(double deltaX, double deltaY);

  Future<void> click(MouseButton button);

  Future<void> doubleClick();

  Future<void> startDrag();

  Future<void> endDrag();

  Future<void> scroll(double deltaX, double deltaY);
}
