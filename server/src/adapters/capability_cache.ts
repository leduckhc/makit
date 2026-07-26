/**
 * Capability cache (SPEC-27) — a small JSON store, under the makit data dir,
 * keyed `agentId → { fingerprint, configOptions? }`. It lets `agents.list`
 * serve each harness's cached `configOptions` catalog with NO live session:
 * on a fingerprint miss/change it re-probes that harness ONCE (via the
 * per-transport throwaway probe) before returning; a warm cache spawns nothing.
 * `agents.refresh` forces a re-probe.
 *
 * Persists like {@link DeviceRegistry}: `~/.makit/capability-cache.json`
 * (honouring the `MAKIT_HOME` override), written 0600.
 */

import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { AgentDescriptor } from "./catalog.js";
import type { SessionConfigOption } from "../protocol.js";
import { probeAcpConfigOptions } from "./acp.js";
import { probeCodexConfigOptions } from "./codex.js";
import { piAcpSpec } from "../agent_factory.js";
import { log } from "../log.js";

/** One cached harness catalog: the fingerprint it was probed at + its options. */
export interface CachedCapability {
  fingerprint: string;
  configOptions?: SessionConfigOption[];
}

/** Probe a harness for its `configOptions`. Injectable so tests never spawn. */
export type Prober = (descriptor: AgentDescriptor) => Promise<SessionConfigOption[]>;

function makitHome(): string {
  return process.env.MAKIT_HOME || join(homedir(), ".makit");
}

function defaultCachePath(): string {
  return join(makitHome(), "capability-cache.json");
}

/**
 * The production prober: dispatch on transport to the right throwaway probe —
 * codex (`native`) → `codex app-server` model/list projection; every ACP agent
 * (pi via `pi-acp`) → `session/new` in a temp cwd.
 */
export function defaultProber(): Prober {
  return async (descriptor) => {
    if (descriptor.transport === "native") return probeCodexConfigOptions();
    return probeAcpConfigOptions(piAcpSpec());
  };
}

export class CapabilityCache {
  private readonly path: string;
  private readonly prober: Prober;
  private readonly store = new Map<string, CachedCapability>();
  // Coalesce concurrent probes for the same agent so a reconnect burst (or two
  // clients hitting a cold/changed fingerprint at once) spawns the harness
  // ONCE instead of N times — mirrors SessionManager's in-flight promise maps.
  private readonly inFlight = new Map<string, Promise<SessionConfigOption[]>>();

  constructor(opts: { path?: string; prober?: Prober } = {}) {
    this.path = opts.path ?? defaultCachePath();
    this.prober = opts.prober ?? defaultProber();
    this.load();
  }

  /** The cached entry for an agent id, or `undefined` when never probed. */
  get(agentId: string): CachedCapability | undefined {
    return this.store.get(agentId);
  }

  /** Upsert a cached entry and persist. */
  set(agentId: string, cap: CachedCapability): void {
    this.store.set(agentId, cap);
    this.persist();
  }

  /**
   * Serve a descriptor's `configOptions` from cache, re-probing once on a
   * fingerprint miss/change. An UNAVAILABLE harness is returned untouched — it
   * is never probed (SPEC-27: only probe available agents). A warm cache hit
   * (matching fingerprint) spawns nothing.
   */
  async serve(descriptor: AgentDescriptor): Promise<AgentDescriptor> {
    if (!descriptor.available) return descriptor;
    const cached = this.store.get(descriptor.id);
    if (cached && cached.fingerprint === descriptor.fingerprint) {
      return withOptions(descriptor, cached.configOptions);
    }
    const configOptions = await this.probeDeduped(descriptor);
    this.set(descriptor.id, { fingerprint: descriptor.fingerprint, configOptions });
    return withOptions(descriptor, configOptions);
  }

  /**
   * Force a re-probe of an AVAILABLE harness, replacing its cached entry.
   * Returns the freshly enriched descriptor. Unavailable → returned untouched.
   */
  async refresh(descriptor: AgentDescriptor): Promise<AgentDescriptor> {
    if (!descriptor.available) return descriptor;
    const configOptions = await this.probeDeduped(descriptor);
    this.set(descriptor.id, { fingerprint: descriptor.fingerprint, configOptions });
    return withOptions(descriptor, configOptions);
  }

  /**
   * Probe with in-flight coalescing: a probe already running for this agent id
   * is shared rather than starting a second child. The entry is cleared once
   * settled so the next fingerprint change re-probes.
   */
  private probeDeduped(descriptor: AgentDescriptor): Promise<SessionConfigOption[]> {
    const running = this.inFlight.get(descriptor.id);
    if (running) return running;
    const p = this.probeSafe(descriptor).finally(() =>
      this.inFlight.delete(descriptor.id),
    );
    this.inFlight.set(descriptor.id, p);
    return p;
  }

  /** Probe best-effort: a failing probe caches an empty catalog (default-only). */
  private async probeSafe(descriptor: AgentDescriptor): Promise<SessionConfigOption[]> {
    try {
      return await this.prober(descriptor);
    } catch (e) {
      log.warn(`[makit] capability probe for ${descriptor.id} failed: ${(e as Error).message}`);
      return [];
    }
  }

  private load(): void {
    if (!existsSync(this.path)) return;
    try {
      const raw = JSON.parse(readFileSync(this.path, "utf8")) as Record<string, CachedCapability>;
      for (const [id, cap] of Object.entries(raw)) {
        if (cap && typeof cap.fingerprint === "string") this.store.set(id, cap);
      }
    } catch {
      // Corrupted cache is not authoritative — start empty and re-probe lazily.
    }
  }

  private persist(): void {
    const obj: Record<string, CachedCapability> = {};
    for (const [id, cap] of this.store) obj[id] = cap;
    try {
      mkdirSync(dirname(this.path), { recursive: true });
      writeFileSync(this.path, JSON.stringify(obj, null, 2), { mode: 0o600 });
    } catch (e) {
      log.warn(`[makit] could not persist capability cache: ${(e as Error).message}`);
    }
  }
}

/** Attach `configOptions` to a descriptor only when non-empty (else omit). */
function withOptions(
  descriptor: AgentDescriptor,
  configOptions: SessionConfigOption[] | undefined,
): AgentDescriptor {
  if (!configOptions || configOptions.length === 0) {
    const { configOptions: _drop, ...rest } = descriptor;
    return rest;
  }
  return { ...descriptor, configOptions };
}
