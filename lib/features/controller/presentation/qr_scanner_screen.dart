import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:remotex/core/models/pairing_qr_payload.dart';

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _processing = false;
  String? _scanError;

  void _onDetect(BarcodeCapture capture) {
    if (_processing) return;
    final rawValue = capture.barcodes
        .map((barcode) => barcode.rawValue)
        .whereType<String>()
        .firstOrNull;
    if (rawValue == null) return;
    setState(() => _processing = true);
    try {
      final payload = PairingQrPayload.parse(rawValue);
      Navigator.of(context).pop(payload);
    } on FormatException catch (error) {
      setState(() {
        _scanError = error.message;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Scan Windows QR code'),
      leading: IconButton(
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.close),
        tooltip: 'Cancel scanning',
      ),
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.no_photography, size: 48),
                      const SizedBox(height: 12),
                      Text(
                        error.errorCode == MobileScannerErrorCode.permissionDenied
                            ? 'Camera access is required to scan a pairing QR code. Enable camera permission for RemoteX in Android settings, then retry.'
                            : 'The camera could not be started. Check camera access and try again.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () {
                          setState(() {
                            _processing = false;
                            _scanError = null;
                          });
                          unawaited(_controller.start());
                        },
                        child: const Text('Retry camera'),
                      ),
                    ],
                  ),
                ),
              ),
              placeholderBuilder: (_) =>
                  const Center(child: CircularProgressIndicator()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const Text('Scan the QR code displayed by RemoteX on Windows.'),
                if (_scanError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'QR rejected: $_scanError',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _processing = false;
                      _scanError = null;
                    }),
                    child: const Text('Try another QR code'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

extension on Iterable<String> {
  String? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
