# Development Runbook — build, debug & deploy

Day-to-day commands for the **server** (`server/`) and the **Flutter app**
(`app/`). Everything here is copy-paste ready. For App Store / DMG
notarization specifics see [`../BUILD_AND_DEPLOY.md`](../BUILD_AND_DEPLOY.md).

---

## 0. Toolchain & environment

| Thing | Value |
|-------|-------|
| Flutter | `3.47.0` (stable), binary at `/Users/le/Work/Vibe/flutter/bin/flutter` |
| Server package manager | **pnpm** (`npm install` is blocked by a preinstall guard) |
| Node | 20+ (server runs via `tsx`) |
| Apple team | `RT8DP44B6N` · bundle id `dev.getmakit.app` |
| Rust | **required** — `rustup` + `cargo` on `PATH` (see below) |
| CocoaPods | **required** for iOS/macOS builds (see below) |
| KC's iPhone (wireless) | device id `00008150-0006282C3E52401C` |
| Booted simulator | `iPhone 17` — `803DF95F-0D22-4ACD-9A9F-82A9F50F5CC8` |

If `flutter` is not on your `PATH`, add it once per shell:

```sh
export PATH="/Users/le/Work/Vibe/flutter/bin:$PATH"
```

Sanity check:

```sh
flutter --version          # expect 3.47.0
pnpm --version
rustup --version           # SPEC-user-attachments: required, see "Rust + CocoaPods" below
pod --version
xcrun simctl list devices booted
flutter devices            # lists simulators, macOS, and wireless iPhones
```

### Rust + CocoaPods (both required since SPEC-user-attachments)

The app depends on `super_clipboard` (clipboard **image** reads — Flutter's own
`Clipboard` is text-only), which is implemented in Rust via
`super_native_extensions`. Two consequences for the toolchain:

**1. `rustup` is mandatory, not optional.** Without it the plugin silently
downloads *precompiled* binaries, which `pubspec.lock` does not hash-verify —
precisely what `app/SECURITY.md` §3/§4 exist to prevent. With `rustup` present
the build integration compiles from source instead. `app/tool/audit.sh` step 10
**fails** when `super_clipboard` is locked and `rustup` is missing, so this is
enforced, not merely documented.

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup update              # if already installed
```

The first build after a clean checkout compiles ~600 crates (~1 min on an M-series
Mac); later builds are incremental. Android additionally auto-installs the NDK
(~1 GB) on first build.

**2. CocoaPods is back in the iOS/macOS builds.** `super_native_extensions` does
not support Swift Package Manager, so adding it re-introduced CocoaPods into two
otherwise SPM-only Xcode projects. `ios/Podfile{,.lock}` and
`macos/Podfile{,.lock}` are now committed, `Runner.xcodeproj` carries Pods build
phases, and the `Flutter-*.xcconfig` files `#include?` the generated Pods
xcconfig. `flutter build`/`flutter run` invoke `pod install` automatically; CI
runners need CocoaPods installed. Flutter currently warns that non-SPM plugins
"will become an error in a future version" — if that lands before the plugin
adopts SPM, we replace it (see SPEC-user-attachments §4.3).

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

### Idle auto-close (opt-in memory hygiene)

makit runs **one agent process per session**, so live sessions cost real
memory (60–450 MB each). Idle auto-close is **off** by default: a session stays
open until you close it. `MAKIT_IDLE_CLOSE_MIN` opts the host in.

When you opt in, the server closes each session that is idle longer than the
window: it releases the agent (ACP `session/close` / codex
`thread/unsubscribe`) and reaps the process (`SIGTERM` → `SIGKILL` after a
grace period). This is always reversible — the transcript and resume handle are
kept, the session moves to the **Closed** list, and simply sending a message
reopens and resumes it. Opening a closed session to *read* it does not respawn
an agent.

| Env var | Default | Meaning |
| --- | --- | --- |
| `MAKIT_IDLE_CLOSE_MIN` | unset (off) | Minutes of inactivity before the server auto-closes a session. Only a positive number turns it on. Unset, empty, `0`, negative, and non-numeric values all keep every session open. The server logs a value that it rejects. Set it on a memory-tight host. |

