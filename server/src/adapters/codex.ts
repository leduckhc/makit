/**
 * CodexAppServerAdapter — drives Codex's **native** app-server protocol
 * (`codex app-server`, JSON-RPC over stdio) through makit's `AgentAdapter` seam.
 *
 * Unlike the ACP path (codex-acp bridge), this speaks Codex's first-party
 * protocol directly, which exposes richer interaction — notably
 * `item/tool/requestUserInput` (structured questions) that map cleanly to
 * makit's `askUserQuestion`, plus native exec/patch approvals.
 *
 * Envelope (confirmed live): requests `{method,id,params}`, responses
 * `{id,result}` / `{id,error}`, notifications `{method,params}`. No `jsonrpc`
 * field. Lines are newline-delimited JSON.
 */

/* eslint-disable @typescript-eslint/no-explicit-any */

import type { SpawnOpts, UserInput } from "./adapter.js";
import { SubprocessAdapter } from "./subprocess-adapter.js";
import { CodexEventMapper } from "./codex-map.js";
import { spawnLineProcess, type ChildLineTransport } from "./child_transport.js";
import { confirmViaUser, mapElicitation, type ElicitationParams } from "./interaction.js";
import type { AskUser } from "../uicall.js";
import { log } from "../log.js";

/** Codex speaks LF-delimited JSON over stdio — the shared line transport. */
export type CodexTransport = ChildLineTransport;

export interface CodexAdapterOpts {
  /** Executable + args (default: `codex app-server`). */
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  /** Force a model for spawned threads (`turn/start.model`). */
  model?: string;
  /** Test seam: supply a transport instead of spawning a subprocess. */
  connect?: (cwd: string, env: Record<string, string>) => CodexTransport;
}

export class CodexAppServerAdapter extends SubprocessAdapter {
  readonly agent = "codex";

  private readonly command: string;
  private readonly args: string[];
  private readonly extraEnv: Record<string, string>;
  private readonly model?: string;
  private readonly connectFn: (cwd: string, env: Record<string, string>) => CodexTransport;

  private transport?: CodexTransport;
  private mapper: CodexEventMapper;
  private makitSessionId = "";
  private askUser?: AskUser;

  private threadId?: string;
  private nextId = 1;
  private readonly pending = new Map<number, { resolve: (v: any) => void; reject: (e: unknown) => void }>();

  constructor(opts: CodexAdapterOpts = {}) {
    super();
    this.command = opts.command ?? "codex";
    this.args = opts.args ?? ["app-server"];
    this.extraEnv = opts.env ?? {};
    this.model = opts.model;
    this.connectFn = opts.connect ?? defaultConnect(this.command, this.args);
    this.mapper = new CodexEventMapper({
      emit: (e) => this.emit("event", e),
      onTitle: (t) => this.emit("title", t),
    });
  }

  async start(opts: SpawnOpts): Promise<void> {
    this.makitSessionId = opts.sessionId ?? "";
    this.askUser = opts.askUser;

    const env = { ...this.extraEnv, ...(opts.env ?? {}) };
    this.transport = this.connectFn(opts.cwd, env);
    this.transport.onLine((line) => this.handleLine(line));
    this.transport.onExit((code) => this.handleExit(code, () => this.rejectPending()));

    await this.request("initialize", {
      clientInfo: { name: "makit", title: "makit", version: "0.1.0" },
      capabilities: { experimentalApi: true, requestAttestation: false },
    });
    this.notify("initialized", {});

    const started = await this.request("thread/start", {
      cwd: opts.cwd,
      ...(this.model ? { model: this.model } : {}),
    });
    this.threadId = started?.thread?.id;
    if (!this.threadId) throw new Error("codex app-server: thread/start returned no thread id");
    this.emit("status", "idle");
  }

  async send(input: UserInput): Promise<void> {
    if (!this.threadId) throw new Error("CodexAppServerAdapter: send before start");

    this.emitEvent({ ts: Date.now(), kind: "user.message", payload: { text: input.text } });
    this.emit("status", "running");

    try {
      const res = await this.request("turn/start", {
        threadId: this.threadId,
        input: [{ type: "text", text: input.text, text_elements: [] }],
      });
      const turnId = res?.turn?.id;
      if (turnId) this.turns.enterTurn(turnId);
    } catch (err) {
      this.emitEvent({
        ts: Date.now(),
        kind: "session.error",
        payload: { message: `turn/start failed: ${(err as Error)?.message ?? String(err)}` },
      });
      this.turns.settleIdle();
    }
  }

