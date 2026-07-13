# Push notifications setup (APNs)

Background wake (SPEC-07) lets Makit reach your phone when the app is
force-quit or long-suspended. The server sends a **content-free** alert via
Apple Push Notification service (APNs). Real session data is never in the push
payload — the app reconnects over your Tailscale tailnet and pulls approvals
via the existing WebSocket.

Without this setup, **Slice 1 still works**: actionable notifications while the
app process is alive. See [NOTIFICATIONS.md](NOTIFICATIONS.md).

---

## Prerequisites

- Apple Developer account with Push Notifications capability
- App bundle ID registered (e.g. `dev.getmakit.app`)
- Makit iOS app installed (development build or TestFlight)
- `makit` server running on your Mac with internet access (to reach APNs)

---

## 1. Create an APNs Auth Key

1. Open [Apple Developer → Keys](https://developer.apple.com/account/resources/authkeys/list).
2. Create a new key with **Apple Push Notifications service (APNs)** enabled.
3. Download the `.p8` file (only once). Note the **Key ID** and your **Team ID**.

Store the key privately:

```sh
mkdir -p ~/.makit/apns
mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.makit/apns/
chmod 600 ~/.makit/apns/AuthKey_XXXXXXXXXX.p8
```

---

## 2. Configure the server

Create `~/.makit/push.json` (mode `0600`):

```json
{
  "apns": {
    "keyPath": "~/.makit/apns/AuthKey_XXXXXXXXXX.p8",
    "keyId": "XXXXXXXXXX",
    "teamId": "YOUR_TEAM_ID",
    "bundleId": "dev.getmakit.app",
    "env": "sandbox"
  }
}
```

| Field | Description |
|-------|-------------|
| `keyPath` | Path to the `.p8` auth key (`~/` expands) |
| `keyId` | 10-character key ID from Apple |
| `teamId` | Your Apple Developer Team ID |
| `bundleId` | Must match the iOS app bundle ID |
| `env` | `sandbox` for dev/TestFlight builds; `production` for App Store |

Restart the server:

```sh
makit restart   # or stop + start
```

Confirm in the server log:

```
[makit] push: APNs sender active (sandbox, dev.getmakit.app)
```

If the file is missing or invalid, the server uses `NoopPushSender` (no wakes;
Slice-1 notifications still work).

---

## 3. Xcode / iOS app

The repo already includes:

- **Push Notifications** capability
- **Background Modes → Remote notifications** in `Info.plist`
- `aps-environment` in `Runner.entitlements`
- `AppDelegate` forwards the APNs token to Dart via the `makit/push` channel

For local development builds, use a provisioning profile that includes push.
TestFlight and App Store builds use the production APNs environment — set
`"env": "production"` in `push.json` for those.

---

## 4. Verify registration

1. Install and pair the iOS app.
2. Grant notification permission when prompted.
3. In the app: **Settings → Notifications** — "Background wake" should show
   **Registered** when connected.
4. On the server: `makit devices` — the device entry should include a push
   token (value redacted in logs).

The app sends `push.register` after each successful WebSocket connect. The
server stores the token in `~/.makit/devices.json`.

---

## 5. Test the wake loop

Follow the SPEC-07 checklist in [NOTIFICATIONS.md](NOTIFICATIONS.md#on-device-checklist--spec-07-background-wake).

Quick smoke test:

1. Force-quit Makit on the phone.
2. Trigger an approval on the desktop.
3. Phone should buzz within a few seconds.

---

## Security & privacy

- Makit operates **no cloud relay** — your Mac signs JWTs and talks to APNs
  directly.
- Push payloads contain **no session IDs, messages, or approval text**.
- Device tokens live in `~/.makit/devices.json` (mode `0600`).
- Revoke a lost device: `makit devices revoke <device-id>`.

---

## Android / FCM

Deferred. The `PushSender` and `PushRegistrar` interfaces are platform-agnostic;
an FCM adapter can be added later behind the same `pushPlatform: "fcm"` seam.
