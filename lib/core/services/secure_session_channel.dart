abstract interface class SecureSessionChannel {
  Future<void> send(List<int> plaintext);

  Future<List<int>> receive();

  Future<void> close();
}
