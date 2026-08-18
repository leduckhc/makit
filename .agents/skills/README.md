# `.agents/skills/` — procedures for agents

A **skill** is a procedure an agent loads on demand. Only the `name` and
`description` of each skill sit in the model's prompt at all times. The body
loads when a task matches. So a skill costs almost nothing until it is used.

This is the third of three agent-facing layers. Keep them apart:

| Layer | Holds | Loads |
| --- | --- | --- |
| [`AGENTS.md`](../../AGENTS.md) | facts and standing rules | always, in full |
| [`docs/`](../../docs/) | deep reference | when a link is followed |
| `.agents/skills/` | procedures | on demand, per skill |

Rule of thumb: a **fact** belongs in `AGENTS.md`. A **procedure** belongs here.
If a section of `AGENTS.md` turns into numbered steps, move it into a skill.

## Layout

```
.agents/skills/
├── <name>/SKILL.md          # makit procedures — written here, reviewed in PRs
├── vendor/dart-lang/        # vendored upstream skills, see below
└── vendor/verify.sh         # integrity gate for the vendored copies
```

Which harnesses read this directory:

- **pi** reads `.agents/skills/` recursively, after you trust the project.
- **codex** reads `~/.agents/skills/`; symlink a skill there if you need it
  outside this repo.
- **Claude Code** reads `.claude/skills/`. Symlink if you use it.

## Write a skill

```markdown
---
name: makit-do-the-thing
description: One line. Say what it does AND when to use it. Put the trigger words a user would type first.
---
## When to Use
## Procedure
## Pitfalls
## Verification
```

Rules that come from experience, not taste:

- The `description` is the only thing the model sees before it decides. Name the
  symptom, the file, or the command a user would mention. A vague description
  means the skill never fires.
- Keep `SKILL.md` under ~500 lines. Once loaded, it stays in context.
- Put deterministic work in a script beside `SKILL.md`, not in prose. Code is
  cheaper and repeatable.
- Record the **traps**, not the happy path. The happy path is in `docs/`.
- Use only spec fields in the frontmatter: `name`, `description`, `license`,
  `compatibility`, `metadata`. Other fields make some harnesses fail the file.
- Keep sentences at 20 words or fewer, as [`AGENTS.md`](../../AGENTS.md) asks.
  A trap you cannot parse at speed is a trap you will hit again.

## Vendored skills (`vendor/dart-lang/`)

Twelve Dart and Flutter skills come from
[`dart-lang/skills`](https://github.com/dart-lang/skills). `skills-lock.json` at
the repo root records the source, the upstream path, and a hash per skill.

Keep only skills this repo can actually use. A skill for a package we do not
depend on still costs prompt budget. It also steals description budget from the
skills that matter. Nine were removed for that reason: they covered `intl`,
`http`, `json_serializable`, `ffigen`, native FFI assets, `mockito`, `checks`,
widget previews, and Dart CLI apps. None of those appear in `app/pubspec.yaml`
or `server/package.json`.

### Integrity

Each entry carries two hashes:

- `computedHash` — what the fetch tool hashed upstream. It does **not** match the
  committed bytes: the tool injects a `metadata:` block after it hashes. Treat it
  as provenance only.
- `committedHash` — the `sha256` of the committed `SKILL.md`. This one is
  enforced.

```sh
bash .agents/skills/vendor/verify.sh            # check every entry
bash .agents/skills/vendor/verify.sh --write    # re-record after a refresh
```

The script fails on a modified file, a missing file, and a skill that no lock
entry covers. `--write` re-records the hashes, but it still fails on a missing or
an untracked skill: a rewrite cannot repair a lock that does not describe the
tree. The `skills-ci` workflow runs the check on every PR that touches this
directory. So a local edit to a vendored skill can no longer pass as upstream
code.

To refresh a vendored skill, replace its `SKILL.md` from upstream and update its
entry in `skills-lock.json`. Then run `verify.sh --write` and commit the result.

## Security

A skill can tell a model to run anything. Review a skill in the PR as carefully
as you review code. Never paste one in from an unknown source.
