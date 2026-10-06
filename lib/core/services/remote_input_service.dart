abstract interface class RemoteInputService {
  Future<void> movePointer(double x, double y);

  Future<void> mouseButton(String button, String action);

  Future<void> scroll(int deltaX, int deltaY);

  Future<void> keyboardKey(String key, String action);

  Future<void> releaseAll();
}
