/**
 * Manual herdr smoke test for SPEC-04 (requires running `herdr server`).
 * Usage: PINO_MUX_ANCHOR=w1:p1 tsx test/mux-herdr.smoke.ts
 */
import assert from "node:assert/strict";
import { getMultiplexer } from "../src/mux/index.js";

async function main(): Promise<void> {
  const anchor = process.env.PINO_MUX_ANCHOR;
  if (!anchor) {
    console.error("Set PINO_MUX_ANCHOR to an existing pane id (e.g. w1:p1)");
    process.exit(2);
  }

  process.env.PINO_MUX = "herdr";
  const mux = getMultiplexer();
  assert.ok(mux, "getMultiplexer() should return adapter");
  assert.equal(mux!.name, "herdr");

  const available = await mux!.isAvailable();
  assert.equal(available, true, "isAvailable() should be true with herdr server");

  const handle = await mux!.spawnPane({
    cwd: process.cwd(),
    command: "echo pino-smoke-ok; sleep 2",
    label: "pino: smoke test",
  });
  console.log("spawned pane:", handle);

  assert.equal(await mux!.paneExists(handle), true, "paneExists after spawn");

  await mux!.closePane(handle);
  await mux!.closePane(handle);
  assert.equal(await mux!.paneExists(handle), false, "pane gone after close");

  console.log("SPEC-04 herdr smoke: PASS");
}

main().catch((e) => {
  console.error("SPEC-04 herdr smoke: FAIL", e);
  process.exit(1);
});
