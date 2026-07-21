<div align="center">

<img src="assets/makit-icon.png" alt="Makit" width="120" />

# Makit

### Drive your coding agent from your phone.

Run a server on your desktop, scan a QR with your phone, and steer
`pi` / `codex` / `claude-code` sessions from a chat UI — from the couch,
the train, or anywhere on your [Tailscale](https://tailscale.com) tailnet.

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](./LICENSE)
[![Server CI](https://github.com/leduckhc/makit/actions/workflows/server-ci.yml/badge.svg)](https://github.com/leduckhc/makit/actions/workflows/server-ci.yml)
[![Flutter CI](https://github.com/leduckhc/makit/actions/workflows/flutter-ci.yml/badge.svg)](https://github.com/leduckhc/makit/actions/workflows/flutter-ci.yml)

<!-- Demo: record the flow, save it at docs/media/demo.gif (see docs/media/README.md),
     then uncomment the line below. -->
<!-- <img src="docs/media/demo.gif" alt="Makit demo: scan a QR and drive an agent from your phone" width="720" /> -->

_▶️ Demo video coming soon — see [`docs/media/`](./docs/media/) to add it._

</div>

---

## Why Makit

- 🤖 **One client for every agent.** Talk to `pi`, `codex`, and
  `claude-code` through the same chat UI — no per-tool app.
- 📱 **Untethered.** Kick off work at your desk, review diffs and approve
  tool calls from your phone while you're away.
- 🔒 **Private by default.** Binds to your Tailscale tailnet, not open Wi-Fi.
  The transport is cert-pinned — no ports exposed to café networks, no OS
  trust store needed.
- 🔔 **Never miss a prompt.** Get notified when an agent is waiting on you
  (approval, a question, or a finished turn).

📱 [`app/`](./app/) (Flutter client) · 🖥 [`server/`](./server/) (Node/TS server)
· 📚 [UX](./docs/UX.md) · [Architecture](./docs/ARCHITECTURE.md) ·
[Development runbook](./docs/DEVELOPMENT.md) · [Notifications](./docs/NOTIFICATIONS.md)

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
pnpm start
```

First run generates a self-signed cert in `~/.makit/` and prints a QR with a
5-minute pairing token. With Tailscale up it binds the tailnet IP:

```
[makit] cert fingerprint: 3b54c69fec19cbad88efaef52a0c5f163aa4d65e55c9796312a1506a22636144
[makit] mDNS: advertising _makit._tcp on port 7777
[makit] projects:
  · makit  (~/Vibe/makit)
  · cmux  (~/Vibe/cmux)
[makit] transport: Tailscale (100.120.70.21) — private ✓

[makit] no paired devices yet — scan this QR with the app:

  █▀▀▀▀▀█ ... (QR here)
  █▄▄▄▄▄█

[makit] makit://pair?host=100.120.70.21&port=7777&fp=...&t=...
[makit] wss listening on wss://100.120.70.21:7777
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
cd server && pnpm start -- --no-auth

# Terminal 2:
cd app && flutter run -d macos \
  --dart-define=MAKIT_WS_URL=wss://127.0.0.1:7777 \
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

**M2 — sessions & approvals ✅**
- Agent adapters (`pi`, `codex`, `claude-code`, ACP) with tool cards and approval flow
- `srv.request` / `srv.response` for in-app and lock-screen approvals
- Repo-centric home (worktrees, diff stats, PR badges)
- SQLite event log for reconnect/resume

**M5 — notifications ✅**
- Actionable lock-screen Approve/Deny/Reply ([SPEC-08](docs/specs/2026-07-08-SPEC-08-actionable-notifications.md))
- Content-free APNs background wake ([SPEC-07](docs/specs/2026-07-08-SPEC-07-background-wake-notifications.md)) — see [push setup](docs/PUSH.md)
- On-device checklists: [docs/NOTIFICATIONS.md](docs/NOTIFICATIONS.md)

## Not yet

- Multi-turn while agent is mid-turn — currently dropped
- QR auto-mint via long-press / button in server (instead of SIGUSR1)
- Per-type notification mute & default approval policy in Settings
- Signed macOS app distribution (see [specs README](docs/specs/README.md) M3)

See [`docs/ARCHITECTURE.md §12`](./docs/ARCHITECTURE.md) for the full roadmap.

## License

Makit is **dual-licensed**:

- **Open source:** [GPL-3.0-or-later](./LICENSE) — free for everyone.
- **Commercial:** for organizations that cannot comply with the GPL, a
  commercial license is available. Contact **license@getmakit.dev**.

Contributions are welcome under our [Contributor License Agreement](./CLA.md);
see [`CONTRIBUTING.md`](./CONTRIBUTING.md).
