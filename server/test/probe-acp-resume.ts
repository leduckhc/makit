/**
 * Isolation probe: does a REAL pi-acp session survive being resumed by native
 * id, with no makit server / manager / event log in the picture?
 *
 * Fresh adapter -> prompt -> kill -> NEW adapter started with
 * resumeAgentSessionId -> prompt again. If the second prompt fails, the bug is
 * in the adapter/pi-acp resume contract, not in the re-attach feature.
 *
 *   pnpm exec tsx test/probe-acp-resume.ts
 */

import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { AcpAdapter } from "../src/adapters/acp.js";
import { startBridge } from "../src/bridge.js";
import { piAcpSpec } from "../src/agent_factory.js";
import { startFakeModelServer } from "./fake-model/server.js";
import { guardAgainstRealBilling, currentModelFromEvents } from "./fake-model/billing-guard.js";

const FAKE_PROVIDER_EXT = fileURLToPath(
  new URL("./fake-model/provider-extension.ts", import.meta.url),
);
const FAKE_MODEL = "makit-fake/fake-1";

function makeAdapter(tag: string, events: { kind: string; payload?: unknown }[]) {
  const a = new AcpAdapter({ spec: piAcpSpec() });
  a.on("event", (e: { kind: string; payload?: unknown }) => events.push(e));
  a.on("event", (e: { kind: string; payload?: unknown }) => {
    if (e.kind === "session.error" || e.kind === "agent.message") {
      console.log(`  [${tag}] ${e.kind}: ${JSON.stringify(e.payload).slice(0, 160)}`);
    }
  });
  a.on("exit", (code: number | null) => console.log(`  [${tag}] EXIT code=${code}`));
  return a;
}

async function firstReply(a: AcpAdapter, timeoutMs = 60_000): Promise<string> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("no reply in time")), timeoutMs);
    const onEvent = (e: { kind: string; payload?: { text?: string; message?: string } }) => {
      if (e.kind === "agent.message") {
        clearTimeout(t);
        a.off("event", onEvent);
        resolve(String(e.payload?.text ?? ""));
      }
      if (e.kind === "session.error") {
        clearTimeout(t);
        a.off("event", onEvent);
        reject(new Error(String(e.payload?.message ?? "session.error")));
      }
    };
    a.on("event", onEvent);
  });
}

async function main() {
  const cwd = mkdtempSync(join(tmpdir(), "makit-probe-"));
  const fake = await startFakeModelServer();
  process.env.MAKIT_FAKE_MODEL_URL = fake.url;
  // PROBE_WITH_BRIDGE=1 reproduces what the manager's startOpts() hands a real
  // session: the loopback bridge env. That env is also what activates the user's
  // GLOBAL pi extensions (e.g. makit-mirror), so it is the prime suspect for the
  // full-stack failure the isolated probe does not show.
  const bridge = process.env.PROBE_WITH_BRIDGE === "1"
    ? await startBridge({ askDevice: async () => ({}) as never })
    : undefined;
  const startOpts = {
    cwd,
    model: FAKE_MODEL,
    extensions: [FAKE_PROVIDER_EXT],
    env: (bridge
      ? { MAKIT_BRIDGE_URL: bridge.url, MAKIT_BRIDGE_TOKEN: bridge.token, MAKIT_SESSION_ID: "probe-1" }
      : {}) as Record<string, string>,
  };
  if (bridge) console.log("probe: bridge env ON ->", bridge.url);

  try {
    // ---- run 1: fresh session -------------------------------------------
    const e1: { kind: string; payload?: unknown }[] = [];
    const a1 = makeAdapter("fresh", e1);
    await a1.start({ ...startOpts, sessionId: "probe-1" });
    console.log("fresh: capabilities =", JSON.stringify(a1.capabilities));
    guardAgainstRealBilling("probe-acp-resume (fresh)", currentModelFromEvents(e1));
    const p1 = firstReply(a1);
    await a1.send({ text: "hello one" });
    console.log("fresh: reply =", JSON.stringify(await p1));
    const nativeId = a1.agentSessionId;
    console.log("fresh: agentSessionId =", nativeId);
    await a1.kill();

    // ---- run 2: resume by native id -------------------------------------
    const e2: { kind: string; payload?: unknown }[] = [];
    const a2 = makeAdapter("resumed", e2);
    await a2.start({ ...startOpts, sessionId: "probe-1", resumeAgentSessionId: nativeId });
    console.log("resumed: capabilities =", JSON.stringify(a2.capabilities));
    console.log("resumed: agentSessionId =", a2.agentSessionId);
    // The point of the probe: assert identity, don't just print it. Without this
    // it prints PROBE PASS even when the agent quietly started a fresh session.
    assert.ok(nativeId, "the fresh session reported a native id to resume by");
    assert.equal(a2.agentSessionId, nativeId, "the resumed adapter kept the same native session id");
    guardAgainstRealBilling("probe-acp-resume (resumed)", currentModelFromEvents(e2));
    // PROBE_DELAY_MS: idle gap between a successful resume and the first prompt.
    // A real user opens the session (which re-attaches) and types seconds later.
    const gap = Number(process.env.PROBE_DELAY_MS ?? 0);
    if (gap > 0) {
      console.log(`resumed: waiting ${gap}ms before prompting (idle gap)`);
      await new Promise((r) => setTimeout(r, gap));
    }
    const p2 = firstReply(a2);
    await a2.send({ text: "hello two" });
    console.log("resumed: reply =", JSON.stringify(await p2));
    await a2.kill();
    console.log("\nPROBE PASS — pi-acp resumed by native id and answered a new prompt.");
  } catch (e) {
    console.error(`\nPROBE FAIL — ${(e as Error).message}`);
    process.exitCode = 1;
  } finally {
    await bridge?.stop();
    await fake.close();
    rmSync(cwd, { recursive: true, force: true });
  }
}

await main();
