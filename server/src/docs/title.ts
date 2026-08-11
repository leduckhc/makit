/**
 * makit — SPEC-46 D4/D14: give a document a human name.
 *
 * `2026-08-07-SPEC-44-ports-forward.md` is unreadable on a 375 pt row, and the
 * real name is already inside the file. Pure extractors below, with one thin IO
 * shell (`readDocMeta`) that reads only a bounded prefix — a title lives in the
 * first few hundred bytes, so there is no reason to pull 5 MB to find it.
 */

import { closeSync, openSync, readSync } from "node:fs";
import { basename } from "node:path";

import type { DocKind } from "./resolve.js";

/** How much of a file we are willing to read to find a title. */
export const TITLE_READ_BYTES = 64 * 1024;

/** How many leading lines of markdown may be scanned for an H1 / status line. */
const MAX_HEADER_LINES = 80;

export interface DocMeta {
  title: string;
  docStatus?: string;
}

/** The `<title>` element's text, or undefined. Entities decoded, whitespace collapsed. */
export function titleFromHtml(text: string): string | undefined {
  const m = /<title\b[^>]*>([\s\S]*?)<\/title\s*>/i.exec(text);
  if (m === null) return undefined;
  return clean(decodeEntities(m[1]!));
}

/**
 * The first ATX heading's text, or undefined. An H1 always wins; an H2 is
 * accepted only when the document has no H1 at all (three files in this repo
 * start at `##`, and their heading beats their filename). Skips front matter
 * and fenced code.
 */
export function titleFromMarkdown(text: string): string | undefined {
  let h2: string | undefined;
  for (const line of headerLines(text)) {
    const m = /^(#{1,2})\s+(.*)$/.exec(line);
    if (m === null) continue;
    // Strip a closing "###" run, then inline emphasis/code markers.
    const stripped = m[2]!.replace(/\s+#+\s*$/, "");
    const plain = clean(stripped.replace(/[`*_]/g, ""));
    if (plain === undefined) continue;
    if (m[1]!.length === 1) return plain;
    h2 ??= plain;
  }
  return h2;
}

/**
 * The `**Status:**` value, shortened to the first clause so it fits a chip:
 * `**Status:** Implemented (P1, rev 2) · **Priority:** P2` → `Implemented`.
 * Absent rather than guessed (D14).
 */
export function statusFromMarkdown(text: string): string | undefined {
  for (const line of headerLines(text)) {
    const m = /^\*\*Status:\*\*\s*(.*)$/.exec(line.trim());
    if (m === null) continue;
    const head = m[1]!.split("·")[0]!;
    return clean(head.replace(/\s*\(.*$/, "").replace(/[`*_]/g, ""));
  }
  return undefined;
}

/**
 * Read a bounded prefix of `absPath` and extract what is there. Never throws —
 * an unreadable file simply falls back to its basename, because a row with a
 * filename is still useful and a failed scan must not lose the file (scanOk).
 */
export function readDocMeta(absPath: string, kind: DocKind): DocMeta {
  const fallback = basename(absPath);
  const text = readPrefix(absPath);
  if (text === undefined) return { title: fallback };

  if (kind === "html") {
    return { title: titleFromHtml(text) ?? fallback };
  }
  const docStatus = statusFromMarkdown(text);
  const title = titleFromMarkdown(text) ?? fallback;
  return docStatus === undefined ? { title } : { title, docStatus };
}

/** Up to TITLE_READ_BYTES of `absPath` as utf8, or undefined if unreadable. */
function readPrefix(absPath: string): string | undefined {
  let fd: number | undefined;
  try {
    fd = openSync(absPath, "r");
    const buf = Buffer.allocUnsafe(TITLE_READ_BYTES);
    const read = readSync(fd, buf, 0, TITLE_READ_BYTES, 0);
    return buf.subarray(0, read).toString("utf8");
  } catch {
    return undefined;
  } finally {
    if (fd !== undefined) {
      try {
        closeSync(fd);
      } catch {
        /* already gone */
      }
    }
  }
}

/**
 * The leading lines of a markdown document, with YAML front matter and fenced
 * code blocks removed — a `#` inside either is not a heading.
 */
function headerLines(text: string): string[] {
  const lines = text.split(/\r?\n/);
  let i = 0;

  if (lines[0]?.trim() === "---") {
    const end = lines.findIndex((l, idx) => idx > 0 && l.trim() === "---");
    if (end !== -1) i = end + 1;
  }

  const out: string[] = [];
  let inFence = false;
  for (; i < lines.length && out.length < MAX_HEADER_LINES; i++) {
    const line = lines[i]!;
    if (/^\s*(```|~~~)/.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (!inFence) out.push(line);
  }
  return out;
}

/** Collapse whitespace; undefined when nothing is left. */
function clean(s: string): string | undefined {
  const t = s.replace(/\s+/g, " ").trim();
  return t === "" ? undefined : t;
}

/** Decode only the entities that realistically appear in a title. */
function decodeEntities(s: string): string {
  return s
    .replace(/&nbsp;/gi, " ")
    .replace(/&quot;/gi, '"')
    .replace(/&#0*39;|&apos;/gi, "'")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&amp;/gi, "&"); // last, so "&amp;lt;" does not become "<"
}
