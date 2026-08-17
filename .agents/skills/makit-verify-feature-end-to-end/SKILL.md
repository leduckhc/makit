---
name: "makit-verify-feature-end-to-end"
description: "Prove a makit feature actually works (not just unit-passes) using the keyless stub loops, and avoid the specific traps in makit's test harnesses"
---
## When to Use
Use after implementing any makit feature that spans server + app (wire field, new route, composer affordance). Unit tests here routinely pass while the feature is dead in the real app, because StubAdapter has its own send()/event path and several harnesses hide missing wiring behind casts.

## Procedure
1. Server gates: `cd server && node_modules/.bin/tsc -p . --noEmit && npm test`. Use `npm test` (node --import tsx), NOT `pnpm exec tsx --test` — the latter can prune devDependencies and hangs.
2. App gates: `cd app && flutter analyze --fatal-infos --no-pub && flutter test --no-pub`.
3. Full-stack proof (the step that actually matters): add a case to `app/integration_test/stub/` and register it in `integration_test/all_stub_test.dart`, then run `tool/e2e.sh --mode=stub`. This boots the real server (StubAdapter, no API key) plus the real app on an iOS simulator, so real HTTP/WSS/native-plugin paths execute. ~5 min, mostly the Xcode build.
4. For native-plugin paths (clipboard, pickers) that a simulator cannot exercise, add a macOS case under `app/integration_test/desktop/` and run `flutter test integration_test/desktop/<f>_test.dart -d macos`.
5. When touching adapters, update `src/adapters/stub.ts` too — it implements `send()` independently, so both e2e loops silently bypass unported logic.
6. Finish with `cd app && tool/audit.sh` (includes the stub e2e as step 5) and `dart format lib test tool integration_test`.
7. Probe real runtime shapes with a throwaway script instead of assuming: `cp /tmp/probe.ts server/probe.ts && node --import tsx probe.ts` (e.g. it revealed the default session has worktreePath == null).

## Pitfalls
- `Clipboard.getData` has NO default mock in flutter_test — an un-mocked call never completes and the test HANGS rather than fails. Install a `SystemChannels.platform` mock handler.
- `pumpAndSettle` never settles once text is in a focused TextField (cursor blink). Use `pump()` + `pump(Duration)`.
- Test doubles built as `new EventEmitter() as unknown as AgentAdapter` silently omit new required interface members; fix the doubles rather than adding `?.` in production (the cast, not the code, is the liar).
- A second `server.on('request')` handler in a route test wins the race against any handler that answers asynchronously (e.g. after a request body arrives) — scope harness fallthroughs to paths the route does not own.
- `git rev-parse --absolute-git-dir` is the wrong dir for excludes in a linked worktree; git reads `info/exclude` from `--git-common-dir`. makit always runs sessions in linked worktrees, so this only breaks for real users.
- In `app/`, `dart format .` walks `build/`, where cargokit writes an unformatted generated Dart file — scope the format check to `lib test tool integration_test`.

## Verification
1. server: `tsc --noEmit` clean and all tests pass.
2. app: `analyze --fatal-infos` clean and all tests pass.
3. `tool/e2e.sh --mode=stub` passes with the new integration case listed in its output.
4. `tool/audit.sh` reports PASS (no warnings).
5. `flutter build macos --debug` and `flutter build ios --debug --no-codesign` both succeed.
