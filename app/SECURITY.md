# Security Policy

This project codifies Dart/Flutter and pub.dev security practices that
mirror the npm/pnpm policy in [`../server/SECURITY.md`](../server/SECURITY.md).

If you change anything in this document, update `analysis_options.yaml`,
`pubspec.yaml`, or `tool/audit.sh` to match — and vice versa.

---

## Threat model

Mobile/desktop coding-agent client. Compromise impact:

- Read access to the user's paired makit server bearer (stored in
  Keychain / Android Keystore via `flutter_secure_storage`).
- Ability to drive any agent CLI exposed by that makit server.
- Microphone / camera access (camera used by the Vision-based QR scanner;
  no mic access in v1).

Primary risks we care about:

1. **Supply-chain attack via pub.dev package** — analogous to npm
   Shai-Hulud / Nx / eslint-scope. The biggest realistic threat to a
   small Flutter app with ~15 prod deps.
2. **Native plugin compromise** — flutter_secure_storage, multicast_dns,
   crypto, and the camera/Vision integration ship native Swift/Kotlin
   code. A compromised plugin can read secure storage and exfiltrate
   bearers.
3. **Lockfile drift** between dev and CI silently pulling new versions.
4. **Untrusted server impersonation** — pinning + cert fingerprinting
   handle this at the transport layer; see `ws_client.dart`.

What we are **not** defending against here:

- Targeted attacks against an unlocked device with the app open
  (device-level compromise is out of scope).
- Reverse engineering of the .ipa / .apk to extract the cert fingerprint
  pinning logic. The bearer is per-device and revocable on the server.

---

## Codified controls

### 1. Hosted-only dependencies

- `pubspec.yaml`: **no** `git:` or `path:` dependencies for production
  code. Only `sdk: flutter` is allowed.
- `dev_dependencies` may use `path:` for local plugin development, but
  must be removed before commit unless documented.
- Verify with `dart pub deps --no-dev --style=compact | grep -E 'from git|from path'`
  — should print nothing. The script `tool/audit.sh` does this.

To add a new package:

1. Open `https://pub.dev/packages/<name>`. Check **Verified publisher**.
   Prefer dart.dev, flutter.dev, google.dev, or a well-known org.
2. Check **score** (130+ pub points, recent publish, sound null safety).
3. Inspect `pubspec.yaml` of the candidate for native code (`android/`,
   `ios/`, `macos/`, plugin-class entries). Native code = security review.
4. Pin to a known-good major. Use `^x.y.z` only for stable, audited deps.
5. Check the target version is at least 3 days old (§8).

### 2. No git-source dependencies

- `pubspec.yaml` rule (enforced by review + `tool/audit.sh`): no
  `git: ...` sources for either prod or dev deps.
- `dependency_overrides:` requires a justification comment.

### 3. Deterministic installs

- `pubspec.lock` is committed.
- CI and local-CI MUST use `flutter pub get --enforce-lockfile`. This
  fails the install if the lockfile would be modified — pub.dev's
  closest equivalent to `pnpm install --frozen-lockfile`.
- `environment.sdk` and `environment.flutter` are pinned to a range; the
  Flutter version used in CI is fixed via `.fvm/fvm_config.json`
  (or an explicit `flutter --version` check).

### 4. Pub.dev provenance and hashes

- Every entry in `pubspec.lock` includes a `sha256` hash; pub.dev
  verifies these on fetch. We do not pin to a mirror.
- Prefer packages with **Verified publisher** badge on pub.dev. Where
  possible, list the publisher next to each prod dep in `pubspec.yaml`
  as an inline comment (see that file).

### 5. Native plugin allow-list

Plugins ship native Swift / Kotlin / Objective-C code that runs with
the app's full permissions. Each prod plugin is reviewed and listed
here with a one-line justification:

| Plugin | Native | Justification |
|---|---|---|
| `flutter_secure_storage` | iOS Keychain / Android Keystore | Bearer token storage — required. |
| `multicast_dns` | Pure Dart | LAN discovery of `_makit._tcp`. |
| `crypto` | Pure Dart | SHA256 fingerprint of pinned server cert. |
| `web_socket_channel` | Pure Dart over `dart:io` | Transport. |

In-tree native code:

| Module | Purpose | Notes |
|---|---|---|
| `ios/Runner/QrScannerPlugin.swift` | QR scanner via AVFoundation + Vision | No third-party libs. Replaces `mobile_scanner` (which pulls Google MLKit). |
| `ios/Runner/AppDelegate.swift` + `android/.../MainActivity.kt` (`makit/device_info`) | Reads the device name (`UIDevice.current.name` / Android `device_name`) for the pairing label | Read-only. No secure-storage/pasteboard access, no network. Avoids a `device_info_plus` dependency. |

To add a new plugin with native code:

1. Read the plugin's `ios/` and `android/` source.
2. Confirm it does not write to `flutter_secure_storage`, `NSUserDefaults`,
   `SharedPreferences` belonging to this app, or any pasteboard.
3. Confirm no network calls that aren't documented.
4. Add a row to the table above.

### 6. Static analysis

- `analysis_options.yaml` extends `package:flutter_lints/flutter.yaml`
  plus an additional rule set tuned for security and correctness
  (avoid_print, avoid_dynamic_calls, no_runtimeType_toString,
  unsafe_html, secure_pubspec_urls, etc.).
