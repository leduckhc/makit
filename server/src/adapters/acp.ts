/**
 * AcpAdapter — drives any Agent Client Protocol (v1) agent as a subprocess and
 * bridges it to makit's `AgentAdapter` seam. makit acts as the ACP *client*;
 * the agent (e.g. `codex-acp`, `claude-agent-acp`) is the server.
 *
 * Lifecycle: spawn agent → `initialize` → `session/new` → one `session/prompt`
 * per user turn. Streaming `session/update` notifications are normalized by
 * {@link AcpEventMapper}. Tool-permission requests are surfaced to the phone
 * via `askUser` (confirmAction).
 *
 * Only pi's native `PiAdapter` gives full-fidelity pi (extension slash commands,
 * ctx.ui.* transport). This path trades some of that for multi-agent reach.
 */

import { readFile, writeFile, mkdir, realpath } from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import {
  ClientSideConnection,
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
import type { AnyMessage } from "@agentclientprotocol/sdk";
import type { SpawnOpts, UserInput } from "./adapter.js";
import { SubprocessAdapter } from "./subprocess-adapter.js";
import { AcpEventMapper } from "./acp-map.js";
import { spawnLineProcess } from "./child_transport.js";
import { mapElicitation, type ElicitationParams } from "./interaction.js";
import { isRecord } from "./wire.js";
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

export class AcpAdapter extends SubprocessAdapter {
  readonly agent: string;

  private readonly spec: AcpSpawnSpec;
  private readonly connectFn: (cwd: string, env: Record<string, string>) => AcpTransport;

  private transport?: AcpTransport;
  private conn?: ClientSideConnection;
  private acpSessionId?: string;
  private makitSessionId = "";
  private workspaceRoot = "";
  private askUser?: AskUser;
  private mapper: AcpEventMapper;

  /**
   * ACP session modes (currentModeId + availableModes), when the agent supports
   * them. ACP has no model/thinking concept, so this is the only meta an ACP
   * agent can feed the composer — surfaced as the session-mode selector.
   */
  private modes?: { current: string; available: { id: string; name: string }[] };

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
    // Canonicalize the workspace ONCE and use it everywhere: as the sandbox
    // root, as the cwd handed to the agent process, and as the newSession cwd.
    // The sandbox realpaths every requested path, so if we advertised a
    // non-canonical cwd (e.g. macOS /var→/private/var, or any symlinked repo
    // dir) the agent's in-workspace paths would resolve to the canonical form
    // and be wrongly rejected as "outside the workspace".
    const cwd = await realpath(opts.cwd);
    this.workspaceRoot = cwd;

    const env = { ...(this.spec.env ?? {}), ...(opts.env ?? {}) };
    this.transport = this.connectFn(cwd, env);
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
      // ACP resume is keyed by an ACP sessionId, not by makit's on-disk path.
      // Cross-world resume is a separate concern; start fresh for now.
      log.warn("[makit] AcpAdapter: resumeSessionPath ignored (ACP resume not wired yet)");
    }

    const res = await this.conn.newSession({ cwd, mcpServers: [] });
    this.acpSessionId = res.sessionId;
    this.captureModes(res.modes);
    this.emit("status", "idle");
    this.emitMeta();
  }

  async send(input: UserInput): Promise<void> {
    if (!this.conn || !this.acpSessionId) throw new Error("AcpAdapter: send before start");

    // Echo the user message so transcripts are complete (mirrors PiAdapter).
    this.emitEvent({ ts: Date.now(), kind: "user.message", payload: { text: input.text } });

    const turnKey = this.turns.enterTurn();

    this.conn
      .prompt({
        sessionId: this.acpSessionId,
        prompt: [{ type: "text", text: input.text }],
      })
      .then((res) => {
        // Turn complete: finalize buffered text/thinking + tool state.
        this.mapper.endTurn();
        if ((res as { stopReason?: string })?.stopReason === "refusal") {
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
        this.turns.leaveTurn(turnKey);
      });
  }

  async cancel(): Promise<void> {
    if (this.conn && this.acpSessionId) {
      await this.conn.cancel({ sessionId: this.acpSessionId });
    }
  }

  /**
   * Control actions from the app. ACP only supports session-mode switching
   * (no model/thinking), so `mode` maps to `session/set_session_mode`; other
   * actions are silently ignored on this transport.
   */
  async sendAction(action: string, args?: Record<string, unknown>): Promise<void> {
    if (action !== "mode" || !this.conn || !this.acpSessionId) return;
    const modeId = typeof args?.id === "string" ? args.id : "";
    if (!modeId) return;
    if (!this.conn.setSessionMode) return;
    await this.conn.setSessionMode({ sessionId: this.acpSessionId, modeId });
    // Reflect immediately; the agent may also confirm via current_mode_update.
    if (this.modes) {
      this.modes = { ...this.modes, current: modeId };
      this.emitMeta();
    }
  }

  /** Cache ACP mode state from a newSession response (no-op if unsupported). */
  private captureModes(
    state:
      | { currentModeId?: string; availableModes?: { id: string; name: string }[] }
      | null
      | undefined,
  ): void {
    if (!state || !Array.isArray(state.availableModes) || state.availableModes.length === 0) {
      return;
    }
    this.modes = {
      current:
        typeof state.currentModeId === "string"
          ? state.currentModeId
          : state.availableModes[0]!.id,
      available: state.availableModes.map((m) => ({ id: m.id, name: m.name })),
    };
  }

  /** Emit the ACP session modes as `session.meta` (only when modes exist). */
  private emitMeta(): void {
    if (!this.modes) return;
    this.emitEvent({
      ts: Date.now(),
      kind: "session.meta",
      payload: { model: null, thinking: "", models: [], modes: this.modes },
    });
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
        // The agent can switch modes autonomously; keep the selector in sync.
        const u = params.update as { sessionUpdate?: string; currentModeId?: string };
        if (u.sessionUpdate === "current_mode_update") {
          if (this.modes && typeof u.currentModeId === "string") {
            this.modes = { ...this.modes, current: u.currentModeId };
            this.emitMeta();
          }
          return;
        }
        this.mapper.handle(params.update);
      },
      requestPermission: async (params: RequestPermissionRequest): Promise<RequestPermissionResponse> => {
        return this.handlePermission(params);
      },
      readTextFile: async (params: ReadTextFileRequest) => {
        const path = await this.workspacePath(params.path, false);
        const content = await readFile(path, "utf8");
        return { content: sliceByLines(content, params.line ?? null, params.limit ?? null) };
      },
      writeTextFile: async (params: WriteTextFileRequest) => {
        const path = await this.workspacePath(params.path, true);
        await mkdir(dirname(path), { recursive: true });
        await writeFile(path, params.content, "utf8");
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
    this.turns.enterApproval("awaiting-approval");
    try {
      const resp = await this.askUser({
        kind: "confirmAction",
        sessionId: this.makitSessionId,
        title: prompt.title,
        message: prompt.message,
        action: prompt.action,
        ...(prompt.preview ? { preview: prompt.preview } : {}),
      });
      if (resp.kind === "confirmAction" && !(resp as { cancelled?: boolean }).cancelled) {
        const pick = resp.approved ? allow : reject;
        if (pick) return { outcome: { outcome: "selected", optionId: pick.optionId } };
      }
    } catch (e) {
      log.warn(`[makit] AcpAdapter permission error: ${(e as Error).message}`);
    } finally {
      this.turns.leaveApproval();
    }
    return { outcome: { outcome: "cancelled" } };
  }

  /**
   * Minimal ACP elicitation handling:
   *   - url mode        → confirmAction (show the link); accept/decline
   *   - single-field    → input UICall; accept with a typed value
   *   - multi-field     → decline (full form UI deferred)
   * Fail-safe declines when no phone is attached.
   */
  private async handleElicitation(params: CreateElicitationRequest): Promise<CreateElicitationResponse> {
    if (!this.askUser) return { action: "decline" };
    this.turns.enterApproval("awaiting-approval");
    try {
      const result = await mapElicitation(params as ElicitationParams, this.askUser, this.makitSessionId);
      return result.action === "accept"
        ? { action: "accept", content: result.content }
        : { action: result.action };
    } catch (e) {
      log.warn(`[makit] AcpAdapter elicitation error: ${(e as Error).message}`);
      return { action: "cancel" };
    } finally {
      this.turns.leaveApproval();
    }
  }

  private async workspacePath(requestedPath: string, forWrite: boolean): Promise<string> {
    const candidate = resolve(this.workspaceRoot, requestedPath);
    this.assertWithinWorkspace(candidate);

    if (!forWrite) {
      const resolved = await realpath(candidate);
      this.assertWithinWorkspace(resolved);
      return resolved;
    }

    let existing = candidate;
    while (true) {
      try {
        const resolved = await realpath(existing);
        this.assertWithinWorkspace(resolved);
        return candidate;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        const parent = dirname(existing);
        if (parent === existing) throw error;
        existing = parent;
      }
    }
  }

  private assertWithinWorkspace(path: string): void {
    const rel = relative(this.workspaceRoot, path);
    if (rel === ".." || rel.startsWith(`..${process.platform === "win32" ? "\\\\" : "/"}`) || isAbsolute(rel)) {
      throw new Error("ACP filesystem path is outside the session workspace");
    }
  }
}

