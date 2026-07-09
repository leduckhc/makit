# makit

Mobile-first coding agent client. Run a server on your desktop, pair your
phone or any other device via QR, and drive `pi` / `codex` / `claude-code`
sessions through a chat UI.

- 📱 [`app/`](./app/) — Flutter mobile/desktop client
- 🖥 [`server/`](./server/) — Node/TS WebSocket server + agent adapters
- 📚 [`docs/UX.md`](./docs/UX.md), [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md)
- 🛠 [`docs/DEVELOPMENT.md`](./docs/DEVELOPMENT.md) — build / debug / deploy runbook (copy-paste commands)

## Quick start — Mac + iPhone over Tailscale

makit is **private by default**: it binds to your [Tailscale](https://tailscale.com)
tailnet, not your local Wi-Fi. That way it works from anywhere (home, office,
cellular) and never exposes a port to untrusted networks like café or airport
Wi-Fi. Plain-LAN is opt-in (`--lan`) for trusted home networks only.

### 0. Install Tailscale (one time, both devices)

Install Tailscale on your Mac and your phone, sign into the **same tailnet**,
and bring it up:

```sh
# macOS
brew install tailscale   # or the App Store app
tailscale up
tailscale ip -4          # confirm you get a 100.x.y.z address
```

Install the Tailscale app on the phone and sign into the same account.

### 1. Start the server on your Mac

```sh
cd server
pnpm install
pnpm start -- --project ~/Work/Vibe/makit --project ~/Work/Vibe/cmux
```

First run generates a self-signed cert in `~/.makit/` and prints a QR with a
5-minute pairing token. With Tailscale up it binds the tailnet IP:

```
[makit] cert fingerprint: 3b54c69fec19cbad88efaef52a0c5f163aa4d65e55c9796312a1506a22636144
[makit] mDNS: advertising _makit._tcp on port 8787
[makit] projects:
  · makit  (/Users/le/Work/Vibe/makit)
  · cmux  (/Users/le/Work/Vibe/cmux)
[makit] transport: Tailscale (100.119.58.97) — private ✓

[makit] no paired devices yet — scan this QR with the app:

  █▀▀▀▀▀█ ... (QR here)
  █▄▄▄▄▄█

[makit] makit://pair?host=100.119.58.97&port=8787&fp=...&t=...
[makit] wss listening on wss://100.119.58.97:8787
```

**If Tailscale isn't running**, makit binds **loopback only** and refuses to
expose your network — it prints how to install Tailscale or opt into LAN:

```
[makit] transport: loopback only — not reachable from other devices.
[makit]   Tailscale not detected. Install it for a private connection:
[makit]     https://tailscale.com/download  then run 'tailscale up' and restart makit.
[makit]   Or pass --lan to expose this (untrusted) local network.
```

To serve over your local Wi-Fi instead (trusted home networks only), pass
`--lan`. Use `--host 0.0.0.0` to bind every interface.

### 2. Run the app and pair

Make sure the phone is on the **same tailnet** (Tailscale toggled on), then run
the app on a device with a camera:

```sh
cd app
flutter run -d "iPhone 15"      # or any other iPhone / iPad / Android device
```

In the app:
1. Pairing screen opens automatically.
2. Tap **"Scan QR"** and point the camera at the terminal. The QR carries the
   server's tailnet address + fingerprint + one-time pair token.
3. App connects over wss:// (cert pinned by fingerprint — no OS trust store
   needed), server mints a long-lived bearer, the app stores it in secure
   storage, and you land on Home.

Subsequent launches reconnect automatically — no QR needed. Tailnet IPs are
stable per-device, so the connection survives Wi-Fi/DHCP changes.

> **On `--lan` only:** the app can also discover the server via the
> **"On this network"** mDNS list (mDNS is link-local and does not cross the
> tailnet). You still scan the QR for the pair token — mDNS only finds the
> address; the token authorizes your device.

### 3. Subsequent pair tokens

To pair another device later, send `SIGUSR1` to the running server:
`kill -USR1 $(pgrep -f "node.*makit")`. A fresh QR appears in the server log
without restarting.

To revoke a paired device, edit `~/.makit/devices.json` (or use the Settings UI).

## Mac → Mac (no pairing needed)

For local dev on the same machine, skip pairing entirely:

```sh
# Terminal 1:
cd server && pnpm start -- --no-auth --project ~/Work/Vibe/makit

# Terminal 2:
cd app && flutter run -d macos \
  --dart-define=MAKIT_WS_URL=wss://127.0.0.1:8787 \
  --dart-define=MAKIT_FP=$(cat ~/.makit/server.crt | openssl x509 -outform der | shasum -a 256 | cut -d' ' -f1)
```

Or just `flutter run -d macos` with no defines and use the in-app
**FakeServer** for UI iteration without an agent.

## Project layout

```
makit/
├── docs/
│   ├── UX.md            # product spec
│   └── ARCHITECTURE.md  # protocol, server internals, adapter design
├── server/              # Node/TS WS server
│   └── src/
│       ├── index.ts        # `makit serve` / `makit pair` CLI
│       ├── server.ts       # wss + auth + fan-out
│       ├── session.ts      # one agent process + event log
│       ├── manager.ts      # projects + sessions registry
│       ├── protocol.ts     # wire types (mirrors app/lib/transport/protocol.dart)
│       ├── pairing/
│       │   ├── cert.ts     # self-signed cert; fingerprint
│       │   ├── registry.ts # paired devices + pair tokens (JSON-persisted)
│       │   ├── url.ts      # makit://pair?... builder
│       │   └── mdns.ts     # bonjour-service advertisement
│       └── adapters/
│           ├── adapter.ts  # AgentAdapter interface
│           └── pi.ts       # `pi --mode json` adapter
└── app/                 # Flutter client
    └── lib/             # see app/README.md
```

## Status

**M1 — pairing & LAN ✅**
- Self-signed TLS, cert pinning at the WS layer (no OS trust store needed)
- mDNS auto-discovery + QR pair token flow
- Persistent bearer token in secure storage; auto-reconnect on launch
- `--no-auth` localhost dev path preserved

**M0 — protocol + pi adapter ✅**
- WebSocket Envelope protocol + reconnect/resume
- `pi --mode json` adapter (real text + tool calls)
- Multiple projects → sessions, presence-aware fan-out

## Not yet

- Approval gating actually pausing tool execution (M2)
- Multi-turn while agent is mid-turn — currently dropped (M2)
- SQLite event log; in-memory only (M4)
- Push notifications (M5)
- QR auto-mint via long-press / button in server (instead of SIGUSR1)
- Settings UI to view & revoke paired devices

See [`docs/ARCHITECTURE.md §12`](./docs/ARCHITECTURE.md) for the full roadmap.
