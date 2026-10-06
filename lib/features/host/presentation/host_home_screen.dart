import 'dart:async';

import 'package:flutter/material.dart';
import 'package:remotex/app/remote_x_services.dart';
import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/pairing_qr_payload.dart';
import 'package:remotex/core/models/session_state.dart';
import 'package:remotex/core/models/web_pairing_payload.dart';
import 'package:remotex/core/protocol/authorization_scope.dart';
import 'package:remotex/core/services/pairing_service.dart';
import 'package:remotex/services/pairing/web_pairing_service.dart';
import 'package:qr_flutter/qr_flutter.dart';

class HostHomeScreen extends StatefulWidget {
  const HostHomeScreen({super.key, required this.services});

  final RemoteXServices services;

  @override
  State<HostHomeScreen> createState() => _HostHomeScreenState();
}

class _HostHomeScreenState extends State<HostHomeScreen> {
  StreamSubscription<HostPairingStatus>? _subscription;
  StreamSubscription<SessionState>? _sessionSubscription;
  StreamSubscription<WebPairingStatus>? _webSubscription;

  HostPairingStatus? _status;
  WebPairingStatus? _webStatus;
  late Future<List<PairedDevice>> _trustedDevices;
  SessionState _sessionState = SessionState.disconnected;
  String? _errorMessage;
  bool _starting = true;
  bool _creatingQr = false;
  bool _creatingWebQr = false;
  String _relayUrl = const String.fromEnvironment(
    'REMOTE_X_RELAY_URL',
    defaultValue: 'ws://127.0.0.1:8080',
  );

  @override
  void initState() {
    super.initState();
    _loadTrustedDevices();
    _sessionState = widget.services.sessionService.state;
    _subscription = widget.services.hostPairingService.statusChanges.listen((
      status,
    ) {
      if (mounted) {
        setState(() {
          _status = status;
          _loadTrustedDevices();
        });
      }
    });
    _sessionSubscription = widget.services.sessionService.stateChanges.listen((
      state,
    ) {
      if (mounted) setState(() => _sessionState = state);
    });
    if (widget.services.webPairingService != null) {
      _webSubscription = widget.services.webPairingService!.statusChanges.listen((
        status,
      ) {
        if (mounted) setState(() => _webStatus = status);
      });
    }
    unawaited(_startHost());
  }

  void _loadTrustedDevices() {
    _trustedDevices = widget.services.sessionService.getTrustedDevices();
  }

  Future<void> _startHost() async {
    try {
      await widget.services.hostPairingService.start();
      await widget.services.sessionService.startHost();
      if (mounted) {
        setState(() {
          _status = widget.services.hostPairingService.status;
          _starting = false;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _starting = false;
          _errorMessage =
              'RemoteX could not start its local pairing listener. Check local network access.';
        });
      }
    }
  }

  Future<void> _startQrSession() async {
    setState(() {
      _creatingQr = true;
      _errorMessage = null;
    });
    try {
      await widget.services.hostPairingService.startPairingSession();
      if (mounted) {
        setState(() {
          _status = widget.services.hostPairingService.status;
          _creatingQr = false;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _creatingQr = false;
          _errorMessage = 'A new pairing QR code could not be generated.';
        });
      }
    }
  }

  Future<void> _cancelQrSession() async {
    try {
      await widget.services.hostPairingService.cancelPairingSession();
      if (mounted) {
        setState(() {
          _status = widget.services.hostPairingService.status;
          _errorMessage = null;
        });
      }
    } on Object {
      if (mounted) {
        setState(() => _errorMessage = 'The pairing QR session could not be cancelled.');
      }
    }
  }

