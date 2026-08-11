import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { resolveTranscriptPath } from "./transcript-path.js";
import { piSessionsDir } from "./pi-sessions.js";

// Two REAL colliding UUIDv7 ids from this machine (SPEC-52 D15): their first 8
// chars are identical (`019fa9f4`), so a prefix match would resolve the wrong
// one. Asserted server-side too, not just in the app.
const ID_A = "019fa9f4-443d-7d86-8f4c-d9c4988ddf4f";
const ID_B = "019fa9f4-d3c8-7e0d-9e34-8c70180ca113";

/** Seed a pi transcript for `cwd` named `<ts>_<id>.jsonl`. Returns its path. */
function seed(agentDir: string, cwd: string, id: string): string {
  const dir = piSessionsDir(cwd, agentDir);
  mkdirSync(dir, { recursive: true });
  const path = join(dir, `2026-01-01T00-00-00-000Z_${id}.jsonl`);
  writeFileSync(
    path,
    JSON.stringify({ type: "session", version: 3, id, timestamp: "2026-01-01T00:00:00.000Z", cwd }) + "\n",
  );
  return path;
}

function withAgentDir(run: (agentDir: string) => void): void {
  const agentDir = mkdtempSync(join(tmpdir(), "makit-tp-"));
  try {
    run(agentDir);
  } finally {
    rmSync(agentDir, { recursive: true, force: true });
  }
}

test("resolveTranscriptPath returns the exact-suffix match for a pi session", () => {
  withAgentDir((agentDir) => {
    const cwd = "/work/proj";
    const path = seed(agentDir, cwd, ID_A);
    assert.equal(resolveTranscriptPath({ agent: "pi", agentSessionId: ID_A, cwd }, agentDir), path);
  });
});

test("resolveTranscriptPath does not match a different uuid sharing the first 8 chars (D15)", () => {
  withAgentDir((agentDir) => {
    const cwd = "/work/collide";
    const wanted = seed(agentDir, cwd, ID_A);
    seed(agentDir, cwd, ID_B); // same 8-char prefix, different uuid
    // Ask for A → must get A's file, never B's.
    assert.equal(resolveTranscriptPath({ agent: "pi", agentSessionId: ID_A, cwd }, agentDir), wanted);
    // And asking for B returns B, proving both are present and the suffix is exact.
    const wantedB = piSessionsDir(cwd, agentDir);
    assert.equal(
      resolveTranscriptPath({ agent: "pi", agentSessionId: ID_B, cwd }, agentDir),
      join(wantedB, `2026-01-01T00-00-00-000Z_${ID_B}.jsonl`),
    );
  });
});

test("resolveTranscriptPath returns undefined when the slug dir is absent", () => {
  withAgentDir((agentDir) => {
    assert.equal(resolveTranscriptPath({ agent: "pi", agentSessionId: ID_A, cwd: "/nope" }, agentDir), undefined);
  });
});

test("resolveTranscriptPath returns undefined for an unreadable dir (never throws)", () => {
  withAgentDir((agentDir) => {
    const cwd = "/work/locked";
    seed(agentDir, cwd, ID_A);
    const dir = piSessionsDir(cwd, agentDir);
    chmodSync(dir, 0o000);
    try {
      assert.equal(resolveTranscriptPath({ agent: "pi", agentSessionId: ID_A, cwd }, agentDir), undefined);
    } finally {
      chmodSync(dir, 0o755); // restore so rmSync can clean up
    }
  });
});

test("resolveTranscriptPath returns undefined for a non-pi agent even when a file matches (D16)", () => {
  withAgentDir((agentDir) => {
    const cwd = "/work/codex";
    seed(agentDir, cwd, ID_A);
    assert.equal(resolveTranscriptPath({ agent: "codex", agentSessionId: ID_A, cwd }, agentDir), undefined);
  });
});

test("resolveTranscriptPath prefers resumeSessionPath over a derivable path", () => {
  withAgentDir((agentDir) => {
    const cwd = "/work/attached";
    seed(agentDir, cwd, ID_A); // a derivable path exists…
    const authoritative = "/some/attached/from/disk.jsonl";
    // …but the on-disk resume handle is authoritative and returned verbatim.
    assert.equal(
      resolveTranscriptPath({ agent: "pi", agentSessionId: ID_A, resumeSessionPath: authoritative, cwd }, agentDir),
      authoritative,
    );
  });
});

test("resolveTranscriptPath returns undefined with no agentSessionId", () => {
  withAgentDir((agentDir) => {
    assert.equal(resolveTranscriptPath({ agent: "pi", cwd: "/work/proj" }, agentDir), undefined);
  });
});
