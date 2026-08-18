# AGENTS.md — `app/`

Flutter client for iOS and macOS. Riverpod for state, `go_router` for routes.
Read the root [`AGENTS.md`](../AGENTS.md) first; this file adds app facts.

## Commands

```sh
cd app
flutter pub get --enforce-lockfile
flutter analyze                       # audit gate adds --fatal-infos
flutter test                          # unit + widget
flutter test test/home_screen_test.dart
flutter run -d macos                  # in-app FakeServer: no server, no pairing
flutter run -d "iPhone 17"
dart format lib test tool integration_test    # never `dart format .` — build/ has generated code
tool/audit.sh                         # the pre-handoff gate, includes the stub e2e
```

Flutter must be on `PATH`. A new native plugin needs a full `flutter run`;
hot reload will not pick it up.

## Layout

| Path | Role |
| --- | --- |
| `lib/store/` | state and reducers — pure functions of (state, event) |
| `lib/transport/` | WebSocket client and the cert pin |
| `lib/ui/` | screens and widgets |
| `lib/desktop/` | macOS control plane and the daemon supervisor |
| `lib/pairing/`, `lib/notifications/`, `lib/status/` | pairing, pushes, presence |
| `integration_test/stub/` | simulator e2e cases, registered in `all_stub_test.dart` |
| `integration_test/desktop/` | macOS cases for native paths a simulator cannot run |
| `tool/` | audit, e2e, recording, and demo harnesses |

## Rules that bite here

- **State is immutable.** Use `copyWith`. Never mutate shared state in place.
- **Reducers stay pure**, so replays and duplicate events are safe.
- **`Clipboard.getData` has no default mock in `flutter_test`.** An un-mocked
  call never completes, so the test hangs instead of failing. Install a
  `SystemChannels.platform` mock handler.
- **`pumpAndSettle` never settles** while text sits in a focused `TextField`,
  because the cursor blinks. Use `pump()` plus `pump(Duration)`.
- **A widget test is not proof** for anything that crosses the wire. Add a case
  under `integration_test/stub/` and run `tool/e2e.sh --mode=stub`.
- Keep `debugPrint` out of shipped hot paths. Use the leveled logger.
- Two desktop builds can run at once. Each build isolates its own
  `MAKIT_HOME`, port, and prefs from the `.app` path.

## Deeper reading

- Mobile app section: [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) §6
- Debug loops and keyless QA: [`../docs/DEVELOPMENT.md`](../docs/DEVELOPMENT.md) §2
- UX rules: [`../docs/UX.md`](../docs/UX.md)
- Lockfile and supply-chain rules: [`SECURITY.md`](./SECURITY.md),
  [`LINTING_AND_SECURITY.md`](./LINTING_AND_SECURITY.md)
