import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// This suite validates the structural and cross-referential integrity of the
// SPEC-assistant-display-media design document. The PR under test adds only a markdown spec file
// (no executable code), so these tests treat the document as data: they
// assert that its required sections, code samples, and cross-references are
// present and internally consistent, guarding against future edits that
// silently break the spec's contract (e.g. renaming a referenced file,
// dropping a registration point, or corrupting the documented regex).

const __dirname = dirname(fileURLToPath(import.meta.url));
const SPECS_DIR = join(__dirname, "..", "..", "..", "docs", "specs");
const SPEC_PATH = join(SPECS_DIR, "20260720-002200-SPEC-assistant-display-media.md");
const SPEC_FILENAME = "20260720-002200-SPEC-assistant-display-media.md";

function readSpec(): string {
  return readFileSync(SPEC_PATH, "utf8");
}

// -------- file location & naming convention --------------------------------

test("SPEC-assistant-display-media file exists at the expected docs/specs path", () => {
  assert.ok(existsSync(SPEC_PATH), `expected spec file at ${SPEC_PATH}`);
});

test("SPEC-assistant-display-media filename follows the <stamp>-SPEC-<slug>.md convention", () => {
  // The repo-wide guard is app/test/spec_naming_test.dart; this only pins the
  // one file this suite reads, so a rename here fails loudly rather than
  // silently reading nothing. See docs/specs/README.md#spec-naming.
  const pattern = /^\d{8}-\d{6}-SPEC-[a-z0-9]+(?:-[a-z0-9]+)*\.md$/;
  assert.match(SPEC_FILENAME, pattern);
});

// -------- header / front matter --------------------------------------------

test("SPEC-assistant-display-media has the expected title header", () => {
  const content = readSpec();
  const firstLine = content.split("\n", 1)[0];
  assert.equal(firstLine, "# SPEC-assistant-display-media — Assistant display media (images, video, gifs)");
});

test("SPEC-assistant-display-media front-matter block declares Status, Depends on, and Blocks", () => {
  const content = readSpec();
  // The front-matter paragraph wraps across two lines, so join it before
  // asserting on the fields it declares.
  const frontMatter = content.slice(0, content.indexOf("## Goal"));
  // Phases 1–3 shipped (images/GIF + local file refs); phase 4 (video/audio)
  // has not. Pinned so a status change is a deliberate edit, not drift.
  assert.match(frontMatter, /\*\*Status:\*\*\s*phases 1–3 implemented/);
  assert.match(frontMatter, /\*\*Depends on:\*\*/);
  assert.match(frontMatter, /\*\*Blocks:\*\*\s*—/);
});

test("SPEC-assistant-display-media declares its dependencies on SPEC-server-adapter-consolidation and SPEC-app-chat-simplification", () => {
  const content = readSpec();
  assert.match(content, /SPEC-server-adapter-consolidation \(adapter consolidation\)/);
  assert.match(content, /SPEC-app-chat-simplification\s*\n?\(app chat\)/);
});

// -------- required top-level sections ---------------------------------------

