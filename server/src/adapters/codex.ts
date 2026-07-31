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

import type { SpawnOpts, UserInput, AgentSessionInfo, SessionCapabilities } from "./adapter.js";
import { mkdtemp, rm } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { SubprocessAdapter } from "./subprocess-adapter.js";
import { CodexEventMapper } from "./codex-map.js";
import { spawnLineProcess, type ChildLineTransport } from "./child_transport.js";
import { confirmViaUser, mapElicitation, type ElicitationParams } from "./interaction.js";
import { isRecord, parseJsonLine } from "./wire.js";
import type { AskUser } from "../uicall.js";
import type { SessionConfigOption, ConfigOptionValue } from "../protocol.js";
import { log } from "../log.js";

/** Codex speaks LF-delimited JSON over stdio — the shared line transport. */
export type CodexTransport = ChildLineTransport;

/**
 * Bound codex JSON-RPC handshakes: `request()` only settles on a response, an
 * error frame, or transport exit, so a started-but-silent `codex app-server`
 * would otherwise hang session launch and `agents.list` forever. Mirrors the
 * ACP adapter's `ACP_HANDSHAKE_TIMEOUT`.
 */
const CODEX_HANDSHAKE_TIMEOUT = 15_000;

/** Rejects with a labelled error when [p] doesn't settle within [ms]. */
function withDeadline<T>(p: Promise<T>, ms: number, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  const deadline = new Promise<T>((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`${label} timed out after ${ms}ms`)),
      ms,
    );
  });
  return Promise.race([p, deadline]).finally(() => clearTimeout(timer));
}

/**
 * Fallback reasoning-effort levels for the `thought_level` config option when a
 * model does not advertise its own `supportedReasoningEfforts` (SPEC-26).
 * codex's `turn/start.effort` accepts these values. Real codex models advertise
 * a **per-model** list (see {@link reasoningEffortOptions}); this is only used
 * for older app-servers / models with no advertised set.
 */
const FALLBACK_REASONING_EFFORTS: ConfigOptionValue[] = [
  { value: "minimal", name: "Minimal" },
  { value: "low", name: "Low" },
  { value: "medium", name: "Medium" },
  { value: "high", name: "High" },
];
const DEFAULT_REASONING_EFFORT = "medium";

/** Title-case a bare effort id (`"xhigh"` → `"Xhigh"`) for display. */
function titleCaseEffort(value: string): string {
  return value.length === 0 ? value : value[0]!.toUpperCase() + value.slice(1);
}

/**
 * Map a codex model's advertised `supportedReasoningEfforts` into the
 * `thought_level` option's values, preserving codex's order and per-effort
 * descriptions. Returns `[]` when the model advertises none (caller falls back
 * to {@link FALLBACK_REASONING_EFFORTS}).
 */