  Future<void> _startWebPairing() async {
    final webPairingService = widget.services.webPairingService;
    final relayClient = widget.services.relayHostClient;
    if (webPairingService == null || relayClient == null) return;

    setState(() {
      _creatingWebQr = true;
      _errorMessage = null;
    });

    final urlTrimmed = _relayUrl.trim();
    final parsedUri = Uri.tryParse(urlTrimmed);
    if (parsedUri == null ||
        (!parsedUri.isScheme('ws') && !parsedUri.isScheme('wss')) ||
        parsedUri.host.isEmpty) {
      if (mounted) {
        setState(() {
          _creatingWebQr = false;
          _errorMessage = 'Invalid Relay Server URL. Must start with ws:// or wss://';
        });
      }
      return;
    }

    if ((const bool.fromEnvironment('dart.vm.product') || Uri.base.scheme == 'https') &&
        parsedUri.isScheme('ws') &&
        parsedUri.host != '127.0.0.1' &&
        parsedUri.host != 'localhost') {
      if (mounted) {
        setState(() {
          _creatingWebQr = false;
          _errorMessage =
              'Insecure ws:// scheme is not permitted for remote relay in production; use wss://';
        });
      }
      return;
    }

    try {
      if (!relayClient.isRunning) {
        await relayClient.start(relayUrl: urlTrimmed);
        widget.services.sessionService.startHost();
        relayClient.incomingConnections.listen((wire) {
          unawaited(webPairingService.handleIncomingWebPairingWire(wire));
        });
      }

      await webPairingService.startWebPairingSession(relayUrl: urlTrimmed);
      if (mounted) {
        setState(() {
          _creatingWebQr = false;
          _webStatus = webPairingService.status;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _creatingWebQr = false;
          _errorMessage = 'Could not enable Web Remote Access: $e';
        });
      }
    }
  }

  Future<void> _cancelWebPairing() async {
    final webPairingService = widget.services.webPairingService;
    if (webPairingService == null) return;
    try {
      await webPairingService.cancelWebPairingSession();
      if (mounted) {
        setState(() => _webStatus = webPairingService.status);
      }
    } on Object {
      if (mounted) {
        setState(() => _errorMessage = 'Web pairing session could not be cancelled.');
      }
    }
  }

  Future<void> _toggleHost() async {
    final running = _status?.isRunning ?? false;
    setState(() {
      _starting = !running;
      _errorMessage = null;
    });
    try {
      if (running) {
        await widget.services.relayHostClient?.stop();
        await widget.services.sessionService.stopHost();
        await widget.services.hostPairingService.stop();
      } else {
        await widget.services.hostPairingService.start();
        await widget.services.sessionService.startHost();
      }
      if (mounted) {
        setState(() {
          _status = widget.services.hostPairingService.status;
          _starting = false;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _starting = false;
          _errorMessage = running
              ? 'The local pairing service could not stop cleanly.'
              : 'RemoteX could not start its local pairing listener.';
        });
      }
    }
  }

