# SPEC-04 — Multiplexer adapter layer + herdr

**Status:** implemented · **Depends on:** none (foundation) · **Blocks:** SPEC-05

## Goal

Introduce a small, **pluggable multiplexer abstraction** so pino can spawn and
manage `pi` processes inside a terminal multiplexer the user can attach to.
Ship a working **herdr** implementation now; keep the seam clean so **tmux** and
**cmux** can be added later without touching callers.

## Why

Consensus #4/#5: sessions should live in a pane the user can attach to in the
terminal. herdr is the current daily driver; tmux/cmux are "someday."

## Scope

### In
- `MultiplexerAdapter` interface (below) + a registry keyed by name.
- `HerdrAdapter` implementing it via the herdr CLI (verified verbs):
  - create pane: `herdr pane split <anchor> --direction down --cwd <cwd>
    --no-focus` → returns new `pane_id` (parse JSON result).
  - run a command in a pane: `herdr pane run <pane_id> "<cmd>"`.
  - close a pane: `herdr pane close <pane_id>`.
  - (helpers) `herdr pane list` (existence/health), `herdr pane rename <id>
    <label>`.
- Config: which multiplexer is active (default `herdr`), and how to pick the
  anchor pane / target workspace (see open questions). Read from
  `~/.pino/config.json` or env (`PINO_MUX=herdr`).
- **Background/unfocused** creation is the default (`--no-focus`).
- Capability reporting: adapter advertises whether it's available on this host
  (e.g. `herdr` binary present + inside/adjacent to a herdr instance).

### Out
- Deciding *when* to spawn a session in a pane, correlation with a pino session,
  and auto-close-on-end — that's **SPEC-05** (this spec only provides mechanism).
- tmux/cmux implementations — interface must accommodate them; do not build.

## Interface (freeze — SPEC-05 depends on it)

```ts
// server/src/mux/adapter.ts
export interface PaneHandle {
  readonly mux: string;      // "herdr"
  readonly paneId: string;   // e.g. "w7:pS"
}

export interface SpawnPaneOpts {
  cwd: string;
  command: string;           // full shell command to run (e.g. the pi launch)
  label?: string;            // pane title, e.g. "pino: <session name>"
  focus?: boolean;           // default false (background)
}

export interface MultiplexerAdapter {
  readonly name: string;
  /** Is this multiplexer usable on this host right now? */
  isAvailable(): Promise<boolean>;
  /** Create a (background) pane and run `command` in it. */
  spawnPane(opts: SpawnPaneOpts): Promise<PaneHandle>;
  /** Best-effort: relabel a pane. */
  setLabel?(handle: PaneHandle, label: string): Promise<void>;
  /** Close/kill a pane. Idempotent — no throw if already gone. */
  closePane(handle: PaneHandle): Promise<void>;
  /** True if the pane still exists. */
  paneExists(handle: PaneHandle): Promise<boolean>;
}

// server/src/mux/registry.ts
export interface GetMultiplexerOpts {
  exec?: ExecFn; // injectable for tests
}
export function getMultiplexer(
  name?: string,
  opts?: GetMultiplexerOpts,
): MultiplexerAdapter | undefined;
```

## Design
- New dir `server/src/mux/`: `adapter.ts` (types), `herdr.ts` (`HerdrAdapter`),
  `registry.ts` (name → adapter; default herdr), `index.ts`.
- `HerdrAdapter` shells out via `execFile("herdr", [...])`, parses JSON from
  `herdr pane split` (`result.pane.pane_id`). Robust to non-JSON/errors — throw a
  typed `MuxError` the caller can handle.
- Keep it pure mechanism: no pino-session knowledge here.

## Acceptance criteria
- [x] `HerdrAdapter.isAvailable()` returns true when herdr is reachable and the
      configured anchor pane exists, false when `herdr` is missing or the anchor
      is not usable.
- [x] `spawnPane({cwd, command:'echo hi; sleep 30', label:'pino: test'})` creates
      a **new, unfocused** pane running the command; `paneExists` is true;
      `setLabel` shows the label; `closePane` removes it and is safe to call twice.
- [x] Anchor/workspace selection documented and deterministic (see Decisions).
- [x] `getMultiplexer()` returns herdr by default; `getMultiplexer('tmux')`
      returns undefined (not implemented) without crashing.
- [x] Unit tests: adapter with a **fake exec** (inject the command runner) —
      assert exact herdr argv for split/run/close/rename, JSON parse of pane_id,
      idempotent close, MuxError on failure. `pnpm test` green, `pnpm typecheck`
      clean.

## Decisions (formerly open questions)
- **Anchor pane:** `PINO_MUX_ANCHOR` env or `config.json` key `mux.anchor`
  (default `"pino"` as a setup label). New panes split from that anchor pane id
  so sessions don't fragment the user's active layout. `HerdrAdapter.isAvailable()`
  returns false until the configured anchor appears in `herdr pane list`; callers
  can then fall back instead of failing on `pane_not_found`.
- **Exec injection:** yes — `HerdrAdapter` accepts an optional `exec` fn in its
  constructor (defaults to `execFile`). Keeps the adapter testable without a real
  herdr binary.
- **Config file shape:** `~/.pino/config.json` → `{ "mux": { "name": "herdr", "anchor": "pino" } }`.
  Env `PINO_MUX` / `PINO_MUX_ANCHOR` override file values. `PINO_MUX=off` disables
  the registry (returns `undefined` — used by SPEC-05 fallback).
- **Split failure cleanup:** if `pane run` fails after a successful split, the
  adapter closes the orphan pane before rethrowing `MuxError`.
- **`setLabel` optional:** not every future mux may support rename. `HerdrAdapter`
  implements it; SPEC-05 title updates must use `adapter.setLabel?.(...)` so
  tmux/cmux stubs without rename don't break. Initial label is still passed via
  `spawnPane({ label })` (best-effort inside the adapter).
