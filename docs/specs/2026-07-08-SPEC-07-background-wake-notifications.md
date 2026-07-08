# SPEC-07 — Background wake for notifications (true push over a private tailnet)

**Status:** proposed / backlog (fast-follow to Slice 1 actionable notifications)
**Depends on:** Slice 1 (actionable local notifications — see the architect TDD
plan) · **Touches:** `app/lib/notifications/*`, `app/ios/`, `server/src/` (push
dispatch), `~/.pino/` (device push tokens)

## Goal

Make the "your agent needs you" loop fire **reliably even when the pino app is
suspended or killed** and the phone is locked — so a user can start a task, put
the phone in their pocket, walk away, and still get buzzed for an approval, a
question, or completion within seconds.

Slice 1 delivers actionable notifications **while the app is alive** (foreground
or backgrounded with a live WebSocket). Slice 2 closes the reliability gap: iOS
aggressively suspends the socket and background isolates, so "away for 20+
minutes" needs an OS-level **wake signal**, not a live connection.

## Why this is hard here (the core tension)

pino is **private by default** — it talks to your desktop over a Tailscale
tailnet, with **no cloud backend**. But OS push (APNs on iOS, FCM on Android)
*is* a cloud path: Apple/Google servers must reach the device. There is no way
to wake a killed iOS app from a tailnet-only server.

The resolution: use push **only as a content-free wake signal**. The push body
carries **no session data** — just "you have N pending item(s)". On wake, the
app reconnects to the private tailnet and pulls the actual approval/question
over WSS as usual. The cloud sees a bearer-less "ping"; all real data stays on
the tailnet. This preserves the privacy story while getting OS-level reliability.

## Approach options (decide during design)

| Option | Wake mechanism | Cloud dependency | Notes |
|--------|----------------|------------------|-------|
| **A. APNs/FCM content-free push** | Standard OS push | A tiny relay the server calls to send the push token a "wake" ping | Most reliable; needs an APNs auth key + a minimal relay endpoint (could be a small hosted function or the user's own). |
| **B. VoIP / high-priority silent push** | `content-available` background push | Same as A | Wakes the app to fetch; iOS rate-limits silent pushes. |
| **C. Local keep-alive only** | Background fetch + BGProcessingTask | None | No true cloud; iOS grants only opportunistic background time — unreliable for time-sensitive approvals. Good as a fallback, not a primary. |
| **D. Live Activities / interactive widget** | n/a | None | Shows agent status on lock screen while app recently active; complements, doesn't replace, wake. |

Leaning **A** (content-free APNs) as primary with **C** as best-effort fallback.

## Work items

1. **Device push registration.** App requests APNs/FCM token; sends it to the
   server on pair/connect; server persists per-device in `~/.pino/devices.json`
   (alongside the existing bearer). Revoking a device drops its token.
2. **Server push dispatch.** When a session raises an approval / question /
   completion and the target device has no live socket, the server sends a
   **content-free wake** to that device's push token via the relay.
3. **Relay decision.** Choose/host the minimal APNs sender (auth key, topic).
   Keep payload content-free. Document self-host vs shared-relay tradeoff.
4. **App wake handler.** On silent/wake push: reconnect to the tailnet, fetch
   pending UICalls, and (re)present the actionable notification from Slice 1.
5. **Background-isolate action path.** Allow answering an approval from the
   notification action even when the app was killed: the wake reconnects first,
   then the action's `srv.response` is delivered. (Slice 1 handles the
   app-alive path; this generalizes it.)
6. **Fallback: iOS background fetch / BGTaskScheduler** for opportunistic
   catch-up when push is unavailable.
7. **Settings + graceful degradation.** Per-device toggle; if the user declines
   push, fall back to Slice 1 behavior (works only while app is alive) with a
   clear explanation.

## Open questions

- Do we ship a shared pino relay (convenience, we operate it) or require users
  to bring their own APNs key (max privacy, more setup)? Default + opt-out?
- Android: FCM is mandatory-cloud too; same content-free approach.
- How do we prove "no content leaks" — assert the push payload schema in a test.
- Interaction with multi-device: wake all paired devices, or a primary?

## Acceptance criteria

- With the app **force-quit** and the phone **locked**, triggering an approval
  on the desktop delivers a notification to the phone within a few seconds.
- The push payload contains **no session content** (asserted by a test).
- Tapping **Approve** from that notification resolves the approval on the
  desktop without the user manually opening and navigating the app.
- Declining push permission degrades gracefully to Slice 1 (app-alive) behavior.
- Revoking a device removes its push token; no further wakes are sent to it.
