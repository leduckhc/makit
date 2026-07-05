# AGENTS.md

Behavioral rules cut LLM coding mistakes. Merge with project instructions as needed.

**Tradeoff:** Rules bias caution over speed. Trivial task, use judgment.

## 1. Think Before Coding

**No assume. No hide confusion. Surface tradeoffs.**

Before code:
- State assumptions. Unsure, ask.
- Multiple readings, show them - no silent pick.
- Simpler way exist, say. Push back when right.
- Unclear, stop. Name confusion. Ask.

## 2. Simplicity First

**Min code solve problem. Nothing speculative.**

- No features beyond ask.
- No abstractions for single-use code.
- No "flexibility" or "configurability" unrequested.
- No error handling for impossible cases.
- Wrote 200 lines, could be 50, rewrite.

Ask: "Would senior engineer call overcomplicated?" Yes, simplify.

## 3. Surgical Changes

**Touch only what must. Clean only own mess.**

Editing existing code:
- No "improve" adjacent code, comments, formatting.
- No refactor unbroken things.
- Match existing style, even if you'd differ.
- Spot unrelated dead code, mention - no delete.

Changes make orphans:
- Remove imports/variables/functions YOUR changes made unused.
- No remove pre-existing dead code unless asked.

Test: every changed line trace to user request.

## 4. Goal-Driven Execution

**Define success. Loop until verified.**

Turn tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

Multi-step task, state brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong criteria = independent loop. Weak criteria ("make it work") = constant clarification.

## 5. Coding Standards

- TDD: failing test before production logic (red → green → refactor).
- Apply SOLID; can't say why change no violate one of five, probably does.

---

**Rules working if:** fewer needless changes in diffs, fewer rewrites from overcomplication, clarifying questions before code, every behavior change ships with passing test.