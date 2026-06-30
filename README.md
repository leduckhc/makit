# pino

Mobile-first coding agent client. Run a server on your desktop, pair your
phone or any other device via QR, and drive `pi` / `codex` / `claude-code`
sessions through a chat UI.

- 📱 [`app/`](./app/) — Flutter mobile/desktop client
- 🖥 [`server/`](./server/) — Node/TS WebSocket server + agent adapters
- 📚 [`docs/UX.md`](./docs/UX.md), [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md)

## Quick start — Mac + iPhone over Wi-Fi

### 1. Start the server on your Mac

```sh
cd server
npm install
npm start -- --project ~/Work/Vibe/pino --project ~/Work/Vibe/cmux
```

First run generates a self-signed cert in `~/.pino/`, advertises the server
via mDNS as `_pino._tcp`, and prints a QR with a 5-minute pairing token:

```
[pino] cert fingerprint: 3b54c69fec19cbad88efaef52a0c5f163aa4d65e55c9796312a1506a22636144
[pino] mDNS: advertising _pino._tcp on port 8787
[pino] projects:
  · pino  (/Users/le/Work/Vibe/pino)
  · cmux  (/Users/le/Work/Vibe/cmux)

[pino] no paired devices yet — scan this QR with the app:

  █▀▀▀▀▀█ ... (QR here)
  █▄▄▄▄▄█

[pino] pino://pair?host=192.168.0.221&port=8787&fp=...&t=...
[pino] wss listening on wss://0.0.0.0:8787
```

### 2. Run the app and pair

On the **same Wi-Fi**, run the app on a device with a camera:

```sh
cd app
flutter run -d "iPhone 15"      # or any other iPhone / iPad / Android device
```

In the app:
1. Pairing screen opens automatically.
2. Either tap **"Scan QR"** and point the camera at the terminal,
3. Or pick the server from the **"On this network"** mDNS list (you'll still
   need to scan the QR to get the one-time pair token — mDNS just finds the
   server's address; the token authorizes your device).
4. App connects over wss://, server mints a long-lived bearer, app stores
   it in secure storage, you land on Home.

Subsequent launches reconnect automatically — no QR needed.

### 3. Subsequent pair tokens

If you want to pair another device later, send `SIGUSR1` to the running
server: `kill -USR1 $(pgrep -f "node.*pino")`. A fresh QR appears in the
server log without restarting.

To revoke a paired device, edit `~/.pino/devices.json` (or wait for the
Settings UI in M2).

## Mac → Mac (no pairing needed)

For local dev on the same machine, skip pairing entirely:

```sh
# Terminal 1:
cd server && npm start -- --no-auth --project ~/Work/Vibe/pino

# Terminal 2:
cd app && flutter run -d macos \
  --dart-define=PINO_WS_URL=wss://127.0.0.1:8787 \
  --dart-define=PINO_FP=$(cat ~/.pino/server.crt | openssl x509 -outform der | shasum -a 256 | cut -d' ' -f1)
```

Or just `flutter run -d macos` with no defines and use the in-app
**FakeServer** for UI iteration without an agent.

## Project layout

```
pino/
├── docs/
│   ├── UX.md            # product spec
│   └── ARCHITECTURE.md  # protocol, server internals, adapter design
├── server/              # Node/TS WS server
│   └── src/
│       ├── index.ts        # `pino serve` / `pino pair` CLI
│       ├── server.ts       # wss + auth + fan-out
│       ├── session.ts      # one agent process + event log
│       ├── manager.ts      # projects + sessions registry
│       ├── protocol.ts     # wire types (mirrors app/lib/transport/protocol.dart)
│       ├── pairing/
│       │   ├── cert.ts     # self-signed cert; fingerprint
│       │   ├── registry.ts # paired devices + pair tokens (JSON-persisted)
│       │   ├── url.ts      # pino://pair?... builder
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
