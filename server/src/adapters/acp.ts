/**
 * AcpAdapter — drives any Agent Client Protocol (v1) agent as a subprocess and
 * bridges it to makit's `AgentAdapter` seam. makit acts as the ACP *client*;
 * the agent (e.g. `pi` via `pi-acp`, `codex-acp`) is the server.
 *
 * Lifecycle: spawn agent → `initialize` → `session/new` → one `session/prompt`
 * per user turn. Streaming `session/update` notifications are normalized by
 * {@link AcpEventMapper}. Tool-permission requests are surfaced to the phone
 * via `askUser` (confirmAction).
 *
 * pi runs through this adapter via the `pi-acp` bridge (SPEC-27), which spawns
 * `pi --mode rpc` and bridges ACP JSON-RPC over stdio; makit no longer ships a
 * native pi adapter.
 */

import { readFile, writeFile, mkdir, realpath, mkdtemp, rm } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { tmpdir } from "node:os";
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
  type SessionConfigOption as AcpConfigOption,
} from "@agentclientprotocol/sdk";
import type { AnyMessage } from "@agentclientprotocol/sdk";
import type { SpawnOpts, UserInput } from "./adapter.js";
import { SubprocessAdapter } from "./subprocess-adapter.js";
import { AcpEventMapper } from "./acp-map.js";
import { spawnLineProcess } from "./child_transport.js";
import { mapElicitation, type ElicitationParams } from "./interaction.js";
import { isRecord } from "./wire.js";
import type { AskUser } from "../uicall.js";
import type { SessionConfigOption, ConfigOptionValue, ConfigOptionGroup } from "../protocol.js";
import { log } from "../log.js";

/**
 * Timeout (ms) for ACP harness initialization and session spawn. If the child
 * process hangs before or after `initialize`/`newSession`, it is aborted.
 */
