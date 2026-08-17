# AGENTS.md

Facts and rules for coding agents. Humans start at [`README.md`](./README.md).
Read this file fully before you change code. The nearest `AGENTS.md` wins:
`app/` and `server/` each add their own.

## What makit is

makit drives a coding agent on your desktop from your phone.

- `server/` — Node/TS daemon. Spawns `pi`, `codex`, or `claude-code`, and serves
  a cert-pinned WebSocket over a Tailscale tailnet.
- `app/` — Flutter client for iOS and macOS.
- `docs/` — architecture, runbook, UX, and specs.
- `.agents/skills/` — procedures you should load before you repeat a workflow.

## Commands

Toolchain: Node ≥22.13, pnpm ≥11 (`npm install` is blocked by a guard),
Flutter ≥3.38 (repo runs 3.44.9), plus `rustup` and CocoaPods for app builds.

```sh
# server
cd server && pnpm install
pnpm test           # node --test, ~5.5 min for the full run
pnpm typecheck      # tsc --noEmit for server + the pi extension
pnpm dev -- --no-auth --project <repo>    # auto-reload, localhost, no pairing

# app
cd app && flutter pub get --enforce-lockfile
flutter analyze     # the audit gate adds --fatal-infos
flutter test
flutter run -d macos                      # FakeServer, no server needed

# full stack, no API key (StubAdapter)
./app/tool/e2e.sh --mode=stub             # ~50s + Xcode build
./app/tool/e2e-desktop.sh                 # macOS control plane
cd app && tool/audit.sh                   # the pre-handoff gate
```

While iterating, run only the affected test files. Run the full suite once
before you hand off.

## Definition of done

1. A test that failed first now passes.
2. `pnpm typecheck` and `flutter analyze` are clean.
3. `./app/tool/e2e.sh --mode=stub` is green when the change crosses the
   app ↔ server boundary.

## Standards

- **TDD.** Write a failing test before production logic (red → green → refactor).
  A bug starts as a failing reproduction.
- **SOLID.** If you cannot say why a change respects each of the five
  principles, it probably violates one.
- **Simplicity first.** Write the minimum code that solves the problem. Add no
  speculative abstraction and no unrequested option.
- **Surgical changes.** Touch only what the change needs. Match the existing
  style. Do not refactor unrelated code.
- **Never leave a verified bug unfixed.** Fix a confirmed bug even when it sits
  outside the current task. If a fix is unsafe or too large now, say so.
  Do not move on in silence.
- **Speed and memory are features.** Keep the app and the server light. Prefer
  targeted updates over full rebuilds. Keep heavy work off the main thread.
  Measure before you claim a win.
- **Write prose in ASD-STE100** (Simplified Technical English). Use active voice
  and simple tenses. One instruction per sentence. Keep sentences ≤20 words.
  One word per meaning, and no idioms. This covers replies, commits, comments,
  error messages, UI copy, and docs. Code identifiers, commands, and paths stay
  verbatim.

[`docs/ENGINEERING.md`](./docs/ENGINEERING.md) §1 explains the reasoning, and
adds contract-first parsing, DI seams, YAGNI, and observability.

## Conventions

- Commits use Conventional Commits with a scope: `fix(app): …`, `feat(server): …`,
  `docs: …`. Name the user-visible outcome. Add the spec slug when a spec exists,
  as `(SPEC-cli-as-client)`.
- Specs carry a clock, not a counter. Create one with `scripts/new-spec.sh "a
  short title"`, and refer to it by slug. Never hand-write the timestamp, and
  never claim a spec number — numbers clashed six times across parallel
  worktrees. See [`docs/specs/README.md`](./docs/specs/README.md#spec-naming).
- The wire protocol is the real API. Change the codec and both ends together.
- Parse untrusted input at the boundary. Interior code trusts typed values.
- Never log a secret. Keep secrets at `0600`.

## Read before you act

| Question | File |
| --- | --- |
| How is the system put together? | [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) |
| How do I build, debug, or deploy? | [`docs/DEVELOPMENT.md`](./docs/DEVELOPMENT.md) |
| Why is the code shaped this way? | [`docs/ENGINEERING.md`](./docs/ENGINEERING.md) |
| What are the UX rules? | [`docs/UX.md`](./docs/UX.md) |
| How do I ship a release? | [`BUILD_AND_DEPLOY.md`](./BUILD_AND_DEPLOY.md) |
| How do I contribute or sign the CLA? | [`CONTRIBUTING.md`](./CONTRIBUTING.md) |

## Skills

Procedures live in [`.agents/skills/`](./.agents/skills/). Load one before you
repeat a known workflow: verify a feature end to end, capture real app
screenshots, add a session event kind, add a forge provider, or record an ACP
fixture. Add a skill when you solve something the hard way, and follow
[`.agents/skills/README.md`](./.agents/skills/README.md).
