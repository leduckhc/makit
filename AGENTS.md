# AGENTS.md

## Coding Standards

- TDD: write a failing test before production logic (red → green → refactor).
- Apply SOLID; if you can't explain why a change respects each of the five principles, it probably violates one.
- Never leave a verified bug unfixed: once a bug is confirmed real, fix it even when it lies outside the current diff or task scope. If fixing it right now is genuinely unsafe or too large, flag it explicitly instead of silently moving on.

## Cursor Cloud specific instructions

Standard build/run/test commands live in [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md); this section only covers cloud-specific caveats. The update script already runs `pnpm install` (server) and `flutter pub get` (app) on startup.

- **Toolchain locations (Linux VM):** Flutter `3.44.4` is installed at `~/flutter` and is on `PATH` via `~/.bashrc`. Non-interactive shells may not source `~/.bashrc`, so use the absolute binary `~/flutter/bin/flutter` when a command can't find `flutter`. The server uses pnpm `11.8.0` via corepack (plain `npm install` is blocked by a preinstall guard); Node is 22.x.
- **Server (`server/`) runs fully on Linux.** Lint = `pnpm typecheck` (there is no ESLint). `pnpm test`, `pnpm build`, and `pnpm dev`/`pnpm start` all work headless.
- **App (`app/`) has no Linux GUI target** (iOS-first, plus macOS desktop / Android — all needing macOS or a device). On this VM only `flutter analyze --no-pub` (lint) and `flutter test --no-pub` are runnable; `flutter run` and the `app/tool/e2e.sh` simulator flows cannot run here.
- **Keyless end-to-end server loop:** `pnpm exec tsx test/e2e-server.ts --mode stub --project <path>` starts the WSS server on port `9787` with the in-process `StubAdapter` (deterministic echo/STREAM/THINK replies — no LLM key, no `pi` binary) and seeds a paired device with bearer `e2e-token`. Drive it with any WSS client (`{t:"hello",bearer}` → `sub` → `send.message`). The real `pi`/`codex`/`claude` adapters need external agent binaries/API keys that are not present on the VM.
- **Harmless startup noise:** the server prints `/bin/sh: 1: tailscale: not found` and falls back to a loopback-only listener — expected on the VM (no Tailscale).
