/**
 * Per-repo settings commands (SPEC-48).
 *
 * `repo.settings.set` is the only write, and it is **gated on a loopback
 * connection**. That is not a UI convention — it is checked here, on the server,
 * against `WsClient.isLocal`, which `server.ts` derives from the socket's real
 * remote address. The precedent is SPEC-37 decision 6, where the same flag already
 * refuses a non-loopback client's reported pid: *"a non-loopback client must
 * connect normally but may not ask us to sample an arbitrary pid."*
 *
 * The reason is concrete: `worktreeRoot` is a path the daemon **creates
 * directories under and, via prune, removes**. A paired phone that could set it
 * arbitrarily would be directing host filesystem operations at a path of its
 * choosing. Reads are unrestricted; writes are host-only.
 *
 * A refusal is an explicit error, never a silent no-op — a settings row that
 * appears to save and does not is worse than one that says it cannot.
 */

import { WireErrorCode } from "../../protocol/codec.js";
import type { CommandRouter } from "../command_router.js";
import type { CommandDeps } from "./deps.js";
import {
  validateBranch,
  validateProvider,
  validateWorktreeRoot,
  type RepoSettings,
} from "../../repo_settings.js";

/** Fields a client may write, and how each is validated. */
type Patch = Partial<Record<keyof RepoSettings, unknown>>;

export function register(r: CommandRouter, deps: CommandDeps): void {
  const { manager, onProjectsChanged } = deps;

  r.register("repo.settings.set", (ctx) => {
    if (!ctx.client.isLocal) {
      ctx.err(
        // No `forbidden` code exists on this wire; `unauthorized` is the closest
        // honest one and the app already renders it as a refusal.
        WireErrorCode.Unauthorized,
        "Repository settings can only be changed on the machine running makit.",
      );
      return;
    }

    const projectId = typeof ctx.env.projectId === "string" ? ctx.env.projectId : "";
    if (projectId.length === 0) {
      ctx.err(WireErrorCode.BadRequest, "projectId is required.");
      return;
    }
    const patch = ctx.env.settings;
    if (typeof patch !== "object" || patch === null || Array.isArray(patch)) {
      ctx.err(WireErrorCode.BadRequest, "settings must be an object.");
      return;
    }

    const applied: Record<string, unknown> = {};
    for (const [key, raw] of Object.entries(patch as Patch)) {
      // `null` clears a setting: absent means inherit, so clearing is how the UI
      // says "go back to inheriting" without inventing a sentinel value.
      if (raw === null) {
        applied[key] = null;
        continue;
      }
      switch (key) {
        case "worktreeRoot": {
          if (typeof raw !== "string") {
            ctx.err(WireErrorCode.BadRequest, "worktreeRoot must be a string.");
            return;
          }
          const v = validateWorktreeRoot(raw);
          if (!v.ok) {
            ctx.err(WireErrorCode.BadRequest, v.error);
            return;
          }
          applied.worktreeRoot = v.value;
          break;
        }
        case "provider": {
          const v = validateProvider(raw);
          if (!v.ok) {
            ctx.err(WireErrorCode.BadRequest, v.error);
            return;
          }
          // `auto` is the default, so it is stored as absence rather than as a
          // value — otherwise "believe detection" and "no opinion" would differ on
          // disk while meaning the same thing.
          applied.provider = v.value === "auto" ? null : v.value;
          break;
        }
        case "defaultBranch": {
          if (typeof raw !== "string") {
            ctx.err(WireErrorCode.BadRequest, "defaultBranch must be a string.");
            return;
          }
          const v = validateBranch(raw);
          if (!v.ok) {
            ctx.err(WireErrorCode.BadRequest, v.error);
            return;
          }
          applied.defaultBranch = v.value;
          break;
        }
        case "logoHue": {
          if (typeof raw !== "number" || !Number.isInteger(raw) || raw < 0) {
            ctx.err(WireErrorCode.BadRequest, "logoHue must be a non-negative integer.");
            return;
          }
          applied.logoHue = raw;
          break;
        }
        default:
          ctx.err(WireErrorCode.BadRequest, `Unknown setting '${key}'.`);
          return;
      }
    }

    const ok = manager.updateProjectSettings(projectId, applied);
    if (!ok) {
      ctx.err(WireErrorCode.BadRequest, `No project ${projectId}.`);
      return;
    }
    ctx.ack();
    // `updateProjectSettings` has already persisted. Re-broadcast so every client
    // re-renders from one source rather than from whatever it optimistically
    // assumed — including the client that just wrote.
    onProjectsChanged?.();
  });
}
