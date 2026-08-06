# SPEC-40 — Composer footer: space by need

**Status:** Implemented · **Priority:** P2 · **Branch:** `fix/token-usage` (continues)
**Plan:** [`2026-08-06-SPEC-40-PLAN.md`](./2026-08-06-SPEC-40-PLAN.md)
**Mockup:** [`mockups/composer-footer-space.html`](../../mockups/composer-footer-space.html)
**Depends on:** SPEC-26 (unified config options), SPEC-31 (model pill + picker), SPEC-37 *(context usage — the ring that shares this row)*

**Scope:** app + docs. No protocol, server, or adapter change.
*app:* `app/lib/ui/composer/composer.dart` (footer layout + one new parameter),
`app/lib/ui/composer/composer_selectors.dart` (`shortModelLabel`, `ModelConfigPill` label +
tooltip), call sites `app/lib/ui/session/session_screen.dart` and
`app/lib/desktop/chat/desktop_chat_pane.dart`.
*app tests:* `app/test/composer_test.dart` (extended, the granted-constraint probe),
`app/test/composer_footer_space_test.dart` (new, 24 cases),
`app/test/composer_selectors_test.dart` (extended, `shortModelLabel`),
`app/test/session_screen_test.dart` and `app/test/desktop/desktop_chat_pane_test.dart` (extended —
the two call sites), and `app/test/ui/composer/composer_footer_golden_test.dart` with **three**
goldens rather than one: 393 pt (the label whole), 375 pt (the chips yielded and one character
clipped) and codex at 700 pt (the chips kept). Each is a distinct state of the same decision, and
one image cannot show three of them.
*docs:* this spec + plan, the SPEC-37 crowding correction
(`2026-08-05-SPEC-37-context-usage.md`), `docs/specs/README.md`.

`app/lib/desktop/chat/worktree_starter.dart` is **not** in scope: it passes one flexible action
and no trailing control, so the new parameter's default leaves it unchanged. Asserted, not
assumed — see the plan's T5.

---

## Goal

Make the composer footer give each control the width it actually needs, so the model pill is
readable on a phone and the shapes our adapters emit cannot produce a `RenderFlex` overflow.

## The premise SPEC-37 got wrong

SPEC-37 recorded the footer as crowded: *"the footer's pill area is 267 pt, and a 3-config-pill
pi session already needs 279 pt"*, and its mockup drew three pills (`Sonnet`, `Sandbox`,
`Approval`). **No shipping adapter emits that shape**, so the diagnosis was wrong even though the
symptom was real. What the adapters actually advertise, read from the code:

| Agent | `configOptions` | Footer pills | Source |
| --- | --- | --- | --- |
| **pi** via `pi-acp` | `model`, `thought_level` | **1** — `thought_level` is model-scoped, so it folds into the model pill as a chip | `pi-acp/dist/index.js` `buildConfigOptions` |
| **codex** app-server | `model`, `thought_level`, optional `fast`/`model_config` | **1** — all folded | `server/src/adapters/codex.ts` `buildCodexConfigOptions` |
| **ACP agent with modes only** | one synthesised `mode` option | **1**, and it *is* a standalone pill | `server/src/adapters/acp.ts` `buildConfigOptions` |
| legacy `model`/`thinking`/`modes` meta | — (only when `configOptions` is empty) | 3, but no current adapter leaves `configOptions` empty | `session_screen.dart:425-451` |

So **every agent we ship today renders one pill**, and the bug is not crowding — it is that the
one pill is starved.

This is a statement about those three agents, not a guarantee about ACP: `acp.ts:404-405` returns
an agent's supplied `configOptions` **unchanged**, so a third-party ACP agent may advertise any
number of options, including several standalone ones. That shape is supported (D3 keeps it from
overflowing) but unbounded, which is exactly why the deferred `⋯ N` ladder has a measured trigger
rather than being declared unnecessary.