  async cancel(): Promise<void> {
    if (!this.threadId) return;
    for (const turnId of this.turns.activeTurnIds) {
      await this.request("turn/interrupt", { threadId: this.threadId, turnId }).catch(() => {});
    }
  }

  async kill(): Promise<void> {
    this.transport?.dispose();
    this.handleExit(null, () => this.rejectPending());
  }

  // ---- JSON-RPC plumbing ---------------------------------------------------

  private request(method: string, params: unknown): Promise<any> {
    const id = this.nextId++;
    this.write({ method, id, params });
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }

  private notify(method: string, params: unknown): void {
    this.write({ method, params });
  }

  private write(msg: unknown): void {
    this.transport?.send(JSON.stringify(msg));
  }

  private handleLine(line: string): void {
    if (!line.trim()) return;
    let msg: any;
    try {
      msg = JSON.parse(line);
    } catch {
      return;
    }
    if (msg == null || typeof msg !== "object") return;

    // Response to one of our requests.
    if (msg.id !== undefined && (msg.result !== undefined || msg.error !== undefined)) {
      const p = this.pending.get(msg.id);
      if (p) {
        this.pending.delete(msg.id);
        if (msg.error) p.reject(new Error(msg.error?.message ?? JSON.stringify(msg.error)));
        else p.resolve(msg.result);
      }
      return;
    }

    // Server → client request (needs a response).
    if (typeof msg.method === "string" && msg.id !== undefined) {
      void this.handleServerRequest(msg.method, msg.id, msg.params);
      return;
    }

    // Notification.
    if (typeof msg.method === "string") {
      this.handleNotification(msg.method, msg.params);
    }
  }

  private handleNotification(method: string, params: any): void {
    if (method === "turn/started") {
      const id = params?.turn?.id;
      if (id) this.turns.enterTurn(id);
      else this.emit("status", "running");
      return;
    }
    if (method === "turn/completed") {
      const id = params?.turn?.id;
      this.mapper.endTurn();
      if (id) this.turns.leaveTurn(id);
      else this.turns.settleIdle();
      return;
    }
    this.mapper.handle(method, params);
  }

  // ---- server → client requests -------------------------------------------

  private async handleServerRequest(method: string, id: number | string, params: any): Promise<void> {
    try {
      switch (method) {
        case "item/tool/requestUserInput":
          return this.reply(id, await this.handleUserInput(params));
        case "item/commandExecution/requestApproval": {
          const ok = await this.confirm(describeCommand(params), "execute");
          return this.reply(id, { decision: ok ? "accept" : "decline" });
        }
        case "item/fileChange/requestApproval": {
          const ok = await this.confirm(describeFileChange(params), "edit");
          return this.reply(id, { decision: ok ? "accept" : "decline" });
        }
        case "item/permissions/requestApproval": {
          const ok = await this.confirm(
            { message: typeof params?.reason === "string" && params.reason ? params.reason : "Grant additional permissions?" },
            "permissions",
          );
          // Approve → grant exactly what was requested for this turn; deny → grant nothing.
          const req = params?.permissions ?? {};
          return this.reply(id, {
            permissions: ok ? { network: req.network ?? undefined, fileSystem: req.fileSystem ?? undefined } : {},
            scope: "turn",
          });
        }
        case "mcpServer/elicitation/request":
          return this.reply(id, await this.handleElicitation(params));
        case "execCommandApproval": {
          const cmd = Array.isArray(params?.command) ? params.command.join(" ") : "";
          const ok = await this.confirm({ message: cmd || "Run command?", preview: cmd }, "execute");
          return this.reply(id, { decision: ok ? "approved" : "denied" });
        }
        case "applyPatchApproval": {
          const ok = await this.confirm({ message: "Apply patch?", preview: patchPaths(params?.fileChanges) }, "edit");
          return this.reply(id, { decision: ok ? "approved" : "denied" });
        }
        case "currentTime/read":
          return this.reply(id, { currentTime: new Date().toISOString() });
        default:
          // Unknown/unsupported server request — fail cleanly so the agent
          // doesn't hang waiting on us.
          return this.replyError(id, -32601, `unsupported server request: ${method}`);
      }
    } catch (e) {
      log.warn(`[makit] codex server-request error (${method}): ${(e as Error).message}`);
      this.replyError(id, -32000, (e as Error).message);
    }
  }

