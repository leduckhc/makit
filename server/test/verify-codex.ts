/**
 * Manual verification (not a unit test): drive the REAL `codex app-server`
 * binary end to end through makit's `CodexAppServerAdapter`. Confirms the
 * JSON-RPC handshake (initialize → initialized → thread/start), turn streaming,
 * and event mapping all line up against the installed codex CLI.
 *
 * Requires codex to be on PATH (or MAKIT_CODEX_BIN) and authenticated. Costs a
 * real (tiny) model call. Run: pnpm exec tsx test/verify-codex.ts
 */
import { CodexAppServerAdapter } from "../src/adapters/codex.js";
import type { AdapterEvent } from "../src/adapters/adapter.js";

const PROMPT = "Reply with exactly this and nothing else: makit e2e ok";
const EXPECT = "makit e2e ok";
const TIMEOUT_MS = 60_000;

async function main(): Promise<void> {
  const command = process.env.MAKIT_CODEX_BIN || "codex";
  const model = process.env.MAKIT_CODEX_MODEL; // undefined → codex default
  const adapter = new CodexAppServerAdapter({ command, ...(model ? { model } : {}) });

  let streamed = "";
  let finalText = "";
  let sawError = "";

  adapter.on("event", (e: AdapterEvent) => {
    switch (e.kind) {
      case "agent.message.delta":
        streamed += String((e.payload as { chunk?: string }).chunk ?? "");
        break;
      case "agent.message":
        finalText = String((e.payload as { text?: string }).text ?? "");
        break;
      case "session.error":
        sawError = String((e.payload as { message?: string }).message ?? "error");
        break;
      default:
        break;
    }
    if (process.env.VERIFY_DUMP) console.log("EV:", e.kind, JSON.stringify(e.payload).slice(0, 200));
  });

  const done = new Promise<void>((resolve) => {
    adapter.on("status", (s) => {
      // The turn is over when the adapter returns to idle after running.
      if (s === "idle" && (streamed || finalText || sawError)) resolve();
    });
  });

  const deadline = new Promise<never>((_, reject) =>
    setTimeout(() => reject(new Error(`TIMEOUT — no completed turn within ${TIMEOUT_MS / 1000}s`)), TIMEOUT_MS),
  );

  console.log(`[verify] launching ${command} app-server${model ? ` (model ${model})` : ""}`);
  await adapter.start({ cwd: process.cwd(), sessionId: "verify-codex" });
  console.log("[verify] thread started; sending prompt");
  await adapter.send({ text: PROMPT });

  try {
    await Promise.race([done, deadline]);
  } finally {
    await adapter.kill().catch(() => {});
  }

  const got = (finalText || streamed).toLowerCase();
  console.log("[verify] streamed:", JSON.stringify(streamed));
  console.log("[verify] final:   ", JSON.stringify(finalText));
  if (sawError) {
    console.error("[verify] FAIL ✗ session.error:", sawError);
    process.exit(1);
  }
  const ok = got.includes(EXPECT);
  console.log(ok ? "[verify] PASS ✓" : `[verify] FAIL ✗ (expected to contain '${EXPECT}')`);
  process.exit(ok ? 0 : 1);
}

main().catch((err) => {
  console.error("[verify] FAIL ✗", err?.message ?? err);
  process.exit(1);
});