function reasoningEffortOptions(model: Record<string, unknown>): ConfigOptionValue[] {
  const raw = Array.isArray(model.supportedReasoningEfforts)
    ? model.supportedReasoningEfforts
    : [];
  const out: ConfigOptionValue[] = [];
  for (const e of raw) {
    if (!isRecord(e)) continue;
    const value = typeof e.reasoningEffort === "string" ? e.reasoningEffort : "";
    if (!value) continue;
    const description = typeof e.description === "string" && e.description ? e.description : undefined;
    out.push(description ? { value, name: titleCaseEffort(value), description } : { value, name: titleCaseEffort(value) });
  }
  return out;
}

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

  /**
   * codex `app-server` always exposes the full thread lifecycle
   * (`thread/resume`, `thread/list`, `thread/delete`, `thread/fork`) — SPEC-29.
   * `load` is false: codex resume does not replay history (nor does makit need
   * it to; the event log is authoritative).
   */
  readonly capabilities: SessionCapabilities = { resume: true, load: false, list: true, delete: true, fork: true, archive: true };

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
  private readonly pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: unknown) => void }>();

  /**
   * Projected config surface (SPEC-26). codex `app-server` is not ACP, so its
   * model list (from `model/list`) and reasoning effort are projected into the
   * same {@link SessionConfigOption} shape the composer consumes. Picks apply on
   * the next turn via `turn/start` `model`/`effort` overrides.
   */
  private catalogModels: ConfigOptionValue[] = [];
  private effortsByModel: Record<string, ConfigOptionValue[]> = {};
  private defaultEffortByModel: Record<string, string> = {};
  private fastByModel: Record<string, boolean> = {};
  private activeModel?: string;
  private activeEffort?: string;
  /** "Fast" service tier (priority) toggle; defaults OFF (standard tier). */
  private activeFast = false;

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

    const started = (await this.request(
      opts.resumeAgentSessionId ? "thread/resume" : "thread/start",
      opts.resumeAgentSessionId
        ? { threadId: opts.resumeAgentSessionId, cwd: opts.cwd }
        : { cwd: opts.cwd, ...(this.model ? { model: this.model } : {}) },
    )) as { thread?: { id?: string } };
    this.threadId = started?.thread?.id ?? opts.resumeAgentSessionId;
    if (!this.threadId) throw new Error("codex app-server: thread/start returned no thread id");
    this.agentSessionId = this.threadId;
    this.activeModel = this.model;
    await this.captureModelCatalog();
    this.emit("status", "idle");
    this.emitConfigOptions();
  }

  async send(input: UserInput): Promise<void> {
    if (!this.threadId) throw new Error("CodexAppServerAdapter: send before start");

    this.emitEvent({ ts: Date.now(), kind: "user.message", payload: { text: input.text } });
    this.emit("status", "running");

    try {
      const res = (await this.request("turn/start", {
        threadId: this.threadId,
        input: [{ type: "text", text: input.text, text_elements: [] }],
        ...(this.activeModel ? { model: this.activeModel } : {}),
        ...(this.activeEffort ? { effort: this.activeEffort } : {}),
        ...(this.activeFast ? { serviceTier: FAST_SERVICE_TIER } : {}),
      })) as { turn?: { id?: string } };
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

  /**
   * Control actions from the app. Projects the unified `configOption` action
   * (SPEC-26) onto codex's turn params: `model`/`thought_level` picks are cached
   * and applied on the next `turn/start` (`model`/`effort`), then re-emitted so
   * the composer reflects the new current value.
   */
  async sendAction(action: string, args?: Record<string, unknown>): Promise<void> {
    if (action !== "configOption") return;
    const id = typeof args?.id === "string" ? args.id : "";
    if (id === "fast") {
      // Boolean toggle: only valid for an active model that supports the fast
      // tier (absent/unsupported model → ignore).
      if (typeof args?.value !== "boolean") return;
      if (!this.activeModel || !this.fastByModel[this.activeModel]) return;
      this.activeFast = args.value;
      this.emitConfigOptions();
      return;
    }
    const value = typeof args?.value === "string" ? args.value : "";
    if (!value) return;
    if (id === "model") {
      this.activeModel = value;
      // Clamp the reasoning effort to the new model's advertised set: switching
      // to a model that doesn't support the current effort would otherwise send
      // an invalid `effort` on the next turn ([pickEffort] prefers the new
      // model's default, else its first advertised effort, else the current).
      const efforts = this.effortsByModel[value] ?? [];
      if (efforts.length > 0 && this.activeEffort && !efforts.some((e) => e.value === this.activeEffort)) {
        this.activeEffort = pickEffort(efforts, this.defaultEffortByModel[value], this.activeEffort);
      }
      // Drop Fast when the new model doesn't support the tier (avoids sending
      // serviceTier to a model that can't use it).
      if (!this.fastByModel[value]) this.activeFast = false;
    } else if (id === "thought_level") this.activeEffort = value;
    else return;
    this.emitConfigOptions();
  }

  async kill(): Promise<void> {
    this.transport?.dispose();
    this.handleExit(null, () => this.rejectPending());
  }

  // ---- config-option projection (SPEC-26) ----------------------------------

  /**
   * Fetch codex's model catalog via the `model/list` RPC and seed the active
   * model + reasoning effort from the default entry. Best-effort: an older
   * app-server without `model/list` simply yields no model option.
   */
  private async captureModelCatalog(): Promise<void> {
    try {
      const res = await withDeadline(
        this.request("model/list", {}),
        CODEX_HANDSHAKE_TIMEOUT,
        "codex model/list",
      );
      const projected = projectCodexModelList(res);
      this.catalogModels = projected.models;
      this.effortsByModel = projected.effortsByModel;
      this.defaultEffortByModel = projected.defaultEffortByModel;
      this.fastByModel = projected.fastByModel;
      if (!this.activeModel && projected.activeModel) this.activeModel = projected.activeModel;
      // Initialise the effort from the SELECTED model (which may be a forced
      // non-default model via CodexAdapterOpts.model) — not the catalog default
      // — so we never emit/send an effort the active model doesn't support.
      // The fallback (only when the model advertises no efforts) is the catalog
      // default model's default effort.
      if (!this.activeEffort) {
        const selected = this.activeModel;
        const efforts = (selected && this.effortsByModel[selected]) || [];
        const modelDefault = selected ? this.defaultEffortByModel[selected] : undefined;
        const fallback = selected === projected.activeModel ? projected.activeEffort : undefined;
        this.activeEffort = pickEffort(efforts, modelDefault, fallback);
      }
      // Clamp Fast to the selected model's support (parallel to the sendAction
      // logic: drop it if unsupported to avoid sending serviceTier to a model that can't use it).
      if (this.activeModel && !this.fastByModel[this.activeModel]) this.activeFast = false;
    } catch (e) {
      log.warn(`[makit] codex model/list failed: ${(e as Error).message}`);
      this.catalogModels = [];
      this.effortsByModel = {};
      this.defaultEffortByModel = {};
      this.fastByModel = {};
    }
    if (!this.activeEffort) this.activeEffort = DEFAULT_REASONING_EFFORT;
  }

  /**
   * Emit the projected config surface as `session.meta.configOptions`, in the
   * same {@link SessionConfigOption} shape the ACP adapter emits: a
   * `category:"model"` select (when a catalog is available) and a
   * `category:"thought_level"` reasoning-effort select.
   */
  private emitConfigOptions(): void {
    const efforts = (this.activeModel && this.effortsByModel[this.activeModel]) || [];
    const fastSupported = Boolean(this.activeModel && this.fastByModel[this.activeModel]);
    const configOptions = buildCodexConfigOptions(
      this.catalogModels,
      this.activeModel,
      this.activeEffort,
      efforts,
      { supported: fastSupported, active: this.activeFast },
    );
    this.emitEvent({ ts: Date.now(), kind: "session.meta", payload: { configOptions } });
  }

  // ---- JSON-RPC plumbing ---------------------------------------------------

  private request(method: string, params: unknown, timeoutMs = 15_000): Promise<unknown> {
    const id = this.nextId++;
    this.write({ method, id, params });
    return Promise.race([
      new Promise((resolve, reject) => this.pending.set(id, { resolve, reject })),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error(`codex.${method} timeout after ${timeoutMs}ms`)), timeoutMs),
      ),
    ]);
  }

  private notify(method: string, params: unknown): void {
    this.write({ method, params });
  }

  private write(msg: unknown): void {
    this.transport?.send(JSON.stringify(msg));
  }

  private handleLine(line: string): void {
    const msg = parseJsonLine(line);
    if (!isRecord(msg)) return;

    // Response to one of our requests.
    if (msg.id !== undefined && (msg.result !== undefined || msg.error !== undefined)) {
      const p = this.pending.get(msg.id as number);
      if (p) {
        this.pending.delete(msg.id as number);
        if (msg.error !== undefined) {
          const err = msg.error;
          const message =
            isRecord(err) && typeof err.message === "string" ? err.message : JSON.stringify(err);
          p.reject(new Error(message));
        } else {
          p.resolve(msg.result);
        }
      }
      return;
    }

    // Server → client request (needs a response).
    if (typeof msg.method === "string" && msg.id !== undefined) {
      void this.handleServerRequest(msg.method, msg.id as number | string, msg.params);
      return;
    }

    // Notification.
    if (typeof msg.method === "string") {
      this.handleNotification(msg.method, msg.params);
    }
  }

  private handleNotification(method: string, params: unknown): void {
    const p = isRecord(params) ? params : {};
    const turn = isRecord(p.turn) ? p.turn : undefined;
    const id = typeof turn?.id === "string" ? turn.id : undefined;
    if (method === "turn/started") {
      if (id) this.turns.enterTurn(id);
      else this.emit("status", "running");
      return;
    }
    if (method === "turn/completed") {
      this.mapper.endTurn();
      if (id) this.turns.leaveTurn(id);
      else this.turns.settleIdle();
      return;
    }
    this.mapper.handle(method, params);
  }

  // ---- server → client requests -------------------------------------------

  private async handleServerRequest(method: string, id: number | string, params: unknown): Promise<void> {
    const p = isRecord(params) ? params : {};
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
            { message: typeof p.reason === "string" && p.reason ? p.reason : "Grant additional permissions?" },
            "permissions",
          );
          // Approve → grant exactly what was requested for this turn; deny → grant nothing.
          const req = isRecord(p.permissions) ? p.permissions : {};
          return this.reply(id, {
            permissions: ok ? { network: req.network ?? undefined, fileSystem: req.fileSystem ?? undefined } : {},
            scope: "turn",
          });
        }
        case "mcpServer/elicitation/request":
          return this.reply(id, await this.handleElicitation(params));
        case "execCommandApproval": {
          const cmd = Array.isArray(p.command) ? p.command.join(" ") : "";
          const ok = await this.confirm({ message: cmd || "Run command?", preview: cmd }, "execute");
          return this.reply(id, { decision: ok ? "approved" : "denied" });
        }
        case "applyPatchApproval": {
          const ok = await this.confirm({ message: "Apply patch?", preview: patchPaths(p.fileChanges) }, "edit");
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
  private async handleUserInput(params: unknown): Promise<{ answers: Record<string, { answers: string[] }> }> {
    const rawQuestions = isRecord(params) ? params.questions : undefined;
    const questions: Record<string, unknown>[] = Array.isArray(rawQuestions)
      ? rawQuestions.filter(isRecord)
      : [];
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
          ).map((o: unknown) =>
            isRecord(o)
              ? { label: String(o.label ?? o), description: typeof o.description === "string" ? o.description : undefined }
              : { label: String(o), description: undefined },
          ),
          multi: q?.multiSelect === true,
        })),
      });
      const answers: Record<string, { answers: string[] }> = {};
      if (resp.kind === "askUserQuestion" && !(resp as { cancelled?: boolean }).cancelled && Array.isArray(resp.answers)) {
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
  private async handleElicitation(params: unknown): Promise<{ action: string; content: unknown; _meta: null }> {
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

// ---------- config-option projection (SPEC-26 / SPEC-27) -------------------

/**
 * Projected view of codex's `model/list` result: the visible models as
 * {@link ConfigOptionValue}s plus the default active model + reasoning effort.
 * Pure so it is the ONE source of truth shared by the live adapter
 * ({@link CodexAppServerAdapter.captureModelCatalog}) and the throwaway probe
 * ({@link probeCodexConfigOptions}).
 */
/**
 * Whether a codex model supports the "Fast" service tier (1.5x speed): it
 * advertises a `serviceTiers` entry with id `priority` (name "Fast") or lists
 * `fast` in `additionalSpeedTiers`. Verified against a live `turn/start` probe:
 * sending `serviceTier:"priority"` (or `"fast"`) resolves to the `priority`
 * tier; omitting it resolves to `default` (standard).
 */
function modelSupportsFast(model: Record<string, unknown>): boolean {
  const tiers = Array.isArray(model.serviceTiers) ? model.serviceTiers : [];
  if (tiers.some((t) => isRecord(t) && t.id === "priority")) return true;
  const extra = Array.isArray(model.additionalSpeedTiers) ? model.additionalSpeedTiers : [];
  return extra.includes("fast");
}

/** The `serviceTier` value sent to `turn/start` when Fast is ON. */
const FAST_SERVICE_TIER = "priority";

/**
 * Choose a reasoning effort for a model: its advertised [modelDefault] when
 * that value is in the advertised [efforts], else the first advertised effort,
 * else [fallback]. Shared by the initial effort seed and the model-switch
 * clamp so we never keep/emit an effort the active model doesn't support.
 */
function pickEffort(
  efforts: ConfigOptionValue[],
  modelDefault: string | undefined,
  fallback: string | undefined,
): string | undefined {
  if (efforts.length === 0) return fallback;
  if (modelDefault && efforts.some((e) => e.value === modelDefault)) return modelDefault;
  return efforts[0]?.value ?? fallback;
}

export function projectCodexModelList(res: unknown): {
  models: ConfigOptionValue[];
  activeModel?: string;
  activeEffort?: string;
  /** Per-model reasoning-effort option lists, keyed by model value. */
  effortsByModel: Record<string, ConfigOptionValue[]>;
  /** Per-model default reasoning effort, keyed by model value. */
  defaultEffortByModel: Record<string, string>;
  /** Per-model "Fast" service-tier support, keyed by model value. */
  fastByModel: Record<string, boolean>;
} {
  const data = isRecord(res) && Array.isArray(res.data) ? res.data.filter(isRecord) : [];
  const visible = data.filter((m) => m.hidden !== true);
  const effortsByModel: Record<string, ConfigOptionValue[]> = {};
  const defaultEffortByModel: Record<string, string> = {};
  const fastByModel: Record<string, boolean> = {};
  const models: ConfigOptionValue[] = visible.map((m) => {
    const value = String(m.model ?? m.id ?? "");
    const name = typeof m.displayName === "string" && m.displayName ? m.displayName : value;
    const description = typeof m.description === "string" ? m.description : "";
    if (value) {
      const efforts = reasoningEffortOptions(m);
      if (efforts.length > 0) effortsByModel[value] = efforts;
      if (typeof m.defaultReasoningEffort === "string") defaultEffortByModel[value] = m.defaultReasoningEffort;
      if (modelSupportsFast(m)) fastByModel[value] = true;
    }
    return description ? { value, name, description } : { value, name };
  });
  const active = visible.find((m) => m.isDefault === true) ?? visible[0];
  const out: {
    models: ConfigOptionValue[];
    activeModel?: string;
    activeEffort?: string;
    effortsByModel: Record<string, ConfigOptionValue[]>;
    defaultEffortByModel: Record<string, string>;
    fastByModel: Record<string, boolean>;
  } = { models, effortsByModel, defaultEffortByModel, fastByModel };
  if (active) {
    out.activeModel = String(active.model ?? active.id ?? "");
    if (typeof active.defaultReasoningEffort === "string") out.activeEffort = active.defaultReasoningEffort;
  }
  return out;
}

/**
 * Build the projected {@link SessionConfigOption} list codex surfaces: a
 * `category:"model"` select (only when a catalog is available) and a
 * `category:"thought_level"` reasoning-effort select. Single source of truth
 * for the live `session.meta` emission and the cached-catalog probe.
 */
export function buildCodexConfigOptions(
  models: ConfigOptionValue[],
  activeModel: string | undefined,
  activeEffort: string | undefined,
  efforts: ConfigOptionValue[] = FALLBACK_REASONING_EFFORTS,
  fast?: { supported: boolean; active: boolean },
): SessionConfigOption[] {
  const configOptions: SessionConfigOption[] = [];
  if (models.length > 0) {
    // Keep the select self-consistent: a forced/unlisted active model (e.g.
    // CodexAdapterOpts.model, or a pick for an id not in model/list) is
    // appended so currentValue always matches an option instead of rendering
    // an empty selection.
    const options = [...models];
    if (activeModel && !options.some((o) => o.value === activeModel)) {
      options.push({ value: activeModel, name: activeModel });
    }
    configOptions.push({
      id: "model",
      name: "Model",
      category: "model",
      type: "select",
      currentValue: activeModel ?? models[0]!.value,
      options,
    });
  }
  // Reasoning-effort values are the active model's advertised set (falling back
  // to a generic list). Keep the select self-consistent if the current effort
  // is not in the list.
  const effortOptions = efforts.length > 0 ? [...efforts] : FALLBACK_REASONING_EFFORTS;
  const current = activeEffort ?? DEFAULT_REASONING_EFFORT;
  if (!effortOptions.some((o) => o.value === current)) {
    effortOptions.push({ value: current, name: titleCaseEffort(current) });
  }
  configOptions.push({
    id: "thought_level",
    name: "Reasoning effort",
    category: "thought_level",
    type: "select",
    currentValue: current,
    options: effortOptions,
  });
  // "Fast" service tier (1.5x speed) — a boolean model_config, shown only when
  // the active model advertises the priority/fast tier. ON → turn/start
  // serviceTier "priority"; OFF → omit (codex resolves to "default").
  if (fast?.supported) {
    configOptions.push({
      id: "fast",
      name: "Fast",
      category: "model_config",
      type: "boolean",
      currentValue: fast.active,
      description: "1.5x speed, increased usage",
    });
  }
  return configOptions;
}

/**
 * Throwaway capability probe for codex (native `app-server`): spawn
 * `codex app-server`, `initialize`, query `model/list`, and project the result
 * into the same {@link SessionConfigOption} list the live adapter emits — then
 * dispose. NO thread is started (no `thread/start`), so there is no user
 * session/worktree to clean up. Best-effort: a codex without `model/list`
 * yields just the reasoning-effort option.
 */
export async function probeCodexConfigOptions(
  opts: {
    command?: string;
    args?: string[];
    env?: Record<string, string>;
    connect?: (cwd: string, env: Record<string, string>) => CodexTransport;
  } = {},
): Promise<SessionConfigOption[]> {
  const command = opts.command ?? process.env.MAKIT_CODEX_BIN ?? "codex";
  const args = opts.args ?? ["app-server"];
  const connect = opts.connect ?? defaultConnect(command, args);
  const cwd = await mkdtemp(join(tmpdir(), "makit-codex-probe-"));
  const transport = connect(cwd, opts.env ?? {});

  const pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: unknown) => void }>();
  let nextId = 1;
  transport.onLine((line) => {
    const msg = parseJsonLine(line);
    if (!isRecord(msg) || msg.id === undefined) return;
    if (msg.result === undefined && msg.error === undefined) return;
    const p = pending.get(msg.id as number);
    if (!p) return;
    pending.delete(msg.id as number);
    if (msg.error !== undefined) p.reject(new Error(String(msg.error)));
    else p.resolve(msg.result);
  });
  transport.onExit(() => {
    for (const [, p] of pending) p.reject(new Error("codex app-server exited during probe"));
    pending.clear();
  });
  const request = (method: string, params: unknown): Promise<unknown> => {
    const id = nextId++;
    transport.send(JSON.stringify({ method, id, params }));
    return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
  };

  try {
    await withDeadline(
      request("initialize", {
        clientInfo: { name: "makit", title: "makit", version: "0.1.0" },
        capabilities: { experimentalApi: true, requestAttestation: false },
      }),
      CODEX_HANDSHAKE_TIMEOUT,
      "codex probe initialize",
    );
    transport.send(JSON.stringify({ method: "initialized", params: {} }));
    const res = await withDeadline(
      request("model/list", {}),
      CODEX_HANDSHAKE_TIMEOUT,
      "codex probe model/list",
    );
    const projected = projectCodexModelList(res);
    const efforts = (projected.activeModel && projected.effortsByModel[projected.activeModel]) || [];
    const fastSupported = Boolean(projected.activeModel && projected.fastByModel[projected.activeModel]);
    return buildCodexConfigOptions(projected.models, projected.activeModel, projected.activeEffort, efforts, {
      supported: fastSupported,
      active: false,
    });
  } catch (e) {
    log.warn(`[makit] codex probe failed: ${(e as Error).message}`);
    return buildCodexConfigOptions([], undefined, undefined);
  } finally {
    transport.dispose();
    await rm(cwd, { recursive: true, force: true }).catch(() => {});
  }
}

