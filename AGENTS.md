# AGENTS.md

## Coding Standards

- Write prose in ASD-STE100 (Simplified Technical English): active voice, simple tenses, one instruction per sentence, ≤20 words per instruction, one word per meaning, no idioms. Applies to replies, commits, comments, error messages, UI copy, and docs. Code identifiers, commands, and paths stay verbatim.
- TDD: write a failing test before production logic (red → green → refactor).
- Apply SOLID; if you can't explain why a change respects each of the five principles, it probably violates one.
- Never leave a verified bug unfixed: once a bug is confirmed real, fix it even when it lies outside the current diff or task scope. If fixing it right now is genuinely unsafe or too large, flag it explicitly instead of silently moving on.
