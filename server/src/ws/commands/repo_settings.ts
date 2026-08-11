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
  LOGO_HUE_COUNT,
  validateBranch,
  validateProvider,
  validateWorktreeRoot,
  type RepoSettings,
} from "../../repo_settings.js";

/** Fields a client may write, and how each is validated. */
type Patch = Partial<Record<keyof RepoSettings, unknown>>;

/**
 * The keys a client may write. Checked BEFORE the value, because the clear-a-setting
 * branch used to run first and so skipped this rule entirely for a `null` value:
 * `{wroktreeRoot: null}` was acked and the typo written into the patch. A settings
 * write that silently stores a misspelling is worse than one that refuses, because
 * the user believes the setting exists.
 *
 * A `Set` rather than a property test, so inherited names (`__proto__`,
 * `constructor`) are not keys — assigning `applied["__proto__"]` invokes the
 * prototype setter instead of creating an own property.
 */
const WRITABLE_KEYS: ReadonlySet<string> = new Set<keyof RepoSettings>([
  "worktreeRoot",
  "provider",
  "defaultBranch",
  "logoHue",
]);

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
      // The key rule comes first, so it applies to a clear as well as to a write.
      if (!WRITABLE_KEYS.has(key)) {
        ctx.err(WireErrorCode.BadRequest, `Unknown setting '${key}'.`);
        return;
      }
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
          if (typeof raw !== "number" || !Number.isInteger(raw) || raw < 0 || raw >= LOGO_HUE_COUNT) {
            ctx.err(
              WireErrorCode.BadRequest,
              `logoHue must be an integer from 0 to ${LOGO_HUE_COUNT - 1}.`,
            );
            return;
          }
          applied.logoHue = raw;
          break;
        }
        default:
          // Unreachable: `WRITABLE_KEYS` already rejected anything not listed above.
          // Kept so adding a key to that set without handling it here fails loudly
          // rather than silently storing an unvalidated value.
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

  /**
   * Re-point a project at a new root path (D4′).
   *
   * A separate command from `repo.settings.set`, not a field in its patch, because
   * it is not a setting: it mutates the project record, must re-validate that the
   * target is a git repository, and re-runs forge detection. Folding an async
   * filesystem-and-subprocess check into a loop that validates plain values would
   * also break that loop's all-or-nothing property — one bad field would abort a
   * move that had already happened.
   *
   * Same loopback gate, for a sharper reason than the worktree root: this names the
   * directory every session's git commands run in.
   */
  r.register("repo.path.set", async (ctx) => {
    if (!ctx.client.isLocal) {
      ctx.err(
        WireErrorCode.Unauthorized,
        "A repository's path can only be changed on the machine running makit.",
      );
      return;
    }
    const projectId = typeof ctx.env.projectId === "string" ? ctx.env.projectId : "";
    if (projectId.length === 0) {
      ctx.err(WireErrorCode.BadRequest, "projectId is required.");
      return;
    }
    const path = typeof ctx.env.path === "string" ? ctx.env.path : "";
    if (path.length === 0) {
      ctx.err(WireErrorCode.BadRequest, "path is required.");
      return;
    }

    const result = await manager.repointProject(projectId, path);
    if (!result.ok) {
      // Verbatim: the reasons are actionable ("not a git repository", "already open
      // as X"), and a generic message would discard the only part the user can act
      // on.
      ctx.err(WireErrorCode.BadRequest, result.error);
      return;
    }
    ctx.ack();
    onProjectsChanged?.();
  });
}
