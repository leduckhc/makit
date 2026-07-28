/**
 * record-acp-session — drive the REAL `pi-acp` bridge as an ACP client and
 * capture every wire event to a JSONL fixture, for deterministic replay in
 * mapper + UI tests (see replay-acp-session.ts).
 *
 * Each JSONL line is one of:
 *   { t: "update", update: <ACP SessionUpdate> }   // session/update notifications
 *   { t: "permission", toolCall, options }          // requestPermission (auto-answered)
 *   { t: "elicitation", params }                    // createElicitation (auto-declined)
 *   { t: "prompt", text }                           // the user turn we sent
 *   { t: "stopReason", reason }                     // prompt result
 *
 * Usage:
 *   pnpm exec tsx test/record-acp-session.ts --out test/fixtures/acp/<name>.jsonl \
 *     --prompt "use the bash tool to run: echo hi"
 *
 * Requires a working, authenticated `pi` on PATH (real LLM calls).
 */

import { writeFileSync, mkdirSync, appendFileSync } from "node:fs";
import { dirname } from "node:path";
import {
  ClientSideConnection,
  type Client as AcpClient,
  type RequestPermissionRequest,
  type RequestPermissionResponse,
  type SessionNotification,
} from "@agentclientprotocol/sdk";
import { defaultConnect } from "../src/adapters/acp.js";
import { piAcpSpec } from "../src/agent_factory.js";

function arg(name: string, fallback?: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : fallback;
}

const out = arg("out", "test/fixtures/acp/session.jsonl")!;
const prompt = arg("prompt", "Use the bash tool to run: echo hello-from-pi")!;
const cwd = arg("cwd", process.cwd())!;

async function main() {
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, "");
  const rec = (line: unknown) => appendFileSync(out, JSON.stringify(line) + "\n");

  const transport = defaultConnect(piAcpSpec())(cwd, { ...process.env } as Record<string, string>);
  let done = false;
  transport.onExit((code) => {
    if (!done) console.error(`[record] pi-acp exited early: ${code}`);
  });

  const client: AcpClient = {
    sessionUpdate: async (p: SessionNotification) => {
      rec({ t: "update", update: p.update });
    },
    requestPermission: async (p: RequestPermissionRequest): Promise<RequestPermissionResponse> => {
      rec({ t: "permission", toolCall: p.toolCall, options: p.options });
      // Auto-answer so the session proceeds: pick the first choice/allow option.
      const opts = p.options ?? [];
      const pick =
        opts.find((o) => o.kind === "allow_once") ??
        opts.find((o) => o.kind === "allow_always") ??
        opts[0];
      return pick
        ? { outcome: { outcome: "selected", optionId: pick.optionId } }
        : { outcome: { outcome: "cancelled" } };
    },
    readTextFile: async () => ({ content: "" }),
    writeTextFile: async () => ({}),
    unstable_createElicitation: async (params: unknown) => {
      rec({ t: "elicitation", params });
      return { action: "decline" };
    },
    unstable_completeElicitation: async () => {},
  };

  const conn = new ClientSideConnection(() => client, transport.stream);
  await conn.initialize({
    protocolVersion: 1,
    clientCapabilities: {
      fs: { readTextFile: true, writeTextFile: true },
      terminal: false,
      session: { configOptions: { boolean: {} } },
    },
  });
  const sess = await conn.newSession({ cwd, mcpServers: [] });

  rec({ t: "prompt", text: prompt });
  const res: any = await conn.prompt({
    sessionId: sess.sessionId,
    prompt: [{ type: "text", text: prompt }],
  });
  rec({ t: "stopReason", reason: res?.stopReason ?? "unknown" });

  done = true;
  transport.dispose();
  console.error(`[record] wrote ${out}`);
  process.exit(0);
}

main().catch((e) => {
  console.error("[record] error:", e?.message ?? e);
  process.exit(1);
});