// ---------- session listing (SPEC-29) --------------------------------------

/**
 * List a cwd's prior codex threads via a throwaway `codex app-server`
 * connection (SPEC-29). Mirrors {@link probeCodexConfigOptions}: spawn,
 * `initialize`, call `thread/list {}`, keep the threads whose `cwd` matches the
 * target, and normalize to {@link AgentSessionInfo}. No thread is started, so
 * there is nothing to clean up. Never throws — logs + returns `[]` on error.
 */
export async function listCodexThreads(
  cwd: string,
  opts: {
    command?: string;
    args?: string[];
    env?: Record<string, string>;
    connect?: (cwd: string, env: Record<string, string>) => CodexTransport;
  } = {},
): Promise<AgentSessionInfo[]> {
  const command = opts.command ?? process.env.MAKIT_CODEX_BIN ?? "codex";
  const args = opts.args ?? ["app-server"];
  const connect = opts.connect ?? defaultConnect(command, args);
  const transport = connect(cwd, opts.env ?? {});

  const pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: unknown) => void }>();
  let nextId = 1;
  transport.onLine((line) => {
    const msg = parseJsonLine(line);
    if (!isRecord(msg) || msg.id === undefined) return;
    if (msg.result === undefined && msg.error === undefined) return;
    const p = pending.get(msg.id as number);
    if (!p) return;
    pending.delete(msg.id as number);
    if (msg.error !== undefined) p.reject(new Error(String(msg.error)));
    else p.resolve(msg.result);
  });
  transport.onExit(() => {
    for (const [, p] of pending) p.reject(new Error("codex app-server exited during list"));
    pending.clear();
  });
  const request = (method: string, params: unknown): Promise<unknown> => {
    const id = nextId++;
    transport.send(JSON.stringify({ method, id, params }));
    return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
  };

  try {
    await withDeadline(
      request("initialize", {
        clientInfo: { name: "makit", title: "makit", version: "0.1.0" },
        capabilities: { experimentalApi: true, requestAttestation: false },
      }),
      CODEX_HANDSHAKE_TIMEOUT,
      "codex list initialize",
    );
    transport.send(JSON.stringify({ method: "initialized", params: {} }));
    const res = await withDeadline(request("thread/list", {}), CODEX_HANDSHAKE_TIMEOUT, "codex thread/list");
    return projectCodexThreadList(res, cwd);
  } catch (e) {
    log.warn(`[makit] codex thread/list failed: ${(e as Error).message}`);
    return [];
  } finally {
    transport.dispose();
  }
}

