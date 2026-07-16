# SPEC-18 — Protocol & type-boundary hardening (validation, dead surface, drift)

**Status:** Proposed · **Priority:** P1 · **Source:** `docs/research/2026-07-16-code-quality-audit.md` §3 T1, T3–T5, §2 P5
**Scope:** `server/src/index.ts`, `server/src/protocol*`, `app/lib/control/control_types.dart`, `app/lib/ui/widgets/srv_request_handler.dart`, `app/lib/notifications/notification_request.dart`, `app/lib/store/store.dart`.

---

## 🚦 Branch & worktree gate (NO GO if not met)

This spec **MUST** be implemented in a **new git worktree branched from `chore/code-quality-review`**, and its **pull request MUST target `chore/code-quality-review`** (not `main`).

- Base branch: `chore/code-quality-review`
- PR target branch: `chore/code-quality-review`

If either condition is not satisfied, **this spec is NO GO**.

```bash
git fetch origin chore/code-quality-review
git worktree add ../spec-18-boundaries -b spec-18/boundary-hardening origin/chore/code-quality-review
```

---

## Goal

Close the untrusted-input gap at the device-response boundary, delete dead
protocol surface, and remove two drift risks where the same wire shape is
hand-built in two places.

## Work items

### T1 — Validate `srv.response` at the boundary *(untrusted input)*

- **Where:** `server/src/index.ts:306, 339` (`return env as unknown as ...UIResponse`).
- **Problem:** `ReverseRpc.askDevice` double-casts a raw `Envelope` to
  `UIResponse` with **zero validation**. A malformed/hostile client response
  yields `undefined` silently propagated into agent replies (e.g. codex
  `handleUserInput` iterates `resp.answers` assuming shape). The `as unknown as`
  is the tell that two unrelated types are welded.
- **Fix:** add `decodeUIResponse(env: Envelope): UIResponse | null` in the codec
  (mirror `decodeSessionEvent`); `askDevice`/the bridge return the validated union
  or reject. Removes both double-casts.

### T3 — Delete the dead `toJson` surface in `control_types.dart` (~70 lines)

- **Where:** `app/lib/control/control_types.dart:158, 215, 253, 311, 342, 472`
  (`StatusData`, `PairMintData`, `PairCurrentData`, `DevicesListData` + `DeviceInfo`,
  `DevicesRevokeData`, `ServerStopData`).
- **Problem:** the control client is **decode-only**; grep shows **zero** callers
  of any `toJson` (the only internal ref is `DevicesListData.toJson` →
  `DeviceInfo.toJson`, itself never called).
- **Fix:** delete every `toJson` (keep `fromJson`). Halves the change-surface per
  control verb. Note: `ControlSession` has no `toJson` — after this, the absence
  is consistent.

### T4 — One shared `srv.response` builder

- **Where:** `app/lib/ui/widgets/srv_request_handler.dart` vs
  `app/lib/notifications/notification_request.dart:88` (`responseForAction`).
- **Problem:** both independently hand-build the canonical bodies
  (`{'kind':'confirmAction','approved':…}`,
  `{'kind':'askUserQuestion','indices':…,'answers':…}`,
  `{'kind':'input','value':…}`). Untested drift risk between the dialog-answer and
  notification-answer paths.
- **Fix:** one `SrvResponse` builder (`confirmAction(approved)`,
  `askUserQuestion(indices, answers)`, `input(value)`, `cancelled(kind)`) used by
  **both** call sites. Add a test locking the shapes.

### T5 — Remove dead protocol surface

- **Where:** `server/src/protocol.ts:48` (`session.action_error` — declared in
  `protocol.ts` + `protocol/codec.ts`, never emitted); `protocol.ts:154-166`
  (`CmdKind` union has drifted from `buildCommandRouter` registrations — lists
  `session.policy` with no handler, omits `session.action`, `session.setAgent`,
  `worktree.create`, `project.*`, `session.list`, `debug.*`).
- **Fix:** either wire `session.action_error` (the `session.action`/`cancel`
  handlers currently swallow adapter failures) **or** delete the kind; reconcile
  `CmdKind` with the actual registry (generate from the registry, or drop the
  pretense to a comment). Pick one direction and make it consistent.

### P5 — Drop the `_onFrame` length-heuristic refresh

- **Where:** `app/lib/store/store.dart:283-292`.
- **Problem:** infers "server dropped a repos snapshot" from
  `projects.length > repos.length` on the hot frame path — can spuriously trigger
  `refreshRepos()` on every subsequent frame (potential refresh loop).
- **Fix:** let `project.add`/`removeProject` (which already call `refreshRepos()`)
  be the only refresh trigger; delete the length heuristic from `_onFrame`. If
  server-drop recovery is genuinely needed, gate it on a one-shot correlation id,
  not a running length compare.

## Verification (definition of done)

- New server test: `decodeUIResponse` rejects malformed envelopes and accepts
  each valid `UIResponse` variant; no `as unknown as` remains in `index.ts`.
- New Dart test locking the shared `SrvResponse` shapes (used by both the dialog
  and notification paths).
- Grep proves no remaining `toJson` in `control_types.dart` and no producer/
  consumer mismatch for the resolved `session.action_error` decision.
- `cd server && pnpm typecheck && pnpm test` green; `flutter analyze
  --fatal-infos` clean; `app/tool/audit.sh` passes.

## Non-goals

- No change to the on-wire message *values* (T4/T3 remove dead code and unify
  builders; the emitted shapes stay identical). No new control verbs.
