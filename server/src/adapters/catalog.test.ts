import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { listAgents, transportFor, onPath } from "./catalog.js";

function withEnv(patch: Record<string, string | undefined>, fn: () => void) {
  const saved: Record<string, string | undefined> = {};
  for (const k of Object.keys(patch)) saved[k] = process.env[k];
  Object.assign(process.env, patch);
  for (const [k, v] of Object.entries(patch)) if (v === undefined) delete process.env[k];
  try {
    fn();
  } finally {
    for (const k of Object.keys(patch)) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  }
}

/** Create a fake executable and return its path. */
function fakeBin(name: string): string {
  const dir = mkdtempSync(join(tmpdir(), "makit-bin-"));
  const bin = join(dir, name);
  writeFileSync(bin, "#!/bin/sh\n");
  chmodSync(bin, 0o755);
  return bin;
}

test("pi is listed (acp transport) only when BOTH pi-acp and pi resolve on PATH", () => {
  const piAcp = fakeBin("pi-acp");
  const pi = fakeBin("pi");
  withEnv({ MAKIT_PI_ACP_BIN: piAcp, MAKIT_PI_BIN: pi }, () => {
    const agents = listAgents();
    const entry = agents.find((a) => a.id === "pi");
    assert.ok(entry, "pi should be listed when both binaries resolve");
    assert.equal(entry!.transport, "acp");
    assert.equal(entry!.available, true);
  });
});

test("pi is NOT listed when the pi-acp binary is missing", () => {
  const pi = fakeBin("pi");
  withEnv(
    { MAKIT_PI_ACP_BIN: "/definitely/not/a/real/pi-acp", MAKIT_PI_BIN: pi },
    () => {
      assert.ok(!listAgents().some((a) => a.id === "pi"));
    },
  );
});

test("pi is NOT listed when the pi binary is missing", () => {
  const piAcp = fakeBin("pi-acp");
  withEnv(
    { MAKIT_PI_ACP_BIN: piAcp, MAKIT_PI_BIN: "/definitely/not/a/real/pi" },
    () => {
      assert.ok(!listAgents().some((a) => a.id === "pi"));
    },
  );
});

test("codex is listed (native transport, app-server) when the codex binary resolves", () => {
  const codex = fakeBin("codex");
  withEnv({ MAKIT_CODEX_BIN: codex }, () => {
    const entry = listAgents().find((a) => a.id === "codex");
    assert.ok(entry);
    assert.equal(entry!.transport, "native");
    assert.equal(entry!.available, true);
    // The retired codex-acp entry is gone.
    assert.ok(!listAgents().some((a) => a.id === "codex-native"));
  });
});

test("codex is NOT listed when the codex binary is missing", () => {
  withEnv({ MAKIT_CODEX_BIN: "/definitely/not/a/real/codex" }, () => {
    assert.ok(!listAgents().some((a) => a.id === "codex"));
  });
});

test("transportFor maps pi to acp and codex to native", () => {
  assert.equal(transportFor("pi"), "acp");
  assert.equal(transportFor("codex"), "native");
  // Back-compat alias for persisted sessions.
  assert.equal(transportFor("codex-native"), "native");
  // Unknown ACP agents default to acp (pi is the ACP path).
  assert.equal(transportFor("anything-else"), "acp");
});

test("onPath finds a real binary and rejects a bogus one", () => {
  assert.equal(onPath("sh"), true);
  assert.equal(onPath("definitely-not-a-real-binary-xyz"), false);
});
