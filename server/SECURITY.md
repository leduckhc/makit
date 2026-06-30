# Security Policy

This project codifies the npm/pnpm security best practices from
[lirantal/npm-security-best-practices](https://github.com/lirantal/npm-security-best-practices).

If you change anything in this document, update `pnpm-workspace.yaml`,
`.npmrc`, or `package.json` to match — and vice versa.

---

## Threat model

Internal dental-software chat tool. Compromise impact:

- Read access to xDent knowledge graph (gbrain) via the chat UI's bearer token
- Read access to all stored chats (which may contain Czech support content)
- Outbound calls to Azure Foundry on the org's API key
- The container runs on Dokploy on a shared internal network

Primary risks we care about:

1. **Supply-chain attack via npm package** (Shai-Hulud, Nx, eslint-scope, axios) —
   biggest realistic threat to a small TS/Svelte app.
2. **Lockfile drift** between dev and prod silently pulling new versions.
3. **Lifecycle-script execution** on `pnpm install` reading our env / writing
   to disk during dev.

What we are _not_ defending against here:

- Targeted attacks against our own infra (out of scope for this file).
- Secrets in `.env` — we keep them out of git but accept the local-disk risk.
  See "Secrets" section below.

---

## Codified controls

### 1. No lifecycle scripts (defense in depth)

- `pnpm-workspace.yaml` → `allowBuilds:` is the **only** way for a package to
  run a build script. Adding to this list is a security review: pin the
  reason in a comment.
- `pnpm-workspace.yaml` → `strictDepBuilds: true` makes a non-allowlisted
  build a hard install failure (not a warning).
- `.npmrc` → `ignore-scripts=true` covers the case of someone using `npm` or
  `npx` against this repo by mistake.

To allow a new native package:

1. Read the package's install script. If it phones home, refuse.
2. Add the package name to `allowBuilds` in `pnpm-workspace.yaml` with a
   one-line justification comment.
3. Re-run `pnpm install --frozen-lockfile` to confirm.

### 2. No git-source dependencies

- `.npmrc` → `allow-git=none` blocks `git+https://` / `git+ssh://` deps.
- `pnpm-workspace.yaml` → `blockExoticSubdeps: true` blocks transitive deps
  from pulling git URLs or raw tarballs.

### 3. Cooldown on new versions

- `pnpm-workspace.yaml` → `minimumReleaseAge: 10080` (7 days). Delays
  installation of any version published less than 7 days ago. Catches the
  large class of attacks where a malicious version is published and
  detected/unpublished within hours.
- `minimumReleaseAgeExclude` carries a small allow-list (`typescript`,
  `@types/*`). Add others only with a one-line justification.
- `.npmrc` → `min-release-age=7` is the npm-CLI equivalent.

To bypass for a one-off security patch:

```bash
pnpm audit --fix      # respects the policy, opens excluded slot per fix
# or, manually:
# add the exact version to minimumReleaseAgeExclude with a comment
# linking to the CVE / advisory.
```

### 4. Trust policy: no downgrade

- `pnpm-workspace.yaml` → `trustPolicy: no-downgrade`. If a package
  previously published with provenance / via a Trusted Publisher and the
  new version drops that signal, the install is aborted. Early indicator
  of an account compromise.

### 5. Deterministic installs

- `package.json` → `packageManager: "pnpm@11.4.0"` — Corepack will refuse
  to use any other version.
- `package.json` → `preinstall` runs a small `node -e` script that inspects
  `npm_execpath` / `npm_config_user_agent` and aborts the install with a
  pointer to `corepack enable && pnpm install` if anything other than pnpm
  invoked it — refuses `npm install` / `yarn install` against this repo.
- `package.json` → `engines.node` and `engines.pnpm` + `.npmrc`
  `engine-strict=true` — refuses installs on the wrong runtime version.
- CI and Docker MUST use `pnpm install --frozen-lockfile`
  (alias `pnpm secure:install`).

### 6. Audits

- `pnpm secure:audit` runs `pnpm audit --prod` in CI.
- The `pnpm-lock.yaml` format is resistant to the lockfile-injection
  pattern that affects `package-lock.json` / `yarn.lock`, so we don't
  also run `lockfile-lint`.

---

## Secrets

`.env` files are gitignored and contain plaintext secrets (Azure key,
gbrain bearer token, admin password, session secret). This is a deliberate
trade-off for an internal tool. To reduce blast radius:

- Never log raw env values. Use `***REDACTED***` formatting in error paths.
- The Dockerfile passes secrets via env, never bakes them into layers.
- Production secrets live in Dokploy's environment editor, not in any file.
- If you handle these creds long-term, consider 1Password CLI / Infisical
  for just-in-time secret injection (see best-practices guide §9).

---

## Reporting a security issue

This is an internal project. Report directly to the repo owner. Do not
file a public issue.
