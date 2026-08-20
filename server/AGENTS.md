# AGENTS.md — `server/`

Node/TS daemon. ESM only, run through `tsx`. Read the root
[`AGENTS.md`](../AGENTS.md) first; this file adds server facts.

## Commands

```sh
cd server
pnpm install          # npm is blocked by a preinstall guard
pnpm test             # node --test over src/**/*.test.ts, test/**, and the pi extension
pnpm typecheck        # tsc --noEmit for the server AND .pi/extensions/pi-computer-use
pnpm build            # tsc → dist/
pnpm dev -- --no-auth --project <repo>       # watch mode, localhost, no pairing
pnpm exec tsx src/index.ts <pair|qr|devices|sessions|status>
```

Run a single test file while you iterate:
`node --import tsx --test src/session.test.ts`. The full run takes ~5.5 minutes.

## Layout

| Path | Role |
| --- | --- |
| `src/index.ts` | composition root — the only place that builds real dependencies |
| `src/manager.ts` | projects and sessions |
| `src/session.ts` | append-only event log per session |
| `src/protocol.ts`, `src/protocol/` | the wire contract and its codec |
| `src/adapters/` | one adapter per agent: `acp.ts`, `codex.ts`, `stub.ts` |
| `src/ws/`, `src/pairing/`, `src/storage/`, `src/push/` | transport, auth, disk, notifications |
| `test/e2e-server.ts` | real daemon with `StubAdapter`, for keyless e2e |

Tests sit beside the code as `*.test.ts`.

## Rules that bite here

- **Update `src/adapters/stub.ts` whenever you change an adapter.** It implements
  `send()` on its own. So both e2e loops bypass logic you forget to port there.
- **Parse at the boundary.** WS frames, agent stdout, and files become typed
  values in the codec. Never use `as` outside that layer.
- **Register, do not extend a switch.** Add a command or event to its table.
- **Inject side effects.** Transport, clock, storage, randomness, and subprocess
  spawn are parameters. Only `index.ts` news up the real ones.
- **Never fake `PATH` in a passed-in env** to test a missing binary.
  `resolveBinPath` reads the real `process.env.PATH`. Inject the resolver.
- **A test double built by casting an `EventEmitter`** silently drops new
  interface members. Fix the double, not the production code.
- Errors carry `{code, message}` with a shared code enum. Nothing is swallowed
  on a path a user waits on.
- One session is one agent process, at 60–450 MB. Idle sessions close after
  `MAKIT_IDLE_CLOSE_MIN` minutes (default 14 days). Keep that reversible.

## Deeper reading

- Wire protocol and adapter interface: [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) §2 and §5
- Runbook, forges, CLI: [`../docs/DEVELOPMENT.md`](../docs/DEVELOPMENT.md) §1 and §1b
- Threat model: [`SECURITY.md`](./SECURITY.md)
