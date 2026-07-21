# Development Runbook — build, debug & deploy

Day-to-day commands for the **server** (`server/`) and the **Flutter app**
(`app/`). Everything here is copy-paste ready. For App Store / DMG
notarization specifics see [`../BUILD_AND_DEPLOY.md`](../BUILD_AND_DEPLOY.md).

---

## 0. Toolchain & environment

| Thing | Value |
|-------|-------|
| Flutter | `3.44.4` (stable), binary at `/Users/le/Work/Vibe/flutter/bin/flutter` |
| Server package manager | **pnpm** (`npm install` is blocked by a preinstall guard) |
| Node | 20+ (server runs via `tsx`) |
| Apple team | `RT8DP44B6N` · bundle id `dev.getmakit.app` |
| KC's iPhone (wireless) | device id `00008150-0006282C3E52401C` |
| Booted simulator | `iPhone 17` — `803DF95F-0D22-4ACD-9A9F-82A9F50F5CC8` |

If `flutter` is not on your `PATH`, add it once per shell:

```sh
export PATH="/Users/le/Work/Vibe/flutter/bin:$PATH"
```

Sanity check:

```sh
flutter --version          # expect 3.44.4
pnpm --version
xcrun simctl list devices booted
flutter devices            # lists simulators, macOS, and wireless iPhones
```

---

## 1. Server (`server/`)

### Install

```sh
cd server
pnpm install                 # NOT npm — preinstall guard rejects it
```

### Run — development (auto-reload, localhost, no pairing)

```sh
cd server
pnpm dev -- --no-auth --project ~/Work/Vibe/makit
```

`pnpm dev` is `tsx watch src/index.ts serve` — it restarts on file changes.
`--no-auth` lets localhost clients connect without a pairing token (dev only).
Repeat `--project <path>` for each repo you want to expose.

### Run — foreground (for pairing a phone over Wi-Fi)

```sh
cd server
pnpm start -- --project ~/Work/Vibe/makit --project ~/Work/Vibe/cmux
```

First run creates a self-signed cert in `~/.makit/`, advertises `_makit._tcp`
via mDNS, and prints a QR + `makit://pair?...` URL with a 5-minute token.
Add `--host 0.0.0.0` only if you must bind every interface.

Print a fresh pairing QR without restarting:

```sh
kill -USR1 "$(pgrep -f 'tsx.*index.ts serve' || pgrep -f 'node.*makit')"
```

### CLI subcommands

`pnpm start`/`pnpm dev` always run `serve`. For the other subcommands invoke
the entrypoint directly (dev), or build once and use the `makit` binary:

```sh
cd server
pnpm exec tsx src/index.ts pair        # one-shot: print a QR + URL
pnpm exec tsx src/index.ts qr          # reprint the current QR
pnpm exec tsx src/index.ts devices     # list paired devices
pnpm exec tsx src/index.ts sessions    # list live sessions
pnpm exec tsx src/index.ts status      # start|stop|restart|status|logs

# or, after `pnpm build`:
node dist/index.js devices
```

### Test / typecheck / build

```sh
cd server
pnpm test              # node --test over src/**/*.test.ts (unit)
pnpm typecheck         # tsc -p . --noEmit
pnpm build             # tsc -p . → dist/  (then: node dist/index.js serve ...)
```

---

## 2. App (`app/`)

### Setup

```sh
cd app
flutter pub get --enforce-lockfile
```

### Debug on the iOS simulator (hot reload)

```sh
cd app
open -a Simulator                                   # boot one if needed
flutter run -d 803DF95F-0D22-4ACD-9A9F-82A9F50F5CC8 # or:  flutter run -d "iPhone 17"
```

While `flutter run` is attached:

```
r   hot reload (keep state)
R   hot restart (reset Dart VM)
q   quit
```

> Adding a **new native plugin** (e.g. url_launcher) needs a full
> `flutter run` rebuild — hot reload/restart won't pick it up.

### Debug on macOS desktop

```sh
cd app
flutter run -d macos
```

Pure UI iteration with no server? `flutter run -d macos` uses the in-app
**FakeServer** — no agent, no pairing.

### Debug on the physical iPhone (attached, hot reload over Wi-Fi)

```sh
cd app
flutter run --release -d 00008150-0006282C3E52401C   # or debug: drop --release
```

### Local dev loop — Mac app ↔ Mac server (no pairing)

