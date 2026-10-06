import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/core/models/pairing_session.dart';

void main() {
  test(
    'pairing session records its host and progresses to success or failure',
    () {
      const awaitingConfirmation = PairingSession(
        state: PairingSessionState.awaitingConfirmation,
        host: 'Laptop',
      );
      final pairing = awaitingConfirmation.copyWith(
        state: PairingSessionState.pairing,
      );
      final paired = pairing.copyWith(state: PairingSessionState.paired);
      final failed = pairing.copyWith(
        state: PairingSessionState.failed,
        message: 'Expired QR session',
      );

      expect(pairing.host, 'Laptop');
      expect(paired.state, PairingSessionState.paired);
      expect(failed.message, 'Expired QR session');
      expect(
        const PairingSession(state: PairingSessionState.idle)
            .copyWith(state: PairingSessionState.cancelled)
            .state,
        PairingSessionState.cancelled,
      );
    },
  );
}
