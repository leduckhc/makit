---
name: "makit-media-ingestion"
description: "Implement multimodal media ingestion for SPEC-assistant-display-media: wire agent.media events at registration points, then extract image blocks from ACP and codex adapter streams into the store."
---
## When to Use
Use when adding agent.media event registration (step 4) or implementing ingestion in acp-map.ts / codex-map.ts (steps 5–6). Prerequisites: media store (server/src/media/store.ts) and /media route (server/src/media/route.ts) must already be complete and wired.

## Procedure
1. Register agent.media event kind: add to SessionEvent union in models.ts; add to protocol.ts PROTOCOL_KINDS; update CLI renderer in cli.ts; update acp-map.ts and codex-map.ts adapter registration.
2. In acp-map.ts: extract image blocks from tool_call_update.content[] and tool_call_update.rawOutput.content[]; pass each to sharedMediaStore().putBase64(); emit agent.media events with mediaId.
3. In codex-map.ts: scan codex content blocks for image/audio types; store and emit agent.media events (codec already wires codex-map results into AdapterEvent[].
4. Test: acp-map unit tests should inject fixtures with image blocks; verify mediaId round-trip and store side-effects (files written to ~/.makit/media/).
5. Verify: CLI render must display agent.media events (e.g. '[image mediaId=abc123…]'); replay fixtures through chat_items store to confirm app receives descriptors.
6. End-to-end: run makit against real pi-acp agent that reads/produces an image; verify media file appears in ~/.makit/media/, event seq is correct, route serves bytes.

## Pitfalls
- Do NOT emit agent.media without storing first — store is the source of truth for mediaId; event must reference extant blob.
- Watch for tool result structure: both content[] (structured) and rawOutput.content[] (raw) can contain images. Check both in ACP (codex only uses one path).
- Image blocks in codex are inline deltas (item/commandExecution/delta with type=image) — different event kind; must map to same agent.media output.
- Base64 decode failure or mime mismatch is not an exception — silently skip (log at debug level) so one bad image doesn't crash the agent.
- mediaId is sha256 of raw bytes (store's responsibility). Mapper only passes base64 + mime to store; store returns id. Do NOT hand-construct mediaIds.

## Verification
1. pnpm test src/adapters/acp-map.test.ts — verify image block extraction in fixtures.
2. pnpm test src/adapters/codex-map.test.ts — verify codex image delta mapping.
3. pnpm test src/models.ts — verify agent.media is a valid SessionEvent and round-trips codec.
4. CLI render: pnpm exec tsx test/e2e-server.ts --mode stub, send agent message with embedded image via fake adapter, verify CLI prints '[image …]'.
5. End-to-end: makit session with real pi-acp → agent reads a screenshot → verify media file in ~/.makit/media/ and GET /media/<sha256> returns bytes.
