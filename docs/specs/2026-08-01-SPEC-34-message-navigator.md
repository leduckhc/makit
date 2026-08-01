# SPEC-34 — Message navigator (find your own messages in a long transcript)

**Status:** Proposed · **Priority:** P2 · **Branch:** `feat/user-message-scroller`
**Depends on:** SPEC-21 (reversed anchored transcript), SPEC-24 (fold state in `expandedTranscriptRowsProvider`)
**Mockups:** [`mockups/user-message-rail.html`](../../mockups/user-message-rail.html) (the five candidates) · [`mockups/chat-navigator-settings.html`](../../mockups/chat-navigator-settings.html) (settings + schema)

**Scope:** new `app/lib/ui/session/navigator/` (shared), `app/lib/ui/session/chat_transcript.dart`,
`app/lib/ui/session/transcript_list.dart` (read-only additions: index→offset lookup),
`app/lib/desktop/settings/prefs/preference_entries.dart`,
`app/lib/desktop/settings/sections/agents_chat_section.dart`.
No server changes. No protocol changes.

---

## Goal

In a long session the transcript is ~90% assistant output, so re-finding **your own
prompts** means scrolling blind. Give the user a way to see, preview and jump to their
own messages without leaving the transcript — and let them choose *which* affordance
they get, because the right answer differs between a mouse on a 27" display and a thumb
on an iPhone.

Success is behavioural, not visual:

1. From any scroll position, land on any prior user message in **≤ 2 interactions**.
2. Doing so **never** disturbs the transcript's anchoring (SPEC-21) or fold state (SPEC-24).
3. The affordance costs **zero** transcript width and is inert while streaming.
4. A user who finds it noisy can turn it off completely — on **both** surfaces (see
   [§Surface matrix](#surface-matrix); mobile gets an on/off switch, not the picker).

## Background — why this is not just "a scrollbar with marks"

The transcript is a **reversed lazy list** (`TranscriptListView` → `_AnchoredSliverList`,
SPEC-21). Two consequences drive the whole design:

- **Offsets of un-built rows do not exist.** Anything that draws a marker at a
  *proportional scroll position* would need the extent of rows that have never been laid
  out. `maxScrollExtent` on a lazy list is an estimate, and forcing it accurate is exactly
  the "measure everything" lurch SPEC-21 removed. **Markers must therefore be placed by
  item index, not by scroll offset.**
- **Jumping to an un-built index is not a one-liner.** `Scrollable.ensureVisible` only
  works on a built element. See [§Jumping](#jumping-to-an-un-built-index) — this is the
  single largest implementation risk in this spec.

The data side is free: the full transcript is already in memory
(`subscribeSession(fromSeq: 0)`, `chatItemsProvider`), so "list my messages" is a filter,
not a fetch.

## Design

### Five navigator styles, one shared spine

All styles are pure consumers of two shared pieces plus a preference:

```
userMessageIndicesProvider   // List<int> — indices into chatItemsProvider of role==user
TranscriptJumper             // jumpToItem(int index) — see §Jumping
messageNavigatorStylePref    // which style renders
```

Every style is a sibling widget under `app/lib/ui/session/navigator/`, stacked over the
transcript by the **shared** `chat_transcript.dart` (never per-surface) so mobile and
desktop cannot drift — the SPEC-21/SPEC-24 parity rule.

| Style | Affordance | Input | Notes |
|---|---|---|---|
| `rail` | Cosy cluster of hairline ticks in the **top-right corner**; hover ripples the cluster and reveals the message; click jumps | pointer | **default on desktop** |
| `scrubber` | Drag the right edge; a preview card snaps prompt-to-prompt | touch + pointer | **default on mobile** |
| `palette` | Shortcut opens a filterable list of your messages; ↑↓ previews, ⏎ jumps | keyboard | only style that **searches** |
| `breadcrumb` | Glass chip always shows which prompt produced what you're reading, ◀ ▶ hops | passive | answers "where am I", not "where was it" |
| `outline` | Toggle hides assistant/tool rows, leaving your prompts as a table of contents; click one to expand back in place | toggle | doubles as a session summary |
| `off` | Nothing | — | escape hatch |

### The rail, precisely

The chosen default, specified tightly because the feel is the feature:

- **Placement:** absolute cluster pinned top-right of the transcript viewport, inset 10pt
  from the trailing edge, 12pt from the top. It does **not** span the viewport height and
  is **not** proportional to scroll position (see Background).
- **Resting state:** one 1.5pt hairline per user message at `spacing` pt apart
  (default 6), `onSurfaceVariant` at **60% opacity — not lower**: the ticks are UI
  components, so they owe WCAG 1.4.11's 3:1 contrast against the transcript surface, and a
  38% hairline fails it. Length encodes message length when
  `encodeLength` is on (20 / 15 / 11pt for long / medium / short) so the cluster reads as
  a fingerprint of the session.
- **Ripple (hover):** the tick nearest the pointer grows +30pt; neighbours +21 / +12 / +5
  over ±3, **and** are pushed vertically away from the crest by 3.5 / 2 / 0.8pt. 260ms,
  `Curves.easeOutCubic`. The vertical push is what makes it read as a liquid surface
  rather than three lines growing — it is only legible *because* the ticks are cosy.
- **Peek:** a `surfaceContainer` card pinned to the crest showing `you · n/N` + the full
  message text, max 280pt wide, 160ms fade.
- **Current-position tick:** the tick governing the visible region stays `primary` at 90%.
- **Hit target:** ticks at 6pt are far below the 44pt minimum, so the pointer maps to the
  nearest **index** across a 70pt-wide invisible strip; individual ticks are never hit-tested.

### Jumping to an un-built index

`TranscriptJumper.jumpToItem(position)` — the one genuinely hard part, and the one where
the obvious implementation is **wrong**.

**The trap.** The obvious approach is: jump to an estimated offset, then fix it up in an
`addPostFrameCallback` once the target is built. Do not do this. The render object's own
doc comment (`transcript_list.dart:126-128`) already rules it out:

> *"...returned as a `SliverGeometry.scrollOffsetCorrection`, which `RenderViewport`
> applies during layout and re-runs the layout — so no intermediate frame is ever painted.
> **Correcting from a post-frame callback instead paints the wrong frame first (a visible
> blink)**."*

A post-frame correction loop paints one wrong frame per correction — precisely the blink
`_RenderAnchoredSliverList` exists to prevent, reintroduced under a new name.

**The mechanism.** Reuse the anchoring machinery instead of working around it.
`_RenderAnchoredSliverList` already corrects position *inside* `performLayout`; give it a
target:

1. Set `jumpTargetChild` on the render object and seed a jump to an estimated offset
   (`meanBuiltExtent × distanceInItems`, clamped to `[0, maxScrollExtent]`) so the lazy
   list starts building near the target.
2. In `performLayout`, once the target child has been laid out, return the delta between
   its `layoutOffset` and the desired viewport position as
   `SliverGeometry.scrollOffsetCorrection`. `RenderViewport` applies it and **re-runs
   layout within the same frame** — a bad estimate costs extra layout passes, never a
   painted frame.
3. Clear the target once it sits within 4pt of the desired position (4pt is under one line
   of body text — invisible).

**Bounding it.** `RenderViewport` allows only a limited number of correction attempts per
frame before it asserts. Count our own and **give up at 5**, clearing the target and
accepting the position — so a pathological transcript (tall un-built image rows the
estimate keeps under-shooting) degrades to "lands close" rather than tripping a framework
assert. Convergence is therefore guaranteed *within one frame*; accuracy is bounded
best-effort, which is what step 4 covers.

4. **Landing flash.** The target row flashes a 2pt `primary` outline for 900ms. This is
   *not* cover for a jump artefact (there is none now): it earns its place by confirming
   the jump did something when the target was **already on screen**, which is otherwise
   indistinguishable from a no-op. If the jump gave up short, the flash still goes on the
   target row so the user's eye has somewhere to land.

**Three index spaces — never conflate them.**

| Space | Meaning |
|---|---|
| item position `p` | index into `chatItemsProvider`, ascending/oldest-first — what `userMessageIndicesProvider` returns |
| child index | what the lazy list uses: `items.length - 1 - p + (hasTrailer ? 1 : 0)` (`chat_transcript.dart:168`) |
| scroll offset | reversed space, 0 = newest |

`jumpToItem` takes an **item position** and applies the child-index transform internally,
**reusing** `transcriptChildIndexFinder`'s expression rather than restating it. An
off-by-one here is a jump that lands one message away — a failure a casual test will not
catch. `hasTrailer` varies at runtime (working indicator / inline ask card), and
`outline` changes `itemCount` while active, so the transform must be read live and never
cached across a mode change.

### Settings — style picker + per-style options

Lives in **Agents & Chat** under a `Message navigator` subsection header, blurb:
*"How you jump back to your own messages in a long transcript."*

Presentation: **expanding radio list** — one `SettingsGroup` row per style (name, badge,
one-line description); the selected row expands its options inline underneath. Rationale:
five styles × 2–3 options = 13 controls, so progressive disclosure is mandatory, and a
radio list lets the user read what "Outline" *means* without selecting it — this is a
choice made once, so informed beats compact. (Alternative treatment — a `SegmentedButton`
matching `appearance_section.dart` — is mocked up and rejected for this reason; see
[open question D1](#open-questions).)

Options per style:

| Style | Options |
|---|---|
| `rail` | Tick spacing (`cosy 6` / `normal 10` / `roomy 14`) · Ripple on hover · Tick length = message length |
| `scrubber` | Scroll while dragging (off = preview, jump on release) · Show timestamps |
| `palette` | Search assistant messages too · Shortcut (read-only; rebound in **Shortcuts**) |
| `breadcrumb` | Hide while streaming · Show position counter |
| `outline` | Hide tool calls too · Show hidden-row counts |

### Preference schema

```dart
enum MessageNavigatorStyle { off, rail, scrubber, palette, breadcrumb, outline }

const PreferenceEntry<MessageNavigatorStyle> messageNavigatorStylePreference =
    PreferenceEntry(
      id: 'chat.navigator.style',
      defaultValue: MessageNavigatorStyle.rail,
      encode: _encodeNavigatorStyle,   // value.name
      decode: _decodeNavigatorStyle,   // name lookup; null when unknown
    );

// rail
'chat.navigator.rail.spacing'          int   6
'chat.navigator.rail.ripple'           bool  true
'chat.navigator.rail.encodeLength'     bool  true
// scrubber
'chat.navigator.scrub.liveScroll'      bool  true
'chat.navigator.scrub.timestamps'      bool  true
// palette
'chat.navigator.palette.searchAll'     bool  false
// breadcrumb
'chat.navigator.crumb.autoHide'        bool  true
'chat.navigator.crumb.counter'         bool  true
// outline
'chat.navigator.outline.hideTools'     bool  false
'chat.navigator.outline.showCounts'    bool  true
```

Four schema decisions, each load-bearing:

1. **Flat and namespaced, not nested under the style.** One `PreferenceEntry` per option
   means the existing diff-only persistence gives per-row "modified" tracking and reset
   for free. A nested map would need a custom codec and lose both.
2. **Unknown style ids decode to `null` → default.** A downgrade, or a style removed
   later, can never corrupt the chat pane. This is also what makes phasing safe: the enum
   can ship complete while only some styles are implemented.
3. **Options for non-selected styles stay persisted.** Switching Rail → Outline → Rail
   must return the user to their spacing. The picker must not clear sibling entries.
   *(Verified in the mockup; the naive implementation gets this wrong.)*
4. **The picker is desktop-only, and the spec says so.** `PreferencesController` persists
   to the SharedPreferences key `desktop_settings_overrides` and is used **nowhere** outside
   `lib/desktop/`; mobile's `ui/settings/settings_screen.dart` is hand-built `ListTile`s
   with no `PreferenceEntry` at all. Pretending otherwise would ship a phone that is stuck
   on one style with no off switch. See [§Surface matrix](#surface-matrix).

### Surface matrix
<a id="surface-matrix"></a>

| | Desktop | Mobile |
|---|---|---|
| Style picker + all per-style options | ✅ full, in Settings › Agents & Chat | ❌ not available |
| Effective style | as chosen (default `rail`) | `scrubber`, or `off` |
| On/off | via the `off` style | ✅ a single switch in mobile Settings |

Mobile gets **one** control — *Message navigator: on/off* — because success criterion 4 ("a
user who finds it noisy can turn it off") is not negotiable, and because a phone has
exactly one sensible style anyway (`scrubber`; the rail and breadcrumb are pointer-only).
It is deliberately **not** wired to `PreferencesController`: adopting the desktop
preference system on mobile is a real refactor (the storage key is literally named
`desktop_settings_overrides`) and belongs in its own spec, not smuggled in here.

Instead, shared UI reads a shared provider that each surface overrides at its app root —
the same shape as `RecentModelsController.load(prefs)` in `lib/store/recent_models.dart`,
which SPEC-31 used to make the model picker's Recent list work on mobile:

```dart
// shared: lib/ui/session/navigator/navigator_style.dart
final messageNavigatorStyleProvider = Provider<MessageNavigatorStyle>(
  (ref) => MessageNavigatorStyle.off,   // overridden per surface; off is the safe floor
);

// desktop root: override with the full preference
// mobile root:  override with  enabled ? scrubber : off,  from one SharedPreferences bool
```

Consequences to respect:
- Shared `ui/` never imports `desktop/` — the override direction is what keeps that true.
- A hover-only style is impossible on mobile **by construction**, not by a coercion call
  the next contributor can forget.
- There is still exactly one stored style value on desktop and one bool on mobile; no
  duplicated state, nothing to drift.

### Non-goals

- No new scroll physics, no replacement of `_AnchoredSliverList`, no
  `scrollable_positioned_list` dependency (it cannot preserve SPEC-21 anchoring).
- No jumping to assistant messages (except `palette` with `searchAll` on).
- No cross-session search. No server-side index.
- No pagination protocol — history is already in memory.
- **No port of the desktop preference system to mobile.** Mobile gets one on/off switch;
  full parity needs its own spec.

## Decisions (locked)

| # | Decision | Rationale |
|---|---|---|
| 1 | Ship **all five styles + off**, selectable in **desktop** Settings, each with its own options | User's explicit choice over the trimmed "Rail + Off + density" alternative. Intent is that all five ship; the unknown-id fallback means deferring any of them later needs no migration |
| 1b | Mobile gets **one on/off switch**, not the picker | The desktop preference system does not reach mobile; a full port is its own spec |
| 2 | **Rail** is the desktop default; **scrubber** the mobile default | Rail is hover-only; mobile has no hover |
| 3 | Rail is a **cosy top-right cluster** at fixed spacing, not a proportional full-height gutter | The ripple is only legible when ticks are close; also removes the lazy-list geometry problem entirely |
| 4 | Markers placed by **item index**, never scroll offset | Un-built rows have no offset (SPEC-21) |
| 5 | **Outline** is one of the mutually-exclusive styles | Confirmed: not an independent toggle that coexists with the rail |
| 6 | Jump corrects **inside layout** via `scrollOffsetCorrection`, never from a post-frame callback; never `animateTo` | A post-frame correction paints the wrong frame first — the blink `_RenderAnchoredSliverList` exists to prevent (`transcript_list.dart:126`) |
| 7 | Navigator widgets live in **shared** `ui/session/`, mounted by `chat_transcript.dart` | Mobile/desktop parity by construction |

## Phases

Each phase is independently shippable and ends green (`flutter analyze --fatal-infos`,
`flutter test`, `app/tool/audit.sh`). TDD: the failing test precedes the widget.

**P0 — Spine (blocks everything).**
`userMessageIndicesProvider`; `offsetForIndex` on `_AnchoredSliverList`;
`TranscriptJumper` with the 3-step jump + landing flash; all 11 preference entries
registered; the Settings subsection rendering the picker with only `off` + `rail`
selectable. → *verify:* jump-to-index tests for built, un-built and out-of-range targets;
preference codec round-trip + unknown-id fallback; a transcript-anchoring regression test
proving a jump does not disturb fold state.

**P1 — Rail.** Cluster, ripple, peek, current-tick, 3 options.
→ *verify:* widget tests for tick count/spacing per option, pointer→index mapping at the
cluster edges, ripple disabled under `MediaQuery.disableAnimations`, jump on click.

**P2 — Scrubber.** Unblocks mobile (P0 leaves mobile on `off`). Drag, snap, preview card,
`liveScroll` both ways.
→ *verify:* drag gesture tests; `liveScroll: false` scrolls only on release; mobile
coercion test (`rail` stored → `scrubber` rendered).

**P3 — Outline.** Global fold reusing SPEC-24's expansion machinery; hidden-row counts;
click-to-expand-in-place preserving the clicked prompt's position.
→ *verify:* row visibility per option; the clicked prompt stays under the pointer on exit.

**P4 — Breadcrumb.** Chip, ◀ ▶, counter, auto-hide while streaming/pinned.
→ *verify:* the chip tracks the governing prompt across scroll; hides while streaming.

**P5 — Palette.** Filter, ↑↓ preview, ⏎ jump, `searchAll`; shortcut registered in the
desktop keymap (rebindable in **Shortcuts**, not in this section).
→ *verify:* filter narrowing; `searchAll` widens the corpus to all roles; keyboard-only
traversal.

## Testing

- **Unit:** preference codecs (incl. unknown-id → default); `userMessageIndices` folding;
  jump-offset estimation arithmetic.
- **Widget:** one suite per style, driven by the preference so the tests double as the
  settings integration test. Reuse the SPEC-21 harness.
- **Regression (required):** a jump must not (a) break anchoring, (b) drop fold state,
  (c) leave a stacked animation. Assert `ScrollPosition` settles in ≤ 3 corrections.
- **A11y:** each tick/node carries `Semantics(label: 'your message n of N')`; the rail is
  reachable and jumpable by keyboard even though it is hover-revealed.

## Risks

| Risk | Mitigation |
|---|---|
| **Index-based jump lands imprecisely** on tall un-built rows (code blocks, images) | In-layout `scrollOffsetCorrection` converges within one frame with no painted intermediate; our own ≤5 cap keeps us under `RenderViewport`'s assert, and the landing flash covers a give-up-short landing |
| Jump lands one message off via a botched index transform | Reuse `transcriptChildIndexFinder`'s expression; test with `hasTrailer` both ways and while `outline` is active |
| **Five navigators is five maintenance bills** — tests, mobile story, forever | Phased so each lands green independently; enum + unknown-id fallback means P4/P5 can be deferred or dropped without migration |
| Rail collides with the macOS scrollbar / iOS edge-swipe-back | Rail is a top-corner cluster, not a full-height gutter; scrubber is the touch style and must be tested against edge-swipe |
| Cluster outgrows the corner past ~60 prompts | 60 × 6pt = 360pt still fits; beyond that, cap the cluster height and squeeze spacing — **not** in scope here, but the widget takes a max-height so the fix is local |
| Peek card obscures the newest messages | Card is pinned to the crest and inset; it never covers the composer |

## Open questions

<a id="open-questions"></a>

- **D1 — picker treatment.** Spec assumes the **expanding radio list**. The
  `SegmentedButton` alternative is mocked; it is shorter but hides each style's meaning
  until selected. Confirm before P0.
- **D2 — default tick spacing.** Spec assumes **6pt ("cosy")**. The live dial in
  `mockups/user-message-rail.html` exists to settle this; 6 is my recommendation but it is
  the one number a user will notice immediately.
- **D3 — does `palette` earn its shortcut slot?** It overlaps the (unbuilt) global search.
  Deferring P5 until search exists may be cheaper than shipping two search-ish surfaces.
