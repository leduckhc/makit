/**
 * Wire protocol — keep in sync with `app/lib/transport/protocol.dart`.
 *
 * Single source of truth would be a shared JSON schema; for M0 we mirror by
 * hand and trust the test surface to catch drift.
 */
export const PROTOCOL_VERSION = 1;
/** Default title for a freshly-spawned, not-yet-named session. */
export const DEFAULT_SESSION_TITLE = "new session";
let _seq = 0;
export const newId = (prefix = "id") => `${prefix}-${Date.now().toString(36)}-${(_seq++).toString(36)}`;
//# sourceMappingURL=protocol.js.map