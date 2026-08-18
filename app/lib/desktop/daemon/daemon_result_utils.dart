/// Utilities for daemon action results (SPEC-profiles).
library;

import 'dart:io' show ProcessResult;

/// Builds the human-readable detail for a non-zero `makit <verb>` exit.
///
/// Both streams are consulted, because `makit start` reports *why* it failed on
/// **stdout**, not stderr: the daemon is spawned detached with its own output
/// redirected into the log file, so the parent process's only diagnostic is
/// `deps.out(...)` -> `console.log` (see `start` in
/// `server/src/daemon/service.ts` and `out:` in `server/src/index.ts`).
/// Reading stderr alone yielded the bare, useless `makit start exited 1: ` for
/// every real start failure -- including the common "port already in use" case,
/// whose message names the log file and the fix.
String formatDaemonError(String verb, ProcessResult result) {
  final head = 'makit $verb exited ${result.exitCode}';
  final parts = <String>[];
  for (final stream in [result.stderr, result.stdout]) {
    if (stream is! String) continue;
    final text = stream.trim();
    if (text.isNotEmpty && !parts.contains(text)) parts.add(text);
  }
  return parts.isEmpty ? head : '$head: ${parts.join(' — ')}';
}
