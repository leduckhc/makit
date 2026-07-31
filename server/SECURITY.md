# Security Policy — server

This document codifies the npm/pnpm supply-chain hardening for the makit
server, following
[lirantal/npm-security-best-practices](https://github.com/lirantal/npm-security-best-practices).

If you change anything here, update `pnpm-workspace.yaml`, `.npmrc`, or
`package.json` to match — and vice versa. They are the single source of truth;
this file explains them.

> **Reporting a vulnerability:** see the repository-root
> [`SECURITY.md`](../SECURITY.md). Do **not** open a public issue.
> Runtime/transport security (pairing, cert pinning, bearer storage) is covered
> there and in [`../app/SECURITY.md`](../app/SECURITY.md).

---

## Threat model

The makit server runs on a developer's machine and **spawns coding-agent CLIs
(`pi` / `codex` / `claude-code`) as child processes** on that machine, over a
network transport paired devices connect to. Compromise impact:

- **Arbitrary code execution** on the developer's machine — the agents the
  server drives can run shell commands, edit files, and hit the network with
  the user's credentials.
- Read/write access to every project the server was launched with
  (`--project <path>`).
- Access to pairing state in `~/.makit/` (self-signed cert **private key**,
  device bearer tokens, pair tokens).

Primary risks this file defends against:

1. **Supply-chain attack via an npm package** (Shai-Hulud, Nx, eslint-scope,
   axios-style) — the biggest realistic threat to a small TS server, and the
   most dangerous given the RCE impact above.
2. **Lockfile drift** between dev, CI, and release silently pulling new
   versions.
3. **Lifecycle-script execution** on `pnpm install` reading the environment or
   writing to disk during dev.

Out of scope for this file (see root `SECURITY.md`): network exposure,
unauthorized pairing, transport/cert-pinning attacks.

---

## Codified controls

### 1. No lifecycle scripts (defense in depth)

- `pnpm-workspace.yaml` → `allowBuilds:` is the **only** way for a package to
  run a build script. Adding to this list is a security review: pin the reason
  in a comment. Current entries: `esbuild` (transitive of `tsx`; downloads a
  platform native binary), `pi-decimals` (transitive of `pi`).
- `pnpm-workspace.yaml` → `strictDepBuilds: true` makes a non-allowlisted build
  a hard install failure (not a warning).
- `.npmrc` → `ignore-scripts=true` covers the case of someone using `npm` or
  `npx` against this repo by mistake (pnpm uses its own stricter mechanism).

To allow a new native package:

1. Read the package's install script. If it phones home, refuse.
2. Add the package name to `allowBuilds` in `pnpm-workspace.yaml` with a
   one-line justification comment.
3. Re-run `pnpm install --frozen-lockfile` to confirm.

**Gap this control does not cover:** a package that ships a *prebuilt* native
binary in its tarball needs no lifecycle script, so `allowBuilds` never sees it.
`typescript@7` (the native compiler port) is our one such dependency: it declares
20 `@typescript/typescript-<os>-<arch>` optional deps, and the one matching the
host — e.g. `@typescript/typescript-darwin-arm64` — unpacks a ~23 MB (22.6 MiB)
Mach-O executable at `lib/tsc` that runs on every `pnpm typecheck` / `pnpm
build`. It is
first-party Microsoft (`microsoft1es`, `typescript-bot` maintainers), has no
install scripts, and is pinned by the lockfile with a `sha512` integrity hash —
but note it publishes **without npm provenance attestations**, so `trustPolicy`
has no Trusted-Publisher signal to check. Treat any future bump of it as a
review, and keep it a dev dependency: it must never reach a runtime path.

### 2. Block exotic (git/tarball) sources

- `pnpm-workspace.yaml` → `blockExoticSubdeps: true` blocks transitive deps
  from pulling git URLs or raw tarballs, which bypass the registry's
  provenance and audit signals.

### 3. Cooldown on new versions

- `pnpm-workspace.yaml` → `minimumReleaseAge: 4320` (3 days). Refuses to
  install any version published less than 3 days ago. Catches the large class
  of attacks where a malicious version is published and detected/unpublished
  within hours.
- `minimumReleaseAgeExclude` carries a small allow-list
  (`typescript`, `@types/node`, `@types/qrcode-terminal`, `@types/ws`). Add
  others only with a one-line justification.
- pub.dev has no equivalent setting, so the app enforces the same 3-day window
  itself — see [`../app/SECURITY.md`](../app/SECURITY.md) §8
  (`app/tool/pub_cooldown.dart`). Change both windows together.

To bypass for a one-off security patch:

```bash
pnpm audit --fix      # respects the policy, opens an excluded slot per fix
# or, manually: add the exact version to minimumReleaseAgeExclude with a
# comment linking to the CVE / advisory.
```

### 4. Trust policy: no downgrade

- `pnpm-workspace.yaml` → `trustPolicy: no-downgrade`. If a package previously
  published with provenance / via a Trusted Publisher and the new version drops
  that signal, the install is aborted — an early indicator of account
  compromise.
- `trustPolicyExclude` carries targeted, commented bypasses (currently
  `undici-types@6.21.0`, pulled un-provenanced by `@types/node`). Each entry is
  a security review.

### 5. Deterministic installs

- `package.json` → `packageManager: "pnpm@11.8.0"` — Corepack refuses any other
  version.
- `package.json` → `preinstall` inspects `npm_config_user_agent` and aborts
  with a `corepack enable && pnpm install` pointer if anything other than pnpm
  invoked it — refuses `npm install` / `yarn install` against this repo.
- `package.json` → `engines.node` (`>=22.13.0`) and `engines.pnpm`
  (`>=11.0.0`) + `.npmrc` `engine-strict=true` — refuses installs on the wrong
  runtime version.
- CI and any release build MUST use `pnpm install --frozen-lockfile`
  (alias `pnpm secure:install`).

### 6. Audits

- `pnpm secure:audit` runs `pnpm audit --prod` in CI.
- The `pnpm-lock.yaml` format is resistant to the lockfile-injection pattern
  that affects `package-lock.json` / `yarn.lock`, so we don't also run
  `lockfile-lint`.

---

## Secrets & sensitive state

The server does not hold third-party API keys. Its sensitive state lives in
`~/.makit/`:

- **`server.crt` / the self-signed cert private key** — the identity paired
  devices pin. Leaking the private key lets an attacker impersonate the server.
- **`devices.json`** — long-lived device bearer tokens and pair tokens.

Handling rules:

- Never log raw tokens, bearers, or key material. Redact in error paths.
- `~/.makit/` is created with owner-only permissions; keep it out of any repo,
  backup, or log bundle.
- Pair tokens are short-lived (5 min) by design — do not extend their lifetime
  without a security review.
