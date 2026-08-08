# Handout — bumping the Flutter SDK

**Branch:** `chore/bump-flutter` · **Worktree:** `/Users/le/.worktrees/makit/chore-bump-flutter`
**Base:** `main` @ `9d31156` · **Written:** 2026-08-08

Self-contained brief for whoever (human or agent) picks this branch up. It also
doubles as the repo's Flutter-upgrade runbook — this chore recurs, and it has
two traps that are not discoverable from the diff.

---

## 0. Status — landed 2026-08-08

Pinned SDK is now **`3.44.9`** (rev `6b182d2c75`, Dart 3.12.2), taken for the
Xcode 27 lipo fix in §4. Installed the **separate-directory** way (§6) at
`/Users/le/Work/Vibe/flutter-3.44.9`, so the shared checkout stayed on `3.44.4`
and the other four worktrees did not move. Using it needs a per-shell override:

```sh
export PATH="/Users/le/Work/Vibe/flutter-3.44.9/bin:$PATH"
```

**At merge:** move the shared checkout to `3.44.9` (§7 step 1), re-run
`patch_flutter_sdk.sh` against it, then delete `flutter-3.44.9` (4.0 GB).
`docs/DEVELOPMENT.md` deliberately documents the canonical shared path, not the
temporary one.

Every claim below was re-checked against 3.44.9 rather than assumed: §3
byte-identical pubspecs ✓ · zero-line `pubspec.lock` diff ✓ · `pub get` still
reports 28 incompatible packages ✓ · patch script reported `patched 5 class(es)`,
not 0 ✓ · `analyze` clean ✓ · `build macos --release` launches with no `illegal
cid` ✓ · server typecheck + 1115 tests ✓.

---

## 1. Goal

Move the pinned Flutter SDK off `3.44.4`, which is what every CI workflow, the
development runbook, and the local toolchain currently expect.

**Non-goal — read this before you start.** This branch will *not* shrink the
"N packages have newer versions incompatible with dependency constraints"
warning. That was the original motivation and it does not survive contact with
the evidence; see §3. If someone handed you this branch to silence that warning,
go back and re-scope.

---

## 2. Where things stand

| | version | Dart | released |
|---|---|---|---|
| was pinned | `3.44.4` (rev `ad70ec4617`) | 3.12.2 | 2026-06-24 |
| **pinned now** · latest stable | `3.44.9` (rev `6b182d2c75`) | 3.12.2 | 2026-08-06 |
| previous stable | `3.44.8` | 3.12.2 | 2026-07-23 |
| latest beta | `3.47.0-0.4.pre` | **3.13.0** | 2026-08-05 |

The local SDK is a **git checkout** at `/Users/le/Work/Vibe/flutter` on branch
`stable`, not a downloaded archive. That matters for §5 and §6.

`app/pubspec.yaml` declares `sdk: ">=3.10.0 <4.0.0"` and `flutter: ">=3.38.0"`.
Both are satisfied by every row above, so **no `pubspec.yaml` edit is required**
for any of these targets.

---

## 3. Staying on stable 3.44.x frees zero pinned packages

The Flutter SDK pins four packages with `=`, not `^`:

```yaml
# packages/flutter/pubspec.yaml
meta: 1.18.0
vector_math: 2.2.0
# packages/flutter_test/pubspec.yaml
matcher: 0.12.19
test_api: 0.7.11
```

Those four cascade into eleven packages that pub reports as outdated but cannot
resolve:

| package | wants | blocked by |
|---|---|---|
| `meta`, `vector_math`, `matcher`, `test_api` | 1.19.0 / 2.4.2 / 0.12.20 / 0.7.13 | the exact pin above |
| `test` 1.31.2, `test_core` 0.6.19 | `test_api: 0.7.13` (exact) | `test_api` held at 0.7.11 |
| `analyzer` 14.1.0 | `meta: ^1.18.3` | `meta` held at 1.18.0 |
| `_fe_analyzer_shared` 105.0.0 | ships with analyzer 14 | ↑ |
| `package_config` 3.0.0 | — | `analyzer` 12.1.0 + `test` 1.31.0 both require `^2.0.0` |
| `hooks` 2.1.0 | `meta: ^1.19.0` | `meta` held at 1.18.0 |
| `record_use` 1.0.0 | ships with hooks 2.1.0 | ↑ |

**Verify before doubting it** — the three relevant SDK pubspecs are byte-identical
between the two tags:

```sh
cd /Users/le/Work/Vibe/flutter
git fetch --tags origin 'refs/tags/3.44.9:refs/tags/3.44.9'   # if not present
git diff 3.44.4 3.44.9 -- packages/flutter/pubspec.yaml \
    packages/flutter_test/pubspec.yaml packages/flutter_tools/pubspec.yaml
# expected: no output
```