  /** Codex's native structured questions → makit askUserQuestion. */
  private async handleUserInput(params: any): Promise<{ answers: Record<string, { answers: string[] }> }> {
    const questions: any[] = Array.isArray(params?.questions) ? params.questions : [];
    if (!this.askUser || questions.length === 0) return { answers: {} };

    this.turns.enterApproval("awaiting-input");
    try {
      const resp = await this.askUser({
        kind: "askUserQuestion",
        sessionId: this.makitSessionId,
        questions: questions.map((q) => ({
          header: typeof q?.header === "string" ? q.header : undefined,
          question: String(q?.question ?? "?"),
          options: (Array.isArray(q?.options) && q.options.length
            ? q.options
            : [{ label: "Yes" }, { label: "No" }]
          ).map((o: any) => ({ label: String(o?.label ?? o), description: o?.description })),
          multi: q?.multiSelect === true,
        })),
      });
      const answers: Record<string, { answers: string[] }> = {};
      if (resp.kind === "askUserQuestion" && !(resp as any).cancelled && Array.isArray(resp.answers)) {
        questions.forEach((q, i) => {
          const a = resp.answers[i];
          if (typeof a === "string") answers[String(q.id)] = { answers: [a] };
        });
      }
      return { answers };
    } finally {
      this.turns.leaveApproval();
    }
  }

  /**
   * Minimal MCP elicitation (mirrors the ACP path): url mode -> confirmAction,
   * single-field form -> input, complex/multi-field -> decline.
   */
  private async handleElicitation(params: any): Promise<{ action: string; content: unknown; _meta: null }> {
    if (!this.askUser) return { action: "decline", content: null, _meta: null };
    this.turns.enterApproval("awaiting-input");
    try {
      const result = await mapElicitation(params as ElicitationParams, this.askUser, this.makitSessionId);
      // Codex's wire shape has no `cancel`; a user cancel maps to decline.
      const action = result.action === "cancel" ? "decline" : result.action;
      return { action, content: result.content ?? null, _meta: null };
    } finally {
      this.turns.leaveApproval();
    }
  }

  private async confirm(
    prompt: { message: string; preview?: string },
    action: string,
  ): Promise<boolean> {
    if (!this.askUser) return false; // fail safe: deny
    this.turns.enterApproval("awaiting-approval");
    try {
      return await confirmViaUser(this.askUser, {
        sessionId: this.makitSessionId,
        title: action === "execute" ? "Run command?" : "Approve change?",
        message: prompt.message,
        action,
        ...(prompt.preview ? { preview: prompt.preview } : {}),
      });
    } finally {
      this.turns.leaveApproval();
    }
  }

  private reply(id: number | string, result: unknown): void {
    this.write({ id, result });
  }

  private replyError(id: number | string, code: number, message: string): void {
    this.write({ id, error: { code, message } });
  }

  private rejectPending(): void {
    for (const [, p] of this.pending) p.reject(new Error("codex app-server exited"));
    this.pending.clear();
  }
}

// ---------- default subprocess transport -----------------------------------

export function defaultConnect(command: string, args: string[]) {
  return (cwd: string, env: Record<string, string>): CodexTransport =>
    spawnLineProcess({ command, args, cwd, env, label: "codex-app-server" });
}

function describeCommand(params: any): { message: string; preview?: string } {
  const cmd = typeof params?.command === "string" ? params.command : "";
  const reason = typeof params?.reason === "string" ? params.reason : "";
  return { message: reason || cmd || "Run command?", preview: cmd || undefined };
}

function describeFileChange(params: any): { message: string; preview?: string } {
  const reason = typeof params?.reason === "string" ? params.reason : "";
  return { message: reason || "Apply file changes?", preview: params?.grantRoot ? String(params.grantRoot) : undefined };
}

function patchPaths(fileChanges: unknown): string | undefined {
  if (!fileChanges || typeof fileChanges !== "object") return undefined;
  const keys = Object.keys(fileChanges as Record<string, unknown>);
  return keys.length ? keys.join("\n") : undefined;
}
