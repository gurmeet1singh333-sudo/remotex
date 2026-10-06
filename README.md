
# remotex

# RemoteX

RemoteX is a personal remote-desktop project with an Android controller and a
Windows host. Stage 2 implements temporary local-LAN discovery and pairing;
the pairing bootstrap is presented as a short-lived QR code.
Stage 3 adds a separate authenticated, encrypted LAN session layer. Screen
streaming and remote input are not included. Stage 4 defines the versioned
message protocol carried inside that encrypted session. Stage 5 adds a
LAN-only screen-view MVP over the authenticated session.

## Architecture

- `lib/app/` composes services and selects the platform UI.
- `lib/features/controller/` contains Android pairing and QR scanning screens.
- `lib/features/host/` contains Windows host status and QR pairing UI.
- `lib/core/models/` and `lib/core/services/` define shared data and contracts.
- `lib/services/discovery/` implements mDNS using Bonsoir/Android NSD.
- `lib/services/pairing/` implements the bounded TCP pairing protocol and
  single-use QR nonce lifecycle.
- `lib/services/identity/` handles Ed25519 device identity and HMAC proofs.
- `lib/services/storage/` stores the identity and paired-device records using
  platform secure storage.
- `lib/services/session/` implements a separate mDNS-discovered TCP listener,
  signed X25519 handshake, HKDF key schedule, and AES-GCM session channel.
- `lib/core/protocol/` defines the versioned session-message envelope,
  validation, authorization scopes, and shared encrypted control/frame
  packet multiplexer.
- `lib/services/session/` also includes the bounded binary JPEG frame
  transport, screen stream coordinator, and Windows desktop-capture adapter.
- `windows/runner/screen_capture.cpp` captures the primary desktop using DXGI
  Desktop Duplication and scales/encodes JPEG using Windows Imaging Component.

The host advertises only the RemoteX service identifier, protocol version,
host ID/name, and TCP port in mDNS. For pairing, Windows displays a versioned
QR payload containing the pinned host public identity, local endpoint, expiry,
and a random 256-bit single-use nonce. It expires after two minutes and is
invalidated on cancellation, regeneration, or successful pairing. The nonce
is only a temporary bootstrap secret; it contains no private key or reusable
credential. Fresh handshake nonces and HMAC-SHA-256 proofs bind each device's
Ed25519 public identity, and both devices sign the transcript with their
Ed25519 private keys to prove possession.

Android private identity seed material and paired-device records use
`flutter_secure_storage`; the host uses Windows secure storage. Public device
identity is derived from the Ed25519 public key. Private key material is never
sent to the other device.

## Stage 3 session security

Transport options considered:

- **TLS over TCP** provides mature transport encryption, but using the existing
  Ed25519 identities directly as cross-platform TLS client/server certificates
  adds certificate and private-key interoperability work.
- **Secure WebSocket** inherits TLS protections and is useful with a browser or
  HTTP infrastructure, but adds HTTP framing without helping this native LAN
  prototype.
- **WebRTC data channels** are a good eventual choice for direct LAN/Internet
  connectivity and NAT traversal; they require signaling and ICE/TURN
  decisions that are intentionally out of scope for this step.
- **Selected for this stage:** a separate LAN-only TCP listener with an
  application-level signed ephemeral X25519 handshake and AES-GCM channel.
  It reuses the pinned Ed25519 identities, avoids carrying sensitive data over
  the Stage 2 pairing socket, and keeps transport behind `SessionTransport` so
  a later WebRTC/TLS transport can replace it.

Each connection uses a fresh session ID, client and host 256-bit random
nonces, and fresh X25519 ephemeral keys. Each side signs the complete
domain-separated transcript with its persisted Ed25519 identity. The host
checks the client key against its paired-device record and checks revocation;
Android checks the host key against its paired-host record. HKDF-SHA-256
derives separate controller-to-host, host-to-controller, and confirmation
keys from the X25519 shared secret and handshake transcript. HMAC key
confirmation completes the handshake. Session messages use AES-256-GCM with
direction-specific keys, sequence-derived unique nonces, session/direction/
sequence associated data, and strict in-order sequence checks.

The host stores a revocation tombstone when a selected paired device is
revoked. Reconnect always repeats the complete identity handshake; no previous
session is trusted. A controller retries a dropped session a limited number of
times with fresh handshakes and no renewed pairing step.

## Stage 4 session message protocol

After authentication, session messages use the existing AES-GCM channel; the
protocol adds no second encryption layer. Each JSON envelope includes a
protocol version, message type, random message ID, per-direction sequence,
UTC-millisecond timestamp, payload byte length, object payload, and (for a
response) the originating request ID. The protocol has separate send and
receive counters in each direction, in addition to the encrypted frame
counters. Sequence checks are the primary protocol replay defense; message IDs
also detect duplicates within a bounded recent-ID window.

