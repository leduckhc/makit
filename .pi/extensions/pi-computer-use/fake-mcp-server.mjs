#!/usr/bin/env node
/**
 * A fake stdio MCP server, standing in for `cua-driver mcp` in tests (the real
 * binary is not installed on CI or on a dev box without desktop grants — this
 * is the same idea as Hermes' `HERMES_COMPUTER_USE_BACKEND=noop`).
 *
 * Speaks newline-delimited JSON-RPC 2.0 and advertises two tools: one that
 * returns text + a PNG (a `capture`), one that returns text only (a `click`).
 * `FAKE_MCP_FAIL=1` makes `capture` answer with a JSON-RPC error instead.
 */

/** A real 1x1 red PNG: the model rejects a payload that is not decodable. */
const PNG_1PX = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC";

let buf = "";
process.stdin.on("data", (chunk) => {
  buf += chunk;
  const lines = buf.split("\n");
  buf = lines.pop() ?? "";
  for (const line of lines) if (line.trim()) handle(JSON.parse(line));
});

const send = (msg) => process.stdout.write(JSON.stringify(msg) + "\n");
const reply = (id, result) => send({ jsonrpc: "2.0", id, result });

function handle(msg) {
  switch (msg.method) {
    case "initialize":
      return reply(msg.id, {
        protocolVersion: "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "fake-cua-driver", version: "0.0.0-fake" },
      });
    case "notifications/initialized":
      return; // notification: no reply
    case "tools/list":
      return reply(msg.id, {
        tools: [
          {
            name: "capture",
            description: "Screenshot a window with numbered elements.",
            inputSchema: {
              type: "object",
              properties: { app: { type: "string" }, mode: { type: "string", enum: ["som", "ax"] } },
              required: [],
            },
          },
          {
            name: "click",
            description: "Click an element by index.",
            inputSchema: {
              type: "object",
              properties: { element: { type: "number" } },
              required: ["element"],
            },
          },
        ],
      });
    case "tools/call": {
      const { name, arguments: args } = msg.params ?? {};
      if (name === "capture") {
        if (process.env.FAKE_MCP_FAIL === "1") {
          return send({ jsonrpc: "2.0", id: msg.id, error: { code: -32000, message: "screen recording denied" } });
        }
        return reply(msg.id, {
          content: [
            { type: "text", text: `captured ${args?.app ?? "screen"} (2 elements)` },
            { type: "image", data: PNG_1PX, mimeType: "image/png" },
          ],
        });
      }
      if (name === "crash") {
        // Exit without replying: lets a test observe the client's behaviour after
        // the driver dies mid-flight.
        process.exit(0);
      }
      if (name === "click") {
        return reply(msg.id, { content: [{ type: "text", text: `clicked ${args?.element}` }] });
      }
      return reply(msg.id, { content: [{ type: "text", text: "unknown tool" }], isError: true });
    }
    default:
      if (msg.id !== undefined) send({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "no such method" } });
  }
}
