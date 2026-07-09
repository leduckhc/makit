# makit — mobile app (Flutter)

Mobile-first coding agent client. See [`../docs/UX.md`](../docs/UX.md) and
[`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) for the product and
protocol specs.

## Status: M0 skeleton

What works:

- App boots, routes through pairing → home → session → tool-call drilldown.
- An **in-process fake server** seeds 2 projects with 3 sessions (codex, pi,
  claude) and a scripted transcript including a pending approval request.
- Sending a message echoes back from the fake server as a real `agent.message`
  event flowing through the same projection pipeline that will handle the real
  Node server in M2.
- Slash palette (`/`) shows command suggestions.
- Composer supports ⌘↩ to send.

What's stubbed (TODO markers in code):

- Real QR scan + mDNS discovery (`pairing/pairing_screen.dart`).
- Real WebSocket to a Node server (the `WsClient` exists in
  `transport/ws_client.dart` — it just isn't routed to from
  `ConnectionController` yet; the fake server intercepts).
- Voice dictation, @-mentions, diff viewer.

## First-time setup

This repo only contains `lib/` and `pubspec.yaml`. Generate the iOS/Android
platform shells with:

```sh
cd app
flutter create . \
  --org dev.makit \
  --project-name makit \
  --platforms=ios,android,macos
flutter pub get
```

`flutter create .` is safe to run over an existing `lib/` — it only adds the
platform folders and any missing entry-point files.

## Run

```sh
flutter run                 # picks first available device
flutter run -d macos        # desktop, fastest iteration loop
flutter run -d "iPhone 15"  # iOS simulator
```

## Layout

```
lib/
├── main.dart                  // ProviderScope + MaterialApp.router
├── app/
│   ├── router.dart            // go_router; pair-guard redirect
│   └── theme.dart
├── transport/
│   ├── protocol.dart          // Envelope, MsgType, EventKind, SessionEvent
│   └── ws_client.dart         // reconnecting WS w/ resume cursors
├── store/
│   ├── connection.dart        // owns transport (fake or real)
│   ├── fake_server.dart       // M0 in-process fake; delete in M2
│   ├── models.dart            // Project, Session, ChatItem, foldEvents
│   └── store.dart             // Riverpod providers; event projection
├── pairing/
│   └── pairing_screen.dart
└── ui/
    ├── home/                  // Projects → Sessions list
    ├── session/               // chat view, tool card, drilldown
    ├── composer/              // input bar + slash palette
    └── settings/
```

State flow: incoming `Envelope`s → `StoreController._onFrame` → updates
`_StoreSnapshot` → derived `projectsProvider` / `sessionsProvider` /
`chatItemsProvider` → widgets rebuild.

The chat UI never touches `SessionEvent` directly; it consumes `ChatItem`s
produced by `foldEvents` (which collapses `tool.call.{start,delta,end}` into
one `ToolCallItem`). That fold is the seam where the wire model meets the
visual model — if the wire grows new event kinds, update `foldEvents` and the
switch in `SessionScreen`.

## Next milestones

- **M1**: real pairing (QR + mDNS + Noise-IK), wire `WsClient` to
  `ConnectionController`, retire the fake server behind a `--dart-define`.
- **M2**: connect to the real Node/TS server (Spike 0 decides PTY vs native).
- **M3+**: per `docs/ARCHITECTURE.md` §12.
