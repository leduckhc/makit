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

**Post-merge cleanup — done 2026-08-12.** The shared checkout
`/Users/le/Work/Vibe/flutter` is now `3.44.9` (rev `6b182d2c75`),
`patch_flutter_sdk.sh` re-applied against it (`patched 5 class(es)`), and the
temporary `flutter-3.44.9` directory deleted (3.8 GB reclaimed).
`docs/DEVELOPMENT.md` deliberately documents the canonical shared path, not the
temporary one — as of this cleanup that row is finally accurate rather than
aspirational.

**This cleanup sat undone for four days**, during which local builds ran
`3.44.4` while all 8 CI pins said `3.44.9`. If you land a pin bump the
separate-directory way (§6), do the §7-step-1 move in the *same* sitting or the
drift is invisible until something breaks only on one side.

Every claim below was re-checked against 3.44.9 rather than assumed: §3
byte-identical pubspecs ✓ · zero-line `pubspec.lock` diff ✓ · `pub get` still
reports 28 incompatible packages ✓ · patch script reported `patched 5 class(es)`,
not 0 ✓ · `analyze` clean ✓ · `build macos --release` launches with no `illegal
cid` ✓ · server typecheck + 1115 tests ✓.

All of that was measured on base `9d31156`. `#148` has since landed four
dependency upgrades on `main`, so the package counts in §3 are a snapshot, not a
live figure — re-measure before quoting them. CI for this branch runs on the
merge ref, so the green run did exercise 3.44.9 against the post-`#148`
lockfile.

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
resolve (counted on base `9d31156`; `#148` later bumped four constraints, which
shortens the list but does not change the mechanism):

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

## 6. Trap 2 — one SDK, every worktree

`/Users/le/Work/Vibe/flutter` is shared by every worktree. Run
`git worktree list` for the live set rather than trusting a list here — it goes
stale fast (as of 2026-08-12 it is 4, and 3 of the 5 originally listed are
gone).

`flutter upgrade` moves **all of them** at once, before this branch has merged
or even passed CI.

The §5 patch, however, is applied to the **SDK**, not to a worktree — so one run
of `patch_flutter_sdk.sh` against the shared checkout covers every worktree, and
re-running it from another worktree is a verified no-op
(`patched 0 class(es); 5 already patched`). Earlier wording here and in §7 step 0
implied per-worktree re-application; that is wrong, and only misleads you into
thinking you have more work than you do.

If that is unacceptable, install the new SDK into a separate directory and point
only this worktree's `PATH` at it, leaving the shared checkout on 3.44.4 until
merge.

---

## 7. Procedure

Pick a target first: **`3.44.9`** for the Xcode 27 fix, or **`3.44.8`** if you
want more soak time (3.44.9 was 2 days old when this was written). Substitute
below.

```sh
# 0. where things live. Run this from the worktree you are bumping. §6: one
#    shared SDK serves all five worktrees, so REPO_ROOT is whichever one you
#    are in — and each of the others still needs step 2 re-run for itself.
REPO_ROOT=$(git rev-parse --show-toplevel)
FLUTTER_SDK_DIR=/Users/le/Work/Vibe/flutter   # or a per-worktree SDK, see §6

# 1. clean the SDK, then move it
cd "$FLUTTER_SDK_DIR"
git checkout -- packages/flutter/lib/src/widgets/_window_macos.dart \
                packages/flutter_tools/lib/src/build_system/tools/shader_compiler.dart
git checkout 3.44.9 && flutter precache   # explicit tag: CI pins an exact
                                          # version, so match it exactly.
                                          # `flutter upgrade` chases whatever
                                          # stable is newest and overshoots.
                                          # Use 3.44.8 here for more soak time.

# 2. re-apply the in-place patch (§5) — not optional. FLUTTER_ROOT pins which
#    SDK gets patched; without it the script falls back to `command -v flutter`,
#    which may still be the old SDK if PATH has not been repointed yet.
FLUTTER_ROOT="$FLUTTER_SDK_DIR" bash "$REPO_ROOT/app/tool/patch_flutter_sdk.sh"

# 3. update the pins (§8) — covers flutter-version *and* the cache keys.
#    cd back first: step 1 left the shell inside the SDK, not the repo.
cd "$REPO_ROOT"
sed -i '' "s/3\.44\.4/3.44.9/g" .github/workflows/*.yml
$EDITOR docs/DEVELOPMENT.md          # lines 13 and 31

# 4. verify (§9). Run these separately — do NOT chain with `&&`: `flutter test`
#    exits non-zero on the known loading-stage flake, which would stop the
#    macOS build, and the build is the one check that cannot be skipped (§5).
cd "$REPO_ROOT/app"
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

```text
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

