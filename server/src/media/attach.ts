/**
 * Attachment materialiser (SPEC-user-attachments T4) — writes an uploaded image into the
 * session's own worktree so **any** agent can open it, and builds the prompt
 * suffix that names it.
 *
 * This is v1's delivery mechanism, chosen because it is universal: it needs no
 * capability negotiation, works on codex and on ACP agents alike, and has no
 * size ceiling beyond the store's own. The trade-off is that the agent must
 * *choose* to read the file, which is why the prompt names it explicitly and the
 * app labels the message accordingly.
 *
 * Three rules shape everything here:
 *
 * 1. **The client never names a path.** `name` is a display hint; the on-disk
 *    name is derived from the content hash and the hint is sanitised down to a
 *    conservative character set. This is what keeps a hostile or buggy client
 *    from writing outside the attachments directory.
 * 2. **Nothing enters git.** The directory is excluded via
 *    `$GIT_DIR/info/exclude`, never a tracked `.gitignore`: pasting a screenshot
 *    must not produce a diff in the user's repository.
 * 3. **A missing worktree is an error, not a silent drop.** A session with
 *    nowhere to write cannot deliver the image, and the caller must say so.
 */

import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, readFileSync, appendFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";

import { log } from "../log.js";
import type { SessionEvent } from "../protocol.js";
import type { MediaAttachment, MediaStore } from "./store.js";

/** Directory (relative to the worktree root) attachments are written into. */
export const ATTACHMENTS_DIR = join(".makit", "attachments");

/** The line added to `$GIT_DIR/info/exclude` so `.makit/` never shows in git. */
const EXCLUDE_LINE = ".makit/";

/** Extension used when the client's hint gives us nothing usable. */
const EXT_BY_MIME: Record<string, string> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/gif": "gif",
  "image/webp": "webp",
  "image/bmp": "bmp",
};

/** Raised when a session has no worktree to write attachments into. */
export class NoWorktreeError extends Error {
  constructor() {
    super("this session has no worktree, so attachments cannot be delivered");
    this.name = "NoWorktreeError";
  }
}

/** One materialised attachment: where it landed, and what to call it. */
export interface MaterialisedAttachment {
  absPath: string;
  name: string;
}

/**
 * Reduce a client-supplied display name to a filename we are willing to create.
 *
 * Allowlist, not denylist: everything outside `[A-Za-z0-9._-]` becomes `-`, runs
 * collapse, and leading dots go (so no `.hidden`, and `..` cannot survive). An
 * empty or all-junk hint falls back to `attachment.<ext>`, which is why this can
 * never return "".
 */
export function safeName(hint: string | undefined, mime: string): string {
  const ext = EXT_BY_MIME[mime] ?? "bin";
  const cleaned = (hint ?? "")
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/-{2,}/g, "-")
    .replace(/^[.-]+/, "")
    .replace(/[.-]+$/, "")
    .slice(0, 64);
  if (!cleaned) return `attachment.${ext}`;
  // Keep an extension so editors/agents can tell what they opened.
  return /\.[A-Za-z0-9]{1,5}$/.test(cleaned) ? cleaned : `${cleaned}.${ext}`;
}

/**
 * Ensure `.makit/` is ignored for this worktree, idempotently.
 *
 * The path matters more than it looks. In a **linked worktree** `.git` is a
 * *file* pointing into `<main>/.git/worktrees/<name>`, so `<root>/.git/info/`
 * does not exist — but `--absolute-git-dir` is *also* wrong: git reads
 * `info/exclude` from the **common** git dir, so an exclude written into the
 * per-worktree directory is silently ignored and `.makit/` shows up as untracked
 * (verified by the linked-worktree test). Hence `--git-common-dir`.
 *
 * Best-effort: a non-repo directory (or a git that refuses) must not fail the
 * user's turn, so this only warns.
 */
