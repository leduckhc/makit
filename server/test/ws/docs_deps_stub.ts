/**
 * Shared stubs for the docs-domain `CommandDeps` members (SPEC-doc-preview).
 *
 * The sibling of `ports_deps_stub.ts`, for the same reason and after the same
 * near-miss: three `CommandRouter` harnesses (`agents_catalog`, `pr_commands`,
 * `send_message_attachments` — the last one twice) need these members only so
 * the object satisfies `CommandDeps`; none of them exercises docs. When
 * `isIndexedWorktree` was added to `DocsCommandPort` all four copies had to be
 * edited. Extracted so the next member is ONE edit.
 *
 * `satisfies` is the load-bearing word: it checks every member against
 * `CommandDeps` while keeping the object usable in a spread.
 */

import type { CommandDeps } from "../../src/ws/commands/deps.js";

/** No-op docs deps: own no worktree, refuse every read/publish/open, hold no grants. */
export const docsDepsStub = {
  onDocsWatchersChanged: () => {},
  sendDocsSnapshot: () => {},
  docs: {
    // Inert harnesses index nothing, so every client-supplied path is out of
    // scope — the same answer the real service gives for an unknown worktree.
    isIndexedWorktree: () => false,
    read: () => ({ ok: false as const, message: "" }),
    publish: async () => ({ ok: false as const, reason: "" }),
    open: async () => ({ ok: false as const, reason: "stub" }),
    unpublish: () => false,
    grants: () => [],
  },
} satisfies Pick<CommandDeps, "onDocsWatchersChanged" | "sendDocsSnapshot" | "docs">;
