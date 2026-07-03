/**
 * Pure terminal-rendering logic for the `pino attach` client. Kept free of I/O
 * so it can be unit-tested: given a SessionEvent and the running RenderState,
 * it returns the ANSI string to print and the next state.
 *
 * Streaming: agent.message.delta chunks for one msgId are printed inline (the
 * bubble grows on a single line); the authoritative agent.message that finalizes
 * that msgId just closes the line instead of reprinting the text.
 */
import type { SessionEvent } from "../protocol.js";

export interface RenderState {
  /** msgId of the agent bubble currently streaming inline, if any. */
  streamingMsgId?: string;
  /** true when the last write left the cursor mid-line (no trailing newline). */
  midLine?: boolean;
}

const C = {
  reset: "\x1b[0m",
  dim: "\x1b[2m",
  cyan: "\x1b[36m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  red: "\x1b[31m",
};

function str(v: unknown): string {
  return typeof v === "string" ? v : v == null ? "" : String(v);
}

function oneLine(s: string, max = 100): string {
  const first = s.replace(/\s+/g, " ").trim();
  return first.length > max ? first.slice(0, max - 1) + "…" : first;
}

/** Map one session event to terminal output + the next render state. */
export function renderEvent(
  ev: SessionEvent,
  st: RenderState,
): { out: string; st: RenderState } {
  const p = ev.payload as Record<string, unknown>;
  // Close any open (mid-line) streamed bubble before non-delta output.
  const nl = st.midLine ? "\n" : "";

  switch (ev.kind) {
    case "user.message":
      return { out: `${nl}\n${C.cyan}you ›${C.reset} ${str(p.text)}\n`, st: {} };

    case "agent.message.delta": {
      const msgId = str(p.msgId);
      const chunk = str(p.chunk);
      if (st.streamingMsgId === msgId) {
        return { out: chunk, st: { streamingMsgId: msgId, midLine: true } };
      }
      return {
        out: `${nl}\n${C.green}pi ›${C.reset} ${chunk}`,
        st: { streamingMsgId: msgId, midLine: true },
      };
    }

    case "agent.message": {
      const msgId = p.msgId ? str(p.msgId) : undefined;
      if (msgId && st.streamingMsgId === msgId) {
        // Deltas already printed the text — just close the line.
        return { out: "\n", st: {} };
      }
      return { out: `${nl}\n${C.green}pi ›${C.reset} ${str(p.text)}\n`, st: {} };
    }

    case "agent.thinking":
      return {
        out: `${nl}${C.dim}  … ${oneLine(str(p.text))}${C.reset}\n`,
        st: {},
      };

    case "tool.call.start": {
      const name = str(p.name);
      return { out: `${nl}${C.yellow}⚙ ${name}${C.reset}\n`, st: {} };
    }

    case "tool.call.end": {
      const bad = Number(p.exitCode) !== 0;
      const mark = bad ? `${C.red}✗${C.reset}` : `${C.dim}✓${C.reset}`;
      const sum = p.summary ? ` ${C.dim}${oneLine(str(p.summary))}${C.reset}` : "";
      return { out: `${nl}  ${mark}${sum}\n`, st: {} };
    }

    case "session.status":
      return { out: `${nl}${C.dim}[${str(p.status)}]${C.reset}\n`, st: {} };

    case "session.error":
      return {
        out: `${nl}${C.red}error: ${str(p.message)}${C.reset}\n`,
        st: {},
      };

    // Not rendered in the terminal MVP.
    case "tool.call.delta":
    case "session.commands":
      return { out: "", st };
  }
  return { out: "", st };
}