## Evidence

Measured, not estimated. The numbers below were first taken with a throwaway probe widget test on
Flutter 3.44.4 (revision `ad70ec4617`), pumping the real widgets at fixed
`tester.view.physicalSize` widths. They are now reproducible from the repo:
`app/test/composer_footer_space_test.dart` pumps the same four shapes at the same three widths, and
the pre-fix figures in the table can be reproduced from it by moving the ring back into
`footerActions` in its `pumpFooter` helper. Definitions used throughout:

- **label width** — the rendered size of the pill's `Text` widget box (`tester.getSize`), i.e.
  what the user can actually read, after ellipsis.
- **natural width** — the same widget's width when laid out by an unconstrained parent.
- **granted constraint** — the `maxWidth` the footer hands a `footerActions` entry, captured by a
  test-owned `LayoutBuilder` probe passed as that entry. This, not any rendered width, is what
  "starved" means and what the regression test asserts.

At 375 pt (a 375 pt window leaves **263 pt** for the actions row after the composer's padding,
`[+]` and the send slot):

| Session | Label width today | Cause |
| --- | --- | --- |
| pi — `anthropic/Claude Opus 4.6` | **65.5 pt** → `anthropic/Cl…` | starved, and two thirds of what survives is the provider prefix |
| codex — `gpt-5.6-codex` + `256k` chip | **29.8 pt** + 19.8 pt → `gpt…` | starved harder, because the pill also carries chips |
| ACP modes-only — `architect` | 81.5 pt | fits |
| model + thinking + 2 standalone (hypothetical) | **`RenderFlex` overflowed by 18 px**, then 2.2 px; labels at 0 pt | a real exception, not just clipping |

## Root cause

`Composer._buildExpanded` wraps **every** `footerActions` entry in its own equal-share
`Flexible`:

```dart
Expanded(child: Row(children: [
  for (final action in widget.footerActions)
    Flexible(child: Padding(padding: EdgeInsets.only(right: 6), child: action)),
]))
```

`Flexible` defaults to `FlexFit.loose`, so the usage ring — a fixed **36 pt** control
(`kUsageTargetSize`, `context_usage.dart:172`) — is *allowed* half the row, lays out at its
natural size, and **the remaining ~95 pt is not redistributed**. The config pill is capped at
half of a row it is the only real occupant of. Two actions → 50/50; the ring wastes its half.

This is also why the hypothetical four-option row overflows: the pill area is squeezed into half
the row before `ModelConfigFooter` even starts dividing space between its own pills.

## Decisions

**D1 — the footer distributes by need, via an explicit contract.** `Composer` gains
`footerTrailing`, a single **intrinsically sized** trailing control (`Widget?`, default `null`),
laid out after the flexible `footerActions` and before `[+]`/send:

```dart
Row(children: [
  Expanded(child: Row(children: [ ...footerActions (each Flexible) ])),
  if (footerTrailing != null) footerTrailing!,   // natural width
  _buildPlus(), SizedBox(width: 48, child: _buildSendSlot()),
])
```

Singular, not a list: both call sites pass exactly one control (the ring), and a caller that
later needs two can wrap them itself — a list would be speculative plurality.

No extra padding is added around `footerTrailing`: each `footerActions` entry already carries
`Padding(right: 6)` (`composer.dart:536-542`), so that 6 pt is the gap before the trailing
control, and the trailing→`[+]` boundary is flush exactly as `[+]`→send already is. **"total"**
in the criteria below means the width the actions row receives: the composer's own width minus
its horizontal padding, minus `[+]`, minus the 48 pt send slot.

