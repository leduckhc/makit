import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExecFn } from "./herdr.js";
import { getMultiplexer } from "./registry.js";

function splitJson(paneId: string): string {
  return JSON.stringify({
    result: { pane: { pane_id: paneId } },
  });
}

function withEnv(
  vars: Record<string, string | undefined>,
  fn: () => void | Promise<void>,
): Promise<void> {
  const prev: Record<string, string | undefined> = {};
  for (const [k, v] of Object.entries(vars)) {
    prev[k] = process.env[k];
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  return Promise.resolve(fn()).finally(() => {
    for (const [k, v] of Object.entries(prev)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  });
}

test("getMultiplexer returns herdr by default", async () => {
  const dir = mkdtempSync(join(tmpdir(), "pino-mux-reg-"));
  const file = join(dir, "config.json");
  await withEnv({ PINO_MUX: undefined, PINO_CONFIG_FILE: file }, () => {
    const mux = getMultiplexer();
    assert.ok(mux);
    assert.equal(mux!.name, "herdr");
  });
});

test("getMultiplexer('tmux') returns undefined", () => {
  const mux = getMultiplexer("tmux");
  assert.equal(mux, undefined);
});

test("getMultiplexer returns undefined when PINO_MUX=off", () => {
  withEnv({ PINO_MUX: "off" }, () => {
    assert.equal(getMultiplexer(), undefined);
  });
});

test("getMultiplexer('herdr') returns herdr adapter", () => {
  const mux = getMultiplexer("herdr");
  assert.ok(mux);
  assert.equal(mux!.name, "herdr");
});

test("getMultiplexer passes config anchor into HerdrAdapter", async () => {
  const dir = mkdtempSync(join(tmpdir(), "pino-mux-reg-"));
  const file = join(dir, "config.json");
  writeFileSync(
    file,
    JSON.stringify({ mux: { name: "herdr", anchor: "w3:p1" } }),
  );
  await withEnv(
    {
      PINO_MUX: undefined,
      PINO_MUX_ANCHOR: undefined,
      PINO_CONFIG_FILE: file,
    },
    async () => {
      const calls: Array<{ cmd: string; args: string[] }> = [];
      const exec: ExecFn = async (cmd, args) => {
        calls.push({ cmd, args });
        if (args[1] === "split") {
          return { stdout: splitJson("w7:pS"), stderr: "" };
        }
        return { stdout: "", stderr: "" };
      };
      const mux = getMultiplexer(undefined, { exec });
      assert.ok(mux);
      await mux!.spawnPane({ cwd: "/proj", command: "echo hi" });
      assert.equal(calls[0]!.args[2], "w3:p1");
    },
  );
});
