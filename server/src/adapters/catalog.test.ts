import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { listAgents, transportFor, codexAcpBin, onPath } from "./catalog.js";

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

test("always lists pi (native) and pi-acp", () => {
  withEnv({ MAKIT_CODEX_ACP_BIN: undefined }, () => {
    const agents = listAgents();
    const ids = agents.map((a) => a.id);
    assert.ok(ids.includes("pi"));
    assert.ok(ids.includes("pi-acp"));
    assert.equal(agents.find((a) => a.id === "pi")!.transport, "native");
    assert.equal(agents.find((a) => a.id === "pi-acp")!.transport, "acp");
  });
});

test("pi-acp is available (bundled dependency)", () => {
  withEnv({ MAKIT_PI_ACP_BIN: undefined }, () => {
    assert.equal(listAgents().find((a) => a.id === "pi-acp")!.available, true);
  });
});

test("codex is listed only when a codex-acp binary is present", () => {
  withEnv({ MAKIT_CODEX_ACP_BIN: undefined }, () => {
    // Not present by default in this repo.
    assert.equal(codexAcpBin(), undefined);
    assert.ok(!listAgents().some((a) => a.id === "codex"));
  });

  const dir = mkdtempSync(join(tmpdir(), "makit-codex-"));
  const bin = join(dir, "codex-acp");
  writeFileSync(bin, "#!/bin/sh\n");
  chmodSync(bin, 0o755);
  withEnv({ MAKIT_CODEX_ACP_BIN: bin }, () => {
    assert.equal(codexAcpBin(), bin);
    const codex = listAgents().find((a) => a.id === "codex");
    assert.ok(codex);
    assert.equal(codex!.available, true);
    assert.equal(codex!.transport, "acp");
  });
});

test("transportFor maps ids to native/acp", () => {
  assert.equal(transportFor("pi"), "native");
  assert.equal(transportFor("pi-acp"), "acp");
  assert.equal(transportFor("codex"), "acp");
  assert.equal(transportFor("anything-else"), "native");
});

test("onPath finds a real binary and rejects a bogus one", () => {
  assert.equal(onPath("sh"), true);
  assert.equal(onPath("definitely-not-a-real-binary-xyz"), false);
});