test("SPEC-assistant-display-media defines all required top-level sections", () => {
  const content = readSpec();
  const headings = content
    .split("\n")
    .filter((line) => /^##\s+/.test(line))
    .map((line) => line.replace(/^##\s+/, "").trim());

  const required = [
    "Goal",
    "Why",
    "Where media actually comes from (verified against the code)",
    "Design decision — reference + serve, not inline base64",
    "Scope",
    "Phasing",
    "Risks / open questions",
    "Verification",
  ];

  for (const heading of required) {
    assert.ok(
      headings.includes(heading),
      `expected "## ${heading}" section, got headings: ${JSON.stringify(headings)}`,
    );
  }
});

test("SPEC-assistant-display-media Scope section has In and Out subsections", () => {
  const content = readSpec();
  const subheadings = content
    .split("\n")
    .filter((line) => /^###\s+/.test(line))
    .map((line) => line.replace(/^###\s+/, "").trim());

  assert.ok(subheadings.includes("In"));
  assert.ok(subheadings.includes("Out"));
});

// -------- agent.media payload contract --------------------------------------

function extractPayloadCodeBlock(content: string): string {
  const match = content.match(/```ts\n([\s\S]*?)```/);
  assert.ok(match, "expected a fenced ```ts code block documenting the agent.media payload");
  return match![1];
}

test("agent.media payload code block declares all required fields", () => {
  const content = readSpec();
  const block = extractPayloadCodeBlock(content);

  const requiredFields = [
    "mediaId",
    "mime",
    "kind",
    "width",
    "height",
    "sizeBytes",
    "durationMs",
    "alt",
    "thumbMediaId",
    "callId",
  ];

  for (const field of requiredFields) {
    assert.match(
      block,
      new RegExp(`\\b${field}\\??:`),
      `expected field "${field}" in agent.media payload block:\n${block}`,
    );
  }
});

test("agent.media payload code block restricts kind to image|video|audio", () => {
  const content = readSpec();
  const block = extractPayloadCodeBlock(content);
  assert.match(block, /kind:\s*"image"\s*\|\s*"video"\s*\|\s*"audio"/);
});

test("agent.media payload documents mediaId as a sha256 hex string", () => {
  const content = readSpec();
  const block = extractPayloadCodeBlock(content);
  assert.match(block, /mediaId:\s*string;\s*\/\/\s*sha256/);
});

// -------- mediaId validation regex ------------------------------------------

function extractMediaIdRegexSource(content: string): string {
  const match = content.match(/\^\[a-f0-9\]\{64\}\$/);
  assert.ok(match, "expected the documented mediaId validation regex ^[a-f0-9]{64}$");
  return match![0];
}

test("documented mediaId regex accepts a well-formed 64-char sha256 hex digest", () => {
  const content = readSpec();
  const source = extractMediaIdRegexSource(content);
  const re = new RegExp(source);
  const validSha256 = "a".repeat(64);
  assert.match(validSha256, re);
});

test("documented mediaId regex rejects malformed ids", () => {
  const content = readSpec();
  const source = extractMediaIdRegexSource(content);
  const re = new RegExp(source);

  const invalidIds = [
    "a".repeat(63), // too short
    "a".repeat(65), // too long
    "A".repeat(64), // uppercase not allowed
    "g".repeat(64), // non-hex char
    "../../etc/passwd", // path traversal attempt
    "",
  ];

  for (const id of invalidIds) {
    assert.doesNotMatch(id, re, `expected "${id}" to be rejected by ${source}`);
  }
});

test("mediaId regex is referenced consistently in both the payload comment and the route validation bullet", () => {
  const content = readSpec();
  const occurrences = content.match(/\^\[a-f0-9\]\{64\}\$/g) ?? [];
  assert.ok(
    occurrences.length >= 2,
    `expected the mediaId regex to appear at least twice (payload + route validation), found ${occurrences.length}`,
  );
});

// -------- EventKind registration points -------------------------------------

test("SPEC-assistant-display-media enumerates all four EventKind registration points with concrete file paths", () => {
  const content = readSpec();
  const expectedPaths = [
    "server/src/protocol.ts",
    "server/src/protocol/codec.ts",
    "app/lib/transport/protocol.dart",
    "server/src/cli/render.ts",
  ];

  for (const path of expectedPaths) {
    assert.ok(
      content.includes(path),
      `expected registration-point reference to ${path}`,
    );
  }
});

test("SPEC-assistant-display-media flags that the codec has no Zod schema validation for media payload fields", () => {
  const content = readSpec();
  assert.match(content, /there is\s*\n?NO Zod here/);
});

// -------- TLS pinning prerequisite ------------------------------------------

test("SPEC-assistant-display-media names the WS client fingerprint file as the pinning source to extract", () => {
  const content = readSpec();
  assert.match(content, /app\/lib\/transport\/ws_client\.dart/);
  assert.match(content, /shared pinned/i);
});

// -------- cross-referenced dependency specs exist ---------------------------

test("referenced dependency specs (SPEC-server-adapter-consolidation, SPEC-app-chat-simplification) exist in docs/specs", () => {
  const files = readdirSync(SPECS_DIR);
  const hasConsolidation = files.some((f) => /-SPEC-server-adapter-consolidation\.md$/.test(f));
  const hasSimplification = files.some((f) => /-SPEC-app-chat-simplification\.md$/.test(f));
  assert.ok(hasConsolidation, "expected a SPEC-server-adapter-consolidation file to exist in docs/specs");
  assert.ok(hasSimplification, "expected a SPEC-app-chat-simplification file to exist in docs/specs");
});

// -------- comparison table well-formedness ----------------------------------

function parsePipeTable(content: string, headerHint: string): string[][] {
  const lines = content.split("\n");
  const headerIdx = lines.findIndex((l) => l.includes(headerHint));
  assert.ok(headerIdx >= 0, `expected a table header containing "${headerHint}"`);

  const rows: string[][] = [];
  for (let i = headerIdx; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim().startsWith("|")) break;
    // Skip the markdown separator row (e.g. | --- | --- |)
    if (/^\|[\s-:|]+\|$/.test(line.trim())) continue;
    const cells = line
      .split("|")
      .slice(1, -1)
      .map((c) => c.trim());
    rows.push(cells);
  }
  return rows;
}

test("'Where media actually comes from' table has a consistent 4-column shape", () => {
  const content = readSpec();
  const rows = parsePipeTable(content, "Source | Path | Today | Notes");
  assert.ok(rows.length >= 4, `expected at least 4 rows (header + 3 data rows), got ${rows.length}`);
  for (const row of rows) {
    assert.equal(row.length, 4, `expected 4 columns, got ${row.length}: ${JSON.stringify(row)}`);
  }
  // Sanity: first data row after the header documents the pi tool-result path.
  const dataRows = rows.slice(1);
  assert.ok(
    dataRows.some((r) => r[0].includes("Tool results")),
    "expected a 'Tool results' row in the source table",
  );
});

test("design decision comparison table lists both inline-base64 and reference+serve options", () => {
  const content = readSpec();
  const rows = parsePipeTable(content, "A. Inline base64 in the event");
  // Columns are: row label | option A (inline base64) | option B (reference+serve).
  assert.ok(rows.length >= 4, `expected header + at least 3 data rows, got ${rows.length}`);
  for (const row of rows) {
    assert.equal(row.length, 3, `expected 3 columns, got ${row.length}: ${JSON.stringify(row)}`);
  }
  const dataRows = rows.slice(1);
  assert.ok(dataRows.some((r) => r[0] === "SQLite log"));
  assert.ok(dataRows.some((r) => r[2].includes("HTTP") && r[2].includes("range requests")));
});

// -------- Phasing ------------------------------------------------------------

test("Phasing section defines exactly five ordered phases", () => {
  const content = readSpec();
  const phasingSection = content.split("## Phasing")[1]?.split("## Risks")[0];
  assert.ok(phasingSection, "expected a Phasing section before Risks / open questions");

  const phaseHeads = phasingSection!
    .split("\n")
    .filter((l) => /^\d+\.\s+\*\*/.test(l.trim()))
    .map((l) => l.trim());

  assert.equal(phaseHeads.length, 5, `expected 5 numbered phases, got:\n${phaseHeads.join("\n")}`);
  assert.match(phaseHeads[0], /Images, reference model/);
  assert.match(phaseHeads[phaseHeads.length - 1], /file:\/\/.*resource_link/);
});

// -------- Out-of-scope guarantees -------------------------------------------

test("Out-of-scope section explicitly excludes assistant-generated video/audio and file:// serving", () => {
  const content = readSpec();
  const scopeSection = content.split("### Out")[1]?.split("## Phasing")[0];
  assert.ok(scopeSection, "expected an Out subsection under Scope");
  assert.match(scopeSection!, /generating\*\*\s*video\/audio/i);
  assert.match(scopeSection!, /file:\/\/.*resource_link.*serving/i);
});

// -------- Verification section covers server, app, and manual checks --------

test("Verification section covers server unit tests, typecheck/test commands, app checks, and a manual check", () => {
  const content = readSpec();
  const verificationSection = content.split("## Verification")[1] ?? "";
  assert.match(verificationSection, /Server unit tests/);
  assert.match(verificationSection, /pnpm typecheck.*pnpm test/);
  assert.match(verificationSection, /flutter analyze --fatal-infos/);
  assert.match(verificationSection, /Manual:/);
});

test("Verification section requires the media route to return 206/416 and a media_not_found placeholder on GC'd id", () => {
  const content = readSpec();
  const verificationSection = content.split("## Verification")[1] ?? "";
  assert.match(verificationSection, /206.*Content-Range/);
  assert.match(verificationSection, /416.*bad range/);
  // The route returns 404 {"error":"media_not_found"} on missing/GC'd id,
  // which the app renders as a placeholder (never handed to a decoder).
  assert.match(content, /404.*media_not_found/);
  assert.match(content, /placeholder.*widget/);
});