  Future<void> _revoke(PairedDevice device) async {
    final shouldRevoke = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke device?'),
        content: Text(
          '${device.name} will no longer be able to establish a session.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (shouldRevoke != true) return;
    try {
      await widget.services.sessionService.revokeDevice(device.id);
      if (mounted) {
        setState(_loadTrustedDevices);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${device.name} has been revoked.')),
        );
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The device could not be revoked.')),
        );
      }
    }
  }

  Future<void> _setDeviceScope(
    PairedDevice device,
    AuthorizationScope scope,
    bool enabled,
  ) async {
    try {
      await widget.services.sessionService.setDeviceScope(
        device.id,
        scope,
        enabled: enabled,
      );
      if (mounted) setState(_loadTrustedDevices);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Screen-view permission could not be updated.'),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_sessionSubscription?.cancel());
    unawaited(_webSubscription?.cancel());
    unawaited(widget.services.screenStreamService.stopAll());
    unawaited(widget.services.remoteControlService.dispose());
    unawaited(widget.services.relayHostClient?.stop());
    unawaited(widget.services.sessionService.stopHost());
    unawaited(widget.services.hostPairingService.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final isRunning = status?.isRunning ?? false;
    final qrAvailable = status?.pairingNonce != null && status?.expiresAt != null;

    return Scaffold(
      appBar: AppBar(title: const Text('RemoteX Host'), centerTitle: false),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                _HostStatus(
                  starting: _starting,
                  running: isRunning,
                  error: _errorMessage,
                ),
                const SizedBox(height: 16),
                _PairingDetails(status: status),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _starting ? null : _toggleHost,
                  icon: Icon(isRunning ? Icons.stop : Icons.play_arrow),
                  label: Text(isRunning ? 'Stop hosting' : 'Start hosting'),
                ),
                const SizedBox(height: 12),
                if (qrAvailable)
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: isRunning && !_creatingQr ? _startQrSession : null,
                          icon: const Icon(Icons.refresh),
                          label: Text(_creatingQr ? 'Generating…' : 'Regenerate QR'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _cancelQrSession,
                          icon: const Icon(Icons.close),
                          label: const Text('Cancel QR'),
                        ),
                      ),
                    ],
                  )
                else
                  FilledButton.icon(
                    onPressed: isRunning && !_creatingQr ? _startQrSession : null,
                    icon: const Icon(Icons.qr_code),
                    label: Text(
                      _creatingQr ? 'Generating…' : 'Pair New Device',
                    ),
                  ),
                const SizedBox(height: 24),
                _WebPairingCard(
                  status: _webStatus,
                  creating: _creatingWebQr,
                  relayUrl: _relayUrl,
                  onRelayUrlChanged: (url) => _relayUrl = url,
                  onEnableWeb: isRunning ? _startWebPairing : null,
                  onCancelWeb: _cancelWebPairing,
                ),
                const SizedBox(height: 16),
                _ConnectionStatus(
                  connectedDevices: status?.pairedDeviceCount ?? 0,
                  sessionState: _sessionState,
                ),
                const SizedBox(height: 28),
                Text(
                  'Paired devices',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                FutureBuilder<List<PairedDevice>>(
                  future: _trustedDevices,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return const Card(
                        child: ListTile(
                          title: Text('Trusted devices could not be loaded'),
                        ),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.data!.isEmpty) {
                      return const Card(
                        child: ListTile(title: Text('No paired devices')),
                      );
                    }
                    return Column(
                      children: [
                        for (final device in snapshot.data!)
                          Card(
                            child: ListTile(
                              leading: Icon(
                                device.name.toLowerCase().contains('web')
                                    ? Icons.public
                                    : Icons.phone_android,
                              ),
                              title: Text(device.name),
                              subtitle: Text(
                                'Trusted · Screen ${device.hasScope(AuthorizationScope.screenView) ? 'allowed' : 'disabled'}'
                                ' · Mouse ${device.hasScope(AuthorizationScope.mouseControl) ? 'allowed' : 'disabled'}'
                                ' · Keyboard ${device.hasScope(AuthorizationScope.keyboardControl) ? 'allowed' : 'disabled'}',
                              ),
                              trailing: PopupMenuButton<String>(
                                onSelected: (action) {
                                  if (action == 'revoke') {
                                    unawaited(_revoke(device));
                                  } else {
                                    final parts = action.split(':');
                                    final scope = AuthorizationScope.values
                                        .where((item) => item.name == parts[0])
                                        .first;
                                    unawaited(
                                      _setDeviceScope(
                                        device,
                                        scope,
                                        parts[1] == 'allow',
                                      ),
                                    );
                                  }
                                },
                                itemBuilder: (context) => [
                                  for (final scope in [
                                    AuthorizationScope.screenView,
                                    AuthorizationScope.mouseControl,
                                    AuthorizationScope.keyboardControl,
                                  ])
                                    PopupMenuItem(
                                      value:
                                          '${scope.name}:${device.hasScope(scope) ? 'deny' : 'allow'}',
                                      child: Text(
                                        '${device.hasScope(scope) ? 'Disable' : 'Allow'} ${switch (scope) {
                                          AuthorizationScope.screenView => 'screen viewing',
                                          AuthorizationScope.mouseControl => 'mouse control',
                                          AuthorizationScope.keyboardControl => 'keyboard control',
                                          _ => scope.name,
                                        }}',
                                      ),
                                    ),
                                  const PopupMenuItem(
                                    value: 'revoke',
                                    child: Text('Revoke device'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HostStatus extends StatelessWidget {
  const _HostStatus({
    required this.starting,
    required this.running,
    required this.error,
  });

  final bool starting;
  final bool running;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final label = starting
        ? 'Starting local pairing service…'
        : running
            ? 'Host ready'
            : 'Host unavailable';
    return Card(
      child: ListTile(
        leading: Icon(
          Icons.circle,
          size: 12,
          color: running ? Colors.green : Colors.grey,
        ),
        title: const Text('Host status'),
        subtitle: Text(error ?? label),
      ),
    );
  }
}

class _PairingDetails extends StatelessWidget {
  const _PairingDetails({required this.status});

  final HostPairingStatus? status;

  @override
  Widget build(BuildContext context) {
    final current = status;
    final nonce = current?.pairingNonce;
    final expiry = current?.expiresAt;
    final lanEndpoint = current == null || current.addresses.isEmpty
        ? null
        : '${current.addresses.first}:${current.port}';
    final qrPayload = nonce == null || expiry == null
        ? null
        : PairingQrPayload(
            hostId: current!.hostId,
            hostName: current.hostName,
            hostPublicKey: current.hostPublicKey,
            pairingNonce: nonce,
            addresses: current.addresses,
            port: current.port,
            expiresAt: expiry,
          ).encode();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Pairing', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            _DetailRow(
              label: 'Host name',
              value: current?.hostName ?? 'Starting…',
            ),
            const Divider(height: 28),
            _DetailRow(
              label: 'Device ID',
              value: current?.hostId ?? 'Starting…',
            ),
            const Divider(height: 28),
            _DetailRow(
              label: 'Local network',
              value: current == null
                  ? 'Not connected'
                  : current.addresses.isEmpty
                      ? 'No LAN address available'
                      : '${current.addresses.join(', ')} · port ${current.port}',
            ),
            if (qrPayload != null && lanEndpoint != null) ...[
              const SizedBox(height: 20),
              _DetailRow(
                label: 'LAN endpoint',
                value: lanEndpoint,
              ),
              const SizedBox(height: 12),
              Center(
                child: QrImageView(
                  data: qrPayload,
                  version: QrVersions.auto,
                  size: 250,
                  backgroundColor: Colors.white,
                  errorCorrectionLevel: QrErrorCorrectLevel.Q,
                ),
              ),
              const SizedBox(height: 12),
              const Center(
                child: Text(
                  'Scan this QR code with RemoteX on your phone.',
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  current!.isPairingLocked
                      ? 'Pairing locked. Cancel and generate a new QR.'
                      : 'QR expires in 2 minutes · ${TimeOfDay.fromDateTime(expiry!.toLocal()).format(context)}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ] else ...[
              const SizedBox(height: 12),
              Text(
                current?.isPairingLocked == true
                    ? 'Pairing is locked. Generate a new QR session.'
                    : 'Select Pair LAN Device to display a short-lived QR code.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WebPairingCard extends StatelessWidget {
  const _WebPairingCard({
    required this.status,
    required this.creating,
    required this.relayUrl,
    required this.onRelayUrlChanged,
    required this.onEnableWeb,
    required this.onCancelWeb,
  });

  final WebPairingStatus? status;
  final bool creating;
  final String relayUrl;
  final ValueChanged<String> onRelayUrlChanged;
  final VoidCallback? onEnableWeb;
  final VoidCallback onCancelWeb;

  @override
  Widget build(BuildContext context) {
    final current = status;
    final nonce = current?.pairingNonce;
    final expiry = current?.expiresAt;
    final payload = nonce == null || expiry == null || current == null
        ? null
        : WebPairingPayload(
            hostId: current.hostId,
            hostName: current.hostName,
            hostPublicKey: current.hostPublicKey,
            relayUrl: current.relayUrl,
            pairingNonce: nonce,
            sessionId: current.sessionId ?? 'session',
            expiresAt: expiry,
          ).encode();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Web Remote Access', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: TextEditingController(text: relayUrl),
              onChanged: onRelayUrlChanged,
              decoration: const InputDecoration(
                labelText: 'Relay Server URL',
                hintText: 'ws://127.0.0.1:8080 or wss://relay.remotex.app',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            if (payload != null) ...[
              Center(
                child: QrImageView(
                  data: payload,
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: Colors.white,
                  errorCorrectionLevel: QrErrorCorrectLevel.Q,
                ),
              ),
              const SizedBox(height: 12),
              const Center(
                child: Text(
                  'Scan or copy payload in RemoteX Web to connect.',
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                payload,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onCancelWeb,
                icon: const Icon(Icons.close),
                label: const Text('Cancel Web Session'),
              ),
            ] else ...[
              FilledButton.icon(
                onPressed: creating ? null : onEnableWeb,
                icon: const Icon(Icons.public),
                label: Text(creating ? 'Enabling…' : 'Enable Web Access'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label),
        const SizedBox(width: 12),
        Flexible(
          child: SelectableText(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({
    required this.connectedDevices,
    required this.sessionState,
  });

  final int connectedDevices;
  final SessionState sessionState;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.circle, size: 12, color: Colors.grey),
        title: const Text('Session status'),
        subtitle: Text(
          '${sessionState.name} · $connectedDevices paired device(s)',
        ),
      ),
    );
  }
}
