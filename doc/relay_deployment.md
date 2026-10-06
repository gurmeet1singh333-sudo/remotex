# RemoteX Relay Server Production Hardening & Deployment Specification

## 1. Architecture Overview & Security Model

The RemoteX Relay Server (`bin/relay.dart`) provides blind transport routing for encrypted remote desktop sessions over WebSockets (`WSS`).

```
[ Web Browser Client ] ──────── WSS / HTTPS :443 ────► ┌──────────────────────┐
                                                       │ Caddy / Render Proxy │ (TLS Termination)
[ Windows Desktop Host ] ────── Outbound WSS :443 ───► └──────────┬───────────┘
                                                                  │ Local WS
                                                                  ▼
                                                       ┌──────────────────────┐
                                                       │ RemoteX Relay Server │ (Docker Container)
                                                       └──────────────────────┘
```

### Encryption & Transport Boundaries
- **No Access to Decryption Keys**: The relay does not possess session encryption keys and cannot decrypt E2EE payloads. It only routes encrypted ciphertext and required routing metadata.
- **Payload Privacy**: All screen frames, mouse movements, clicks, scrolls, and keystrokes are encrypted end-to-end using AES-GCM-256 with keys derived via X25519 ECDH directly between Host and Browser Client.
- **Routing Metadata**: The relay observes connection metadata (client IP addresses, WebSocket headers) and 24-character hexadecimal `sessionId` tokens required for socket bridging.
- **Outbound Host Architecture**: The Windows host establishes an outbound WebSocket (`WSS`) connection to the relay server. **No inbound public ports or NAT port forwarding** are required on the Windows host network.

*Notice: This specification prepares RemoteX for deployment. An independent third-party security audit has not been performed, and no real Internet deployment was executed during code preparation.*

---

## 2. Server Hardware & Infrastructure Specifications

| Specification | Minimum Testing Spec | Recommended Small Production | Optional Scale-Up Production |
|---|---|---|---|
| **vCPU** | 1 vCPU | 2 vCPU | 4 vCPU |
| **RAM** | 1 GB | 2 GB | 4 GB - 8 GB |
| **Storage** | 10 GB SSD | 20 GB SSD | 50 GB SSD |
| **Monthly Bandwidth** | 500 GB | 1 TB – 2 TB | 5 TB+ |
| **Operating System** | Debian 12 / Ubuntu 22.04 LTS | Debian 12 / Ubuntu 22.04 LTS | Debian 12 / Ubuntu 22.04 LTS |
| **Architecture** | x86_64 / ARM64 | x86_64 / ARM64 | x86_64 / ARM64 |
| **IP Allocation** | 1 Public IPv4 (Static) | 1 Public IPv4 (Static) | 1 Public IPv4 + IPv6 |
| **Docker Engine** | Version 24.0+ | Version 24.0+ | Version 24.0+ |
| **Concurrent Sessions** | 1 – 5 sessions | Up to 50 active sessions | 100 – 200 active sessions |

### Justification:
- The compiled standalone Dart executable binary consumes ~30 MB base RAM and requires minimal CPU for JSON framing routing.
- The relay is stateless and does not run a database, keeping disk usage under 1 GB for OS and Docker layers.
- Bandwidth throughput (2–4 Mbps per active 720p 10FPS stream) is the primary bottleneck rather than CPU/RAM.

---

## 3. Domain & DNS Specifications

Production VPS deployment requires a domain name for automatic ACME TLS certificate issuance:

- **Example Subdomain**: `relay.example.com`
- **DNS A Record**: `relay.example.com` → `YOUR_SERVER_IPV4`
- **DNS AAAA Record (Optional)**: `relay.example.com` → `YOUR_SERVER_IPV6`
- **Web App Domain (Optional)**: `app.example.com` → `YOUR_SERVER_IPV4` (if hosting Flutter Web bundle on a separate subdomain).

---

## 4. TLS & WSS Architecture

1. **TLS Termination**: Handled externally at the reverse proxy layer (Caddy / Nginx / Render TLS Edge) on TCP port 443.
2. **ACME Certificates**: Caddy automatically provisions and renews Let's Encrypt / ZeroSSL TLS certificates via HTTP-01 challenge on port 80. Render handles TLS automatically at its edge.
3. **Internal Routing**: Proxies WSS requests to the internal relay port via HTTP/1.1 WebSocket upgrade headers.
4. **Scheme Enforcement**: Production mode (`REMOTEX_ENV=production`) forbids insecure `ws://` connections for remote relays in both `WebPairingPayload` and `HostHomeScreen`.

---

## 5. Firewall Policy (VPS UFW)