```sh
# Terminal 1
cd server && pnpm start -- --no-auth --project ~/Work/Vibe/makit

# Terminal 2
cd app && flutter run -d macos \
  --dart-define=MAKIT_WS_URL=wss://127.0.0.1:7777 \
  --dart-define=MAKIT_FP=$(openssl x509 -in ~/.makit/server.crt -outform der | shasum -a 256 | cut -d' ' -f1)
```

### Analyze / test

```sh
cd app
flutter analyze                              # lint (audit gate: --fatal-infos)
flutter test                                 # unit + widget tests
flutter test test/home_screen_test.dart      # a single file
```

### End-to-end suite (simulator + stub server)

```sh
cd /Users/le/Work/Vibe/makit
./app/tool/e2e.sh --mode=stub                # ~50s; boots sim, stub server on :9787
./app/tool/e2e.sh --mode=real                # slow; real pi, needs an LLM key
```

If a killed run leaks the stub server on port 9787:

```sh
pkill -f e2e-server.ts; lsof -ti :9787 | xargs -r kill -9
```

### Full pre-merge audit (lint + tests + E2E + format + dep scan)

```sh
cd /Users/le/Work/Vibe/makit
./app/tool/audit.sh
```

---

## 3. Release builds

### iOS release `.app`

```sh
cd app
flutter build ios --release
# → build/ios/iphoneos/Runner.app  (auto-signed with team RT8DP44B6N)
```

### iOS `.ipa` (App Store / TestFlight)

```sh
cd app
flutter build ipa --release
# → build/ios/ipa/makit.ipa
```

### macOS release app

```sh
cd app
flutter build macos --release
# → build/macos/Build/Products/Release/makit.app
```

DMG signing + notarization: see [`../BUILD_AND_DEPLOY.md`](../BUILD_AND_DEPLOY.md) §2.

---

## 4. Deploy to the physical iPhone

The app must already be installed once (signing set up via Xcode — see
[`../BUILD_AND_DEPLOY.md`](../BUILD_AND_DEPLOY.md) §1.2). For updates, over Wi-Fi:

```sh
cd app
flutter build ios --release
xcrun devicectl device install app \
  --device 00008150-0006282C3E52401C \
  build/ios/iphoneos/Runner.app
```

> **Use `devicectl`, not `flutter install`.** Over Wi-Fi `flutter install`
> reliably stalls at "Uninstalling old version…". `devicectl` works, but the
> first attempt often fails with `NWError 54 — Connection reset by peer`;
> just re-run the exact same command and it succeeds on the 2nd try.

Verify what's installed on the device:

```sh
xcrun devicectl device info apps \
  --device 00008150-0006282C3E52401C \
  --bundle-id dev.getmakit.app | grep -i makit
```

Same cert as before ⇒ no re-trust prompt. Then start a server
(`pnpm start -- --project <path>`) and pair by scanning the QR in the app.

---

## 5. Notifications & background wake

Actionable lock-screen approvals (SPEC-08) and content-free APNs wake (SPEC-07)
are implemented. Full on-device checklists and troubleshooting:

- [docs/NOTIFICATIONS.md](NOTIFICATIONS.md) — SPEC-08/07 validation steps
- [docs/PUSH.md](PUSH.md) — `~/.makit/push.json` APNs setup on the server

In the iOS app: **Settings → Notifications** shows permission and background-wake
registration status.

Quick server check after configuring push:

```sh
makit restart
# expect: [makit] push: APNs sender active (sandbox, dev.getmakit.app)
makit devices   # paired device should list a push token
```

---

## 6. Debugging tips

```sh
# Live device console logs for the app
xcrun devicectl device console --device 00008150-0006282C3E52401C

# Simulator logs (predicate on our subsystem/process)
xcrun simctl spawn booted log stream --level debug --predicate 'process == "Runner"'

# Server verbose logs when run as a daemon
cd server && pnpm exec tsx src/index.ts logs

# Environment / signing sanity
flutter doctor
security find-identity -v -p codesigning
```

Common gotchas:

- **`pnpm` required for the server** — `npm install` exits with a guard error.
- **Snapshots dropped on launch**: `main.dart` eagerly reads
  `storeControllerProvider` so the WS listener attaches before connect; don't
  remove that.
- **E2E leaves the app uninstalled**: `e2e.sh` uninstalls `dev.getmakit.app` on
  exit, which kills a `flutter run` dev app on the same simulator — quit the
  dev app before running E2E, relaunch after.
- **Mac LAN IP drifts** — never hardcode it; pairing carries host + bearer +
  cert fingerprint via the QR.