- CI gate: `flutter analyze --fatal-infos --fatal-warnings`.
- We also enforce in dev: `dart format --set-exit-if-changed .`.

### 7. Outdated and advisory scanning

- `tool/audit.sh` scans `pubspec.lock` against the OSV advisory database
  with `osv-scanner` (`osv-scanner scan source --lockfile=pubspec.lock`),
  plus the hosted-only / lockfile checks above. `dart pub outdated` is kept
  only as a staleness fallback when `osv-scanner` isn't installed locally —
  it is *not* an advisory scanner. (`dart pub outdated --mode=security` was
  removed from pub; do not rely on it.)
- CI enforces this as a blocking gate: the `security-audit` job in
  `.github/workflows/flutter-ci.yml` downloads a pinned, SHA256-verified
  `osv-scanner` binary and fails the build on any known advisory.
- Run before every merge and on a weekly cron in CI.

To triage a reported advisory:

```bash
# Reproduce locally (install once: brew install osv-scanner):
osv-scanner scan source --lockfile=pubspec.lock
# Fix by pinning the patched version in pubspec.yaml, then:
flutter pub get
# Commit the updated pubspec.lock alongside the pubspec.yaml change.
# If the advisory is in an unfixable transitive (e.g. SDK-pinned), record a
# justified ignore in an osv-scanner.toml rather than disabling the gate.
```

### 8. Release cooldown (minimum version age)

The server blocks freshly published versions with pnpm's
`minimumReleaseAge: 4320` (see [`../server/SECURITY.md`](../server/SECURITY.md)
§3). pub has no equivalent knob, so we enforce the same **3-day window**
ourselves:

- A change may not introduce a `pubspec.lock` version that was published to
  pub.dev less than 3 days ago. This catches the large class of attacks where a
  malicious version is published, then detected and unpublished within days.
- Only versions that differ from the baseline lockfile are checked
  (`COOLDOWN_BASE_REF`, default `HEAD`). Like pnpm, the window gates what you
  *newly install*, not what is already locked — an already-shipped version does
  not retroactively fail the gate as it ages in.
- Enforced by `tool/pub_cooldown.dart`, run as step 9 of `tool/audit.sh` and as
  a blocking step in the `security-audit` CI job. Exit codes: `0` clean, `1`
  violation, `2` could not verify. **The gate fails closed:** an unparseable
  lockfile, an unusable baseline ref, or a changed package whose publish date
  pub.dev will not confirm all exit `2`, and `2` fails both `audit.sh` and CI.
  Being offline is therefore a hard failure, not a skip — that is deliberate, a
  gate that passes when it cannot check is not a gate.
- The lockfile is parsed with `package:yaml` (a `dev_dependencies` entry, never
  shipped in the app binary), not a hand-rolled line parser: a parser that
  silently mis-reads one entry would drop it from the check.
- `COOLDOWN_BASE_REF` must never be passed to git empty. `git show
  ':./pubspec.lock'` *succeeds* and returns the **index** copy of the file,
  which would make the baseline identical to the working tree and pass
  everything. `resolveBaseRef` maps blank to `HEAD` and rejects the all-zero sha
  git reports on branch creation; the CI step additionally verifies the ref
  resolves to a commit before invoking the tool.

**Why 3 days:** a 7-day hold mostly blocked routine patch bumps on a small,
plugin-heavy dependency set whose first-party packages move with the pinned
Flutter SDK. 3 days still clears the publish-then-yank window the rule exists
for. If you change it, update `cooldownWindow` in `tool/pub_cooldown.dart`, its
test, and `server/pnpm-workspace.yaml` together.

```bash
cd app && dart run tool/pub_cooldown.dart
```

If a bump is blocked, the normal answer is **wait** — the script prints the
publish date and age, so you know the day it clears. Only override for a
security fix that must ship now, by adding the package to `cooldownExempt` in
`tool/pub_cooldown.dart` with a one-line justification (mirrors
`minimumReleaseAgeExclude`). Adding an entry is a security review; remove it
once the version has aged past the window.

### 9. Transport pinning (cross-reference)

The WS transport pins the server cert SHA256 fingerprint at the
`dart:io` layer (`badCertificateCallback`). No OS trust store is used,
no ATS exception is granted. See `app/lib/transport/ws_client.dart` and
`docs/ARCHITECTURE.md` §pairing.

---

## Secrets

- The server bearer is stored via a `SecureStore` abstraction (`lib/store/
  secure_store.dart`):
  - iOS/Android: **flutter_secure_storage** (iOS Keychain
    `kSecAttrAccessibleAfterFirstUnlock`, Android Keystore).
  - macOS (control app): a `0600` JSON file under `~/Library/Application
    Support/dev.getmakit.app/`. The desktop app ships ad-hoc signed, so a
    keychain item's ACL is bound to an unstable code signature and macOS
    re-prompts for the login password on every rebuild. The file store trades
    that prompt away for weaker at-rest protection (no OS keychain).
- The server cert fingerprint is **not** secret — it's embedded in the
  pair QR.
- No API keys ship in the app. Provider credentials live on the server.
- `.env`-style files are not part of this project.

If a `--dart-define` is ever used for a real secret (rare), document
it here and prefer secure-storage at runtime.

---

## Reporting a security issue

Personal project. Report directly to the repo owner. Do not file a
public issue.
