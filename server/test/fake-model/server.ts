/**
 * Fake model server for the real-pi e2e.
 *
 * Serves the OpenAI chat-completions API (`POST …/chat/completions`) with
 * deterministic, scripted responses (see scenarios.ts). The genuine `pi`
 * binary runs unmodified; only its LLM backend is swapped for this stub via a
 * registered custom provider (test/fake-model/provider-extension.ts). This
 * lets the e2e exercise the real pi → pi ACP adapter → WS → app path while keeping
 * the model output deterministic and hermetic (no network, no API keys).
 */

import { createServer, type IncomingMessage, type Server } from "node:http";
import { chooseScenario, toSseLines, type Scenario } from "./scenarios.js";

export interface FakeModelHandle {
  /** Base URL to hand pi's provider config, e.g. http://127.0.0.1:54321/v1 */
  url: string;
  port: number;
  close(): Promise<void>;
}

/** Extract plain text from an OpenAI message `content` (string or parts). */
function messageText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) =>
        part && typeof part === "object" && typeof (part as { text?: unknown }).text === "string"
          ? (part as { text: string }).text
          : "",
      )
      .join("");
  }
  return "";
}

function lastUserPrompt(body: unknown): string {
  const messages =
    body && typeof body === "object" && Array.isArray((body as { messages?: unknown }).messages)
      ? ((body as { messages: Array<{ role?: string; content?: unknown }> }).messages)
      : [];
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i]?.role === "user") return messageText(messages[i]?.content);
  }
  return "";
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => resolve(raw));
  });
}

/** Non-streaming completion (pi uses streaming, but keep the contract whole). */
function nonStreamResponse(scenario: Scenario, model: string): unknown {
  return {
    id: "chatcmpl-fake",
    object: "chat.completion",
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [
      {
        index: 0,
        message: {
          role: "assistant",
          content: scenario.textDeltas.join(""),
          ...(scenario.toolCall
            ? {
                tool_calls: [
                  {
                    id: scenario.toolCall.id,
                    type: "function",
                    function: {
                      name: scenario.toolCall.name,
                      arguments: scenario.toolCall.arguments,
                    },
                  },
                ],
              }
            : {}),
        },
        finish_reason: scenario.finishReason,
      },
    ],
  };
}

export async function startFakeModelServer(
  opts: { host?: string } = {},
): Promise<FakeModelHandle> {
  const host = opts.host ?? "127.0.0.1";

  const server: Server = createServer(async (req, res) => {
    if (req.method === "POST" && req.url && /\/chat\/completions\/?$/.test(req.url)) {
      const raw = await readBody(req);
      let parsed: unknown = {};
      try {
        parsed = JSON.parse(raw);
      } catch {
        parsed = {};
      }
      const scenario = chooseScenario(lastUserPrompt(parsed));
      const model =
        parsed && typeof parsed === "object" && typeof (parsed as { model?: unknown }).model === "string"
          ? (parsed as { model: string }).model
          : "fake-1";
      const stream = !!(parsed && typeof parsed === "object" && (parsed as { stream?: unknown }).stream);

      if (stream) {
        res.writeHead(200, {
          "content-type": "text/event-stream",
          "cache-control": "no-cache",
          connection: "keep-alive",
        });
        for (const line of toSseLines(scenario, model)) res.write(line);
        res.end();
      } else {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify(nonStreamResponse(scenario, model)));
      }
      return;
    }
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "not found" }));
  });

  await new Promise<void>((resolve) => server.listen(0, host, resolve));
  const addr = server.address();
  const port = addr && typeof addr === "object" ? addr.port : 0;

  return {
    url: `http://${host}:${port}/v1`,
    port,
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
}
