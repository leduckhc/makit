/**
 * Deterministic scenario logic for the fake model server used by the real-pi
 * e2e (server/test/fake-model/server.ts). Pure + side-effect free so it can be
 * unit-tested without a socket.
 *
 * The fake model speaks the OpenAI chat-completions streaming wire format,
 * which is what pi's `openai-completions` provider client consumes. A prompt
 * selects a scenario; a scenario serializes to a fixed sequence of SSE chunks.
 * Determinism is the whole point: the real-pi e2e asserts exact rendered text.
 */

export interface FakeToolCall {
  id: string;
  name: string;
  /** JSON-encoded arguments, streamed as a single fragment. */
  arguments: string;
}

export interface Scenario {
  name: "text" | "tool";
  /** Assistant content fragments, streamed one chunk each. */
  textDeltas: string[];
  toolCall?: FakeToolCall;
  finishReason: "stop" | "tool_calls";
}

/** The canonical happy-path reply. Tests assert this exact string renders. */
const DEFAULT_REPLY_DELTAS = ["makit ", "e2e ", "ok"];

/**
 * Map a user prompt to a scenario. Tests embed an explicit marker so the
 * mapping never depends on fuzzy natural-language matching.
 */
export function chooseScenario(prompt: string): Scenario {
  if (prompt.toLowerCase().includes("[[tool]]")) {
    return {
      name: "tool",
      textDeltas: [],
      toolCall: { id: "call_fake_1", name: "ls", arguments: '{"path":"."}' },
      finishReason: "tool_calls",
    };
  }
  return { name: "text", textDeltas: DEFAULT_REPLY_DELTAS, finishReason: "stop" };
}

/**
 * Serialize a scenario to OpenAI chat-completions SSE lines (each already
 * `data: …\n\n`-framed), terminated by `data: [DONE]\n\n`.
 */
export function toSseLines(
  scenario: Scenario,
  model: string,
  now: () => number = Date.now,
): string[] {
  const id = "chatcmpl-fake";
  const created = Math.floor(now() / 1000);
  const chunk = (
    delta: Record<string, unknown>,
    finishReason: string | null = null,
  ): string => {
    const payload = {
      id,
      object: "chat.completion.chunk",
      created,
      model,
      choices: [{ index: 0, delta, finish_reason: finishReason }],
    };
    return `data: ${JSON.stringify(payload)}\n\n`;
  };

  const lines: string[] = [];
  lines.push(chunk({ role: "assistant" }));
  for (const content of scenario.textDeltas) lines.push(chunk({ content }));
  if (scenario.toolCall) {
    lines.push(
      chunk({
        tool_calls: [
          {
            index: 0,
            id: scenario.toolCall.id,
            type: "function",
            function: {
              name: scenario.toolCall.name,
              arguments: scenario.toolCall.arguments,
            },
          },
        ],
      }),
    );
  }
  lines.push(chunk({}, scenario.finishReason));
  lines.push("data: [DONE]\n\n");
  return lines;
}
