---
name: "makit-cli-verify"
description: "Verify makit CLI verbs work correctly: test terminal commands, session flows, handoffs, and approval gates using the keyless e2e loop."
---
## When to Use
Use this when: testing makit CLI commands (`ls`, `new`, `send`, `wait`, `approve`, `handoff`, `fork`, `ask`, `tree`), verifying a session flow end-to-end, checking that approval gates work, testing handoff lineage, or validating that the CLI stays in sync with the server after changes.

## Procedure
1. Start the keyless e2e server and keep its PID: `pnpm exec tsx test/e2e-server.ts --mode stub --port 9787 & srv=$!; trap 'kill "$srv" 2>/dev/null' EXIT INT TERM`
2. Set `MAKIT_HOME` to a temp dir and export `MAKIT_CLI_TOKEN` if testing credential persistence
3. Run a verb: `makit ls --json` (expect session list), `makit new -m 'test'` (expect JSON with sessionId)
4. For blocking workflows: `makit run -m 'AWAIT_APPROVAL' --project <pid>` (expect exit 10), then `makit approve <sid>` (expect exit 0)
5. For lineage: `makit new -m 'parent' --project <pid>`, then `makit handoff --to <recipient> --carry 2 'child goal'` (expect tree to show parent→child)
6. For fork: `makit fork <src-id> --project <pid> --branch forked` (only works with codex, refuses with stub)
7. Always clean up: `kill "$srv"` (the trap covers an early failure) and verify this run's `$MAKIT_HOME/control.sock` is gone. Never `pkill -f 'e2e-server.ts'` — it kills the servers other worktrees are running, and it never runs at all when an earlier step exits non-zero.

## Pitfalls
- The stub adapter (`StubAdapter`) only responds to magic prompts (`AWAIT_APPROVAL`, `AWAIT_INPUT`, `FAIL_TURN`, etc.) — real agents won't behave the same
- Port collisions: check `lsof -i :9787` before starting; stale e2e servers can clobber the control socket if they fail to bind WSS
- Approval gates: the stub must emit a real `confirmAction` prompt (not just park the status) — old versions hung here
- `attach` is interactive (reads stdin); pipe commands as `echo 'text' | makit attach <id>` or wrap in `expect`
- `makit fork` requires a turn to have completed (codex builds a rollout); a draft session cannot be forked
- Agent tokens (from `MAKIT_SESSION_ID` + `MAKIT_CLI_TOKEN`) cannot fork, approve, answer, or read unrelated sessions — only humans can
- Lineage cycles are detected and won't hang (the test suite proves this), but a forged parentId to a non-existent session is refused as BadRequest
- `makit run` exits 10 on an approval gate and prints its `{"sessionId"}` line BEFORE it blocks. So capture stdout and the exit code separately; a `cmd1 && cmd2` chain never reaches `cmd2`. Under `set -e`, guard the assignment.

## Verification
1. Run `pnpm test` — 1370 tests passing confirms all CLI verb unit and integration gates are green
2. Run the e2e compose manually: `makit run -m 'hello' --json` outputs a single JSON object with sessionId, then prints the agent's reply
3. Approval flow, as separate commands — `run` prints the sessionId and then exits 10 (`EXIT_APPROVAL` in src/cli/wait.ts), so `&&` would swallow every later step:
   ```sh
   out=$(makit run -m 'AWAIT_APPROVAL' --json); rc=$?   # rc == 10
   sid=$(printf '%s' "$out" | jq -r .sessionId)
   makit wait "$sid" --for approval --timeout 5        # exits 10
   makit approve "$sid"                                # exits 0
   ```
4. Handoff with lineage: `makit tree` shows parent→child hierarchy with 'handed off' annotations and reasons
5. Fork refusal (stub): `makit fork <id> --project <pid>` prints '[makit] stub cannot fork: its back end advertises no native fork' and exits 1
6. Security: an agent token cannot `ls` other sessions or approve/answer a prompt not from its own session (read_access.ts guards all paths)