| Port | Protocol | Source | Destination | Purpose |
|---|---|---|---|---|
| `22` | TCP | Any | VPS | SSH Administration |
| `80` | TCP | Any | VPS | HTTP / ACME Challenge / HTTPS Redirect |
| `443` | TCP | Any | VPS | HTTPS / WSS Public Listener |
| `8080` | TCP | Localhost (`127.0.0.1`) | Relay Container | Internal Relay Listener (**Not Public**) |

*Windows Host Network Requirements: **0 inbound public ports**. Requires outbound HTTPS/WSS access on port 443 only.*

---

## 6. Docker Container Requirements

- **Dockerfile**: Multi-stage build (`dart:stable` → `debian:bookworm-slim`).
- **User Security**: Runs as unprivileged non-root user `remotex` (UID 10001).
- **Stateless Design**: No persistent storage, database, or volume mounts required.
- **Restart Policy**: `--restart unless-stopped`.
- **Port Compatibility**: Supports `PORT` environment variable (Render priority) or `REMOTEX_RELAY_PORT` (default 8080).
- **Health Probe**: `GET /health` (returns JSON uptime and connection metrics).

---

## 7. Production Environment Configuration Template (`.env`)

Create `/opt/remotex/.env` on the VPS:

```env
# RemoteX Relay Environment Configuration
REMOTEX_ENV=production
REMOTEX_RELAY_HOST=0.0.0.0
REMOTEX_RELAY_PORT=8080
REMOTEX_ALLOWED_ORIGINS=https://app.example.com,https://relay.example.com
REMOTEX_MAX_SESSIONS=100
REMOTEX_MAX_MESSAGE_BYTES=2097152
REMOTEX_SESSION_TIMEOUT_MINUTES=30
REMOTEX_AUTH_TIMEOUT_SECONDS=10
REMOTEX_RATE_LIMIT_PER_SEC=120
```

---

## 8. Client Relay URL Configuration

- **Production WSS URL**: `wss://relay.example.com` or `wss://YOUR-SERVICE.onrender.com`
- **Compile-Time Default Override**: Pass `--dart-define=REMOTE_X_RELAY_URL=wss://YOUR-SERVICE.onrender.com` when building Web/Host apps.
- **Runtime Override**: Windows Host allows user customization in `HostHomeScreen` text field with built-in format and `wss://` validation.

---

## 9. Caddy Reverse Proxy Configuration (`/etc/caddy/Caddyfile`)

```caddyfile
relay.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

---

## 10. VPS Deployment Plan

```bash
# 1. Connect to VPS
ssh user@YOUR_SERVER_IP

# 2. Update System Packages
sudo apt update && sudo apt upgrade -y

# 3. Install Docker & Caddy
sudo apt install -y docker.io docker-compose-plugin caddy ufw

# 4. Configure Firewall
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

# 5. Create Deployment Directory
sudo mkdir -p /opt/remotex
sudo chown -R $USER:$USER /opt/remotex
cd /opt/remotex

# 6. Copy Repository & Create .env File
nano /opt/remotex/.env

# 7. Build Docker Image
docker build -t remotex-relay:latest .

# 8. Start Relay Container
docker run -d \
  --name remotex-relay \
  --restart unless-stopped \
  --env-file .env \
  -p 127.0.0.1:8080:8080 \
  remotex-relay:latest

# 9. Configure Caddyfile
sudo tee /etc/caddy/Caddyfile << 'EOF'
relay.example.com {
    reverse_proxy 127.0.0.1:8080
}
EOF

# 10. Restart Caddy to Provision TLS
sudo systemctl restart caddy

# 11. Validate Health Check Probe
curl -v https://relay.example.com/health
```

---

## 11. Render Free Deployment Adaptation

For testing and MVP use, RemoteX Relay can be deployed as a Docker Web Service on Render's Free tier using the root `render.yaml` blueprint or manual dashboard setup.

### Step-by-Step Render Deployment:
1. **Render Account**: Create or log in to a free account at [render.com](https://render.com).
2. **New Web Service**: Click **New +** → **Web Service**.
3. **Connect Git Repository**: Connect the `RemoteX` repository.
4. **Environment**: Select **Docker** (Render uses the root `Dockerfile` automatically).
5. **Port Environment Variable**: Render automatically injects `PORT` (e.g. `PORT=10000`). `RemoteXRelayConfig.fromEnvironment()` checks `PORT` first, binding the server dynamically to Render's allocated port.
6. **Environment Variables**: Configure the following environment variables in the Render Dashboard:

| Variable | Recommended Render Value | Notes |
|---|---|---|
| `REMOTEX_ENV` | `production` | Enables strict origin validation & disables dev fallbacks |
| `REMOTEX_RELAY_HOST` | `0.0.0.0` | Required for Render container port binding |
| `REMOTEX_ALLOWED_ORIGINS` | `https://your-web-app.netlify.app` | **Browser application origin** (must NOT be empty or `*`) |
| `REMOTEX_MAX_SESSIONS` | `50` | Sized for free tier memory bounds |
| `REMOTEX_MAX_MESSAGE_BYTES` | `2097152` | 2MB payload cap |
| `REMOTEX_SESSION_TIMEOUT_MINUTES` | `30` | Session inactivity timeout |
| `REMOTEX_AUTH_TIMEOUT_SECONDS` | `10` | Handshake timeout |
| `REMOTEX_RATE_LIMIT_PER_SEC` | `120` | Per-connection sliding window rate limit |