Freeing those eleven requires **Dart 3.13**, which today exists only on beta
`3.47.0-0.4.pre`. That is a channel change, not a version bump — separate
decision, separate branch, and questionable while `liquid_glass_renderer` is on
a `0.2.0-dev.4` prerelease.

A second group of outdated packages is held by upstream plugin constraints
(`qr` ← `qr_flutter`, `cli_util` ← `flutter_launcher_icons`,
`win32`/`win32_registry`/`device_info_plus`/`dbus` ← `super_native_extensions`
and `flutter_local_notifications`). No Flutter version affects those either.

---

## 4. What the bump does buy

`3.44.4..3.44.9` is 16 cherry-picks, ~5 of them CI-infra only. Relevant to us:

- **Fix Xcode 27 lipo verification failure for Darwin frameworks** (#189792) —
  touches macOS/iOS release packaging, the strongest single reason to take this
- Detach LLDB and print stack trace on process stop (#188576) — iOS debugging
- Impeller: text shadow mask positioning (#188766)
- Android: `libapp.so` dropped from APK/bundle (#188516); AccessibilityBridge
  startup crash on vendor-modified ROMs (#189759); no AGP<9 warning spam (#188716)

Plus engine version syncs. Nothing here touches the dependency graph, which is
why §6 expects a **zero-line** `pubspec.lock` diff.

---

## 5. Trap 1 — the SDK is hand-patched, and the patch is load-bearing

`app/tool/patch_flutter_sdk.sh` edits the Flutter SDK **in place** for two
unfixed upstream bugs:

1. **#188060** — macOS `--release` (AOT) crashes with `illegal cid, full-aot`
   because the tree-shaker drops experimental windowing FFI structs. The patch
   force-retains them with `@pragma('vm:entry-point')`.
2. **#182400** — `impellerc` dumps hundreds of lines of SkSL compiler stderr on
   every build. The patch downgrades that to `printTrace`.

Consequences:

- **The SDK checkout is permanently dirty.** `git status` in
  `/Users/le/Work/Vibe/flutter` shows `_window_macos.dart` and
  `shader_compiler.dart` modified. `flutter upgrade` refuses to run over local
  changes, so discard those two files first — the script regenerates them.
- **Re-run the script after upgrading.** `app/macos/Runner.xcodeproj/project.pbxproj:427`
  runs it as a build phase, so `flutter build macos` self-heals, but do not rely
  on that when testing other targets.
- **Both bugs are still open in 3.44.9.** Both patched files are unchanged
  between the tags, so the patch still applies cleanly — no rework needed. Skip
  it and macOS `--release` crashes again.

If a future bump makes the script print `warn: ... not found` or
`patched 0 class(es)`, upstream moved the code: stop and re-derive the patch
rather than assuming the bug is fixed.

---

## 6. Trap 2 — one SDK, five worktrees

`/Users/le/Work/Vibe/flutter` is shared by every worktree:

```
/Users/le/Work/Vibe/makit                         [main]
/Users/le/.worktrees/makit/chore-bump-flutter     [chore/bump-flutter]
/Users/le/.worktrees/makit/chore-update-packages  [chore/update-packages]
/Users/le/.worktrees/makit/feat-cli-client        [feat/cli-client]
/Users/le/.worktrees/makit/feat-todo-lists        [feat/todo-lists]
```

`flutter upgrade` moves **all five** at once, before this branch has merged or
even passed CI. Every one of them then needs the §5 patch re-applied.

If that is unacceptable, install the new SDK into a separate directory and point
only this worktree's `PATH` at it, leaving the shared checkout on 3.44.4 until
merge.

---

## 7. Procedure

Pick a target first: **`3.44.9`** for the Xcode 27 fix, or **`3.44.8`** if you
want more soak time (3.44.9 was 2 days old when this was written). Substitute
below.

```sh
# 1. clean the SDK, then move it
cd /Users/le/Work/Vibe/flutter
git checkout -- packages/flutter/lib/src/widgets/_window_macos.dart \
                packages/flutter_tools/lib/src/build_system/tools/shader_compiler.dart
git checkout 3.44.9 && flutter precache   # explicit tag: CI pins an exact
                                          # version, so match it exactly.
                                          # `flutter upgrade` chases whatever
                                          # stable is newest and overshoots.
                                          # Use 3.44.8 here for more soak time.

# 2. re-apply the in-place patch (§5) — not optional
bash /Users/le/.worktrees/makit/chore-bump-flutter/app/tool/patch_flutter_sdk.sh

# 3. update the pins (§8) — covers flutter-version *and* the cache keys
sed -i '' "s/3\.44\.4/3.44.9/g" .github/workflows/*.yml
$EDITOR docs/DEVELOPMENT.md          # lines 13 and 31

# 4. verify (§9). Run these separately — do NOT chain with `&&`: `flutter test`
#    exits non-zero on the known loading-stage flake, which would stop the
#    macOS build, and the build is the one check that cannot be skipped (§5).
cd app
flutter pub get --enforce-lockfile   # then: git diff --stat pubspec.lock → must be empty
flutter analyze                      # must be clean
flutter test                         # expect 5-17 loading-stage failures, NOT 0.
                                     # Gate is: no failure line lacking
                                     # ": loading ", and the count in family
                                     # with a baseline run on main. See §9.
flutter build macos --release        # must build *and launch* — the #188060 canary
```

---

## 8. Every site that pins the SDK version — 20 lines, 18 in scope

```
.github/workflows/flutter-ci.yml:27,82,127             flutter-version
.github/workflows/flutter-ci.yml:36,38,91,93,136,138   cache key + restore-keys
.github/workflows/integration-ci.yml:30,127            flutter-version
.github/workflows/integration-desktop-ci.yml:31        flutter-version
.github/workflows/protocol-contract-ci.yml:88          flutter-version
.github/workflows/protocol-contract-ci.yml:97,99       cache key + restore-keys
.github/workflows/real-pi-e2e.yml:97                   flutter-version
docs/DEVELOPMENT.md:13    toolchain table row
docs/DEVELOPMENT.md:31    "flutter --version  # expect <version>"
```

**Why the cache keys carry the version.** `flutter-ci.yml` and
`protocol-contract-ci.yml` hand-roll an `actions/cache` whose `path` includes
`${{ runner.tool_cache }}/flutter/` — the SDK itself. An SDK bump does not
change `app/pubspec.lock`, so a key built only from that hash still hits the
*previous* SDK's entry: the new SDK is never saved (exact-key hit ⇒ no save) and
`restore-keys` drags the old one in as the base. `integration-ci.yml` and
`integration-desktop-ci.yml` need nothing here — they use the action's own
`cache: true`, which is version-aware. `real-pi-e2e.yml:124` caches only
`~/.pub-cache`, so keying it on the lockfile alone is correct.

Two more that the first draft of this list missed:

```
BUILD_AND_DEPLOY.md:362   flutter-action snippet, build-ios job
BUILD_AND_DEPLOY.md:394   flutter-action snippet, build-macos job
```

Those are **left at `3.44.4`** — template YAML for a proposed tag-triggered
release workflow, not live CI, so they change nothing today. Unlike the specs
below they are prescriptive, not a record, so copying that template now
reintroduces the old pin. Open follow-up, deliberately out of this diff.

**Do not touch** `docs/specs/2026-08-06-SPEC-40-composer-footer-space.md` or
`docs/specs/2026-08-06-SPEC-40-PLAN.md`. They also say `3.44.4`, but as the
recorded SDK for a past performance measurement. Rewriting them falsifies the
record.

`AGENTS.md` documents Flutter `3.44.4` at `~/flutter` on the Cursor Cloud VM.
That provisioning is outside this repo, so update the prose only if you also
update the VM image.

---

## 9. Definition of done

- [x] `flutter --version` reports the target on the SDK the repo resolves to
- [x] `git -C "$FLUTTER_ROOT" status --porcelain` shows exactly the
      two §5 files modified — i.e. the patch is re-applied
- [x] `cd app && flutter pub get --enforce-lockfile` succeeds **and
      `git diff --stat app/pubspec.lock` is empty.** A non-empty lockfile diff
      means the SDK pins moved after all — stop and re-read §3, because the
      blast radius is then much larger than this branch assumes
- [x] `flutter analyze` — clean
- [x] `flutter test` — no *new* failures. Known pre-existing noise: 5–17 test
      files fail at the *loading* stage on any whole-suite run, a different set
      each time, and each one passes when run alone. **Not** a parallelism
      artifact as earlier drafts of this file claimed — `--concurrency 1` still
      fails 5–7. Baseline on `main` @ 3.44.4: 8 failures parallel / 7 serial,
      and `0` non-loading either way. Check that
      `grep -v ': loading '` over the failure list is empty and that the count
      is in family with a baseline run before blaming the bump
- [x] `flutter build macos --release` succeeds and **launches** — this is the
      #188060 canary; an `illegal cid, full-aot` crash means step 2 was skipped
- [x] `cd server && pnpm typecheck && pnpm test` — untouched, but cheap to confirm
- [ ] CI green on all 5 workflows that were re-pinned
- [x] Decide the fate of this file before merge — **kept** as the standing
      upgrade runbook, corrected in place after the 3.44.9 run

---

## 10. Do not

- Do not merge package-dependency changes into this branch. `chore/update-packages`
  owns those; keeping them apart is what makes both diffs reviewable.
- Do not switch channels to get Dart 3.13 without a separate decision (§3).
- Do not edit `app/pubspec.lock` by hand — see the header comment in
  `app/pubspec.yaml` and `SECURITY.md`.
- Do not skip `app/tool/patch_flutter_sdk.sh` (§5).
