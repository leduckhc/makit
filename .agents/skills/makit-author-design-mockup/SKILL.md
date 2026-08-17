---
name: "makit-author-design-mockup"
description: "Author a new makit design mockup as standalone HTML in mockups/ and verify it renders correctly in a real browser before presenting it."
---
## When to Use
Use when asked to design, explore, or propose makit UI/UX (iOS and/or macOS) and the deliverable should be a reviewable artifact rather than Dart changes. The repo convention is one standalone HTML file per topic in mockups/ (28+ existing files, e.g. activity-ios-macos.html, status-language-ios-macos.html, notice-copy-and-review.html). Do NOT use for changing actual Flutter code, and do not use for auditing built UI against a mockup (that is makit-mockup-vs-built-audit).

## Procedure
1. Ground the design in code first, not in the prompt. Read the relevant spec in docs/specs/, DESIGN.md (tokens), and the actual widgets. Grep for the real enum/state values and their render sites so the mockup uses the app's true vocabulary; the best findings come from contradictions between call sites (e.g. `grep -rn kStatusCaution` vs `grep -c caution status/status_tone.dart`).
2. Copy the house style from an existing mockup (thinking-signal.html is a good small template): dark page #0e0e0e, DESIGN.md dark ramp as CSS vars (--bg #171717, --lowest #121212, --low #1E1E1E, --cont #242424, --high #2E2E2E, --text #F5F5F5, --muted #9E9E9E, --hairline #333333, --primary #4ADE80, --warn #E0A72E, --caution #E07B39, --merged #A371F7), .card with header + .body, uppercase .cap labels, and RECOMMENDED / REJECTED / AS BUILT / FOLLOW-UP badges.
3. Draw Phosphor-Light-style glyphs as inline <symbol> defs on a 24 viewBox with a shared `.i{fill:none;stroke:currentColor;stroke-width:1.45}` class, referenced via <use href='#g-name'>. Use a `.dot` class (not a fill= attribute) for filled sub-shapes, because CSS rules beat presentation attributes. Fake a gear with a dashed-stroke circle.
4. Give EVERY flex child in a .grid an explicit basis: `flex:0 0 320px` for fixed device frames, `flex:1 1 440px;min-width:430px` for the fluid prose column. Omitting it silently stacks the columns (see Pitfalls).
5. Show iOS and macOS side by side for the same idea, drawn to scale (iPhone frame 320px wide with island + status bar + 44pt glass bar + 46pt composer; mac window with traffic lights + 200px sidebar + 24pt title strip + 34pt pane header).
6. Always end with a deltas table: numbered change, exact file path under app/lib/, size, and why - ordered by value per line changed. Also state explicitly what you did NOT change and which spec decisions still stand.
7. Verify in a real browser before presenting (see Verification). Fix every collision and wrap you find, then re-screenshot.

## Pitfalls
- A flex child with no `flex` basis resolves to max-content width. With a long prose paragraph inside, that overflows the row, flex-wrap pushes the sibling to its own line, and the first child then shrinks to full width - so an entire macOS column silently vanishes below the fold and looks 'missing'. This cost a full debug cycle.
- agent-browser/web_browse defaults to a ~342px viewport: run `set viewport 1340 1000` first or every grid stacks. There is no top-level `resize` or `viewport` command.
- `screenshot <selector>` only paints what is inside the current viewport; anything below comes back solid black and looks like a CSS bug. Scroll the element to the top with eval, then take a plain viewport screenshot.
- After `location.reload()` the DOM may not be ready on the next eval call - re-`open` the file rather than trusting the reload.
- Absolutely-positioned annotation labels (.badlbl) and overlay elements inside phone frames collide with composers and list rows. Always eyeball each frame; the collision is invisible in the source.
- Do not cite contrast ratios you have not found in the repo. DESIGN.md and theme.dart carry the measured ones (e.g. #E0A72E is 2.07:1 on light; _statusWarningTextLight #7E5C00 is 5.9:1).
- Check whether the thing being critiqued is already fixed on the current branch before framing it as broken - e.g. `showSnackBar` is 72 on main but 0 on feat/status. Getting this wrong makes the whole document wrong.

## Verification
1. web_browse: `open file:///<abs path>` then `set viewport 1340 1000`.
2. Assert no wrapped grids: eval over `.grid` elements with >1 child and confirm all children share the same rounded bounding-rect `y`. Any mismatch is the flex-basis bug.
3. Assert no broken glyph refs: eval that every `<use>` href resolves via document.querySelector.
4. Assert `document.documentElement.scrollWidth <= window.innerWidth` (no horizontal overflow).
5. Screenshot every card: assign ids with eval, scroll each to the top, take a viewport screenshot, and actually read the image - checking for overlapping labels, text clipped by frame edges, and dead vertical space inside device frames.
6. Confirm the file lands in mockups/ and shows as a new untracked file in git status.
