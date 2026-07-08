/**
 * Manual verification (not a unit test): drive the REAL pi binary against the
 * fake model server, end to end, without a simulator. Confirms the provider
 * extension + --model selection + SSE parsing all line up before we wire the
 * Flutter e2e. Run: pnpm exec tsx test/fake-model/verify-pi.ts
 */
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { startFakeModelServer } from "./server.js";

const EXT = fileURLToPath(new URL("./provider-extension.ts", import.meta.url));

async function main(): Promise<void> {
  const fake = await startFakeModelServer();
  process.env.PINO_FAKE_MODEL_URL = fake.url;
  console.log("[verify] fake model at", fake.url);

  const piBin = process.env.PINO_PI_BIN || "pi";
  const child = spawn(
    piBin,
    ["--mode", "rpc", "--no-session", "-e", EXT, "--model", "pino-fake/fake-1"],
    { cwd: process.cwd(), stdio: ["pipe", "pipe", "pipe"], env: process.env },
  );

  let buf = "";
  let sawText = "";
  const deadline = setTimeout(() => {
    console.error("[verify] TIMEOUT — no agent_end within 20s");
    child.kill("SIGKILL");
    void fake.close();
    process.exit(1);
  }, 20_000);

  child.stdout.on("data", (chunk: Buffer) => {
    buf += chunk.toString();
    let nl: number;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line) continue;
      let ev: Record<string, unknown>;
      try {
        ev = JSON.parse(line);
      } catch {
        continue;
      }
      // pi nests streaming deltas under message_update.assistantMessageEvent,
      // and the final assistant text under turn_end.message.content.
      const inner = (ev as { assistantMessageEvent?: { type?: string; delta?: string } }).assistantMessageEvent;
      if (inner?.type === "text_delta" && typeof inner.delta === "string") sawText += inner.delta;
      if (process.env.VERIFY_DUMP) console.log("EV:", line.slice(0, 200));
      if (ev.type === "turn_end" || ev.type === "agent_end") {
        clearTimeout(deadline);
        console.log("[verify] streamed text:", JSON.stringify(sawText));
        const ok = sawText.includes("pino e2e ok");
        console.log(ok ? "[verify] PASS ✓" : "[verify] FAIL ✗ (expected 'pino e2e ok')");
        child.kill("SIGTERM");
        void fake.close();
        process.exit(ok ? 0 : 1);
      }
    }
  });
  child.stderr.on("data", (c: Buffer) => process.stderr.write(`[pi] ${c}`));
  child.on("error", (err) => {
    clearTimeout(deadline);
    console.error("[verify] failed to spawn pi:", err.message);
    void fake.close();
    process.exit(1);
  });
  child.on("exit", (code) => console.log("[verify] pi exited", code));

  // Give pi a beat to boot + register the provider, then prompt.
  await new Promise((r) => setTimeout(r, 800));
  child.stdin.write(JSON.stringify({ id: `req-${randomUUID()}`, type: "prompt", message: "hello" }) + "\n");
}

void main();