The encoded envelope is capped at 8 KiB, with smaller per-type payload bounds
for control messages. Requests are capped at 32 pending correlations and expire
after 15 seconds. Only the `session` authorization scope is granted by default.
Screen, mouse, keyboard, clipboard, file-transfer, and audio scopes exist as
future capabilities but are not granted, and their functionality is not
implemented. Later key rotation can be introduced as an authenticated,
versioned session message and will not require pairing again.

## Stage 5 screen viewing

The Windows host uses DXGI Desktop Duplication to capture the primary display.
Windows Imaging Component scales the desktop proportionally to at most
1280x720 and encodes JPEG frames, reducing quality as needed to stay under
1 MiB. Capture is requested serially at a target of 10 FPS. The secure session
multiplexer prioritizes control messages ahead of queued video and keeps only
the newest unsent frame.

Screen frames use a separate binary packet lane inside the same authenticated
AES-GCM channel, not the small JSON message payload. Its bounded metadata
contains a per-direction frame sequence, timestamp, dimensions, JPEG format,
encoded size, and key-frame flag. Newly paired devices receive only the
`session` scope. On Windows, open **Paired devices → Allow screen viewing** to
grant the `screen_view` capability. Then use **View screen** on the paired
laptop in Android. Stop releases capture; disconnect/revocation also stops
the capture loop.

Start RemoteX on Windows with `flutter run -d windows`, grant screen viewing
for the paired phone, then run the Android app on the same LAN with
`flutter run -d <android-device-id>`. Pair if needed, then tap **View screen**.
The Windows build requires the Windows SDK, CMake, and Visual Studio C++ desktop
workload because capture uses native DXGI/WIC APIs.

## Run the LAN pairing prototype

Build/run the Windows host:

```shell
flutter run -d windows
```

Build/run the Android controller on a phone or emulator on the same LAN:

```shell
flutter run -d <android-device-id>
```

## LAN pairing test

1. Connect the Windows laptop and Android device to the same Wi-Fi/LAN. Ensure
   the router does not isolate wireless clients.
2. Start RemoteX on Windows and wait for **Host ready**. Select
   **Pair New Device** to display a QR code that expires in two minutes.
3. On Android, tap **Add / Pair Laptop**, then **Scan QR to Pair**.
4. Check the Windows host name, fingerprint, and LAN address, then tap
   **Pair**. The existing signed HMAC pairing handshake runs over TCP.
5. Confirm Android displays the laptop under **Devices** and Windows lists the
   phone as a trusted paired device. The QR is invalidated after success.
6. From Android, tap the paired laptop to establish a secure session. Confirm
   the controller reports **Secure session connected** and Windows reports
   **connected**.
7. Use **Revoke** next to the paired phone on Windows and confirm. Disconnect
   if needed, then try connecting again on Android; the host should reject the
   attempt as revoked.
8. To validate reconnection, pair again with a fresh QR after
   revocation, connect, briefly interrupt Wi-Fi, and restore it. The controller
   retries with a fresh authenticated handshake without scanning again.
9. Pairing lifecycle checks: cancel a QR, regenerate it, and wait two minutes
   to confirm cancellation, replacement, and expiry reject the old payload.

Windows Firewall may ask permission for the host listener; permit it only on
trusted private networks. Pairing cannot work across guest Wi-Fi/client
isolation or when mDNS multicast is blocked.

## Security and limitations

- The Stage 2 pairing TCP connection still does not use TLS and is not the
  secure session transport. The session listener uses signed ephemeral key
  agreement and authenticated encryption, but this has not had an independent
  cryptographic/security audit. Do not describe this prototype as production
  grade.
- Session discovery remains mDNS/LAN-only. No Internet connectivity,
  relay, WebRTC, NAT traversal, or TLS certificate deployment exists.
- Screen viewing is an unaudited LAN MVP, not production-grade streaming.
  DXGI may fail for locked desktops, secure desktop surfaces, some drivers, or
  remote-desktop configurations; only the primary monitor is captured.
- Screen viewing uses JPEG still frames, not a video codec. Network capacity,
  desktop activity, and encoding time can reduce the effective frame rate.
  Frames are never saved to disk or uploaded.
- Stage 5 does not implement mouse, keyboard, clipboard, file transfer, audio,
  relay, or WebRTC.
- Host challenge freshness currently uses wall-clock timestamps with a short
  allowed skew; devices with substantially incorrect clocks may fail to
  authenticate.
- Revocation prevents future handshakes and closes established host sessions.
  It is local to the Windows trusted-device store; no synchronization or
  cross-host revocation system exists.
- Secure-storage plugins protect stored values with platform facilities, but
  these software keys are not guaranteed hardware-non-exportable.
- LAN discovery requires mDNS/multicast support on the same local network.
  Internet access, relays, and NAT traversal are not implemented.
- A crash or secure-storage failure between host acceptance and controller
  persistence can require generating a fresh QR and pairing again.
- The normal desktop app is the host; no Windows service/background host is
  installed.

## Next stage

Stage 6 should threat-model and design remote-input messages under separately
granted mouse and keyboard scopes. Do not enable input until the host has an
explicit consent and safety model.
>>>>>>> 020c752 (Prepare RemoteX for Render deployment)
