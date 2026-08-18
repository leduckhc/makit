# SPEC-preview-groups — Preview groups: one disposable worktree tab

**Status:** Implemented · **Priority:** P2 · **Surface:** desktop chat (`app/lib/desktop/chat/`), desktop settings
**Depends on:** SPEC-tab-groups (tab groups — the thing that accumulates), SPEC-desktop-workspace-tabs (the split/tab tree a group renders)
**Server changes:** none. Preview is a client-side property of the group bar.

---

## Problem

SPEC-tab-groups decision 15 made the sidebar worktree row *navigate*: clicking a branch
activates its worktree group, minting one when none exists. That is the right
gesture and it has one bad consequence — **browsing costs a tab**. A user with
twenty worktrees who clicks through them looking for the right branch ends the
minute with twenty group tabs, none of which they asked to keep. Decision 12
(the rail scrolls, never wraps) then hides the tabs they *do* care about behind
a scroll offset.

Closing them again is free (a worktree group is derived: `closeGroup` leaves no
residue and touches no agent), which is the tell — the tabs were never worth
minting. The user has to clean up after a gesture that was pure navigation.

## Goal

Borrow VSCode's **preview tab**: at most one group tab is *disposable*, and the
next disposable open replaces it instead of appending. Browsing twenty branches
costs one tab; keeping one is an explicit gesture.

Opt-in, default **off** (`layout.previewGroups`): the mode trades a group's
arrangement for a tidy rail, and that trade must be chosen, not discovered.

## Decisions

1. **Only worktree groups can be preview.** A board is hand-named and
   hand-curated — its whole value is that nothing happens to it implicitly.
2. **At most one preview group, and it is a property of the collection, not of a
   group.** `GroupsState.previewGroupId` is a single nullable id, so "at most
   one" holds by construction instead of being an invariant something has to
   enforce across a list. `Group` is unchanged.
3. **The sidebar worktree row opens preview** (when the pref is on). If a
   preview group already exists, the newcomer takes **its slot** in the rail —
   the rail's length does not change while you browse.
4. **Promotion is explicit only.** Exactly two gestures promote: **clicking the
   branch you are already previewing** (the second click says "I'm staying
   here"), or **"Keep this view"** in the group tab's right-click / long-press
   menu. Doing work in the group — sending a message, splitting, spawning — does
   **not** promote it. Rejected the VSCode-faithful "an edit promotes it" rule:
   makit has no save point, so every heuristic for "this group now matters" is a
   guess, and a wrong guess in that direction silently re-fills the rail, which
   is the bug this spec exists to fix. The cost is stated plainly in decision 5.

   *Implementation note.* The gesture began as a literal double-click on the
   sidebar row and changed during implementation, because an `onDoubleTap` on
   that row puts a double-tap recognizer in the gesture arena, which defers
   `onTap` until the double-tap timer expires — **every** branch click would gain
   ~300ms of lag to support a rare gesture. A wall-clock double-click window
   inside the widget was rejected too (unreliable on a trackpad, untestable
   without injecting a clock). The shipped rule is timing-free and strictly more
   forgiving: a fast double click satisfies it, and so does a slow one.
5. **Replacement is residue-free, and it discards an arrangement.** The
   displaced group's sessions keep running and stay in the sidebar — replacement
   is exactly `closeGroup` semantics for a derived group. What is lost is its
   *split/tab arrangement*. Under decision 4 that can include a group you were
   mid-conversation in, so: the pref is off by default, the preview tab is
   visibly marked (decision 8), and promotion is one click away.

   The reason this is a mild loss rather than a data loss is worth stating: a
   worktree group's membership is **derived**, so re-opening the branch places
   its still-running agents back on the canvas automatically. Only the pane
   ratios and tab order were the user's, and only those go.
   `test/desktop/preview_group_reconcile_test.dart` holds that claim to the real
   reconcile wiring rather than to prose.
6. **Deliberate opens are never preview and never evict.** The new-worktree
   dialog, a session click that mints its worktree group (decision 15 case d),
   and `seedFromSessions` all express intent about a *specific* branch, so they
   mint permanent groups and leave the preview group alone.
7. **Closing the preview group clears the pointer.** Whether it goes by the tab
   ✕, by `closeGroupsForDeletedWorktrees`, or by replacement, no stale id
   survives — and a stale id would only mean "no preview" anyway (decision 10).
8. **Marked in italic**, matching VSCode, with a tooltip that says the next
   worktree click will replace it and how to keep it. The kind swatch, count
   pill and live dot are unchanged: it is still a worktree group.
9. **Re-clicking a *background* preview group is still navigation.** Promotion
   (decision 4) requires the preview group to be the one **on screen**, so
   coming back to it from elsewhere activates it and leaves it disposable. Only
   a repeat click on what you are already looking at keeps it.
10. **Persistence adds an optional field, with no version bump.**
    `previewGroupId` is written alongside `activeGroupId`; a payload without it
    (every existing install) decodes to "no preview group". Bumping
    `kGroupsPayloadVersion` would discard every user's real layout to add an
    optional pointer — a strictly worse trade than tolerating its absence.

## Non-goals

- Promotion by drag: group tabs cannot be reordered or dragged today.
- Promotion by a literal double-click gesture — see decision 4's note.
- Mobile. Groups are a desktop-window concept (SPEC-tab-groups).
- A preview *pane* or preview *tab-within-a-group*. The unit that accumulates is
  the group; nothing else changes.

## Surfaces

| Where | Change |
| --- | --- |
| `groups/groups_controller.dart` | `previewGroupId` in state; `openWorktreeGroup(preview:)`; `keepGroup(id)`; `closeGroup` clears the pointer; encode/decode the field |
| `groups/group_providers.dart` | `previewGroupIdProvider`, `previewGroupsEnabledProvider` |
| `selected_session.dart` | `selectWorktree(ref, worktree, {keep})` reads the pref, promotes a repeat click on the on-screen preview group |
| `desktop_sidebar.dart` | unchanged behaviour; documents why it has no `onDoubleTap` |
| `groups/group_bar.dart` | italic label + preview tooltip + "Keep this view" in the tab menu |
| `settings/sections/appearance_section.dart`, `prefs/preference_entries.dart` | `layout.previewGroups` switch under Layout |

## Verification

- Controller: replacement reuses the slot, keeps the rail length, and clears the
  pointer on promote/close; permanent opens neither mark nor evict; round-trip
  through SharedPreferences; a payload with no `previewGroupId` still decodes.
- `selectWorktree`: preview only when the pref is on; a repeat click on the
  on-screen preview group promotes without minting a second group; a background
  one stays disposable.
- Widget: the preview tab renders italic and offers Keep; a plain worktree tab
  does neither. A single click on a worktree row still activates on the same
  frame — the guard that caught the `onDoubleTap` latency regression.
- Integration: a displaced preview group's agents are back on the canvas when
  its branch is clicked again, still running.
