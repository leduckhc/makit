/**
 * AcpAdapter — drives any Agent Client Protocol (v1) agent as a subprocess and
 * bridges it to makit's `AgentAdapter` seam. makit acts as the ACP *client*;
 * the agent (e.g. `pi-acp`, `codex-acp`, `claude-agent-acp`) is the server.
 *
 * Lifecycle: spawn agent → `initialize` → `session/new` → one `session/prompt`
 * per user turn. Streaming `session/update` notifications are normalized by
 * {@link AcpEventMapper}. Tool-permission requests are surfaced to the phone
 * via `askUser` (confirmAction).
 *
 * Only pi's native `PiAdapter` gives full-fidelity pi (extension slash commands,
 * ctx.ui.* transport). This path trades some of that for multi-agent reach.
 */

/* eslint-disable @typescript-eslint/no-explicit-any */

import { spawn, type ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { dirname } from "node:path";
import {
  ClientSideConnection,
  ndJsonStream,
  type Agent as AcpAgent,
  type Client as AcpClient,
  type Stream,
  type RequestPermissionRequest,
  type RequestPermissionResponse,
  type SessionNotification,
  type ReadTextFileRequest,
  type WriteTextFileRequest,
  type CreateElicitationRequest,
  type CreateElicitationResponse,
} from "@agentclientprotocol/sdk";
import type { AdapterEvent, AgentAdapter, SpawnOpts, UserInput } from "./adapter.js";
import { AcpEventMapper } from "./acp-map.js";
import type { AskUser } from "../uicall.js";
import { log } from "../log.js";

export interface AcpSpawnSpec {
  /** makit agent label surfaced in the session DTO ("pi", "codex", …). */
  agent: string;
  /** Executable to spawn (the ACP adapter binary). */
  command: string;
  args?: string[];
  /** Extra env for the agent process. */
  env?: Record<string, string>;
}

export interface AcpTransport {
  stream: Stream;
  onExit: (cb: (code: number | null) => void) => void;
  dispose: () => void;
}

export interface AcpAdapterOpts {
  spec: AcpSpawnSpec;
  /**
   * Test seam: supply a transport (in-memory stream to a fake agent) instead of
   * spawning a subprocess. Production leaves this unset → real subprocess.
   */
  connect?: (cwd: string, env: Record<string, string>) => AcpTransport;
}

export class AcpAdapter extends EventEmitter implements AgentAdapter {
  readonly agent: string;

  private readonly spec: AcpSpawnSpec;
  private readonly connectFn: (cwd: string, env: Record<string, string>) => AcpTransport;

  private transport?: AcpTransport;
  private conn?: AcpAgent;
  private acpSessionId?: string;
  private makitSessionId = "";
  private askUser?: AskUser;
  private mapper: AcpEventMapper;

  /** Number of prompt turns currently in flight (mid-turn sends queue at the agent). */
  private inflight = 0;
  /** Number of pending permission approvals (gates awaiting-approval status). */
  private pendingApprovals = 0;
  private exited = false;

  constructor(opts: AcpAdapterOpts) {
    super();
    this.spec = opts.spec;
    this.agent = opts.spec.agent;
    this.connectFn = opts.connect ?? defaultConnect(opts.spec);
    this.mapper = new AcpEventMapper({
      emit: (e) => this.emit("event", e),
      onTitle: (t) => this.emit("title", t),
    });
  }

  async start(opts: SpawnOpts): Promise<void> {
    this.makitSessionId = opts.sessionId ?? "";
    this.askUser = opts.askUser;

    const env = { ...(this.spec.env ?? {}), ...(opts.env ?? {}) };
    this.transport = this.connectFn(opts.cwd, env);
    this.transport.onExit((code) => this.handleExit(code));

    this.conn = new ClientSideConnection(() => this.buildClient(), this.transport.stream);

    await this.conn.initialize({
      protocolVersion: 1,
      clientCapabilities: {
        fs: { readTextFile: true, writeTextFile: true },
        terminal: false,
      },
    });

    if (opts.resumeSessionPath) {
      // ACP resume is keyed by an ACP sessionId (pi-acp maps it to a transcript
      // file internally), not by makit's on-disk path. Cross-world resume is a
      // separate concern; start fresh for now.
      log.warn("[makit] AcpAdapter: resumeSessionPath ignored (ACP resume not wired yet)");
    }

    const res = await this.conn.newSession({ cwd: opts.cwd, mcpServers: [] });
    this.acpSessionId = res.sessionId;
    this.emit("status", "idle");
  }

  async send(input: UserInput): Promise<void> {
    if (!this.conn || !this.acpSessionId) throw new Error("AcpAdapter: send before start");

    // Echo the user message so transcripts are complete (mirrors PiAdapter).
    this.emitEvent({ ts: Date.now(), kind: "user.message", payload: { text: input.text } });

    this.inflight += 1;
    this.emit("status", "running");

    this.conn
      .prompt({
        sessionId: this.acpSessionId,
        prompt: [{ type: "text", text: input.text }],
      })
      .then((res) => {
        // Turn complete: finalize buffered text/thinking + tool state.
        this.mapper.endTurn();
        if ((res as any)?.stopReason === "refusal") {
          this.emitEvent({
            ts: Date.now(),
            kind: "session.error",
            payload: { message: "Agent refused the request." },
          });
        }
      })
      .catch((err) => {
        this.mapper.endTurn();
        this.emitEvent({
          ts: Date.now(),
          kind: "session.error",
          payload: { message: `prompt failed: ${(err as Error)?.message ?? String(err)}` },
        });
      })
      .finally(() => {
        this.inflight = Math.max(0, this.inflight - 1);
        if (this.inflight === 0 && !this.exited) this.emit("status", "idle");
      });
  }

  async cancel(): Promise<void> {
    if (this.conn && this.acpSessionId) {
      await this.conn.cancel({ sessionId: this.acpSessionId });
    }
  }

  async kill(): Promise<void> {
    this.transport?.dispose();
    this.handleExit(null);
  }

  // ---- ACP client handler --------------------------------------------------

  private buildClient(): AcpClient {
    return {
      sessionUpdate: async (params: SessionNotification) => {
        if (params.sessionId !== this.acpSessionId) return;
        this.mapper.handle(params.update);
      },
      requestPermission: async (params: RequestPermissionRequest): Promise<RequestPermissionResponse> => {
        return this.handlePermission(params);
      },
      readTextFile: async (params: ReadTextFileRequest) => {
        const content = await readFile(params.path, "utf8");
        return { content: sliceByLines(content, params.line ?? null, params.limit ?? null) };
      },
      writeTextFile: async (params: WriteTextFileRequest) => {
        await mkdir(dirname(params.path), { recursive: true });
        await writeFile(params.path, params.content, "utf8");
        return {};
      },
      // ACP v1 unstable extension. Minimal support: URL mode + single-field
      // forms map to existing phone UICalls; complex multi-field forms decline.
      unstable_createElicitation: async (params: CreateElicitationRequest): Promise<CreateElicitationResponse> => {
        return this.handleElicitation(params);
      },
      // URL-mode elicitations complete out of band; nothing to render here.
      unstable_completeElicitation: async () => {},
    };
  }

  private async handlePermission(params: RequestPermissionRequest): Promise<RequestPermissionResponse> {
    const options = params.options ?? [];
    const allow = options.find((o) => o.kind === "allow_once") ?? options.find((o) => o.kind === "allow_always");
    const reject = options.find((o) => o.kind === "reject_once") ?? options.find((o) => o.kind === "reject_always");

    // No phone attached → deny (fail safe) or cancel if we can't reject.
    if (!this.askUser) {
      if (reject) return { outcome: { outcome: "selected", optionId: reject.optionId } };
      return { outcome: { outcome: "cancelled" } };
    }

    const prompt = describePermission(params.toolCall);
    this.enterApproval();
    try {
      const resp = await this.askUser({
        kind: "confirmAction",
        sessionId: this.makitSessionId,
        title: prompt.title,
        message: prompt.message,
        action: prompt.action,
        ...(prompt.preview ? { preview: prompt.preview } : {}),
      });
      if (resp.kind === "confirmAction" && !(resp as any).cancelled) {
        const pick = resp.approved ? allow : reject;
        if (pick) return { outcome: { outcome: "selected", optionId: pick.optionId } };
      }
    } catch (e) {
      log.warn(`[makit] AcpAdapter permission error: ${(e as Error).message}`);
    } finally {
      this.leaveApproval();
    }
    return { outcome: { outcome: "cancelled" } };
  }

  /** Enter the awaiting-approval state (first pending request flips the status). */
  private enterApproval(): void {
    this.pendingApprovals += 1;
    if (this.pendingApprovals === 1) {
      this.emitEvent({ ts: Date.now(), kind: "session.status", payload: { status: "awaiting-approval" } });
    }
  }

  /** Leave awaiting-approval; restore running while the turn is still in flight. */
  private leaveApproval(): void {
    this.pendingApprovals = Math.max(0, this.pendingApprovals - 1);
    if (this.pendingApprovals === 0 && !this.exited && this.inflight > 0) {
      this.emit("status", "running");
    }
  }

  /**
   * Minimal ACP elicitation handling:
   *   - url mode        → confirmAction (show the link); accept/decline
   *   - single-field    → input UICall; accept with a typed value
   *   - multi-field     → decline (full form UI deferred)
   * Fail-safe declines when no phone is attached.
   */
  private async handleElicitation(params: CreateElicitationRequest): Promise<CreateElicitationResponse> {
    const p = params as any;
    if (!this.askUser) return { action: "decline" };

    const message = typeof p.message === "string" ? p.message : "The agent needs input.";
    this.enterApproval();
    try {
      if (p.mode === "url") {
        const resp = await this.askUser({
          kind: "confirmAction",
          sessionId: this.makitSessionId,
          title: "Open link?",
          message,
          action: "open-url",
          ...(typeof p.url === "string" ? { preview: p.url } : {}),
        });
        if (resp.kind === "confirmAction" && !(resp as any).cancelled) {
          return resp.approved ? { action: "accept" } : { action: "decline" };
        }
        return { action: "cancel" };
      }

      // form mode
      const props = (p.requestedSchema?.properties ?? {}) as Record<string, any>;
      const names = Object.keys(props);
      if (names.length !== 1) {
        // Multi-field (or empty) forms need the full form UI (deferred).
        log.warn(`[makit] AcpAdapter: declining ${names.length}-field elicitation form (single-field only)`);
        return { action: "decline" };
      }

      const name = names[0];
      const field = props[name] ?? {};
      const resp = await this.askUser({
        kind: "input",
        sessionId: this.makitSessionId,
        title: message,
        placeholder: typeof field.description === "string" ? field.description : field.title,
        prefill: field.default != null ? String(field.default) : undefined,
        multiline: false,
      });
      if (resp.kind === "input" && !resp.cancelled && typeof resp.value === "string") {
        return { action: "accept", content: { [name]: coerceFieldValue(resp.value, field.type) } };
      }
      return { action: "decline" };
    } catch (e) {
      log.warn(`[makit] AcpAdapter elicitation error: ${(e as Error).message}`);
      return { action: "cancel" };
    } finally {
      this.leaveApproval();
    }
  }

  private handleExit(code: number | null): void {
    if (this.exited) return;
    this.exited = true;
    this.emitEvent({ ts: Date.now(), kind: "session.status", payload: { status: "exited" } });
    this.emit("exit", code);
  }

  private emitEvent(e: AdapterEvent): void {
    this.emit("event", e);
  }
}

// ---------- default subprocess transport -----------------------------------

function defaultConnect(spec: AcpSpawnSpec) {
  return (cwd: string, env: Record<string, string>): AcpTransport => {
    const child: ChildProcess = spawn(spec.command, spec.args ?? [], {
      cwd,
      env: { ...process.env, ...env },
      stdio: ["pipe", "pipe", "pipe"],
    });

    child.stderr?.on("data", (chunk: Buffer) => process.stderr.write(`[${spec.agent}-acp] ${chunk}`));

    const stream = ndJsonStream(nodeWritable(child), nodeReadable(child));

    return {
      stream,
      onExit: (cb) => child.on("exit", (code) => cb(code)),
      dispose: () => {
        try {
          child.kill("SIGTERM");
        } catch {
          /* ignore */
        }
      },
    };
  };
}

/** Our outgoing bytes → the agent's stdin. */
function nodeWritable(child: ChildProcess): WritableStream<Uint8Array> {
  return new WritableStream<Uint8Array>({
    write(chunk) {
      return new Promise<void>((resolve) => {
        const stdin = child.stdin;
        if (!stdin || stdin.destroyed || !stdin.writable) return resolve();
        stdin.write(chunk, () => resolve());
      });
    },
    close() {
      try {
        child.stdin?.end();
      } catch {
        /* ignore */
      }
    },
  });
}

/** The agent's stdout → our incoming bytes. */
function nodeReadable(child: ChildProcess): ReadableStream<Uint8Array> {
  return new ReadableStream<Uint8Array>({
    start(controller) {
      const stdout = child.stdout!;
      stdout.on("data", (c: Buffer) => controller.enqueue(new Uint8Array(c)));
      stdout.on("end", () => {
        try {
          controller.close();
        } catch {
          /* already closed */
        }
      });
      stdout.on("error", (e) => {
        try {
          controller.error(e);
        } catch {
          /* ignore */
        }
      });
    },
  });
}

/** ACP `fs/read_text_file` supports optional 1-based line + limit windows. */
function sliceByLines(content: string, line: number | null, limit: number | null): string {
  if (line == null && limit == null) return content;
  const lines = content.split("\n");
  const start = line != null && line > 0 ? line - 1 : 0;
  const end = limit != null ? start + limit : lines.length;
  return lines.slice(start, end).join("\n");
}

/**
 * Turn an ACP permission request's tool call into a phone-friendly confirmAction
 * payload: a kind-specific title, the tool's own description, and a preview of
 * the command / diff being approved.
 */
function describePermission(toolCall: RequestPermissionRequest["toolCall"] | undefined): {
  title: string;
  message: string;
  action: string;
  preview?: string;
} {
  const tc = (toolCall ?? {}) as any;
  const kind: string = typeof tc.kind === "string" ? tc.kind : "tool";
  const title =
    {
      execute: "Run command?",
      edit: "Approve file edit?",
      delete: "Approve deletion?",
      move: "Approve move?",
      read: "Approve file read?",
      fetch: "Approve network fetch?",
    }[kind] ?? "Approve action?";
  const message = typeof tc.title === "string" && tc.title.trim() ? tc.title : `The agent wants to run a ${kind} action.`;
  return { title, message, action: kind, preview: permissionPreview(tc) };
}

function permissionPreview(tc: any): string | undefined {
  // Prefer an explicit shell command; then a diff path; else compact rawInput.
  const cmd = tc?.rawInput?.command ?? tc?.rawInput?.cmd;
  if (typeof cmd === "string" && cmd.trim()) return cmd;
  if (Array.isArray(tc?.content)) {
    const diff = tc.content.find((c: any) => c?.type === "diff");
    if (diff?.path) return `${diff.path}${typeof diff.newText === "string" ? `\n${diff.newText}` : ""}`;
  }
  if (tc?.rawInput && typeof tc.rawInput === "object") {
    try {
      const s = JSON.stringify(tc.rawInput);
      if (s && s !== "{}") return s.length > 500 ? `${s.slice(0, 497)}…` : s;
    } catch {
      /* ignore */
    }
  }
  return undefined;
}

// ---------- elicitation helper ---------------------------------------------
/** Coerce a free-text input value to the elicitation field's declared type. */
function coerceFieldValue(value: string, type: unknown): string | number | boolean {
  if (type === "number" || type === "integer") {
    const n = Number(value);
    return Number.isFinite(n) ? n : value;
  }
  if (type === "boolean") return /^(true|yes|1|y)$/i.test(value.trim());
  return value;
}

// ---------- production spec helper -----------------------------------------
/** Resolve the bundled `pi-acp` binary (override via MAKIT_PI_ACP_BIN). */
export function piAcpSpec(): AcpSpawnSpec {
  return {
    agent: "pi",
    command: process.env.MAKIT_PI_ACP_BIN || "pi-acp",
    args: [],
  };
}

/** Resolve the `codex-acp` binary (override via MAKIT_CODEX_ACP_BIN). */
export function codexAcpSpec(): AcpSpawnSpec {
  return {
    agent: "codex",
    command: process.env.MAKIT_CODEX_ACP_BIN || "codex-acp",
    args: [],
  };
}
