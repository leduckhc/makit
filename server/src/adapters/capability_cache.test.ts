import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CapabilityCache, type Prober } from "./capability_cache.js";
import type { AgentDescriptor } from "./catalog.js";
import type { SessionConfigOption } from "../protocol.js";

function tmpCachePath(): string {
  const dir = mkdtempSync(join(tmpdir(), "makit-cap-"));
  return join(dir, "capability-cache.json");
}

const MODEL_OPTION: SessionConfigOption = {
  id: "model",
  name: "Model",
  category: "model",
  type: "select",
  currentValue: "gpt-5",
  options: [{ value: "gpt-5", name: "GPT-5" }],
};

function piDescriptor(fingerprint: string): AgentDescriptor {
  return { id: "pi", label: "Pi (ACP)", transport: "acp", available: true, fingerprint };
}

/** A counting prober that returns a fixed option list. */
function countingProber(options: SessionConfigOption[] = [MODEL_OPTION]): {
  prober: Prober;
  calls: () => number;
} {
  let calls = 0;
  const prober: Prober = async () => {
    calls += 1;
    return options;
  };
  return { prober, calls: () => calls };
}

test("serve probes once on a cold cache and enriches the descriptor", async () => {
  const { prober, calls } = countingProber();
  const cache = new CapabilityCache({ path: tmpCachePath(), prober });
  const served = await cache.serve(piDescriptor("fp1"));
  assert.equal(calls(), 1);
  assert.equal(served.configOptions?.[0].id, "model");
});

test("concurrent serve() calls coalesce into a single in-flight probe", async () => {
  let calls = 0;
  let release: () => void = () => {};
  const gate = new Promise<void>((r) => (release = r));
  const prober: Prober = async () => {
    calls += 1;
    await gate; // hold both callers inside the probe simultaneously
    return [MODEL_OPTION];
  };
  const cache = new CapabilityCache({ path: tmpCachePath(), prober });
  const a = cache.serve(piDescriptor("fp1"));
  const b = cache.serve(piDescriptor("fp1"));
  release();
  const [ra, rb] = await Promise.all([a, b]);
  assert.equal(calls, 1, "the harness is probed once, not per caller");
  assert.equal(ra.configOptions?.[0].id, "model");
  assert.equal(rb.configOptions?.[0].id, "model");
  // A later call after the in-flight entry cleared still re-probes on change.
  await cache.serve(piDescriptor("fp2"));
  assert.equal(calls, 2);
});

test("serve does NOT re-probe when the fingerprint is unchanged (warm cache)", async () => {
  const { prober, calls } = countingProber();
  const cache = new CapabilityCache({ path: tmpCachePath(), prober });
  await cache.serve(piDescriptor("fp1"));
  const again = await cache.serve(piDescriptor("fp1"));
  assert.equal(calls(), 1, "second serve should hit cache, not probe");
  assert.equal(again.configOptions?.[0].id, "model");
});

test("serve re-probes when the fingerprint changes", async () => {
  const { prober, calls } = countingProber();
  const cache = new CapabilityCache({ path: tmpCachePath(), prober });
  await cache.serve(piDescriptor("fp1"));
  await cache.serve(piDescriptor("fp2"));
  assert.equal(calls(), 2);
});

test("serve NEVER probes an unavailable harness", async () => {
  const { prober, calls } = countingProber();
  const cache = new CapabilityCache({ path: tmpCachePath(), prober });
  const served = await cache.serve({
    id: "pi",
    label: "Pi (ACP)",
    transport: "acp",
    available: false,
    fingerprint: "fp1",
  });
  assert.equal(calls(), 0);
  assert.equal(served.configOptions, undefined);
});

test("refresh forces a re-probe even when the fingerprint is unchanged", async () => {
  const { prober, calls } = countingProber();
  const cache = new CapabilityCache({ path: tmpCachePath(), prober });
  await cache.serve(piDescriptor("fp1"));
  await cache.refresh(piDescriptor("fp1"));
  assert.equal(calls(), 2);
});

test("an option-less harness caches an empty catalog and does not re-probe", async () => {
  const { prober, calls } = countingProber([]);
  const cache = new CapabilityCache({ path: tmpCachePath(), prober });
  const served = await cache.serve(piDescriptor("fp1"));
  assert.equal(served.configOptions, undefined, "empty catalog omits configOptions");
  await cache.serve(piDescriptor("fp1"));
  assert.equal(calls(), 1, "empty catalog is still a cache hit at the same fingerprint");
});

test("a failing probe caches an empty catalog (best-effort, no throw)", async () => {
  let calls = 0;
  const prober: Prober = async () => {
    calls += 1;
    throw new Error("probe boom");
  };
  const cache = new CapabilityCache({ path: tmpCachePath(), prober });
  const served = await cache.serve(piDescriptor("fp1"));
  assert.equal(served.configOptions, undefined);
  await cache.serve(piDescriptor("fp1"));
  assert.equal(calls, 1);
});

test("the cache persists across instances (survives a restart)", async () => {
  const path = tmpCachePath();
  const first = countingProber();
  const cacheA = new CapabilityCache({ path, prober: first.prober });
  await cacheA.serve(piDescriptor("fp1"));
  assert.equal(first.calls(), 1);
  assert.ok(existsSync(path));

  // A fresh instance at the same path + fingerprint serves from disk, no probe.
  const second = countingProber();
  const cacheB = new CapabilityCache({ path, prober: second.prober });
  const served = await cacheB.serve(piDescriptor("fp1"));
  assert.equal(second.calls(), 0, "warm on-disk cache should not re-probe");
  assert.equal(served.configOptions?.[0].id, "model");

  rmSync(path, { force: true });
});
