abstract interface class KeyboardService {
  Future<void> typeText(String text);

  Future<void> pressKey(String key);
}