7. **Health Check Path**: Set `/health`. Render uses `GET /health` to verify service availability before routing live traffic.
8. **Render WSS URL**: Once deployed, Render assigns a public HTTPS URL (e.g. `https://remotex-relay.onrender.com`). The corresponding WebSocket URL is `wss://remotex-relay.onrender.com`.
9. **Origin Distinction Warning**:
   - `REMOTEX_ALLOWED_ORIGINS` must contain the URL of the **Web Browser application** where users access the control interface (e.g. `https://my-app.netlify.app` or `http://localhost:3000`).
   - Do NOT set `REMOTEX_ALLOWED_ORIGINS` to the relay's own Render URL unless the browser app is served from the relay itself.

### Render Free Tier Limitations & Session Behavior:
- **Service Sleep / Spin-Down**: Render's Free tier automatically spins down web services after 15 minutes of inactivity.
- **Cold-Start Delay**: An incoming connection to a sleeping service wakes it up within ~30–50 seconds.
- **Clean Disconnect & Recovery**: When Render sleeps or restarts the container:
  - Existing WebSocket bridges close cleanly.
  - Windows Host detects the drop via `WebRelayHostClient` and attempts bounded exponential backoff reconnection (`500ms`, `1s`, `2s`).
  - Web Remote Screen detects session disconnect, disables input controls, and releases held keys/buttons.
  - On reconnect, a **fresh authenticated E2EE handshake** is executed. Stale session state or authorization is never automatically trusted.
- **No Keep-Alive Abuse**: RemoteX does not inject artificial dummy traffic to bypass Render sleep policies.

---

## 12. Security Checklist

- [x] SSH key authentication enabled on VPS (if using VPS).
- [x] Firewall restricting inbound traffic to ports 22, 80, 443 (if using VPS).
- [x] Relay port 8080 bound locally (`127.0.0.1`) on VPS or dynamically (`PORT`) on Render.
- [x] TLS 1.2 / 1.3 enforced via Caddy or Render TLS edge.
- [x] Docker container runs as unprivileged non-root user `remotex` (UID 10001).
- [x] `REMOTEX_ALLOWED_ORIGINS` enforced without wildcards (`*`) in production mode.
- [x] All E2EE payloads remain end-to-end encrypted; relay has zero access to decryption keys.
- [x] Zero hardcoded secrets in source code, `render.yaml`, or Git history.

---

## 13. Cost & Scaling Analysis

- **Primary Scaling Bottleneck**: Network Bandwidth.
- **Estimated Stream Bitrate**: ~2–4 Mbps per active 1280x720 @ 10 FPS remote session.
- **10 Active Concurrent Sessions**: Requires ~20–40 Mbps sustained network bandwidth (~1–2 TB/month for moderate daily usage).
- **CPU / Memory Usage**: Very low (~30–50 MB RAM, <5% vCPU usage for 10 sessions).

---

## 14. Observability & Operational Probes

- **Uptime Probe**: `GET /health`
  ```json
  {
    "status": "ok",
    "version": "1.0.0",
    "uptimeSeconds": 86400,
    "activeHostsCount": 4,
    "activeBridgesCount": 2
  }
  ```
- **Container Logs**: `docker logs --tail 100 -f remotex-relay` or Render Dashboard **Logs** tab.

---

## 15. Troubleshooting & Rollback Procedures

- **Container Inspection**: `docker ps`, `docker inspect remotex-relay`
- **Restart Container**: `docker restart remotex-relay` or Render Dashboard **Manual Deploy → Manual Restart**.
- **Caddy Status & Logs**: `sudo systemctl status caddy`, `sudo journalctl -u caddy -n 100`
- **Rollback Procedure**: Revert to previous image tag or Git commit in repository.
