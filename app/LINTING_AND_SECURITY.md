# Flutter Security & Linting Setup

This directory contains security and code-quality policies for the makit Flutter app.

## Files

- **`SECURITY.md`** — Comprehensive security policy covering dependency management,
  platform-channel audits, TLS pinning, secret handling, and incident response.
- **`analysis_options.yaml`** — Dart linting rules enforced by `flutter analyze`.
  Configured for strict type safety and security best practices.
- **`pubspec.yaml`** — Package manifest with exact versions for security-critical
  packages (flutter_secure_storage, multicast_dns, crypto).
- **`.github/workflows/flutter-ci.yml`** — GitHub Actions CI that enforces:
  - Offline installs (lockfile integrity)
  - Strict linting analysis
  - Code formatting
  - Vulnerability checks

## Quick Start

### Local development

```bash
# Install dependencies (offline, respects pubspec.lock)
cd app
./scripts/flutter-secure get

# Run linting (enforces analysis_options.yaml)
./scripts/flutter-secure analyze

# Format code
./scripts/flutter-secure format

# Check for outdated packages
./scripts/flutter-secure audit

# Full CI suite
./scripts/flutter-secure ci
```

### Updating dependencies

```bash
# Interactive upgrade with verification
./scripts/flutter-secure upgrade

# Manual upgrade (expert mode)
cd app
flutter pub upgrade --dry-run   # Preview changes
flutter pub upgrade             # Apply changes
flutter analyze                 # Verify no new lint errors
flutter test                    # Run tests
git add pubspec.lock           # Commit the lockfile
```

## Policy highlights

**Critical principles:**

1. **Exact versions for security-sensitive packages:**
   - `flutter_secure_storage` (Keychain/Keystore)
   - `multicast_dns` (mDNS network APIs)
   - `crypto` (fingerprint validation)
   - `ulid` (deterministic session IDs)

2. **TLS cert pinning** in `WsClient` via `HttpClient.badCertificateCallback`.

3. **Strict linting** enforced by CI:
   - No implicit casts or dynamic types
   - All return types explicit
   - No unsafe platform-channel calls

4. **Dependency audits:**
   - Monthly `flutter pub outdated` review
   - Security advisories checked on pub.dev
   - Lockfile integrity verified in CI

5. **Platform-specific controls:**
   - iOS: Minimal entitlements, NSCameraUsageDescription required
   - Android: Runtime camera permission, no hardcoded secrets

## For reviewers

When merging PRs that touch `pubspec.yaml`:

1. ✓ Exact version in pubspec.yaml (no `^` or `~` for security packages)
2. ✓ New package added to dependency table in SECURITY.md with audit notes
3. ✓ If a plugin is added: check pub.dev for security issues, maintenance status
4. ✓ `pubspec.lock` updated and committed
5. ✓ `flutter analyze` passes locally
6. ✓ CI passes (lint, format, security audit)

## Incident response

If a security issue is found:

1. Verify if it affects our usage (not all CVEs apply to all codepaths)
2. Check if a patch is available
3. Update `pubspec.yaml`, test locally, commit with CVE link
4. If critical and app is in production, plan a release

For upstream issues (pub.dev packages), report via the package's GitHub Security tab.

## See also

- [Dart pub security](https://dart.dev/tools/pub/security)
- [Flutter security best practices](https://flutter.dev/docs/testing/code-debugging)
- [OWASP Mobile Security](https://owasp.org/www-project-mobile-top-10/)
