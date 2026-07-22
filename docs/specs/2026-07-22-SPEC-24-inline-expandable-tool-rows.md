# SPEC-24 — Inline expandable tool rows (thinking-line model for tool calls)

**Status:** Proposed · **Priority:** P2 · **Branch:** `feat/inline-tool-rows`
**Scope (app-only):** `app/lib/ui/session/{tool_call_card.dart,tool_renderers.dart,chat_transcript.dart,session_screen.dart}`, `app/lib/desktop/chat/desktop_chat_pane.dart`, `app/lib/app/router.dart`; delete `app/lib/ui/session/tool_call_detail_screen.dart`. No server/protocol changes. Behavior-preserving except for the tool-row presentation described below.

---

## Goal

Render tool executions (bash, edit, read, write, grep, memory, skill, …) in the
chat transcript as **collapsed one-liners that expand inline** — exactly the
interaction model already used for reasoning traces (`ThinkingLine`) — instead
of large tappable cards that navigate to a **separate full-screen detail page**.

Collapsed, each tool is a single row:

```
[terminal] Ran cd /home/xx && pnpm server …      ✓
[edit]     Edited lib/foo.dart                     ✓
[read]     Read lib/main.dart                       ✓
[skill]    Skill cavemen                            ✓
[memory]   Memory saved                             ⟳
```

Tapping the row expands it in place to show the tool's detail body
(command+output, color-coded diff, file content, skill description, memory
in/out). Long bodies show ~20 lines and scroll internally. Applies identically
to **iOS** (`SessionScreen`) and **macOS** (`DesktopChatPane`) because both
share `chatItemWidget`.

## Background — current state

- `chatItemWidget` (`chat_transcript.dart:46-55`) maps a `ToolCallItem` to
  `ToolCallCard(item, onTap: () => onOpenTool(item))`.
- `ToolCallCard` (`tool_call_card.dart`) is a bordered `surfaceContainer` card:
  risk icon + monospace name + status glyph + trailing `caretRight`. Tapping
  fires `onOpenTool`.
- `onOpenTool` navigates to a **full-screen** `ToolCallDetailScreen`:
  - mobile: `context.go('/session/<id>/tool/<callId>')`
    (`session_screen.dart:120-122`; route in `router.dart:49-54`).
  - desktop: `Navigator.push(MaterialPageRoute(...))`
    (`desktop_chat_pane.dart:145-154`, `_openToolDetail`).
- `ToolCallDetailScreen` (`tool_call_detail_screen.dart`) looks up the item and
  delegates to `rendererFor(tool)?.detail(...)` or `genericToolDetail(...)`.
- Each `ToolRenderer.detail(context, item)` returns a **full `Scaffold`**
  (`ToolDetailScaffold` = `AppBar` + `ListView` of `ToolSection`s), or, for
  `askUserQuestion`, its own `Scaffold`.
- `ThinkingLine` (`chat_transcript.dart:60-140`) is the target interaction: a
  greyed one-liner (brain icon + ellipsized text); tap toggles to the full
  (selectable) text; tapping the leading icon collapses again.
- `flutter_highlight` is already a dependency and already used for markdown code
  blocks (`chat_message.dart` `_CodeBlock`, `HighlightView` +
  `atomOneDarkTheme`/`githubTheme`).

## Design

### Decision: inline-only

Inline expansion **fully replaces** the full-screen detail. `ToolCallDetailScreen`,
its `/tool/:callId` route, and the desktop `_openToolDetail` push are removed.
`chatItemWidget` drops its `onOpenTool` parameter.

### Renderer API: `detail` (Scaffold) → `body` (inline sections)

Refactor `ToolRenderer` so each renderer produces **inline content** plus a
**one-line summary**, instead of a full screen:

```dart
abstract class ToolRenderer {
  String get name;
  String get displayName => name;
  IconData get icon;

  /// Collapsed one-liner shown in the transcript, e.g. "Ran <cmd>",
  /// "Edited <path>", "Read <path>". Default: [displayName].
  String summaryLine(ToolCallItem item) => displayName;

  /// Expanded body: the same [ToolSection]s as today, minus the Scaffold.
  List<Widget> body(BuildContext context, ToolCallItem item) =>
      genericToolBody(context, item);
}
```

- `ToolDetailScaffold` is **removed** (dead once inline-only). `ToolSection`,
  `MonoText`, `ParamRow`, `DiffText`, `DiffLineRow`, `computeLineDiff`,
  `extractToolResultText`, `valueString` are all **kept and reused unchanged**.
- `genericToolDetail` → `genericToolBody` returning `List<Widget>` (the
  `Arguments`/`Output` sections without the scaffold).
