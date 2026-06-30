# AGENTS.md

Behavioral guidelines reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** Guidelines bias caution over speed. Trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State assumptions explicitly. Uncertain, ask.
- Multiple interpretations exist, present them - don't pick silently.
- Simpler approach exists, say so. Push back when warranted.
- Unclear, stop. Name confusion. Ask.

## 2. Simplicity First

**Minimum code solves problem. Nothing speculative.**

- No features beyond ask.
- No abstractions for single-use code.
- No "flexibility" or "configurability" unrequested.
- No error handling for impossible scenarios.
- Write 200 lines, could be 50, rewrite.

Ask: "Would senior engineer say overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only own mess.**

Editing existing code:
- Don't "improve" adjacent code, comments, formatting.
- Don't refactor unbroken things.
- Match existing style, even if you'd differ.
- Notice unrelated dead code, mention - don't delete.

Changes create orphans:
- Remove imports/variables/functions YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

Test: Every changed line traces directly to user request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

Multi-step tasks, state brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria enable independent loop. Weak criteria ("make it work") require constant clarification.

## 5. Coding Standards

- Follow TDD: failing test precedes production logic (red → green → refactor).
- Apply SOLID; can't articulate why change doesn't violate one of five, probably does.

---

**Guidelines working if:** fewer unnecessary changes in diffs, fewer rewrites from overcomplication, clarifying questions precede implementation, every behavior change ships with passing test.
