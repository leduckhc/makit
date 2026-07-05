# iOS & macOS Build and Deployment Guide

This guide covers building and pushing the pino app to **iOS** (physical device + App Store) and **macOS** (DMG + Gatekeeper notarization).

**Prerequisites:**
- Xcode 15+ (for Apple SDKs, code signing)
- Flutter 3.38.0+ (pinned in pubspec.yaml)
- Apple Developer Account (Team ID: `RT8DP44B6N`)
- Bundle IDs: `dev.pino.pino` (iOS/macOS)
- Provisioning profiles & signing certificates provisioned in Xcode

---

## 1. iOS Build & Deployment

### 1.1 Debug Build (Simulator)

For rapid iteration on the simulator:

```bash
cd app
flutter pub get --enforce-lockfile
flutter run -d <simulator-id>  # e.g., "iPhone 16 Pro"
```

**Hot reload** works:
```bash
r           # hot reload (preserve app state, re-run build)
R           # hot restart (restart Dart VM, re-run pubspec)
q           # quit
```

### 1.2 Device Build (Physical iPhone)

To install on a physical iPhone for on-device testing:

```bash
# Verify connected device
flutter devices

# Install + run on device
flutter run -d <device-id>

# Or build an IPA for manual installation
flutter build ipa --release
# Output: build/ios/ipa/pino.ipa
```

**Note:** First run may take 5–10 min (native build + signing).

### 1.3 Release Build (App Store Distribution)

#### Step 1: Update Version

Edit `app/pubspec.yaml`:
```yaml
version: 0.2.0+2  # <major>.<minor>.<patch>+<build-number>
```

Rebuild provisioning:
```bash
cd app
flutter pub get --enforce-lockfile
```

#### Step 2: Build Release IPA

```bash
flutter build ipa \
  --release \
  --export-options-template \
  --no-codesign
```

or with full signing:

```bash
flutter build ipa --release \
  -–dart-define=FLUTTER_BUILD_MODE=release
```

**Outputs:**
- `build/ios/ipa/pino.ipa` — ready for App Store Connect
- `build/ios/archive/Runner.xcarchive` — dSYM + IPA for crash symbolication

#### Step 3: Upload to App Store Connect

**Option A: Using Xcode** (GUI)
```bash
open build/ios/archive/Runner.xcarchive
# Xcode > Organizer > Distribute App > App Store Connect
```

**Option B: Using xcrun** (CLI)
```bash
xcrun altool --upload-app \
  --file build/ios/ipa/pino.ipa \
  --type ios \
  --username <apple-id> \
  --password <app-specific-password>
```

or with Transporter:
```bash
open -a Transporter build/ios/ipa/pino.ipa
```

#### Step 4: App Store Review

- Submission via App Store Connect (Builds → App Store)
- Review cycle: 24–48 hours
- Common rejection reasons: use of private APIs, misleading metadata, requires beta access to test

### 1.4 iOS Code Signing Troubleshooting

**"Profile doesn't match"** error:
```bash
# Refresh provisioning in Xcode
xcode-select --install

# Or manually in Xcode:
Xcode > Preferences > Accounts > Download Profiles
```

