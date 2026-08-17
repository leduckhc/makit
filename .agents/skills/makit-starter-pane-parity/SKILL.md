---
name: "makit-starter-pane-parity"
description: "Give makit's sessionless \"Choose a harness\" starter pane a live-pane capability (draft text, slash commands, attachments) without inventing a second mechanism"
---
## When to Use
Use when a user reports that something is missing or lost in makit's desktop "Choose a harness" / new-session pane (`app/lib/desktop/chat/worktree_starter.dart`) — lost typed text, empty slash palette, inert paperclip, missing footer control. The pane is a reduced copy of the live pane's composer wiring, so its gaps are almost always "the live pane passes X to Composer, the starter does not".

## Procedure
1. Diff the two call sites before theorising: `Composer(...)` in `app/lib/desktop/chat/desktop_chat_pane.dart` (~line 400) versus in `worktree_starter.dart`. Every painpoint so far was a `Composer` parameter the starter omits (`initialText`/`onDraftChanged`, `commands`, `attachments`).
2. Check whether the mechanism already exists before building one: `composer_draft.dart`'s doc already reserved the `starter:<worktreePath>` key space, `composerAttachmentsProvider` is keyed by an opaque `String`, and `POST /media` is session-independent. Reuse beats a parallel store.
3. Confirm that split_view.dart keys `DesktopChatPane` by `ValueKey(active.id)` — that is why a tab switch destroys starter-local state. ANY starter state the user typed or picked must move out of the State and into an app-wide (non-autoDispose) provider keyed by `starter:<worktreePath>`: text in `composerDraftsProvider`, images in `composerAttachmentsProvider`, harness + config picks in `starter_picks.dart`.
4. When moving `setState` fields into a provider, add a matching `ref.watch(thatProvider)` in `build` — the writes no longer go through `setState`, so without the watch the harness cards and footer pills stop repainting even though the store is correct.
5. For agent slash commands, remember they never arrive from `agents.list`: ACP's `NewSessionResponse` carries only `sessionId`/`modes`/`configOptions`, and commands come later as an `available_commands_update` notification (`server/src/adapters/acp-map.ts`). Pre-session, they can only come from a cache of what a live session advertised, keyed by (agent, projectId) since command lists are cwd-dependent.
6. Record the cache from `StoreController._onFrame`/`_flushReplay` on the `session.commands` event, not by diffing the reduced `commands` map — the latter would run on every streamed token.
7. When the starter sends, take staged attachments AFTER the spawn resolves (pass a `takeAttachments` callback into `startSessionInWorktree`), and capture every notifier you will touch post-await BEFORE the await — `attachment_controller.dart` states the convention: a post-await `WidgetRef.read` throws once the pane rebinds.
8. Restore the composer text in `_start`'s catch block: `Composer._send()` calls `_ctrl.clear()` unconditionally, so a refused spawn otherwise eats the message even though its images and picks survive.
9. Decide explicitly what a *successful* spawn does to each draft store. Text and picks are cleared (the composed session now exists); keeping them would silently become a sticky per-worktree harness preference, which is a different feature.
## Pitfalls
- `flutter test` in a fresh worktree needs `flutter pub get` first, or every file fails with "cannot run without a dependency on either package:flutter_test".
- A full `flutter test --no-pub --concurrency 2` reports 6-20 failures that are all `Failed to load ... Unable to connect to flutter_tester`. Count `grep -oE 'Failed to load "[^"]+"'` against the `-N` total and re-run those files individually (`pkill -f flutter_tester; sleep 1` first) instead of chasing them.
- `SlashCmd` has no `==`, so list assertions must compare names (or another field), not instances. `SlashCmd.fromJson` also CASTS (`as String?`), so a wrong-typed field THROWS instead of returning null — `whereType` cannot filter that, and in a bootstrap path it is a failure to start. Wrap per-entry decoding in try/catch.
- Do not persist the command cache in the mobile bootstrap (`app/lib/desktop/../main.dart`): the phone has no starter pane, so it would write a prefs blob it never reads. The default ephemeral controller absorbs its records harmlessly.
- Mutation-check any "ordering" or "validation" test (take-after-spawn, server-switch clear, harness re-validation): break the production line, confirm red, restore. Several of these tests pass vacuously otherwise.
- A non-git project reports `worktrees: []` (`server/src/repo_service.ts` — `isGitRepo` false skips `listWorktrees`). Any prune guard of the form "bail if ANY repo looks unpopulated" is therefore disabled by one notes folder. Guard PER REPO, like `closeGroupsForDeletedWorktrees`, which means the key must carry its `projectId` — a linked worktree's path cannot identify its repo.
- Writing to another provider from a `ref.listen` callback happens INSIDE Riverpod's refresh pass and can poison the graph (see the long comment in `desktop_session_prune.dart`); defer with `Future.microtask`. But a `Stream.listen` callback (e.g. `StoreController._onFrame`) is its own event-loop task and needs no deferral — know which one you are in before adding ceremony.
- When re-validating a persisted choice against a catalog, treat an EMPTY catalog as "not loaded yet", not "nothing available", or a send during the loading frame silently falls back to the default.
## Verification
1. `flutter analyze --no-pub` clean and `dart format --output=none --set-exit-if-changed lib test` clean.
2. Targeted suites green: `test/desktop/chat/worktree_starter_*_test.dart`, `test/store/cached_commands*_test.dart`, `test/composer_attachments_test.dart`, `test/desktop/desktop_chat_pane_test.dart`.
3. Full app suite: every remaining failure appears in the `Failed to load` list and passes when re-run alone.
4. The spec doc plus a row in `docs/specs/README.md` — this repo is spec-driven and a change without one is incomplete.