const ACP_HANDSHAKE_TIMEOUT = 15_000;

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

  /**
   * ACP v1 Session Config Options captured from the `session/new` response,
   * already parsed into makit's wire {@link SessionConfigOption} shape. When
   * present these SUPERSEDE `modes` (the spec says a client that supports
   * `configOptions` uses it exclusively); `modes`-only agents get a single
   * synthesised `category:"mode"` option instead (see {@link buildConfigOptions}).
   */
  private configOptions?: SessionConfigOption[];

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

    await Promise.race([
      this.conn.initialize({
        protocolVersion: 1,
        clientCapabilities: {
          fs: { readTextFile: true, writeTextFile: true },
          terminal: false,
          // We support boolean session config options (SPEC-26). Advertising this
          // lets agents include `type:"boolean"` entries in `configOptions`.
          session: { configOptions: { boolean: {} } },
        },
      }),
      new Promise<void>((_, reject) =>
        setTimeout(
          () => reject(new Error(`ACP initialize timed out after ${ACP_HANDSHAKE_TIMEOUT}ms`)),
          ACP_HANDSHAKE_TIMEOUT,
        ),
      ),
    ]);

    if (opts.resumeSessionPath) {
      // ACP resume is keyed by an ACP sessionId, not by makit's on-disk path.
      // Cross-world resume is a separate concern; start fresh for now.
      log.warn("[makit] AcpAdapter: resumeSessionPath ignored (ACP resume not wired yet)");
    }

    const res = await Promise.race([
      this.conn.newSession({ cwd, mcpServers: [] }),
      new Promise<any>((_, reject) =>
        setTimeout(
          () => reject(new Error(`ACP newSession timed out after ${ACP_HANDSHAKE_TIMEOUT}ms`)),
          ACP_HANDSHAKE_TIMEOUT,
        ),
      ),
    ]);
    this.acpSessionId = res.sessionId;
    this.captureModes(res.modes);
    this.captureConfigOptions(res.configOptions);
    this.emit("status", "idle");
    this.emitMeta();
  }

  async send(input: UserInput): Promise<void> {
    if (!this.conn || !this.acpSessionId) throw new Error("AcpAdapter: send before start");

    // Echo the user message so transcripts are complete (mirrors the pi adapter).
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
   * Control actions from the app. `configOption` maps to ACP
   * `session/set_config_option` (SPEC-26); `mode` maps to
   * `session/set_session_mode` (legacy, for `modes`-only agents). Other actions
   * are silently ignored on this transport.
   */
  async sendAction(action: string, args?: Record<string, unknown>): Promise<void> {
    if (!this.conn || !this.acpSessionId) return;
    if (action === "configOption") return this.setConfigOption(args);
    if (action !== "mode") return;
    const modeId = typeof args?.id === "string" ? args.id : "";
    if (!modeId) return;
    await this.applyMode(modeId);
  }

  /**
   * Apply a `configOption` control action. Real ACP `configOptions` map to
   * `session/set_config_option` (our `id` → wire `configId`); the response's
   * COMPLETE list replaces the cached options (never merged) and re-emits so
   * dependent options recompute. A `modes`-only agent has only the synthesised
   * `category:"mode"` option, which routes to `setSessionMode` instead.
   */
  private async setConfigOption(args?: Record<string, unknown>): Promise<void> {
    const id = typeof args?.id === "string" ? args.id : "";
    if (!id) return;
    const value = args?.value;

    // modes-only agent: the sole option is the synthesised mode selector.
    if (!this.configOptions) {
      if (id === "mode" && typeof value === "string") await this.applyMode(value);
      return;
    }
    if (!this.conn!.setSessionConfigOption) return;

    const target = this.configOptions.find((o) => o.id === id);
    const req =
      target?.type === "boolean"
        ? { sessionId: this.acpSessionId!, configId: id, value: value === true, type: "boolean" as const }
        : { sessionId: this.acpSessionId!, configId: id, value: String(value ?? "") };
    const res = await this.conn!.setSessionConfigOption(req);
    // The COMPLETE list replaces the cache (never merge) so dependent options stay correct.
    this.captureConfigOptions(res.configOptions);
    this.emitMeta();
  }

  /** Route a mode change to `session/set_session_mode` and reflect it locally. */
  private async applyMode(modeId: string): Promise<void> {
    if (!this.conn!.setSessionMode) return;
    await this.conn!.setSessionMode({ sessionId: this.acpSessionId!, modeId });
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

  /** Cache the ACP configOptions from a newSession response, parsed to wire shape. */
  private captureConfigOptions(options: AcpConfigOption[] | null | undefined): void {
    if (!Array.isArray(options) || options.length === 0) {
      this.configOptions = undefined;
      return;
    }
    this.configOptions = options.map(parseAcpConfigOption);
  }

  /**
   * The `configOptions` to surface on `session.meta`. Agent-supplied options win
   * (`modes` is ignored per spec); otherwise a `modes`-only agent gets a single
   * synthesised `category:"mode"` option for back-compat. Undefined when neither.
   */
  private buildConfigOptions(): SessionConfigOption[] | undefined {
    if (this.configOptions) return this.configOptions;
    if (this.modes) {
      return [
        {
          id: "mode",
          name: "Mode",
          category: "mode",
          type: "select",
          currentValue: this.modes.current,
          options: this.modes.available.map((m) => ({ value: m.id, name: m.name })),
        },
      ];
    }
    return undefined;
  }

  /**
   * Emit the session config as `session.meta`. Keeps the legacy
   * `{model, thinking, models, modes}` fields (migration window) and adds the
   * unified `configOptions` list (SPEC-26) when the agent supports either.
   */
  private emitMeta(): void {
    const configOptions = this.buildConfigOptions();
    if (!this.modes && !configOptions) return;
    this.emitEvent({
      ts: Date.now(),
      kind: "session.meta",
      payload: {
        model: null,
        thinking: "",
        models: [],
        modes: this.modes,
        ...(configOptions ? { configOptions } : {}),
      },
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
        const u = params.update as {
          sessionUpdate?: string;
          currentModeId?: string;
          configOptions?: AcpConfigOption[];
        };
        if (u.sessionUpdate === "current_mode_update") {
          if (this.modes && typeof u.currentModeId === "string") {
            this.modes = { ...this.modes, current: u.currentModeId };
            this.emitMeta();
          }
          return;
        }
        // The agent pushed an updated config-option set; re-emit the complete list.
        if (u.sessionUpdate === "config_option_update") {
          this.captureConfigOptions(u.configOptions);
          this.emitMeta();
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

// ---------- capability probe (SPEC-27) -------------------------------------

/**
 * Throwaway capability probe for an ACP harness (pi via `pi-acp`): spawn the
 * adapter's child in an **empty temp `cwd`**, run `initialize` + `session/new`,
 * capture the returned `configOptions` (parsed to makit's wire shape), then
 * clean up. When the agent advertises the `session/delete` capability we call
 * it to drop the probe session (pi-acp also prunes its
 * `~/.pi/pi-acp/session-map.json` entry) — tolerating a method-not-found from
 * agents that lie about it. The child is always killed and the temp dir always
 * removed, so no ghost sessions/dirs are left behind.
 *
 * Standalone (not a full makit {@link Session}): it reuses only the transport
 * plumbing + config-option parser. Returns `[]` for an option-less harness.
 */
export async function probeAcpConfigOptions(
  spec: AcpSpawnSpec,
  opts: { connect?: (cwd: string, env: Record<string, string>) => AcpTransport } = {},
): Promise<SessionConfigOption[]> {
  const cwd = await realpath(await mkdtemp(join(tmpdir(), "makit-acp-probe-")));
  const connect = opts.connect ?? defaultConnect(spec);
  const transport = connect(cwd, spec.env ?? {});
  try {
    const conn = new ClientSideConnection(() => probeClient(), transport.stream);
    const init = await Promise.race([
      conn.initialize({
        protocolVersion: 1,
        clientCapabilities: {
          fs: { readTextFile: true, writeTextFile: true },
          terminal: false,
          session: { configOptions: { boolean: {} } },
        },
      }),
      new Promise<any>((_, reject) =>
        setTimeout(
          () => reject(new Error(`ACP probe initialize timed out after ${ACP_HANDSHAKE_TIMEOUT}ms`)),
          ACP_HANDSHAKE_TIMEOUT,
        ),
      ),
    ]);
    const res = await Promise.race([
      conn.newSession({ cwd, mcpServers: [] }),
      new Promise<any>((_, reject) =>
        setTimeout(
          () => reject(new Error(`ACP probe newSession timed out after ${ACP_HANDSHAKE_TIMEOUT}ms`)),
          ACP_HANDSHAKE_TIMEOUT,
        ),
      ),
    ]);
    const options =
      Array.isArray(res.configOptions) && res.configOptions.length > 0
        ? res.configOptions.map(parseAcpConfigOption)
        : [];

    // Drop the throwaway session when the agent advertises session/delete.
    const supportsDelete = Boolean(init.agentCapabilities?.sessionCapabilities?.delete);
    if (supportsDelete && conn.deleteSession) {
      try {
        await conn.deleteSession({ sessionId: res.sessionId });
      } catch (e) {
        log.warn(`[makit] ACP probe session/delete failed: ${(e as Error).message}`);
      }
    }
    return options;
  } finally {
    transport.dispose();
    await rm(cwd, { recursive: true, force: true }).catch(() => {});
  }
}

/**
 * Minimal ACP {@link AcpClient} for the probe: it never runs a turn, so it
 * needs no real fs/permission handling — filesystem requests are refused and
 * permission/elicitation requests are cancelled/declined.
 */
function probeClient(): AcpClient {
  return {
    sessionUpdate: async () => {},
    requestPermission: async () => ({ outcome: { outcome: "cancelled" } }),
    readTextFile: async () => {
      throw new Error("ACP probe does not serve files");
    },
    writeTextFile: async () => {
      throw new Error("ACP probe does not serve files");
    },
    unstable_createElicitation: async () => ({ action: "decline" }),
    unstable_completeElicitation: async () => {},
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

// ---------- ACP config-option parsing (SPEC-26) ----------------------------

/**
 * Map an ACP v1 {@link AcpConfigOption} into makit's wire
 * {@link SessionConfigOption}. Boolean options carry a boolean `currentValue`;
 * select options carry either a flat value list (`options`) or named `groups`
 * (ACP allows both — grouped choices preserve their group names). Absent
 * `description`/`category` are omitted rather than emitted as `undefined`.
 */
export function parseAcpConfigOption(opt: AcpConfigOption): SessionConfigOption {
  const base: SessionConfigOption =
    opt.type === "boolean"
      ? { id: opt.id, name: opt.name, type: "boolean", currentValue: opt.currentValue }
      : { id: opt.id, name: opt.name, type: "select", currentValue: opt.currentValue };
  if (typeof opt.description === "string") base.description = opt.description;
  if (typeof opt.category === "string") base.category = opt.category;

  if (opt.type === "select") {
    const raw = Array.isArray(opt.options) ? opt.options : [];
    if (isGroupedSelect(raw)) {
      base.groups = raw.map(
        (g): ConfigOptionGroup => ({ name: g.name, options: g.options.map(parseSelectValue) }),
      );
    } else {
      base.options = raw.map(parseSelectValue);
    }
  }
  return base;
}

/** ACP grouped selects carry `{group, name, options}`; flat ones carry `{value, name}`. */
function isGroupedSelect(
  options: readonly unknown[],
): options is { group: string; name: string; options: { value: string; name: string; description?: string | null }[] }[] {
  const first = options[0];
  return isRecord(first) && "group" in first;
}

function parseSelectValue(v: { value: string; name: string; description?: string | null }): ConfigOptionValue {
  const out: ConfigOptionValue = { value: v.value, name: v.name };
  if (typeof v.description === "string") out.description = v.description;
  return out;
}