Sessions that are mid-turn, awaiting input/approval, still drafts, already cold,
or lacking a native resume handle are never auto-closed.

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
node dist/src/index.js devices
```

### Test / typecheck / build

```sh
cd server
pnpm test              # node --test over src/**/*.test.ts (unit)
pnpm typecheck         # tsc -p . --noEmit
pnpm build             # tsc -p . → dist/  (then: node dist/src/index.js serve ...)
```

---

## 1b. Forges other than GitHub (Forgejo / Gitea)

The server picks a provider per repository by **asking the instance what it runs**,
once per host, cached:

| Probe | Forgejo | Gitea | GitLab |
|-------|---------|-------|--------|
| `GET /api/forgejo/v1/version` | 200 | 404 | — |
| `GET /api/v1/version` | 200 | 200 | 302 → sign-in |
| `GET /api/v4/version` | — | — | 401 |

`github.com` (and subdomains) is decided by hostname and never probed. Forgejo and
Gitea share one provider — the REST API is the same. GitLab, or anything
unidentifiable, routes to an **unsupported** provider that makes no requests and
says so on a button press, instead of being polled against an API that is not
there and failing as "unknown" (which looked identical to an outage). The host is
logged once, not once per poll.

Caching, precisely: a decisive answer (`forgejo`, `gitea`, `gitlab`) is cached for
the process lifetime, keyed by the normalised base URL. An **`unknown`** result --
whether the host is unidentifiable or the probe failed to connect -- is cached for
60 seconds and then re-probed, so an instance that was briefly down is not pinned as
unsupported until the server restarts. Routing treats `unknown` as undecided too, so
the repo is re-routed rather than left on the fallback provider.

A repo's **provider setting** short-circuits all of this: `Forgejo`, `Gitea` or
`GitHub` picks the gateway with no probe at all, and `None` reaches no forge. That is
the recourse for an instance the probe cannot classify -- one that answers 401 to an
anonymous request, or sits behind a proxy that hides the version endpoints. See
`docs/specs/20260810-004800-SPEC-per-repo-settings.md`.

No `gh`-style login is involved; the provider talks REST with a token.

| Variable | Purpose |
|----------|---------|
| `FORGEJO_BASE_URL` (or `MAKIT_FORGEJO_BASE_URL`) | The instance URL. Only needed when `https://<host-from-the-remote>` is not right — a sub-path install, a non-standard port, or plain HTTP on a private network. |
| `FORGEJO_ACCESS_TOKEN` (or `MAKIT_FORGEJO_TOKEN`, `FORGEJO_TOKEN`, `GITEA_TOKEN`) | API token, checked in that order. Create it under *Settings → Applications*. |

**Setting an instance URL scopes the token to that host.** This is a security
property: configuring one instance means exporting a single global token, and
without scoping it would be attached to every non-GitHub remote — so opening any
public Gitea/Forgejo repo would send your internal token to a third party. A
foreign host is still queried, just unauthenticated (correct for a public repo).
Host matching ignores scheme, port and path, because an scp-form remote
(`git@host:owner/repo`) cannot express the API's port.

Token scopes: `read:repository` is enough for the PR pills. The PR *actions*
(mark ready, update branch, squash-merge) additionally need `write:repository`.
Creating repositories needs `write:user` / `write:organization`, which makit
never does.

### Differences you will see versus GitHub

- **No quota panel.** Forgejo exposes no request quota to read: no
  `/api/v1/rate_limit` endpoint and no rate-limit response headers, and its
  configuration has no instance-wide request limiter (the `quota` feature meters
  *storage* — repo/LFS/package bytes — not requests). Rate limiting on a Forgejo
  instance therefore comes from whatever sits in front of it, not from Forgejo
  itself. So there is nothing to ration or display, and the budget
  footer keeps showing GitHub's quota only. A Forgejo-only setup therefore polls
  at the fast 5s rung rather than being throttled by GitHub's ladder.
  In a **mixed** setup GitHub's ladder still governs the shared poll timer for
  every repo; per-repo cadence would need reworking `pr_watcher`.
