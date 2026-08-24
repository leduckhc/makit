/**
 * makit — SPEC-doc-preview: `server.ts` must build a REAL {@link DocsService}.
 *
 * The unit tests under `src/docs/` prove the service works in isolation, and
 * `src/ws/commands/docs.test.ts` proves the command layer forwards to whatever
 * port it is handed. Neither notices when `server.ts` hands over a stub — and
 * that is exactly what happened: the docs wiring landed in #158 and #159
 * replaced it with `{ snapshot: () => [] }`, so every client saw an empty index.
 *
 * The app hides its own entry point when the index is empty (the worktree row's
 * glyph on the phone, the sidebar sub-row glyph on desktop), so the whole
 * feature became unreachable with no error anywhere. This test closes that gap
 * at the only layer that can see it: a real socket against a real server.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { WebSocket } from "ws";
import { EventEmitter } from "node:events";

import { startWsServer } from "./server.js";
import { SessionManager } from "./manager.js";
import { loadOrCreateCert } from "./pairing/cert.js";
import { DeviceRegistry } from "./pairing/registry.js";
import { PROTOCOL_VERSION } from "./protocol.js";
import type { Envelope } from "./protocol.js";
import type { AgentAdapter } from "./adapters/adapter.js";

function fakeAdapter(): AgentAdapter {
  const e = new EventEmitter() as unknown as AgentAdapter;
  (e as unknown as { agent: string }).agent = "stub";
  (e as unknown as { start: () => Promise<void> }).start = async () => {};
  (e as unknown as { send: () => Promise<void> }).send = async () => {};
  (e as unknown as { cancel: () => Promise<void> }).cancel = async () => {};
  (e as unknown as { kill: () => Promise<void> }).kill = async () => {};
  return e;
}

/** A git repo holding two docs the default `git` roots must both find. */
function repoWithDocs(): string {
  // realpath, not the raw mkdtemp path: on macOS `$TMPDIR` is `/var/folders/...`,
  // a symlink into `/private/var`. The doc index resolves every candidate
  // through realpath (D2), so the snapshot reports the resolved path and a
  // comparison against the raw one silently matches nothing.
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "makit-docs-repo-")));
  const git = (...a: string[]) => execFileSync("git", a, { cwd: dir });
  git("init", "-q", "-b", "main");
  git("config", "user.email", "t@example.com");
  git("config", "user.name", "t");
  writeFileSync(join(dir, "README.md"), "# Read me\n");
  mkdirSync(join(dir, "docs"), { recursive: true });
  writeFileSync(join(dir, "docs", "guide.md"), "# A guide\n");
  git("add", "-A");
  git("commit", "-q", "-m", "docs");
  return dir;
}

test("docs.watch {on:true} answers with a real index, not an empty stub", async () => {
  const home = mkdtempSync(join(tmpdir(), "makit-home-"));
  const project = repoWithDocs();
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;

  const cert = await loadOrCreateCert();
  const registry = new DeviceRegistry();
  const manager = new SessionManager({ projects: [project], adapterFactory: () => fakeAdapter() });

  const server = startWsServer({
    host: "127.0.0.1",
    port: 0,
    manager,
    cert,
    registry,
    trustLocalhost: true,
  });
  await new Promise<void>((r) => server.https.on("listening", () => r()));
  const port = (server.https.address() as AddressInfo).port;

  const ws = new WebSocket(`wss://127.0.0.1:${port}`, { rejectUnauthorized: false });
  const docsFrames: Array<Record<string, unknown>> = [];
  ws.on("message", (raw) => {
    const env = JSON.parse(raw.toString()) as Envelope & Record<string, unknown>;
    if (env.t === "event" && env.kind === "docs.snapshot") docsFrames.push(env);
  });

  try {
    await new Promise<void>((resolve, reject) => {
      ws.on("open", () => resolve());
      ws.on("error", reject);
    });

    // The real wire shape the app sends (`store/docs.dart`): a `cmd` envelope
    // with `kind` and `on` FLAT on the envelope, not nested under a body.
    ws.send(
      JSON.stringify({
        v: PROTOCOL_VERSION,
        t: "cmd",
        id: "docs-watch-1",
        kind: "docs.watch",
        on: true,
        ts: Date.now(),
      }),
    );

    // The first walk is async (stat + bounded read per candidate, yielding every
    // 32). Poll for a frame that actually carries docs rather than sleep a fixed
    // span, and bound the wait so a regression fails loudly.
    const deadline = Date.now() + 10_000;
    let snapshot: { docs?: unknown[]; scanOk?: boolean } | undefined;
    while (Date.now() < deadline) {
      const withDocs = docsFrames.find((f) => {
        const s = f.snapshot as { docs?: unknown[] } | undefined;
        return Array.isArray(s?.docs) && s.docs.length > 0;
      });
      if (withDocs !== undefined) {
        snapshot = withDocs.snapshot as { docs?: unknown[]; scanOk?: boolean };
        break;
      }
      await new Promise((r) => setTimeout(r, 50));
    }

    assert.ok(docsFrames.length > 0, "a docs watcher receives at least one docs.snapshot frame");
    // The field name is the contract the app decodes (`codec.dart` reads
    // `snapshot`); the stub put a bare array under `docs`, which the app dropped
    // as malformed before it could even paint an empty list.
    assert.ok(
      docsFrames.every((f) => typeof f.snapshot === "object" && f.snapshot !== null),
      "every docs.snapshot frame carries a `snapshot` object, never a bare `docs` array",
    );
    assert.ok(snapshot !== undefined, "the index reports the project's docs");
    assert.equal(snapshot.scanOk, true, "the walk ran");

    const docs = snapshot.docs as Array<{ relPath: string; worktreePath: string; title: string }>;
    const mine = docs.filter((d) => d.worktreePath === project);
    const paths = mine.map((d) => d.relPath).sort();
    assert.deepEqual(paths, ["README.md", "docs/guide.md"], "both docs are indexed");
    // D4: a row shows a human title read from the file, never the basename.
    assert.equal(
      mine.find((d) => d.relPath === "docs/guide.md")?.title,
      "A guide",
      "the title comes from the first heading",
    );
  } finally {
    ws.close();
    await new Promise<void>((r) => server.wss.close(() => r()));
    await new Promise<void>((r) => server.https.close(() => r()));
    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
    rmSync(home, { recursive: true, force: true });
    rmSync(project, { recursive: true, force: true });
  }
});