/**
 * Project a codex `thread/list` result into {@link AgentSessionInfo}s, filtered
 * to threads whose `cwd` matches [cwd] and excluding ephemeral threads. codex
 * timestamps (`updatedAt`/`recencyAt`) are epoch SECONDS — scaled to ms. Pure so
 * it is unit-testable without a live subprocess.
 */
export function projectCodexThreadList(res: unknown, cwd: string): AgentSessionInfo[] {
  const data = isRecord(res) && Array.isArray(res.data) ? res.data.filter(isRecord) : [];
  // Canonicalize cwd so symlinked project roots don't cause spurious mismatches.
  // realpathSync throws on a path that no longer exists (e.g. a removed
  // worktree's thread), so fall back to a plain resolve rather than letting the
  // whole listing reject.
  const canon = (p: string): string => {
    try {
      return realpathSync(p);
    } catch {
      return resolve(p);
    }
  };
  const target = canon(cwd);
  const out: AgentSessionInfo[] = [];
  for (const t of data) {
    if (t.ephemeral === true) continue;
    if (typeof t.cwd === "string" && canon(t.cwd) !== target) continue;
    const id = String(t.id ?? t.sessionId ?? "");
    if (!id) continue;
    const info: AgentSessionInfo = { id, cwd: typeof t.cwd === "string" ? t.cwd : target };
    if (typeof t.preview === "string") info.preview = t.preview;
    const secs = typeof t.recencyAt === "number" ? t.recencyAt : typeof t.updatedAt === "number" ? t.updatedAt : undefined;
    if (typeof secs === "number") info.updatedAt = secs * 1000;
    out.push(info);
  }
  return out;
}

// ---------- default subprocess transport -----------------------------------

export function defaultConnect(command: string, args: string[]) {
  return (cwd: string, env: Record<string, string>): CodexTransport =>
    spawnLineProcess({ command, args, cwd, env, label: "codex-app-server" });
}

function describeCommand(params: unknown): { message: string; preview?: string } {
  const p = isRecord(params) ? params : {};
  const cmd = typeof p.command === "string" ? p.command : "";
  const reason = typeof p.reason === "string" ? p.reason : "";
  return { message: reason || cmd || "Run command?", preview: cmd || undefined };
}

function describeFileChange(params: unknown): { message: string; preview?: string } {
  const p = isRecord(params) ? params : {};
  const reason = typeof p.reason === "string" ? p.reason : "";
  return { message: reason || "Apply file changes?", preview: p.grantRoot ? String(p.grantRoot) : undefined };
}

function patchPaths(fileChanges: unknown): string | undefined {
  if (!fileChanges || typeof fileChanges !== "object") return undefined;
  const keys = Object.keys(fileChanges as Record<string, unknown>);
  return keys.length ? keys.join("\n") : undefined;
}
