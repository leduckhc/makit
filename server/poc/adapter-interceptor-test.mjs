// Integration test: real PiAdapter + poc-ui-ext, fake askUser (the "phone").
import { PiAdapter } from "../src/adapters/pi.ts";

const adapter = new PiAdapter();
let toolText = null;
const uiCalls = [];

adapter.on("event", (e) => {
  if (e.kind === "tool.call.end" && (e.payload?.output ?? '').includes('color=')) { toolText = e.payload.output; }
  if (e.kind === "agent.message") {
    if ((e.payload?.text ?? "").includes("color=")) toolText = e.payload.text;
  }
});

await adapter.start({
  cwd: process.cwd(),
  sessionId: "adapter-int",
  extensions: ["poc/poc-ui-ext.ts"],
  // The "phone": translate each canonical UICall to an answer.
  askUser: async (call) => {
    uiCalls.push(call.kind);
    if (call.kind === "askUserQuestion") {
      const opts = call.questions[0].options.map((o) => o.label);
      const pick = opts.includes("Green") ? "Green" : opts[0];
      return { kind: "askUserQuestion", indices: [opts.indexOf(pick)], answers: [pick], answer: pick };
    }
    if (call.kind === "confirmAction") return { kind: "confirmAction", approved: true };
    if (call.kind === "input") return { kind: "input", value: "Ada" };
    return { kind: call.kind, cancelled: true };
  },
});

await adapter.send({ text: "Call poc_ask now." });

await new Promise((r) => setTimeout(r, 40000));
console.error("uiCalls seen:", uiCalls.join(", "));
console.error("tool text:", JSON.stringify(toolText));
const ok = toolText && toolText.includes("color=Green") && toolText.includes("sure=true") && toolText.includes("name=Ada");
console.error(ok ? "✅ PASS — PiAdapter interceptor transported select/confirm/input" : "❌ FAIL");
await adapter.kill();
process.exit(ok ? 0 : 1);
