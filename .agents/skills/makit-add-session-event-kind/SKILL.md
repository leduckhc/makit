---
name: "makit-add-session-event-kind"
description: "Add a new session event kind end-to-end in makit (server protocol → adapters → app store → UI) and actually prove it works"
---
## When to Use
Use when adding a new `session.*` wire event to makit that must travel agent → server adapter → WSS → Flutter store → UI. Also use when an agent protocol reports something makit currently drops (a `// ignored for now` comment in codex-map.ts / acp-map.ts).

## Procedure
1. Settle the upstream payload shape from the real binary FIRST, never from docs: `codex app-server generate-ts --out DIR` for codex, `$defs` in acp-docs/schema/v1/schema.json for ACP, and grep the shipped pi-acp `dist/index.js` for the `sessionUpdate` literals it actually emits (it emits far fewer than ACP defines).
2. server/src/protocol.ts: add the kind to the EventKind union plus a documented DTO interface. server/src/protocol/codec.ts: add the same string to EVENT_KINDS.
3. Write failing mapper tests in src/adapters/codex-map.test.ts and/or acp-map.test.ts, then handle the notification in the corresponding mapper's `handle` switch. Both mappers are pure and I/O-free.
4. If the event is high-frequency or changes no session-list DTO field, add it to NO_FANOUT_KINDS in src/session.ts.
5. Append a golden entry to server/test/fixtures/events.json AND copy it byte-identically to app/test/fixtures/events.json, then add the kind to the hardcoded list in server/test/protocol/contract.test.ts.
6. app/lib/transport/protocol.dart: add the enum value and its `wire` mapping. app/lib/store/chat_items.dart: add a no-op case to the exhaustive switch.
7. app/lib/store/models.dart: add the model with nullable fields and defensive fromJson. app/lib/store/store.dart: add the state map to the ctor, `empty()`, the field list, `copyWith`, a reducer branch, and a `Provider.family` — mirror `meta`/`sessionMetaProvider` exactly.
8. Update src/adapters/stub.ts to emit the new event too, or both e2e loops render something no code feeds. Also wire any new bridge callback in test/e2e-server.ts for parity with serve.ts.
9. Prove each hop with throwaway scripts: the real agent binary through makit's adapter, then a raw `ws` client against `pnpm exec tsx test/e2e-server.ts --mode stub --project <path>` to confirm the frame crosses WSS.
10. Gates: `cd server && pnpm typecheck && pnpm test`; `cd app && flutter analyze --fatal-infos --no-pub && flutter test --no-pub && dart format lib test tool integration_test`.

## Pitfalls
- `server/test/protocol/contract.test.ts` claims to cover "every EventKind exactly once" but compares against a HARDCODED list, so adding a kind to protocol.ts does NOT fail it. Add the fixture + list entry yourself or the golden coverage silently rots.
- The `events.json` fixture must stay byte-identical between app/ and server/ (CI runs `diff -rq`). Write both from one generator so formatting matches (1-space indent, trailing newline).
- `app/lib/store/chat_items.dart` has an exhaustive switch over EventKind — the Dart compiler will force you to handle the new kind. Add a `break` with a comment saying the store handles it, don't invent a chat item.
- High-frequency events must join `NO_FANOUT_KINDS` in session.ts or every update re-broadcasts the whole sessions snapshot (SPEC-17 P2).
- `SpawnOpts.extensions` is NEVER forwarded to pi — pi-acp spawns `pi --mode rpc` itself, so there is no `-e` channel. Only env vars propagate. A pi extension therefore needs a manual symlink into ~/.pi/agent/extensions/.
- The iOS stub e2e (`tool/e2e.sh --mode=stub`) may already be broken on your branch. Before blaming your change, `git stash -u` and re-run — it takes ~5 min but stops you from chasing someone else's bug.
- Wire envelopes are FLAT, not nested under `body`: `{v,t:"event",kind,sessions:[...]}` and `{t:"cmd",kind:"send.message",sessionId,text}`. Read src/cli/attach.ts for the canonical client shapes.
- A throwaway probe script must live inside server/ (not /tmp) or Node cannot resolve `ws`/deps.

## Verification
1. server: `pnpm typecheck` clean, `pnpm test` all pass (includes the .pi/extensions/**/*.test.ts glob).
2. app: `flutter analyze --fatal-infos --no-pub` clean, `flutter test --no-pub` all pass, `dart format --set-exit-if-changed lib test tool integration_test` reports 0 changed.
3. `diff server/test/fixtures/events.json app/test/fixtures/events.json` is empty.
4. A raw `ws` client against the keyless e2e server receives the new event as `{t:"event",kind:"session.event",event:{kind:"<new kind>",payload:{...}}}`.
5. The real agent binary, driven through makit's adapter, emits the event with the payload the app's tests assume.