- The `askUserQuestion` renderer returns its list of question/answer widgets as
  a body (no inner `Scaffold`/`ListView.separated`; the outer expander scrolls).

Per-renderer `summaryLine` (collapsed) and `label` (expanded verb):

| tool   | collapsed `summaryLine`                             | expanded `label` |
|--------|-----------------------------------------------------|------------------|
| bash   | `Ran <command>` (first line, whitespace-collapsed)  | `Ran`            |
| edit   | `Edited <path>`                                      | `Edited`         |
| write  | `Wrote <path>`                                       | `Wrote`          |
| read   | `Read <path>`                                        | `Read`           |
| grep   | `Grep <pattern>`                                     | `Grep`           |
| memory | `Memory <action>` or `Memory`                        | `Memory`         |
| skill  | `Skill <name>` or `Skill`                            | `Skill`          |
| other  | `displayName` (raw tool name)                        | `displayName`    |

When expanded, the header shows only `label` (the verb) because the full
command/path/argument is already visible in the body; collapsing restores the
full `summaryLine`.

### Row identity (state preservation)

`ToolCallCard` (and `ThinkingLine`) are stateful (expanded/collapsed). In the
reversed transcript `ListView.builder`, new items shift positions, so each
surface **keys the ListView child** by item identity via `KeyedSubtree(key:
chatItemKey(item), …)` (`tool-<callId>` for tool calls, `seq-<seq>` otherwise).
Keying the leaf widget alone is insufficient — reconciliation happens at the
ListView-child level (the `transcriptRow`/`Center` wrapper), so the key must live
there or expand state migrates/resets to the wrong call as items stream in.

### Code blocks + syntax highlighting

Add a reusable `ToolCodeBlock` widget in `tool_renderers.dart` mirroring the
existing markdown `_CodeBlock` look (rounded `surfaceContainer`/dark panel,
`outlineVariant` border, horizontal scroll, monospace `HighlightView` with
`atomOneDarkTheme`/`githubTheme`, and a copy button reusing the existing
pattern). Used for:

- **bash**: `Command` section → `ToolCodeBlock(command, language: 'bash')`;
  `Output`/`Error` → `ToolCodeBlock(output, language: 'plaintext')`.
- **read** / **write**: file content → `ToolCodeBlock(content, language:
  _languageForPath(path))` where `_languageForPath` maps a small, explicit
  extension→language table (`.dart`→dart, `.ts/.tsx`→typescript, `.js`→
  javascript, `.py`→python, `.json`→json, `.sh`→bash, `.yaml/.yml`→yaml,
  `.md`→markdown, else `plaintext`).
- **grep** / **generic output**: `ToolCodeBlock(..., language: 'plaintext')`.

