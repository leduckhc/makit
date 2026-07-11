# Security Policy

Makit lets you drive coding agents (`pi` / `codex` / `claude-code`) on your
desktop from a paired phone or other device. A compromise could give an
attacker the ability to run those agents — and therefore code — on your
machine, plus read access to whatever those agents can see. We take security
seriously.

## Supported versions

Makit is pre-1.0 and moves fast. Security fixes land on `main` and the latest
release only.

| Version | Supported |
|---------|-----------|
| latest `main` / release | ✅ |
| older releases | ❌ |

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report privately using either:

- **GitHub Security Advisories** — [open a private report](https://github.com/leduckhc/makit/security/advisories/new)
  (preferred; keeps discussion and the fix coordinated in one place), or
- **Email** — **license@getmakit.dev** with subject `SECURITY: <short summary>`.

Please include:

- A description of the issue and its impact.
- Steps to reproduce (proof-of-concept if possible).
- Affected component (`app/`, `server/`, pairing/transport, an adapter, …) and
  version / commit.

### What to expect

- **Acknowledgement:** within 3 business days.
- **Assessment & triage:** we'll confirm the issue and share a rough timeline.
- **Fix & disclosure:** we aim to ship a fix and publish an advisory promptly,
  crediting you unless you prefer to remain anonymous. Please give us a
  reasonable window to fix before any public disclosure (coordinated
  disclosure).

## Scope

The security model in short (see [`app/SECURITY.md`](./app/SECURITY.md) and
[`server/SECURITY.md`](./server/SECURITY.md) for details):

- **Private by default:** the server binds to a Tailscale tailnet, not open
  Wi-Fi. Plain-LAN is opt-in (`--lan`).
- **Cert-pinned transport:** the app pins the server's self-signed cert
  fingerprint at the WebSocket layer — no OS trust store involved.
- **Pairing:** one-time QR pair token → long-lived bearer stored in the OS
  secure enclave (Keychain / Android Keystore).

In-scope reports include: authentication/pairing bypass, transport downgrade
or cert-pinning bypass, bearer-token leakage, remote code execution via the
agent adapters, and supply-chain issues in our dependencies.

Out of scope: vulnerabilities in the underlying agents (`pi`, `codex`,
`claude-code`) themselves, in Tailscale, or in your own network configuration.