Rejected alternative: inferring which actions are intrinsic (e.g. "everything after the first is
fixed"). That is magic at a distance — a call site reordering its list would silently change
layout. A named parameter says what it means, and the ring genuinely *is* a trailing indicator
rather than a flexible control.

`footerActions` keeps its meaning and default, so `worktree_starter.dart` needs no change.

**D2 — the model pill shows the model's short name, and its tooltip gains the full one.**
`pi-acp` builds option names as `` `${provider}/${name}` `` (`getModelState`), so the pill's most
valuable label spends its first two thirds on a provider the user is not checking mid-turn. The
pill renders the text after the **first** `/` when there is one, and the full string otherwise.

`ModelConfigPill`'s tooltip currently hard-codes the literal `'Model'`
(`composer_selectors.dart:806`), which would make the provider unrecoverable on desktop once the
label is shortened. It becomes the full `configValueName(model, value)`. The picker sheet already
lists full names, so mobile keeps its recovery path.

This is a **display heuristic, not a structural guarantee**: the app renders
`ConfigOptionValue.name` verbatim (`composer_selectors.dart:50-54`), and since ACP options pass
through unchanged, an agent could send a name whose first segment is meaningful. The heuristic is
safe for what we ship, degrades to "shows slightly less" if wrong, and is fully recoverable via
the tooltip and the picker sheet. It does not touch the legacy `ModelInfo.name` path
(`composer_selectors.dart:139-154`), which is consumed separately.

Rejected alternative: a provider allow-list, or stripping only when the prefix matches a known
provider id. Both add a table to maintain for a display-only nicety, and `provider/model` is the
near-universal convention (`openai/gpt-5.6`, `anthropic/claude-opus-4.6`, `meta-llama/Llama-3`).

**D3 — no overflow for supported widths and known shapes; degradation is by ellipsis.** D1 makes
the pill area `Expanded`, and every label inside is already `Flexible` + `TextOverflow.ellipsis`,
so a narrow row degrades to short labels rather than an exception. This is **not** an
"any width" guarantee — `[+]`, the send slot, the gaps and the trailing control have a nonzero
combined minimum, so a sufficiently narrow parent must still overflow. The guarantee is: **no
overflow at ≥ 320 pt for the three shapes our adapters emit**, which is what the tests assert.

**Found while implementing:** D1 alone left the hypothetical four-option shape overflowing by
**4.7 px at 320 pt** — four pills plus their chips exceed the row whatever the division, because
each pill has an unshrinkable minimum. D5 (below) closed it: with the chips yielding, all four
shapes are clean at 320, 375 and 700 pt. The intermediate state was committed as a failing
expectation first, so the guarantee is the test's, not the prose's.
There is no width constant, no `MediaQuery` check and no breakpoint — the composer lives inside
desktop split panes, where screen width lies about the space available.

**D5 — read-only chips yield to the model name, all or nothing.** Built, not deferred: with both
chips shown, codex rendered `gpt-5.6…` at 375 pt — roughly half its own model name — and the
four-option shape still overflowed at 320 pt. The chips summarise model-scoped options (SPEC-31)
and are pure decoration: every value they show is a live control in the picker sheet. So
`ModelConfigPill` measures what the label wants (`TextPainter` on its own style) plus each chip's
own width, and drops **all** chips when that exceeds the width it was granted.

All-or-nothing because dropping chips one at a time reads as though an option were *unset* rather
than hidden. An unbounded constraint (a shrink-wrap measuring pass) keeps them — there is no width
to fit into yet. A wide pane therefore keeps every chip: nothing is hidden for free.

This is the mockup's ladder step 2, and it moved out of the non-goals during implementation because
the trigger the spec had already written down — *"an agent that ships a session shape which
overflows or ellipsizes a required label"* — turned out to be met by **codex**, measured at 49 %.

**D4 — the row is never scrolled and the ring is never hidden.** Scrolling would push the ring
off-screen; the ring's whole purpose is being glanceable without a tap (SPEC-37 §Why a ring).

## Non-goals

- **Collapsing standalone pills into a `⋯ N` overflow pill** (the mockup's ladder step 3).
  Deliberately not built: with D1 and D5 in place every shape we ship — and the hypothetical
  four-option one — fits at 320 pt with a readable model name, so there is nothing left for a
  collapse to earn. **Trigger to build:** a session shape that still overflows, or that ellipsizes
  the model label below 95 % at 375 pt, once the chips have already yielded.
  (Ladder step 2, hiding the chips, *was* built — see D5. Its trigger fired during implementation.)
- Redesigning the picker sheets or `ModelPickerMenu` (SPEC-31 owns those).
- The legacy `ComposerModelSelector`/`ThinkingSelector`/`ModeSelector` trio. It is unreachable
  with today's adapters (all populate `configOptions`), so folding it into a single pill would be
  work for a code path nothing exercises. Flagged, untouched — it still benefits from D1, because
  the change is in the row above it.
- Any change to `SessionConfigOption`, the `configOption` action, or an adapter.
- Correcting SPEC-37's `32 pt`/`36 pt` discrepancy beyond this spec's own text: the control is
  36 pt in code, SPEC-37 describes it as 32 pt in prose. Recorded here; the code is the truth and
  is not changed.

## App surface

Nothing new renders. The same widgets receive different constraints, and one label gets shorter:

- `Composer.footerTrailing` — new `Widget?`, default `null`. **No other production change**: the
  flex regression is measured by a test-owned `LayoutBuilder` probe passed as a `footerActions`
  entry, so no key or hook is added to production code for testability.
- `shortModelLabel(String)` — new pure helper in `composer_selectors.dart`, used by
  `ModelConfigPill` for its label only.
- `ModelConfigPill` gains a `LayoutBuilder` and measures its own text, so it can drop the chips
  when the label would not fit (D5). Its `_chips` now return `(widget, width)` records rather than
  bare widgets, which is what makes the decision possible in a single layout pass.
- `session_screen.dart` and `desktop_chat_pane.dart` move `ContextUsageButton` from
  `footerActions` to `footerTrailing`.

## Acceptance criteria

At 320, 375 and 700 pt, for all four session shapes in the evidence table:

1. **No `RenderFlex` overflow** at 320, 375 and 700 pt for all four shapes, including the
   hypothetical four-option one — `tester.takeException()` is null. D1 got three shapes there; the
   fourth needed D5.
2. **A trailing control does not reserve flex.** Measured by a **test-owned probe** passed as the
   single `footerActions` entry — a `LayoutBuilder` that records the `maxWidth` it is granted.
   With the ring as a second `footerActions` entry it receives ~50% of the row; with the ring in
   `footerTrailing` it receives `total − 36 − 6` (±1 pt), where 36 pt is `kUsageTargetSize` and
   6 pt is the action's own trailing padding. This is the regression guard, and being a granted
   *constraint* rather than a rendered size it is independent of all text metrics.

   Note what must **not** be measured: the collective `Expanded` actions region. That region is
   full-width in both layouts and in fact gets *narrower* (by 42 pt) when the ring moves out, so
   asserting on it would fail while the fix is correct.
3. **The model label reads as a model, not a provider.** Measured, and narrower than the first
   draft claimed:
   - at **393 pt** (iPhone 15/16/17) pi's `Claude Opus 4.6` renders **whole** —
     `didExceedMaxLines` false, width equal to its natural width;
   - at **375 pt** (SE/mini) it clips a single character: a 15-character name wants 187.5 pt and
     the row can grant 183 pt even with the chips hidden. The remaining 4.5 pt would have to come
     from the avatar, `[+]`, send or the ring — none of which this spec may shrink. So the
     criterion there is **≥ 95 % of the label visible**, i.e. `Claude Opus 4…`, where it used to
     read `anthropic/Cl…` at 18 %;
   - codex's `gpt-5.6-codex` renders **whole at 375 pt**, which needed D5: with both its chips
     shown it got 49 % of its own name;
   - on the real `SessionScreen` (a 377 pt composer inside a 393 pt window) the label gets **99 %**
     of what it wants, against **47 %** before the fix. That ratio is the call-site regression
     guard, and it is the one number that proves the wiring, not just the widget.

   Asserted as shares and as "no ellipsis", never as a pt floor: the pill is `mainAxisSize.min`, so
   the label correctly occupies its natural width, and a floor would fail on any font change.
   **Owner: T4/T5.** The layout work (D1) is proven separately by criteria 1, 2 and 5 with the
   **long** label in place — otherwise a shorter string could make a starved layout look fixed.
4. The ring is present and 36 pt in every case — never squeezed, never hidden. Every fixture must
   therefore seed a non-null `sessionUsageProvider` with both halves of the ratio:
   `ContextUsageButton` returns `SizedBox.shrink()` until usage *and* `fraction` are known
   (`context_usage.dart:204-208`), so an unseeded test would measure a 0 pt ring and pass
   vacuously. On mobile the fixture must also focus the composer, because the footer only renders
   when `alwaysExpanded || _isFocused` (`composer.dart:355`).
5. At 700 pt every pill of a **shipping** shape renders at its natural width: each label's width
   equals the same label's width when pumped in an unconstrained parent (±1 pt). The hypothetical
   four-option shape is excluded because its pills' natural widths together exceed even a 700 pt
   row, so they share it — D3's intended degradation. What is asserted for that shape is that the
   row stays legal and **every control is still rendered**; whether a given label happens to clip at
   exactly 700 pt is font-dependent and deliberately not asserted.
6. `ModelConfigPill`'s tooltip is the full `provider/name`, while its label is the short form.
7. The chip gate measures what will actually be rendered: the ambient `TextScaler`, the merged
   `DefaultTextStyle`, the accessibility bold-text setting and the ambient locale. Accessibility
   scaling therefore makes the chips yield **sooner**, not later — measuring at 1.0 while the label
   renders at 2.4× would keep the chips and clip the name for exactly the users least able to absorb
   it. The scaler is asserted by a widget test; the bold-text path is implemented but **not**
   asserted, because the test font's metrics do not vary with weight, and a test that cannot fail is
   worse than an honest gap.

## Tests

| Layer | Test |
| --- | --- |
| `composer_test.dart` | `footerTrailing` lays out after `footerActions`, at natural width, and does **not** reserve flex: a test-owned `LayoutBuilder` probe passed as the single action is granted ~50% of the row when the ring is a second action, and `total − 36 − 6` when the ring is trailing (criterion 2). The collective `Expanded` region is deliberately **not** asserted on — it is full-width in both layouts and gets 42 pt narrower when the ring moves out |
| `composer_footer_space_test.dart` (new, 24 cases) | the evidence table, table-driven: four shapes × three widths → no exception (criterion 1), every control still rendered, ring at 36 pt (4), natural widths at 700 pt for the shipping shapes (5), plus the chip-gate cases (7: unbounded constraints keep the chips, text scaling makes them yield). Written **after** the layout fix as characterisation/regression coverage, because its fixtures use `footerTrailing`; the RED that drives the fix is `composer_test.dart`'s probe. Extended by T4 with criterion 3 |
| `session_screen_test.dart` / a desktop-pane test | the **call sites** are wired: the real screen's footer puts the ring in the trailing slot, so a regression that fixes `Composer` but forgets a call site fails (this is what makes T5 necessary rather than optional) |
| `composer_selectors_test.dart` | `shortModelLabel` — strips the first segment, leaves a slash-free name alone, pins the degenerate cases, never returns empty; and the pill renders short label + full tooltip |
| `context_usage_test.dart` | unchanged — the ring's own behaviour is untouched |
| goldens | three states **after** the change — 393 pt (label whole), 375 pt (chips yielded, one character clipped), codex at 700 pt (chips kept). A golden stores one image each, so three states need three; the before/after comparison lives in the PR diff |