- **Throttling still happens, just not from Forgejo.** An instance behind nginx
  `limit_req`, Cloudflare or an anti-scraper gate can answer `429`, and a slow
  query can shed load with `503`. Those are honoured: the provider backs off for
  `Retry-After` (capped at 5 minutes so a bad header cannot park polling for a
  day), withholds background polls while waiting, still lets a button press
  through, and reports `throttled` rather than "no PR".
- **"Mark ready" rewrites the title.** Forgejo derives `draft` from a
  `WORK_IN_PROGRESS_PREFIXES` title prefix (default `WIP:`, `[WIP]`,
  case-insensitive, configurable per instance) and its API has no `draft` field.
  makit strips the prefix, and refuses rather than guessing if it does not
  recognise one.
- **No merge-state detail.** GitHub's `BEHIND`/`BLOCKED`/`CLEAN` has no Forgejo
  counterpart, so that fact is reported as unknown instead of guessed.
- **Unresolved review comments are not counted yet.** Forgejo exposes resolution
  per review *comment* via a reviews→comments walk; until that is verified the
  count is marked unmeasured rather than reported as zero.

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

#### Running two builds at once (main + a worktree)

Each desktop **build** auto-isolates against its own server so a `main` build
and a worktree build never collide. The profile is derived from the running
`.app`'s path (`ServerProfile.resolve`, `app/lib/desktop/daemon/server_profile.dart`):

| | Installed app | Dev build (`.../app/build/macos/.../Makit.app`) |
|---|---|---|
| `MAKIT_HOME` | `~/.makit` | `~/.makit-dev/<hash-of-repo-root>` |
| Port (default) | `7777` | `7800–7899` (stable per repo path) |
| Prefs (`NSUserDefaults`) | `flutter.` | `flutter.<hash>.` |
| Window title / badge | `Makit` | `Makit — <folder>` + colored pill |

So you just run both `Makit.app`s and switch by focusing the window (Cmd-Tab);
the colored badge in the sidebar header + the window title tell them apart.
Each keeps its own daemon, pairings, sessions, and settings.

To drive a dev build's server from a terminal, point the CLI at the same home,
e.g. `MAKIT_HOME=~/.makit-dev/<hash> makit status` (the app spawns its bundled
CLI with this env automatically).

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

### Keyless visual QA — real app, real server, scripted turn

The stub adapter answers text triggers, so a live transcript can be driven with
no LLM key and no agent binary. `TOOLS` is the one that produces **tool rows**
(reasoning → read → multi-command shell → grep → edit → a failure → a
destructive call, with real delays so the duration tokens fire):

```sh
# Terminal 1 — real daemon + StubAdapter, seeded pairing on :9787
cd server
export MAKIT_HOME=$(mktemp -d)
pnpm exec tsx test/e2e-server.ts --mode stub --project /path/to/repo   # prints fp + bearer

# Terminal 2 — the real app, paired to it
cd app && flutter run -d "iPhone 17" \
  --dart-define=MAKIT_TEST_HOST=127.0.0.1 --dart-define=MAKIT_TEST_PORT=9787 \
  --dart-define=MAKIT_TEST_BEARER=e2e-token --dart-define=MAKIT_TEST_FP=<fp>

# Terminal 3 — drive a turn; the app renders it live
cd server && pnpm exec tsx test/drive-tools.ts             # sends TOOLS
cd server && pnpm exec tsx test/drive-tools.ts --text THINK # or any other trigger
```

Other triggers: `STREAM`, `THINK`, `SLOW [ms]`, `MARKDOWN`, `ASK_QUESTION`,
`ASK_MULTI`. The desktop app spawns its own daemon with the real adapter catalog
(no stub), so this loop is iOS/simulator-only; for desktop-only row rendering use
the widget harness `app/tool/tool_row_demo.dart`
(`--dart-define=unfold=true` opens every row expanded).

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
# → build/macos/Build/Products/Release/Makit.app
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

Actionable lock-screen approvals (SPEC-actionable-notifications) and content-free APNs wake (SPEC-background-wake-notifications)
are implemented. Full on-device checklists and troubleshooting:

- [docs/NOTIFICATIONS.md](NOTIFICATIONS.md) — SPEC-actionable-notifications/07 validation steps
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
