# Security Policy

This project codifies Dart/Flutter and pub.dev security practices that
mirror the npm/pnpm policy in [`../server/SECURITY.md`](../server/SECURITY.md).

If you change anything in this document, update `analysis_options.yaml`,
`pubspec.yaml`, or `tool/audit.sh` to match — and vice versa.

---

## Threat model

Mobile/desktop coding-agent client. Compromise impact:

- Read access to the user's paired pino server bearer (stored in
  Keychain / Android Keystore via `flutter_secure_storage`).
- Ability to drive any agent CLI exposed by that pino server.
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
| `multicast_dns` | Pure Dart | LAN discovery of `_pino._tcp`. |
| `crypto` | Pure Dart | SHA256 fingerprint of pinned server cert. |
| `web_socket_channel` | Pure Dart over `dart:io` | Transport. |

In-tree native code:

| Module | Purpose | Notes |
|---|---|---|
| `ios/Runner/QrScannerPlugin.swift` | QR scanner via AVFoundation + Vision | No third-party libs. Replaces `mobile_scanner` (which pulls Google MLKit). |
| `ios/Runner/AppDelegate.swift` + `android/.../MainActivity.kt` (`pino/device_info`) | Reads the device name (`UIDevice.current.name` / Android `device_name`) for the pairing label | Read-only. No secure-storage/pasteboard access, no network. Avoids a `device_info_plus` dependency. |

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

### 8. Transport pinning (cross-reference)

The WS transport pins the server cert SHA256 fingerprint at the
`dart:io` layer (`badCertificateCallback`). No OS trust store is used,
no ATS exception is granted. See `app/lib/transport/ws_client.dart` and
`docs/ARCHITECTURE.md` §pairing.

---

## Secrets

- The server bearer is stored in **flutter_secure_storage** (iOS
  Keychain `kSecAttrAccessibleAfterFirstUnlock`, Android Keystore).
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
