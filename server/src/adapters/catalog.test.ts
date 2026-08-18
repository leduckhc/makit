import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, chmodSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { listAgents, transportFor, onPath, fingerprintAgent, resolveBinPath } from "./catalog.js";

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

test("resolveBinPath returns an absolute path for a resolvable binary, undefined otherwise", () => {
  const resolved = resolveBinPath("sh");
  assert.ok(resolved && resolved.endsWith("/sh"));
  assert.equal(resolveBinPath("definitely-not-a-real-binary-xyz"), undefined);
});

test("resolveBinPath / onPath honor an explicit env.PATH override", () => {
  // The child that AcpAdapter spawns runs with `{ ...process.env, ...opts.env }`
  // as its env, so a caller that widens PATH via opts.env must not be rejected
  // by a preflight that reads only the parent process PATH. Mirror that: the
  // env-scoped lookup finds a bin the process PATH does not, and misses one it
  // deliberately excludes.
  const bin = fakeBin("makit-resolve-test");
  const dir = bin.slice(0, bin.lastIndexOf("/"));
  assert.equal(resolveBinPath("makit-resolve-test", { PATH: dir }), bin);
  assert.equal(onPath("makit-resolve-test", { PATH: dir }), true);
  assert.equal(
    resolveBinPath("makit-resolve-test", { PATH: "/usr/bin:/bin" }),
    undefined,
    "a PATH that excludes the dir must NOT resolve the bin",
  );
  assert.equal(onPath("makit-resolve-test", { PATH: "/usr/bin:/bin" }), false);
});

// ---------- fingerprint (SPEC-new-session-config-at-spawn) ------------------------------------------

/** Create a fake config file with given contents and return its path. */
function fakeFile(name: string, contents = "{}"): string {
  const dir = mkdtempSync(join(tmpdir(), "makit-cfg-"));
  const path = join(dir, name);
  writeFileSync(path, contents);
  return path;
}

test("fingerprintAgent is stable across calls when nothing changes (pi)", () => {
  const piAcp = fakeBin("pi-acp");
  const pi = fakeBin("pi");
  const models = fakeFile("models.json");
  const auth = fakeFile("auth.json");
  withEnv(
    {
      MAKIT_PI_ACP_BIN: piAcp,
      MAKIT_PI_BIN: pi,
      MAKIT_PI_MODELS_FILE: models,
      MAKIT_PI_AUTH_FILE: auth,
    },
    () => {
      const first = fingerprintAgent("pi");
      const second = fingerprintAgent("pi");
      assert.equal(first, second);
      assert.ok(first.length > 0);
    },
  );
});

test("fingerprintAgent changes when models.json content changes (pi)", () => {
  const piAcp = fakeBin("pi-acp");
  const pi = fakeBin("pi");
  const models = fakeFile("models.json", `{"a":1}`);
  const auth = fakeFile("auth.json");
  withEnv(
    {
      MAKIT_PI_ACP_BIN: piAcp,
      MAKIT_PI_BIN: pi,
      MAKIT_PI_MODELS_FILE: models,
      MAKIT_PI_AUTH_FILE: auth,
    },
    () => {
      const before = fingerprintAgent("pi");
      writeFileSync(models, `{"a":1,"b":2}`); // larger file → size changes
      const after = fingerprintAgent("pi");
      assert.notEqual(before, after);
    },
  );
});

test("fingerprintAgent changes when models.json mtime is bumped (touch)", () => {
  const piAcp = fakeBin("pi-acp");
  const pi = fakeBin("pi");
  const models = fakeFile("models.json");
  const auth = fakeFile("auth.json");
  withEnv(
    {
      MAKIT_PI_ACP_BIN: piAcp,
      MAKIT_PI_BIN: pi,
      MAKIT_PI_MODELS_FILE: models,
      MAKIT_PI_AUTH_FILE: auth,
    },
    () => {
      const before = fingerprintAgent("pi");
      const future = new Date(Date.now() + 5000);
      utimesSync(models, future, future);
      const after = fingerprintAgent("pi");
      assert.notEqual(before, after);
    },
  );
});

test("fingerprintAgent changes when the auth marker changes (pi login/logout)", () => {
  const piAcp = fakeBin("pi-acp");
  const pi = fakeBin("pi");
  const models = fakeFile("models.json");
  const auth = fakeFile("auth.json", "{}");
  withEnv(
    {
      MAKIT_PI_ACP_BIN: piAcp,
      MAKIT_PI_BIN: pi,
      MAKIT_PI_MODELS_FILE: models,
      MAKIT_PI_AUTH_FILE: auth,
    },
    () => {
      const before = fingerprintAgent("pi");
      writeFileSync(auth, `{"token":"abc"}`);
      const after = fingerprintAgent("pi");
      assert.notEqual(before, after);
    },
  );
});

test("fingerprintAgent for codex folds in config.toml + auth", () => {
  const codex = fakeBin("codex");
  const config = fakeFile("config.toml", "model = 'gpt-5'");
  const auth = fakeFile("auth.json");
  withEnv(
    {
      MAKIT_CODEX_BIN: codex,
      MAKIT_CODEX_CONFIG_FILE: config,
      MAKIT_CODEX_AUTH_FILE: auth,
    },
    () => {
      const before = fingerprintAgent("codex");
      writeFileSync(config, "model = 'gpt-5-codex'\neffort = 'high'");
      const after = fingerprintAgent("codex");
      assert.notEqual(before, after);
      // codex-native alias fingerprints identically to codex.
      assert.equal(fingerprintAgent("codex"), fingerprintAgent("codex-native"));
    },
  );
});

test("fingerprintAgent tolerates absent binaries/config (stable 'absent' marker)", () => {
  withEnv(
    {
      MAKIT_PI_ACP_BIN: "/no/such/pi-acp",
      MAKIT_PI_BIN: "/no/such/pi",
      MAKIT_PI_MODELS_FILE: "/no/such/models.json",
      MAKIT_PI_AUTH_FILE: "/no/such/auth.json",
    },
    () => {
      assert.equal(fingerprintAgent("pi"), fingerprintAgent("pi"));
    },
  );
});

test("listAgents attaches a fingerprint to each descriptor", () => {
  const piAcp = fakeBin("pi-acp");
  const pi = fakeBin("pi");
  withEnv(
    { MAKIT_PI_ACP_BIN: piAcp, MAKIT_PI_BIN: pi, MAKIT_CODEX_BIN: "/no/such/codex" },
    () => {
      const entry = listAgents().find((a) => a.id === "pi");
      assert.ok(entry);
      assert.equal(typeof entry!.fingerprint, "string");
      assert.ok(entry!.fingerprint.length > 0);
      assert.equal(entry!.fingerprint, fingerprintAgent("pi"));
    },
  );
});
