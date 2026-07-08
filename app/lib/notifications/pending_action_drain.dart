/// SPEC-07 Slice 2 — draining the force-quit pending-action queue.
///
/// When the user taps an actionable notification while the app process is dead,
/// Slice-1's `notificationBackgroundHandler` isolate persists
/// `{payload, actionId, input}` to SharedPreferences (`kPendingActionsKey`). On
/// the next launch/reconnect we drain that queue through the SAME pure mapping
/// the live-isolate path uses (`parseNotificationPayload` + `responseForAction`)
/// and replay each response via the injected `respond` (the `respondTo`
/// tear-off), then clear the queue. Idempotency is guaranteed downstream by
/// `respondTo`'s `_respondedRequests` guard (SPEC-08 step 4).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_request.dart';
import 'notification_service.dart';

/// A planned replay: a request id and the `srv.response` body to send.
@immutable
class PendingReplay {
  const PendingReplay(this.requestId, this.body);

  final String requestId;
  final Map<String, dynamic> body;
}

/// Pure: map a raw pending-action queue (FIFO) to the replays to perform.
///
/// Each [rawQueue] entry is the `{payload, actionId, input}` JSON written by
/// `notificationBackgroundHandler`. Entries with garbage JSON, an unknown
/// action, a missing request id, or an action/kind mismatch are skipped;
/// surviving entries keep their original order.
List<PendingReplay> planDrain(List<String> rawQueue) {
  final plan = <PendingReplay>[];
  for (final raw in rawQueue) {
    final Map<String, dynamic> entry;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) continue;
      entry = decoded;
    } on FormatException {
      continue;
    }
    final payload = entry['payload'] as String?;
    final actionId = entry['actionId'] as String?;
    final input = entry['input'] as String?;
    if (actionId == null || actionId.isEmpty) continue;

    final parsed = parseNotificationPayload(payload);
    final rid = parsed.requestId;
    final kind = parsed.kind;
    if (rid == null || rid.isEmpty || kind == null) continue;

    final body = responseForAction(kind: kind, actionId: actionId, input: input);
    if (body == null) continue;
    plan.add(PendingReplay(rid, body));
  }
  return plan;
}

/// Signature of the response sink — the `ConnectionController.respondTo`
/// tear-off. Injected so the drainer stays unit-testable.
typedef RespondTo = void Function(String requestId, Map<String, dynamic> body);

/// Drains the persisted force-quit pending-action queue exactly once.
class PendingActionDrainer {
  PendingActionDrainer(this._prefs, this._respond);

  final SharedPreferences _prefs;
  final RespondTo _respond;

  /// Read the queue, replay each planned response in FIFO order, then clear the
  /// key. Best-effort + idempotent (a cleared queue makes a re-run a no-op; a
  /// double-replay is also absorbed by `respondTo`'s guard).
  Future<void> drain() async {
    final queue = _prefs.getStringList(kPendingActionsKey) ?? const <String>[];
    if (queue.isEmpty) return;
    for (final replay in planDrain(queue)) {
      _respond(replay.requestId, replay.body);
    }
    await _prefs.remove(kPendingActionsKey);
  }
}