```text
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
- [x] `flutter test` — no *new* failures. Known pre-existing noise: test files
      fail at the *loading* stage on any whole-suite run with
      `Unable to connect to flutter_tester process: WebSocketException: Invalid
      WebSocket upgrade request`, a different set each time, and each one passes
      when run alone. **Not** a parallelism artifact as earlier drafts of this
      file claimed — `--concurrency 1` still fails.
      Baselines, all with `0` non-loading failures:
      | SDK | parallel | serial |
      |---|---|---|
      | 3.44.4 (`main`, 2026-08-08) | 8 | 7 |
      | 3.44.9 (2026-08-12) | 19, then 28 | 9, then 2 |
      | 3.47.0 (2026-08-13, §11) | — | 3 |
      **Neither count is reproducible run-to-run — not even the serial one**, so
      do not gate on a number at all. Measured on one machine within one hour,
      serial ranged 2–9 and parallel 19–28 on the *same* commit and SDK; a
      failed load also swallows that file's tests, so the pass total moves too
      (2861–3090). The only stable signal is the **non-loading count, which must
      be 0**, and each named file passing when run alone.
- [x] Two failures that *look* like real regressions but are **intentional** —
      do not chase them. Both print a full `EXCEPTION CAUGHT` banner with a
      stack trace into production code, without incrementing the failure count:
      - `test/desktop/chat/workspace_controller_test.dart` — "a throwing sink
        cannot take the mutation (or the app) down" throws
        `StateError('disk full')` on purpose; the trace points at
        `WorkspaceController._commit`/`divideActive`. File alone: `+48` green.
      - `test/diagnostics/error_capture_test.dart` — "installErrorCapture
        funnels a framework error into the log" throws `Exception: boom in build`.
      Read the *counter* (`-N`), not the banner: if `-N` did not increment on
      that line, nothing failed.
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
- Do not switch **channels** to get a newer Dart. (Dart 3.13 no longer needs a
  channel switch — it is on stable in 3.47.0, §11 — but the rule stands for
  whatever is next.)
- Do not edit `app/pubspec.lock` by hand — see the header comment in
  `app/pubspec.yaml` and `SECURITY.md`.
- Do not skip `app/tool/patch_flutter_sdk.sh` (§5).
- Do not trust the patch script's output without reading it. "Already patched"
  used to be printed for an unpatched file (§11); it is a hard failure now, but
  the general lesson holds — a patch that reports success is not the same as a
  patch that applied.

---

## 11. Next bump — 3.47.0, evaluated 2026-08-13 (not landed)

Measured against this branch on the real SDK, installed as a **git worktree of
the existing SDK clone** rather than a second full clone:

```sh
git -C /Users/le/Work/Vibe/flutter worktree add /Users/le/Work/Vibe/flutter-3.47.0 3.47.0
```

That is a strictly better version of §6's "separate directory": it shares the
object store, so the checkout costs ~1.5 GB instead of ~4 GB, and
`flutter --version` still reports `3.47.0` correctly. Remove it with
`git -C .../flutter worktree remove ../flutter-3.47.0`, not `rm -rf`.

| | version | Dart | published | §3 lockfile moves? |
|---|---|---|---|---|
| pinned | `3.44.9` | 3.12.2 | 2026-08-06 | — |
| candidate | `3.47.0` | **3.13.0** | 2026-08-12 18:44 UTC | **yes — 6 packages** |

**Cooldown.** The repo's window is **3 days** (`cooldownWindow` in
`tool/pub_cooldown.dart`, SECURITY.md §8 — *not* 7; §8 records why 7 was
rejected). 3.47.0 clears it at **2026-08-15 18:44 UTC**. Note the gate covers
`pubspec.lock` packages, **not** the SDK itself, so holding the SDK to that
window is a judgement call by analogy, not something CI enforces. The 6 packages
it *does* force are all ≥3 days old — `pub_cooldown.dart` passes on the 3.47.0
lockfile today.

### What it costs — four things, none of them optional

1. **macOS deployment target 10.15 → 12.0 — accepted 2026-08-13 (KC).**
   `flutter build macos` silently rewrites `macos/Podfile`,
   `macos/Podfile.lock` and `macos/Runner.xcodeproj/project.pbxproj` through the
   tool's own `macos_deployment_target_migration.dart`. That is **dropping macOS
   11 and earlier** — a product decision wearing the costume of a build
   artifact, so it is recorded here rather than discovered in a diff.
   **Decision: acceptable.** macOS 11 (2020) is four majors behind; current is
   26.5.2. Nothing user-facing promised 10.15 — in fact the app's minimum OS is
   documented *nowhere*, only implied by `project.pbxproj`. Land the three
   migrated files deliberately in the bump commit, and close that documentation
   gap at the same time (see the landing checklist).
2. **6 SDK-forced package bumps** — `matcher` 0.12.19→0.12.20, `meta`
   1.18.0→1.19.0, `test` 1.31.0→1.31.1, `test_api` 0.7.11→0.7.12,
   `test_core` 0.6.17→0.6.18, `vector_math` **2.2.0→2.4.2**. So
   `--enforce-lockfile` fails until the lockfile is regenerated — unlike the
   3.44.x bumps, where §3's "zero-line lockfile diff" held. The
   "N packages incompatible" warning drops 27 → 24.
3. **5 golden images must be regenerated.** All five are **rounded-corner
   anti-aliasing only** — verified by eye on the `*_isolatedDiff.png` files,
   which show the four corner arcs and nothing else: no text or layout
   movement. 0.02% / ~75px on `desktop/chat/open_in_ide_golden_test.dart`
   (`split button — light|dark`); 0.08% / ~160px on
   `ui/composer/context_usage_golden_test.dart` (`details panel —
   codex|pi|tightening`). Do **not** regenerate them before the bump lands —
   they would then fail on the pinned 3.44.9.
4. **`pub get` rewrites `analysis_options.yaml`**, appending
   `android|ios|web|windows|macos|linux/**` to `analyzer.exclude`. Tracked file,
   silent edit, so every dev and CI run shows a dirty tree until it is
   committed.

### What it does not cost

- `flutter analyze` — clean.
- `flutter test --concurrency 1` — 3035 pass; 3 loading-stage flakes (§9) plus
  the 5 goldens above, and nothing else. Count failures from
  `--reporter=json` (`testDone` events whose `result != success`, ignoring
  `hidden`) rather than reading the human reporter — that is the only way to
  separate a real failure from the intentional-exception banners §9 lists.
- `flutter build macos --release` — builds **and launches**; the #188060 canary
  is clean.
- The §5 patch — still needed, and still applies. See below.

### The §5 patch nearly broke silently here

#188060 is **still open** in 3.47.0 (no `vm:entry-point` upstream, all five
structs still present) and that half of the patch applies unchanged. But 3.47.0
moved the #182400 call site one nesting level deeper, so the old
literal-with-indentation anchor missed — and the script printed
**`[182400] already patched` against a completely unpatched file**. That is
exactly the "do not assume the bug is fixed" failure §5 warns about, except the
script itself was doing the assuming.

Fixed on this branch: both fixes now match indentation-insensitively, "anchor
absent" is a distinct hard failure (non-zero exit naming the site that moved),
and a *renamed* struct no longer reports as "already patched". Covered by
`app/test/patch_flutter_sdk_test.dart`, which pins the 3.44.9 **and** 3.47.0 call
sites as fixtures, so the next bump fails a test instead of a build.

### Landing it, once the window clears

Follow §7 with `3.47.0`, plus these extra steps:

```sh
cd app
flutter pub get                      # NOT --enforce-lockfile; the lockfile must move
dart run tool/pub_cooldown.dart      # must pass; gates the 6 forced packages
flutter test --update-goldens test/desktop/chat/open_in_ide_golden_test.dart \
                              test/ui/composer/context_usage_golden_test.dart
git add macos/Podfile macos/Podfile.lock macos/Runner.xcodeproj/project.pbxproj \
        analysis_options.yaml pubspec.lock
```

And two docs that §8's pin list does not cover:

- `AGENTS.md` — documents the Cursor Cloud VM's Flutter version.
- `BUILD_AND_DEPLOY.md` — state the supported minimum, **macOS 12.0+**, which
  the bump makes true and which no doc currently says at all. A support floor
  that exists only inside `project.pbxproj` is one nobody can check against.