**"No provisioning profiles found"**:
1. Visit [developer.apple.com](https://developer.apple.com) → Certificates, IDs & Profiles
2. Create a provisioning profile for bundle ID `dev.pino.pino`
3. Download and add to Xcode:
   ```bash
   open ~/Downloads/dev_pino_pino.mobileprovision
   ```

**"Code sign identity not found"**:
```bash
# List available identities
security find-identity -v -p codesigning

# Force re-signing
rm -rf ~/Library/Developer/Xcode/DerivedData/
flutter clean
flutter build ipa --release
```

---

## 2. macOS Build & Deployment

### 2.1 Debug Build (Local)

For development and testing on your Mac:

```bash
cd app
flutter pub get --enforce-lockfile
flutter run -d macos
```

### 2.2 Release Build (DMG for Distribution)

#### Step 1: Update Version

Edit `app/pubspec.yaml`:
```yaml
version: 0.2.0+2
```

#### Step 2: Build macOS App Bundle

```bash
flutter build macos --release
# Output: build/macos/Build/Products/Release/pino.app
```

#### Step 3: Create a Signed and Notarized DMG

Create a build script `app/tool/build-macos-dmg.sh`:

```bash
#!/bin/bash
set -e

FLUTTER_APP="build/macos/Build/Products/Release/pino.app"
IDENTITY="Developer ID Application: Your Name (RT8DP44B6N)"  # Replace with actual cert
TEAM_ID="RT8DP44B6N"
APPLE_ID="your-apple-id@example.com"
APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"  # app-specific password

# Sign the app
echo "Signing pino.app..."
codesign --deep --force --verify --verbose \
  --sign "$IDENTITY" \
  "$FLUTTER_APP"

# Create DMG
echo "Creating DMG..."
hdiutil create -volname "pino" \
  -srcfolder "$FLUTTER_APP" \
  -ov -format UDZO \
  build/pino.dmg

# Sign DMG
echo "Signing DMG..."
codesign --sign "$IDENTITY" \
  build/pino.dmg

# Notarize (required for Gatekeeper on macOS 10.15+)
echo "Submitting for notarization..."
REQUEST_ID=$(xcrun notarytool submit \
  build/pino.dmg \
  --team-id "$TEAM_ID" \
  --apple-id "$APPLE_ID" \
  --password "$APP_PASSWORD" \
  --output-format json | jq -r '.id')

echo "Notarization request ID: $REQUEST_ID"
echo "Waiting for notarization..."

# Poll notarization status
while true; do
  STATUS=$(xcrun notarytool info "$REQUEST_ID" \
    --team-id "$TEAM_ID" \
    --apple-id "$APPLE_ID" \
    --password "$APP_PASSWORD" \
    --output-format json | jq -r '.status')
  
  if [ "$STATUS" = "Accepted" ]; then
    echo "✅ Notarization approved!"
    xcrun stapler staple build/pino.dmg
    break
  elif [ "$STATUS" = "Rejected" ]; then
    echo "❌ Notarization rejected. Review the log:"
    xcrun notarytool log "$REQUEST_ID" \
      --team-id "$TEAM_ID" \
      --apple-id "$APPLE_ID" \
      --password "$APP_PASSWORD"
    exit 1
  fi
  
  echo "Status: $STATUS (waiting...)"
  sleep 30
done

echo "✅ DMG ready: build/pino.dmg"
```

Make executable and run:
```bash
chmod +x app/tool/build-macos-dmg.sh
app/tool/build-macos-dmg.sh
```

#### Step 4: Distribute

Upload to your website / GitHub Releases:
```bash
gh release create v0.2.0 build/pino.dmg --title "pino v0.2.0"
```

### 2.3 macOS Code Signing & Notarization Troubleshooting

**"Code signature invalid"**:
```bash
# Verify signature
codesign -v build/macos/Build/Products/Release/pino.app

# Re-sign
codesign --deep --force --sign <identity> build/macos/Build/Products/Release/pino.app
```

**List available signing identities**:
```bash
security find-identity -v -p codesigning
```

**Notarization fails**:
```bash
xcrun notarytool log <request-id> \
  --team-id RT8DP44B6N \
  --apple-id your-apple-id@example.com \
  --password xxxx-xxxx-xxxx-xxxx
```

Common issues:
- App contains unsigned binaries or frameworks → sign with `--deep --force`
- DMG not signed → sign the DMG before notarizing
- Invalid app-specific password → generate at [appleid.apple.com](https://appleid.apple.com) Security tab

---

## 3. CI/CD Workflow (GitHub Actions)

The repo includes `flutter-ci.yml` which runs:
1. **Lint + analyze** (strict)
2. **Tests** with coverage
3. **Security audit** (dependency scanning)

To add automated iOS/macOS release builds:

Create `.github/workflows/ios-macos-build.yml`:

```yaml
name: iOS & macOS Release Build

on:
  push:
    tags:
      - 'v*'  # e.g., v0.2.0

jobs:
  build-ios:
    runs-on: macos-14
    timeout-minutes: 60

    steps:
      - uses: actions/checkout@v5
      
      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.44.4'
          channel: 'stable'
      
      - name: Install dependencies
        run: |
          cd app
          flutter pub get --enforce-lockfile
      
      - name: Build iOS IPA
        run: |
          cd app
          flutter build ipa --release
      
      - name: Upload to App Store Connect
        run: |
          cd build/ios/ipa
          xcrun altool --upload-app \
            --file pino.ipa \
            --type ios \
            --username ${{ secrets.APPLE_ID }} \
            --password ${{ secrets.APP_SPECIFIC_PASSWORD }}

  build-macos:
    runs-on: macos-14
    timeout-minutes: 60

    steps:
      - uses: actions/checkout@v5
      
      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.44.4'
          channel: 'stable'
      
      - name: Install dependencies
        run: |
          cd app
          flutter pub get --enforce-lockfile
      
      - name: Build macOS DMG
        run: |
          cd app
          ./tool/build-macos-dmg.sh
        env:
          IDENTITY: ${{ secrets.MACOS_SIGNING_IDENTITY }}
          TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APP_PASSWORD: ${{ secrets.APP_SPECIFIC_PASSWORD }}
      
      - name: Create GitHub Release
        uses: softprops/action-gh-release@v1
        with:
          files: build/pino.dmg
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

Set these secrets in GitHub > Settings > Secrets:
- `APPLE_ID` — your Apple ID email
- `APP_SPECIFIC_PASSWORD` — app-specific password
- `APPLE_TEAM_ID` — `RT8DP44B6N`
- `MACOS_SIGNING_IDENTITY` — e.g., `Developer ID Application: Your Name (RT8DP44B6N)`

---

## 4. Version Management

Track version in `app/pubspec.yaml`:

```yaml
version: 0.2.0+15
#       ^major.minor.patch = semantic version
#                      ^build number (App Store/Play Store track)
```

**When to bump:**
- **Major** (0.→1.0.0): breaking changes, new pairing protocol
- **Minor** (0.1→0.2): new features (new commands, desktop app)
- **Patch** (0.2.0→0.2.1): bug fixes, security updates
- **Build** (+14→+15): every release (App Store requires unique build number)

Update and commit:
```bash
cd app
# Edit pubspec.yaml
git add pubspec.yaml
git commit -m "chore: bump version to 0.2.0+15"
git tag v0.2.0
git push origin main --tags
```

---

## 5. Crash Symbolication & Analytics

### iOS (Xcode Crashes / TestFlight)

Crashes are automatically symbolicated on App Store Connect if you upload dSYM:

```bash
# Included in the archive
build/ios/archive/Runner.xcarchive/dSYMs/Runner.app.dSYM
```

App Store Connect automatically retrieves dSYM from the IPA when you upload.

### macOS (Crash Logs)

Users share crash reports:
```bash
~/Library/Logs/DiagnosticMessages/pino_*.crash
```

To symbolicate locally:
```bash
atos -o build/macos/Build/Products/Release/pino.app/Contents/MacOS/pino \
  -l 0x10d00000 \
  <address-from-crash-log>
```

---

## 6. Quick Reference

### Commands

| Task | Command |
|------|---------|
| Dev on simulator | `flutter run -d "iPhone 16 Pro"` |
| Build release IPA | `flutter build ipa --release` |
| Build release macOS app | `flutter build macos --release` |
| Create signed DMG | `app/tool/build-macos-dmg.sh` |
| Upload to App Store | `xcrun altool --upload-app ...` |
| Check codesign | `codesign -v build/macos/.../pino.app` |
| List identities | `security find-identity -v -p codesigning` |

### Files

| Path | Purpose |
|------|---------|
| `app/pubspec.yaml` | Version + dependencies |
| `app/ios/Runner/Info.plist` | iOS metadata, entitlements |
| `app/macos/Runner/Configs/AppInfo.xcconfig` | macOS bundle ID, copyright |
| `app/macos/Runner/Release.entitlements` | macOS sandbox + network permissions |
| `.github/workflows/flutter-ci.yml` | Lint + test CI |
| `app/tool/build-macos-dmg.sh` | macOS signing + notarization script |

---

## 7. Security Checklist

Before release:

- [ ] No secrets in code (API keys, bearer tokens, certificates)
- [ ] `pubspec.lock` committed (reproducible builds)
- [ ] All tests pass (`flutter test --coverage`)
- [ ] No critical lint issues (`flutter analyze --fatal-infos`)
- [ ] Code signing identity verified (`codesign -v`)
- [ ] macOS app notarized (required for Gatekeeper on macOS 10.15+)
- [ ] Privacy Policy / EULA up to date on App Store Connect
- [ ] No use of private iOS APIs (automated on App Store review)
- [ ] Bearer token in `flutter_secure_storage` (not plain text)
- [ ] TLS cert pinning in place (`crypto` package, `web_socket_channel`)

---

## 8. Support & Debugging

**Flutter help:**
```bash
flutter doctor           # Check environment setup
flutter analyze          # Lint issues
flutter test --coverage  # Run tests
```

**Xcode build logs:**
```bash
open build/ios/build/Runner.build/Release-iphoneos/Runner.build/
```

**macOS notarization logs:**
```bash
xcrun notarytool log <request-id> \
  --team-id RT8DP44B6N \
  --apple-id your-apple-id@example.com \
  --password xxxx-xxxx-xxxx-xxxx
```

**Keychain / Signing Issues:**
```bash
# Unlock keychain
security unlock-keychain -p <password> ~/Library/Keychains/login.keychain

# List certificates
security find-certificate -c "Developer ID Application" /Library/Keychains/System.keychain
```

---

See also:
- `app/pubspec.yaml` — dependencies and platform config
- `.github/workflows/flutter-ci.yml` — CI test runs
- `docs/ENGINEERING.md` — architecture overview
- `docs/CAPABILITIES.md` — platform capabilities checklist
