# Contributing to Makit

Thanks for your interest in improving Makit! This document covers licensing,
the contribution workflow, and the project's engineering standards.

## Licensing & the CLA

Makit is **dual-licensed** (see [`LICENSE`](./LICENSE)):

- **Open source:** GPL-3.0-or-later — free for everyone.
- **Commercial:** for organizations that cannot comply with the GPL. Contact
  **license@getmakit.dev**.

Because Makit is dual-licensed, every contributor must sign the
[Contributor License Agreement](./CLA.md) before their code can be merged. The
CLA lets the maintainer (and any future company the project is assigned to)
offer Makit under both the open source and commercial licenses.

Contributing on behalf of a company? Use the
[Entity CLA](./CLA-ENTITY.md) instead and email it to **license@getmakit.dev**.

**How to sign:** open your pull request as normal. The **CLA Assistant** bot
comments on the PR with a link to the CLA and asks you to reply with a single
sentence. Once you post it, the check goes green — you only sign once, and it
covers all future contributions.

## Contribution workflow

1. Fork the repo and create a branch.
2. Make your change following the standards below.
3. Ensure tests and static analysis pass locally:
   - Server: `cd server && pnpm test && pnpm typecheck`
   - App: `cd app && flutter test && flutter analyze`
4. Open a pull request describing **what** changed and **why**.
5. Sign the CLA when the bot prompts you.

## Engineering standards

These are enforced (see [`AGENTS.md`](./AGENTS.md)):

- **TDD:** a failing test precedes production logic (red → green → refactor).
- **Simplicity first:** the minimum code that solves the problem — no
  speculative abstractions or unrequested configurability.
- **Surgical changes:** touch only what the change requires; match existing
  style; don't refactor unrelated code.
- **SOLID:** if you can't say why a change doesn't violate one of the five, it
  probably does.

## Reporting security issues

Please do **not** open public issues for security vulnerabilities. See
[`server/SECURITY.md`](./server/SECURITY.md) and [`app/SECURITY.md`](./app/SECURITY.md),
or email **license@getmakit.dev**.