Trade-off (accepted): `HighlightView` renders `RichText`, so code inside a
`ToolCodeBlock` is **not** text-selectable; the copy button covers copy needs
(same as today's markdown code blocks). `ParamRow` values and diff rows keep
using `SelectableText`.

### Collapsed → expanded row (`ToolCallCard`)

Rework `ToolCallCard` into a `StatefulWidget` that mirrors `ThinkingLine`
(keep the class name — single import site — even though it's no longer a
"card"). No `onTap`/navigation param.

- **Header (both states):** an `InkWell(onTap: toggle)` over the full row —
  `[risk-tinted tool icon]  <summaryLine, maxLines:1, ellipsis>  <status>
  [rotating disclosure caret]`. The caret sits at the trailing (right) edge,
  points right when collapsed and rotates down when expanded
  (`AnimatedRotation`). Tapping anywhere on the header toggles, in both states,
  with `Semantics(button, expanded, onTapHint)` for a11y. `<status>` is the
  existing running-spinner / `checkCircle` / `warningCircle` glyph.
- **Expanded:** the header (above) followed by the renderer `body(...)`, wrapped
  in a **bounded, internally-scrollable** region:
  `ConstrainedBox(maxHeight: kToolExpandedMaxHeight)` → `Scrollbar(controller)` →
  `SingleChildScrollView(controller)`. The body owns no toggle gesture, so its
  code blocks stay scrollable/copyable. When shorter than the cap it renders at
  natural height.
- `kToolExpandedMaxHeight` ≈ 340 (≈ 20 lines at the 12.5px mono line height plus
  section chrome), defined in `chat_metrics.dart` next to the other tokens.

Nested vertical scroll inside the reversed transcript `ListView` is acceptable:
the inner `SingleChildScrollView` only scrolls when its content overflows the
cap; otherwise the parent handles the gesture.

## Work items

### W1 — Renderer API refactor (`tool_renderers.dart`)
- Replace `ToolRenderer.detail` with `body(...)` + `summaryLine(...)`; convert
  every built-in renderer (`read`, `write`, `edit`, `bash`, `grep`,
  `askUserQuestion`) to return `List<Widget>` bodies and a summary.
- Delete `ToolDetailScaffold`; rename `genericToolDetail` → `genericToolBody`
  (returns `List<Widget>`).
- Add `ToolCodeBlock` + `_languageForPath`; route bash/read/write/grep/generic
  code through it.
- Add `_MemoryRenderer` (icon `PhosphorIconsLight.brain`/`floppyDisk`; body =
  args in/out + result) and `_SkillRenderer` (icon `graduationCap`/`bookOpen`;
  body = skill name + full description/args), registered in `toolRenderers`.

### W2 — Inline row (`tool_call_card.dart`)
- Convert `ToolCallCard` to a stateful expandable row per the design; drop
  `onTap`. Keep risk-icon/status logic.

### W3 — Wire-through + row keying (`chat_transcript.dart`, `session_screen.dart`, `desktop_chat_pane.dart`)
- `chatItemWidget`: remove `onOpenTool`; `ToolCallItem() => ToolCallCard(item: item)`.
- Add `chatItemKey(ChatItem)`; both surfaces wrap each ListView child in
  `KeyedSubtree(key: chatItemKey(item), …)` so inline expand/collapse state
  stays with the right call across reorders.
- `session_screen.dart`: drop the `onOpenTool:` argument (remove the `context.go`
  tool route usage).
- `desktop_chat_pane.dart`: drop `onOpenTool:`; delete `_openToolDetail` and the
  `tool_call_detail_screen.dart` import.

### W4 — Remove the full-screen detail
- Delete `tool_call_detail_screen.dart`.
- `router.dart`: remove the `tool/:callId` `GoRoute` and its import.

### W5 — Tests
- `tool_renderers_test.dart`: retarget `.detail(...)`-based widget tests to pump
  the new `body(...)` (wrapped in a minimal `Scaffold`); assert section titles
  and (for code sections) `find.byType(ToolCodeBlock)`/`HighlightView` +
  copy-able text rather than exact `find.text(code)`; keep `rendererFor`,
  display-name, diff, and `extractToolResultText` tests as-is; add
  `summaryLine` cases and memory/skill `rendererFor` cases.
- `chat_transcript_test.dart`: update `chatItemWidget(item)` calls (no
  `onOpenTool`); add a test that a collapsed `ToolCallCard` expands its body on
  tap and shows a bounded scroll region.

## Non-goals

- No server/protocol/`ToolCallItem` model changes; `summary`, `output`,
  `deltas`, `details`, `risk` are consumed as-is.
- No new tool *data* — only presentation. `memory`/`skill` renderers are
  best-effort over whatever args the mirrored agent emits; unknown tools still
  fall back to `genericToolBody`.
- No change to the ask-user **elicitation** modal (`AskWizard`), which is a
  separate modal over the router, not a transcript item. Only the persisted
  `askUserQuestion` tool result (an ordinary `ChatItem`) uses the inline body.
- No copy/selection of highlighted code beyond the code-block copy button.

## Testing
- `flutter analyze --no-pub --fatal-infos` clean; `flutter test --no-pub` green;
  `app/tool/audit.sh` passes.
- Widget: collapsed tool row shows icon + summary + status and **no** trailing
  caret/navigation; tapping expands the body in place; tapping the leading icon
  collapses.
- Widget: an over-long body is capped at `kToolExpandedMaxHeight` and scrolls
  internally (a `Scrollbar`/`SingleChildScrollView` is present); a short body
  is not scrollable.
- Widget: expanding one tool call then appending another does **not** migrate or
  reset the first call's expanded state (keyed-row regression test).
- Renderer bodies keep prior content (bash Command/Output, edit diff rows +
  `DiffText`, read/write content, grep results, generic args-as-rows).
- Both surfaces compile without `onOpenTool`; no references to
  `ToolCallDetailScreen` or the `/tool` route remain (`git grep`).

## Risks
- **Syntax highlighting loses text selection** inside code blocks — mitigated by
  the copy button; matches existing markdown code-block behavior.
- **Nested scroll gesture conflict** in the reversed transcript — mitigated by
  only scrolling on overflow and bounding height; fall back to a fixed-height
  non-scroll clamp if touch gestures fight on iOS.
- **Test churn**: several `.detail`-based finds relied on exact code text that
  `HighlightView` now splits into spans — W5 retargets them to structural finds.
- **`summaryLine` verbosity** for multi-line bash commands — collapse whitespace
  and ellipsize to keep one line.
```
