import 'dart:async';

import 'package:flutter/material.dart';
import 'package:remotex/app/remote_x_services.dart';
import 'package:remotex/core/models/pairing_qr_payload.dart';
import 'package:remotex/core/models/pairing_session.dart';
import 'package:remotex/core/services/pairing_failure.dart';
import 'package:remotex/features/controller/presentation/qr_scanner_screen.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, required this.services});

  final RemoteXServices services;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  PairingSession _session = const PairingSession(state: PairingSessionState.idle);
  bool _pairing = false;
  String? _errorMessage;

  Future<void> _scan() async {
    final payload = await Navigator.of(context).push<PairingQrPayload>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (!mounted || payload == null) return;
    setState(() {
      _session = PairingSession(
        state: PairingSessionState.awaitingConfirmation,
        host: payload.hostName,
      );
      _errorMessage = null;
    });
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Connect to ${payload.hostName}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Verify this is the Windows host you intend to pair.'),
            const SizedBox(height: 12),
            Text('Host fingerprint: ${_formatFingerprint(payload.hostId)}'),
            const SizedBox(height: 6),
            Text('LAN address: ${payload.addresses.join(', ')}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Pair'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _pair(payload);
  }

  Future<void> _pair(PairingQrPayload payload) async {
    setState(() {
      _pairing = true;
      _errorMessage = null;
      _session = PairingSession(
        state: PairingSessionState.pairing,
        host: payload.hostName,
      );
    });
    try {
      final device = await widget.services.pairingService.pair(payload);
      if (!mounted) return;
      _session = PairingSession(
        state: PairingSessionState.paired,
        host: payload.hostName,
      );
      Navigator.of(context).pop(device);
    } on PairingException catch (error) {
      if (!mounted) return;
      setState(() {
        _session = PairingSession(
          state: PairingSessionState.failed,
          host: payload.hostName,
          message: error.userMessage,
        );
        _errorMessage = error.userMessage;
        _pairing = false;
      });
    } on FormatException {
      if (!mounted) return;
      setState(() {
        _session = PairingSession(
          state: PairingSessionState.failed,
          host: payload.hostName,
        );
        _errorMessage = 'The scanned pairing QR code is invalid or expired.';
        _pairing = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _session = PairingSession(
          state: PairingSessionState.failed,
          host: payload.hostName,
        );
        _errorMessage = 'Secure pairing failed. Check the local network and retry.';
        _pairing = false;
      });
    }
  }

  static String _formatFingerprint(String hostId) {
    final normalized = hostId.toUpperCase();
    return '${normalized.substring(0, 8)} ${normalized.substring(8, 16)}';
  }

  Future<void> _cancel() async {
    if (_pairing) await widget.services.pairingService.cancelPairing();
    if (mounted) {
      setState(
        () => _session = _session.copyWith(state: PairingSessionState.cancelled),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    if (_pairing) unawaited(widget.services.pairingService.cancelPairing());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isConfirmed = _session.state == PairingSessionState.awaitingConfirmation;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair with Windows'),
        leading: IconButton(
          onPressed: _pairing ? null : _cancel,
          icon: const Icon(Icons.close),
          tooltip: 'Cancel pairing',
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              isConfirmed
                  ? 'Connect to ${_session.host}?'
                  : 'Pair your Windows laptop securely.',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (_pairing) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('Verifying device identities and pairing securely…'),
            ],
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              _messageCard(_errorMessage!),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _pairing ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR to Pair'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Scan the short-lived QR code shown in RemoteX on the Windows laptop. '
              'Both devices must be on the same local network.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _messageCard(String message) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
      ),
    ),
  );
}