export function excludeMakitDir(worktreePath: string): void {
  let commonDir: string;
  try {
    commonDir = execFileSync(
      "git",
      // `--path-format=absolute` because `--git-common-dir` alone can answer
      // with a path relative to the cwd.
      ["rev-parse", "--path-format=absolute", "--git-common-dir"],
      { cwd: worktreePath, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
  } catch {
    return; // not a git worktree — nothing to exclude
  }
  if (!commonDir) return;
  const excludePath = join(commonDir, "info", "exclude");
  try {
    const current = existsSync(excludePath) ? readFileSync(excludePath, "utf8") : "";
    if (current.split(/\r?\n/).some((line) => line.trim() === EXCLUDE_LINE)) return;
    mkdirSync(dirname(excludePath), { recursive: true });
    const prefix = current.length > 0 && !current.endsWith("\n") ? "\n" : "";
    appendFileSync(excludePath, `${prefix}${EXCLUDE_LINE}\n`);
  } catch (err) {
    log.warn(`[makit] could not exclude .makit/ from git: ${(err as Error).message}`);
  }
}

/**
 * Copy each attachment out of the content-addressed store into
 * `<worktree>/.makit/attachments/` and return where they landed.
 *
 * The filename is `<first 7 of mediaId>-<safeName>`: the hash prefix makes it
 * unique without trusting the client, and the readable tail keeps the prompt
 * legible to both the agent and the user. Copying is idempotent \u2014 the same blob
 * re-attached overwrites an identical file.
 */
export function materialise(
  store: MediaStore,
  attachments: readonly MediaAttachment[],
  worktreePath: string | undefined,
): MaterialisedAttachment[] {
  if (attachments.length === 0) return [];
  if (!worktreePath) throw new NoWorktreeError();

  const dir = join(worktreePath, ATTACHMENTS_DIR);
  mkdirSync(dir, { recursive: true });
  excludeMakitDir(worktreePath);

  return attachments.map((a) => {
    const name = `${a.mediaId.slice(0, 7)}-${safeName(a.name, a.mime)}`;
    const absPath = join(dir, name);
    copyFileSync(store.pathOf(a.mediaId), absPath);
    return { absPath, name };
  });
}

/**
 * The block appended to the user's prompt naming the files.
 *
 * Absolute paths, one per line: the agent's tools take paths, and a relative
 * path would depend on its cwd. Empty string for no attachments, so callers can
 * concatenate unconditionally.
 */
export function promptSuffix(files: readonly MaterialisedAttachment[]): string {
  if (files.length === 0) return "";
  const lines = files.map((f) => `- ${f.absPath}`).join("\n");
  return `\n\nAttached files:\n${lines}`;
}

/** What an adapter needs in order to send one turn (see {@link prepareTurn}). */
export interface PreparedTurn {
  /** Text to hand the agent — the user's text plus the file references. */
  promptText: string;
  /**
   * Payload for the `user.message` echo. Carries the user's **original** text,
   * not `promptText`: the echo is what the transcript renders, and showing the
   * path plumbing back to the person who pasted the image would be noise.
   */
  echo: Record<string, unknown>;
}

/**
 * {@link prepareTurn}, but reporting failure the way an adapter must: emit a
 * persisted `session.error` and return `null` so the caller abandons the turn.
 *
 * Exists because all three adapters (`acp`, `codex`, `stub`) need the identical
 * eleven lines around `prepareTurn`, and had them copy-pasted — including the
 * error message. An adapter's own `emitEvent` is private/protected, so the
 * emitter is passed in rather than inherited. Its parameter is derived from
 * {@link SessionEvent} (the same shape `AdapterEvent` names) rather than spelling
 * out an inline `session.error` literal, so the wire shape stays declared in one
 * place — `media/` deliberately does not import `adapters/`, which is the layer
 * above it. This function only ever emits that one kind.
 *
 * Returning `null` (not throwing) keeps the decision at the call site: a turn
 * whose prompt would reference an image the agent can never open is worse than
 * no turn at all, so `send()` returns early instead of degrading to text.
 */
export function prepareTurnOrFail(
  store: MediaStore,
  input: { text: string; attachments?: readonly MediaAttachment[] },
  worktreePath: string | undefined,
  emit: (event: Omit<SessionEvent, "seq" | "sessionId">) => void,
): PreparedTurn | null {
  try {
    return prepareTurn(store, input, worktreePath);
  } catch (err) {
    emit({
      ts: Date.now(),
      kind: "session.error",
      payload: { message: `attachment delivery failed: ${(err as Error).message}` },
    });
    return null;
  }
}

/**
 * Turn a {@link UserInput}-shaped turn into the prompt text and the echo payload.
 *
 * Lives here, called by both adapters, so the delivery *policy* (v1: hand the
 * agent a file and name it) exists in exactly one place — the ACP and codex
 * `send()` methods then differ only in how they wrap the final text. Throws
 * {@link NoWorktreeError} (or an fs error) if the attachment cannot be written;
 * callers surface that as `session.error` rather than sending a turn whose
 * prompt references an image the agent will never find.
 */
export function prepareTurn(
  store: MediaStore,
  input: { text: string; attachments?: readonly MediaAttachment[] },
  worktreePath: string | undefined,
): PreparedTurn {
  const attachments = input.attachments ?? [];
  if (attachments.length === 0) {
    return { promptText: input.text, echo: { text: input.text } };
  }
  const files = materialise(store, attachments, worktreePath);
  return {
    promptText: `${input.text}${promptSuffix(files)}`,
    // Descriptors only — the app fetches bytes from `GET /media/<mediaId>`,
    // because this event is replayed in full on every resume.
    echo: { text: input.text, attachments: attachments.map((a) => ({ ...a })) },
  };
}
