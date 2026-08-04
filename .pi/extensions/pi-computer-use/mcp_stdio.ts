/**
 * A minimal stdio MCP client — enough to hand pi the tools of an MCP server it
 * cannot talk to itself.
 *
 * pi has no MCP client (`pi-acp` advertises `mcpCapabilities: {http:false,
 * sse:false}` and ignores ACP `mcpServers` outright), so the only way to give a
 * pi session `cua-driver`'s desktop tools is to speak MCP here and republish
 * each tool through `pi.registerTool()`.
 *
 * Deliberately generic: tools are discovered via `tools/list` rather than
 * hardcoded, so this works against whatever version of cua-driver is installed
 * (and against a fake server in tests) without makit having to track its tool
 * vocabulary. That is the opposite of Hermes, which hardcodes a single
 * `computer_use(action=…)` facade — Hermes can afford that because it ships in
 * lockstep with a tested driver baseline; makit cannot.
 *
 * Transport is newline-delimited JSON-RPC 2.0 over the child's stdin/stdout,
 * per the MCP stdio transport.
 */

import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";

/** MCP protocol revision we negotiate. Servers may answer with another. */
const PROTOCOL_VERSION = "2025-06-18";

export interface McpTool {
  name: string;
  description?: string;
  /** Raw JSON Schema from the server; passed to pi as the tool's parameters. */
  inputSchema?: unknown;
}

/** pi's `ToolResultMessage.content` element types (see `pi-ai` `types.d.ts`). */
export type PiContent = { type: "text"; text: string } | { type: "image"; data: string; mimeType: string };

export interface McpCallResult {
  content: PiContent[];
  isError: boolean;
}

export interface McpStdioOpts {
  command: string;
  args: string[];
  env?: Record<string, string>;
  cwd?: string;
  /** Per-request deadline; a wedged driver must not hang the pi turn forever. */
  timeoutMs?: number;
}

export class McpStdioClient {
  private child?: ChildProcessWithoutNullStreams;
  private buf = "";
  private nextId = 1;
  private readonly pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  private readonly timeoutMs: number;
  serverInfo?: { name?: string; version?: string };

  constructor(private readonly opts: McpStdioOpts) {
    this.timeoutMs = opts.timeoutMs ?? 30_000;
  }

  /** Spawn the server, handshake, and return its advertised tools. */
  async start(): Promise<McpTool[]> {
    const child = spawn(this.opts.command, this.opts.args, {
      cwd: this.opts.cwd,
      // cua-driver ships PostHog usage telemetry enabled upstream; a session
      // that is remote-controlling someone's desktop is not something makit
      // reports on their behalf. Same default Hermes applies.
      env: { ...process.env, CUA_DRIVER_RS_TELEMETRY_ENABLED: "0", ...this.opts.env },
      stdio: ["pipe", "pipe", "pipe"],
    }) as ChildProcessWithoutNullStreams;
    this.child = child;

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => this.onData(chunk));
    // stderr is the server's log channel, not protocol — drained so a chatty
    // driver cannot fill its pipe buffer and deadlock.
    child.stderr.resume();
    // A dead child must be uninstalled, not just have its waiters failed: a later
    // `request()` would otherwise pass the `if (!child)` guard, write to a closed
    // stdin (an unhandled EPIPE can take down the whole pi process) and then sit
    // until the request deadline instead of failing at once.
    child.stdin.on("error", () => this.retire(child, new Error("computer-use driver stdin failed")));
    child.on("exit", () => this.retire(child, new Error("computer-use driver exited")));
    child.on("error", (err) => this.retire(child, err));

    const init = (await this.request("initialize", {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: "makit-pi-computer-use", version: "0.1.0" },
    })) as { serverInfo?: { name?: string; version?: string } };
    this.serverInfo = init?.serverInfo;
    this.notify("notifications/initialized", {});

    const listed = (await this.request("tools/list", {})) as { tools?: unknown };
    return Array.isArray(listed?.tools) ? (listed.tools as McpTool[]).filter((t) => typeof t?.name === "string") : [];
  }

  /**
   * Invoke a tool. A protocol error is returned as an error *result* rather than
   * thrown: the model should see "screen recording denied" and adapt, not have
   * its turn torn down.
   */
  async call(name: string, args: Record<string, unknown>): Promise<McpCallResult> {
    let res: { content?: unknown; isError?: unknown };
    try {
      res = (await this.request("tools/call", { name, arguments: args })) as typeof res;
    } catch (err) {
      return { content: [{ type: "text", text: (err as Error)?.message ?? String(err) }], isError: true };
    }
    return { content: toPiContent(res?.content), isError: res?.isError === true };
  }

  async dispose(): Promise<void> {
    const child = this.child;
    this.child = undefined;
    this.failAll(new Error("computer-use driver is not running"));
    child?.stdin.end();
    child?.kill();
  }

  // ---- transport -----------------------------------------------------------

  private request(method: string, params: unknown): Promise<unknown> {
    const child = this.child;
    if (!child) return Promise.reject(new Error("computer-use driver is not running"));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`computer-use driver timed out after ${this.timeoutMs}ms (${method})`));
      }, this.timeoutMs);
      this.pending.set(id, {
        resolve: (v) => {
          clearTimeout(timer);
          resolve(v);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  }

  private notify(method: string, params: unknown): void {
    this.child?.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
  }

  private onData(chunk: string): void {
    this.buf += chunk;
    const lines = this.buf.split("\n");
    this.buf = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) continue;
      let msg: { id?: unknown; result?: unknown; error?: { message?: string } };
      try {
        msg = JSON.parse(line);
      } catch {
        continue; // not protocol (a log line on stdout) — ignore
      }
      if (typeof msg.id !== "number") continue; // server-initiated: unsupported
      const waiter = this.pending.get(msg.id);
      if (!waiter) continue;
      this.pending.delete(msg.id);
      if (msg.error) waiter.reject(new Error(msg.error.message ?? "MCP error"));
      else waiter.resolve(msg.result);
    }
  }

  private failAll(err: Error): void {
    for (const { reject } of this.pending.values()) reject(err);
    this.pending.clear();
  }

  /**
   * Drop `child` as the active driver and fail its in-flight requests. Guarded on
   * identity so a late event from an already-replaced child cannot retire its
   * successor.
   */
  private retire(child: ChildProcessWithoutNullStreams, err: Error): void {
    if (this.child === child) this.child = undefined;
    this.failAll(err);
  }
}

/**
 * MCP result content → pi tool-result content. Text and images survive (pi's
 * `ToolResultMessage.content` accepts `ImageContent`, which is what makes
 * screenshots usable at all); audio and resource links are dropped because pi
 * has nowhere to put them. Never returns an empty array — an empty tool result
 * reads as a malformed message to some providers.
 */
export function toPiContent(content: unknown): PiContent[] {
  const out: PiContent[] = [];
  if (Array.isArray(content)) {
    for (const block of content) {
      if (!block || typeof block !== "object") continue;
      const b = block as { type?: unknown; text?: unknown; data?: unknown; mimeType?: unknown };
      if (b.type === "text" && typeof b.text === "string") out.push({ type: "text", text: b.text });
      else if (b.type === "image" && typeof b.data === "string" && typeof b.mimeType === "string")
        out.push({ type: "image", data: b.data, mimeType: b.mimeType });
    }
  }
  return out.length > 0 ? out : [{ type: "text", text: "(no output)" }];
}
