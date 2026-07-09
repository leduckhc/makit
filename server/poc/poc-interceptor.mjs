/**
 * POC harness: proves the interceptor architecture at the pi rpc boundary.
 *
 * Spawns `pi --mode rpc -e poc-ui-ext.ts`, prompts the model to call poc_ask,
 * and plays makit/PiAdapter: whenever pi emits an `extension_ui_request`, we
 * translate + auto-answer (simulating the phone) with an `extension_ui_response`.
 *
 * Success = the tool returns "color=Green sure=true name=Ada" (our canned
 * answers), proving select/confirm/input all round-trip through interception.
 */
import { spawn } from "node:child_process";

const child = spawn(
  "pi",
  ["--mode", "rpc", "--session-id", "poc-interceptor", "-e", "poc/poc-ui-ext.ts"],
  { cwd: process.cwd(), stdio: ["pipe", "pipe", "pipe"] },
);

const send = (obj) => child.stdin.write(JSON.stringify(obj) + "\n");

// Canned "phone" answers keyed by pi's UI method.
function answer(req) {
  switch (req.method) {
    case "select":
      // req.options is string[]; pick "Green".
      return { value: req.options.includes("Green") ? "Green" : req.options[0] };
    case "confirm":
      return { confirmed: true };
    case "input":
      return { value: "Ada" };
    default:
      return { cancelled: true };
  }
}

let buf = "";
let toolResult = null;
child.stdout.on("data", (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, i);
    buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    let e;
    try { e = JSON.parse(line); } catch { continue; }

    if (e.type === "extension_ui_request") {
      if (["notify", "setStatus", "setWidget", "setTitle", "set_editor_text"].includes(e.method)) {
        continue; // fire-and-forget, no response
      }
      const resp = answer(e);
      console.error(`[intercept] ${e.method}("${e.title}") → ${JSON.stringify(resp)}`);
      send({ type: "extension_ui_response", id: e.id, ...resp });
    } else if (e.type === "tool_execution_end" && e.toolName === "poc_ask") {
      toolResult = e.result;
      console.error(`[tool] poc_ask isError=${e.isError} result=${JSON.stringify(e.result)}`);
    }
  }
});
child.stderr.on("data", (d) => process.stderr.write("[pi] " + d));

setTimeout(() => send({ id: "p1", type: "prompt", message: "Call poc_ask now." }), 1500);
setTimeout(() => {
  const text = toolResult?.content?.[0]?.text ?? "";
  const ok = text.includes("color=Green") && text.includes("sure=true") && text.includes("name=Ada");
  console.error("\n=== POC RESULT ===");
  console.error(ok ? "✅ PASS — select/confirm/input all round-tripped via interception" : "❌ FAIL");
  console.error("tool text:", JSON.stringify(text));
  child.kill();
  process.exit(ok ? 0 : 1);
}, 45000);
