import 'dart:async';

import 'package:flutter/material.dart';
import 'package:remotex/app/remote_x_services.dart';
import 'package:remotex/core/models/paired_device.dart';
import 'package:remotex/core/models/session_info.dart';
import 'package:remotex/core/models/session_error.dart';
import 'package:remotex/core/models/session_state.dart';
import 'package:remotex/features/controller/presentation/pairing_screen.dart';
import 'package:remotex/features/controller/presentation/remote_screen_view.dart';

class ControllerHomeScreen extends StatefulWidget {
  const ControllerHomeScreen({super.key, required this.services});

  final RemoteXServices services;

  @override
  State<ControllerHomeScreen> createState() => _ControllerHomeScreenState();
}

class _ControllerHomeScreenState extends State<ControllerHomeScreen> {
  late Future<List<PairedDevice>> _devices;
  StreamSubscription<SessionState>? _sessionSubscription;
  SessionState _sessionState = SessionState.disconnected;
  SessionInfo? _activeSession;

  @override
  void initState() {
    super.initState();
    _loadDevices();
    _sessionState = widget.services.sessionService.state;
    _sessionSubscription = widget.services.sessionService.stateChanges.listen((
      state,
    ) {
      if (mounted) setState(() => _sessionState = state);
    });
  }

  @override
  void dispose() {
    unawaited(_sessionSubscription?.cancel());
    unawaited(widget.services.remoteControlService.dispose());
    super.dispose();
  }

  void _loadDevices() {
    _devices = widget.services.pairedDevicesService.getPairedDevices();
  }

  Future<void> _connect(PairedDevice device) async {
    try {
      _activeSession = await widget.services.sessionService.connect(device);
    } on SessionException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.userMessage)));
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Secure connection could not be established.'),
          ),
        );
      }
    }
  }

  Future<void> _disconnect() async {
    await widget.services.sessionService.disconnect();
    _activeSession = null;
  }

  Future<void> _openScreen(PairedDevice device) async {
    if (_sessionState != SessionState.connected) {
      await _connect(device);
    }
    final session = _activeSession;
    final sessionId =
        widget.services.sessionService.controllerSessionId ??
        session?.sessionId;
    if (!mounted || session == null || sessionId == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            RemoteScreenView(services: widget.services, sessionId: sessionId),
      ),
    );
  }

  Future<void> _openPairing() async {
    final paired = await Navigator.of(context).push<PairedDevice>(
      MaterialPageRoute(
        builder: (_) => PairingScreen(services: widget.services),
      ),
    );
    if (!mounted || paired == null) return;
    setState(_loadDevices);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${paired.name} paired securely.')));
    await _openScreen(paired);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RemoteX'), centerTitle: false),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _ConnectionStatus(state: _sessionState),
            if (_sessionState == SessionState.connected)
              TextButton.icon(
                onPressed: _disconnect,
                icon: const Icon(Icons.link_off),
                label: const Text('Disconnect'),
              ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _openPairing,
              icon: const Icon(Icons.add_link),
              label: const Text('Add / Pair Laptop'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
              ),
            ),
            const SizedBox(height: 36),
            Text('Devices', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            FutureBuilder<List<PairedDevice>>(
              future: _devices,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const _DeviceLoadError();
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.data!.isEmpty) {
                  return const _EmptyDevices();
                }
                return Column(
                  children: [
                    for (final device in snapshot.data!)
                      Card(
                        child: Column(
                          children: [
                            ListTile(
                              leading: const Icon(Icons.laptop_windows),
                              title: Text(device.name),
                              subtitle: const Text('Trusted paired laptop'),
                              trailing: _sessionState == SessionState.connected
                                  ? const Icon(
                                      Icons.verified,
                                      color: Colors.green,
                                    )
                                  : IconButton(
                                      onPressed:
                                          _sessionState ==
                                                  SessionState.connecting ||
                                              _sessionState ==
                                                  SessionState.authenticating
                                          ? null
                                          : () => _connect(device),
                                      icon: const Icon(Icons.link),
                                      tooltip: 'Connect securely',
                                    ),
                              onTap: _sessionState == SessionState.connected
                                  ? null
                                  : () => _connect(device),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed:
                                    _sessionState == SessionState.connecting ||
                                        _sessionState ==
                                            SessionState.authenticating
                                    ? null
                                    : () => _openScreen(device),
                                icon: const Icon(Icons.desktop_windows),
                                label: const Text('View screen'),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final label = switch (state) {
      SessionState.disconnected => 'Disconnected',
      SessionState.connecting => 'Connecting',
      SessionState.authenticating => 'Authenticating device identity',
      SessionState.connected => 'Secure session connected',
      SessionState.reconnecting => 'Reconnecting to host…',
      SessionState.disconnecting => 'Disconnecting',
      SessionState.authenticationFailed => 'Authentication failed',
      SessionState.revoked => 'Device revoked',
      SessionState.networkDisconnected => 'Network disconnected - retrying',
      SessionState.unknownDevice => 'Device is not trusted by the host',
    };

    return Card(
      child: ListTile(
        leading: const Icon(Icons.circle, size: 12, color: Colors.grey),
        title: const Text('Connection status'),
        subtitle: Text(label),
      ),
    );
  }
}

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
        child: Column(
          children: [
            Icon(
              Icons.devices,
              size: 36,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            const Text('No laptops paired'),
            const SizedBox(height: 4),
            Text(
              'Pair a Windows laptop to get started.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceLoadError extends StatelessWidget {
  const _DeviceLoadError();

  @override
  Widget build(BuildContext context) => const Card(
    child: ListTile(
      leading: Icon(Icons.error_outline),
      title: Text('Paired devices could not be loaded'),
    ),
  );
}
