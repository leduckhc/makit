/**
 * End-to-end: the REAL `pi` binary + the `pi-ask-user` package, driven through
 * makit's real {@link PiAdapter}, exercising the ask_user flow with NO makit
 * connector and NO HTTP bridge (both removed) — only the Path-B ctx.ui.*
 * interceptor + the askUser callback (which stands in for the app here).
 *
 * Flow proven:
 *   model → ask_user tool → ctx.ui.custom()=undefined → ctx.ui.select fallback
 *     → pi emits extension_ui_request{method:"select"}
 *     → PiAdapter.handleUiRequest reframes → askUser({kind:"askUserQuestion"})
 *     → (app stub answers) → extension_ui_response{value} → pi resumes → final text
 *
 * Hermetic + keyless: the LLM backend is the deterministic fake-model provider
 * (test/fake-model), so no network / API key is needed. It still requires the
 * real `pi` binary on PATH and the `pi-ask-user` package installed in pi's
 * agent dir — otherwise the test SKIPS (e.g. the cloud VM, see AGENTS.md).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer, type IncomingMessage } from "node:http";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { PiAdapter } from "../src/adapters/pi.js";
import { toSseLines, type Scenario } from "./fake-model/scenarios.js";
import type { UICall, UIResponse } from "../src/uicall.js";

const PI_BIN = process.env.MAKIT_PI_BIN || "pi";

/** Skip reason if the real toolchain isn't present, else `false` (run it). */
function skipReason(): string | false {
  const v = spawnSync(PI_BIN, ["--version"], { encoding: "utf8" });
  if (v.error || v.status !== 0) return `pi binary (${PI_BIN}) not runnable`;
  const agentDir = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
  const pkg = join(agentDir, "npm", "node_modules", "pi-ask-user", "package.json");
  const settings = join(agentDir, "settings.json");
  const enabled =
    existsSync(settings) && /pi-ask-user/.test(readFileSync(settings, "utf8"));
  if (!existsSync(pkg) || !enabled) return "pi-ask-user not installed/enabled in pi agent dir";
  return false;
}

const ASK_ARGS = JSON.stringify({
  question: "Pick one?",
  options: [{ title: "Yes" }, { title: "No" }],
  allowFreeform: false,
});

/** A turn-aware fake OpenAI endpoint: ask_user on turn 1, final text after. */
async function startFakeModel(): Promise<{ url: string; close: () => void }> {
  const readBody = (req: IncomingMessage) =>
    new Promise<string>((resolve) => {
      let raw = "";
      req.on("data", (c) => (raw += c));
      req.on("end", () => resolve(raw));
    });
  const server = createServer(async (req, res) => {
    if (req.method !== "POST" || !/\/chat\/completions\/?$/.test(req.url ?? "")) {
      res.writeHead(404).end();
      return;
    }
    const parsed = JSON.parse((await readBody(req)) || "{}");
    const messages: Array<{ role?: string }> = parsed.messages ?? [];
    const hasToolResult = messages.some((m) => m.role === "tool");
    const model = typeof parsed.model === "string" ? parsed.model : "fake-1";
    const scenario: Scenario = hasToolResult
      ? { name: "text", textDeltas: ["FINAL: done"], finishReason: "stop" }
      : {
          name: "tool",
          textDeltas: [],
          toolCall: { id: "call_ask_1", name: "ask_user", arguments: ASK_ARGS },
          finishReason: "tool_calls",
        };
    res.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      connection: "keep-alive",
    });
    for (const line of toSseLines(scenario, model)) res.write(line);
    res.end();
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const addr = server.address();
  const port = typeof addr === "object" && addr ? addr.port : 0;
  return { url: `http://127.0.0.1:${port}/v1`, close: () => server.close() };
}

test(
  "e2e: real pi + pi-ask-user round-trips ask_user through the PiAdapter interceptor",
  { skip: skipReason(), timeout: 60_000 },
  async () => {
    const fake = await startFakeModel();
    const providerExt = fileURLToPath(
      new URL("./fake-model/provider-extension.ts", import.meta.url),
    );

    const askCalls: UICall[] = [];
    let finalText = "";
    let done!: () => void;
    const finished = new Promise<void>((r) => (done = r));

    const adapter = new PiAdapter();
    adapter.on("event", (e: { kind: string; payload?: Record<string, unknown> }) => {
      if (e.kind === "agent.message") finalText += String(e.payload?.text ?? "");
      if (finalText.includes("FINAL: done")) done();
    });

    try {
      await adapter.start({
        cwd: process.cwd(),
        sessionId: "e2e-ask",
        env: { MAKIT_FAKE_MODEL_URL: fake.url },
        extensions: [providerExt],
        model: "makit-fake/fake-1",
        // Stands in for the phone/desktop app: answer "Yes".
        askUser: async (call: UICall): Promise<UIResponse> => {
          askCalls.push(call);
          return { kind: "askUserQuestion", indices: [0], answers: ["Yes"] } as UIResponse;
        },
      });

      await adapter.send({ text: "ask me a question, then say done" });
      await finished;

      // The tool call reached the interceptor as a reframed askUserQuestion...
      assert.equal(askCalls.length, 1, "ask_user should hit askUser exactly once");
      assert.equal(askCalls[0].kind, "askUserQuestion");
      const q = (askCalls[0] as any).questions[0];
      assert.equal(q.question, "Pick one?");
      assert.deepEqual(q.options.map((o: any) => o.label), ["Yes", "No"]);
      // ...and pi resumed with the answer and finished the turn.
      assert.ok(finalText.includes("FINAL: done"), `expected final text, got: ${finalText}`);
    } finally {
      await adapter.kill("SIGTERM").catch(() => {});
      fake.close();
    }
  },
);
