import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DEFAULT_MUX_ANCHOR, loadMuxConfig } from "./config.js";

function withEnv(
  vars: Record<string, string | undefined>,
  fn: () => void,
): void {
  const prev: Record<string, string | undefined> = {};
  for (const [k, v] of Object.entries(vars)) {
    prev[k] = process.env[k];
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    fn();
  } finally {
    for (const [k, v] of Object.entries(prev)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

test("loadMuxConfig defaults when file missing", () => {
  withEnv({ MAKIT_MUX: undefined, MAKIT_MUX_ANCHOR: undefined }, () => {
    const dir = mkdtempSync(join(tmpdir(), "makit-mux-cfg-"));
    const file = join(dir, "config.json");
    const cfg = loadMuxConfig(file);
    assert.equal(cfg.mux, "herdr");
    assert.equal(cfg.anchor, DEFAULT_MUX_ANCHOR);
  });
});

test("loadMuxConfig reads file values", () => {
  withEnv({ MAKIT_MUX: undefined, MAKIT_MUX_ANCHOR: undefined }, () => {
    const dir = mkdtempSync(join(tmpdir(), "makit-mux-cfg-"));
    const file = join(dir, "config.json");
    writeFileSync(
      file,
      JSON.stringify({ mux: { name: "herdr", anchor: "w3:p1" } }),
    );
    const cfg = loadMuxConfig(file);
    assert.equal(cfg.mux, "herdr");
    assert.equal(cfg.anchor, "w3:p1");
  });
});

test("loadMuxConfig env overrides file", () => {
  withEnv({ MAKIT_MUX: "off", MAKIT_MUX_ANCHOR: "w9:p0" }, () => {
    const dir = mkdtempSync(join(tmpdir(), "makit-mux-cfg-"));
    const file = join(dir, "config.json");
    writeFileSync(
      file,
      JSON.stringify({ mux: { name: "herdr", anchor: "w3:p1" } }),
    );
    const cfg = loadMuxConfig(file);
    assert.equal(cfg.mux, "off");
    assert.equal(cfg.anchor, "w9:p0");
  });
});

test("loadMuxConfig never throws on corrupt file", () => {
  withEnv({ MAKIT_MUX: undefined, MAKIT_MUX_ANCHOR: undefined }, () => {
    const dir = mkdtempSync(join(tmpdir(), "makit-mux-cfg-"));
    const file = join(dir, "config.json");
    writeFileSync(file, "not json{{{");
    const cfg = loadMuxConfig(file);
    assert.equal(cfg.mux, "herdr");
    assert.equal(cfg.anchor, DEFAULT_MUX_ANCHOR);
  });
});