// ---------- default subprocess transport -----------------------------------

export function defaultConnect(spec: AcpSpawnSpec) {
  return (cwd: string, env: Record<string, string>): AcpTransport => {
    const proc = spawnLineProcess({
      command: spec.command,
      args: spec.args ?? [],
      cwd,
      env,
      label: `${spec.agent}-acp`,
    });
    return {
      stream: lineTransportToStream(proc),
      onExit: (cb) => proc.onExit((code) => cb(code)),
      dispose: () => proc.dispose(),
    };
  };
}

/**
 * Adapt the shared LF-delimited-JSON line transport to the ACP SDK's
 * {@link Stream} (a duplex of parsed messages). This is the ACP equivalent of
 * `ndJsonStream` over a subprocess, but layered on the shared crash-guarded
 * transport so the spawn/stderr/settle/error-swallow invariant lives in one
 * place.
 */
function lineTransportToStream(proc: {
  send: (line: string) => void;
  onLine: (cb: (line: string) => void) => void;
  onStreamEnd: (cb: () => void) => void;
}): Stream {
  const readable = new ReadableStream<AnyMessage>({
    start(controller) {
      proc.onLine((line) => {
        if (!line.trim()) return;
        try {
          controller.enqueue(JSON.parse(line) as AnyMessage);
        } catch {
          /* skip a malformed line rather than tear down the connection */
        }
      });
      // Close on stdout end, NOT process exit: 'exit' can fire while stdout
      // still holds the agent's final frames, and enqueueing into a closed
      // controller silently drops them (the catch above swallows the throw).
      proc.onStreamEnd(() => {
        try {
          controller.close();
        } catch {
          /* already closed */
        }
      });
    },
  });
  const writable = new WritableStream<AnyMessage>({
    write(msg) {
      proc.send(JSON.stringify(msg));
    },
  });
  return { readable, writable };
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
  const tc: Record<string, unknown> = isRecord(toolCall) ? toolCall : {};
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

function permissionPreview(tc: Record<string, unknown>): string | undefined {
  // Prefer an explicit shell command; then a diff path; else compact rawInput.
  const rawInput = isRecord(tc.rawInput) ? tc.rawInput : undefined;
  const cmd = rawInput?.command ?? rawInput?.cmd;
  if (typeof cmd === "string" && cmd.trim()) return cmd;
  if (Array.isArray(tc.content)) {
    const diff = tc.content.find((c: unknown): c is Record<string, unknown> => isRecord(c) && c.type === "diff");
    if (diff && typeof diff.path === "string") {
      return `${diff.path}${typeof diff.newText === "string" ? `\n${diff.newText}` : ""}`;
    }
  }
  if (rawInput) {
    try {
      const s = JSON.stringify(rawInput);
      if (s && s !== "{}") return s.length > 500 ? `${s.slice(0, 497)}…` : s;
    } catch {
      /* ignore */
    }
  }
  return undefined;
}

// ---------- production spec helper -----------------------------------------
/** Resolve the `codex-acp` binary (override via MAKIT_CODEX_ACP_BIN). */
export function codexAcpSpec(): AcpSpawnSpec {
  return {
    agent: "codex",
    command: process.env.MAKIT_CODEX_ACP_BIN || "codex-acp",
    args: [],
  };
}
