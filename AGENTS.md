# AGENTS.md

## Coding Standards

- Write prose in ASD-STE100 (Simplified Technical English).
  Use active voice and simple tenses.
  One instruction per sentence.
  Keep sentences ≤20 words.
  One word per meaning, no idioms.
  Applies to replies, commits, comments, error messages, UI copy, and docs.
  Code identifiers, commands, and paths stay verbatim.
- Treat speed and memory as features.
  Keep the app and the server light.
  Prefer targeted updates over full rebuilds.
  Keep heavy work off the main thread.
  Measure before you claim a win.
- TDD: write a failing test before production logic (red → green → refactor).
- Apply SOLID; if you can't explain why a change respects each of the five principles, it probably violates one.
- Never leave a verified bug unfixed.
  Fix a confirmed bug even when it sits outside the current diff or task.
  If a fix is unsafe or too large right now, say so explicitly.
  Do not move on in silence.
