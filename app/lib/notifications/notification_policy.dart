import '../store/models.dart';

/// The user-facing content of a local notification.
class NotificationContent {
  const NotificationContent({required this.title, required this.body});
  final String title;
  final String body;

  @override
  bool operator ==(Object other) =>
      other is NotificationContent &&
      other.title == title &&
      other.body == body;

  @override
  int get hashCode => Object.hash(title, body);
}

/// Pure decision: does a session status transition warrant a notification?
///
/// Returns null when nothing should fire. Rules:
///   - running → idle/exited                → "finished its turn"
///   - * → awaitingInput                     → "needs your input"
///   - * → awaitingApproval                  → "needs your approval"
///   - * → error                             → "hit an error"
///   - transitions into `running`, or a repeat of the same status, are silent.
///
/// The caller is responsible for only invoking this when the app is
/// backgrounded — in the foreground the user already sees the UI.
NotificationContent? notificationFor({
  required SessionStatus? from,
  required SessionStatus to,
  required String sessionLabel,
}) {
  if (from == to) return null;
  return switch (to) {
    // "Finished" only makes sense if it was actually working.
    SessionStatus.idle ||
    SessionStatus.exited => from == SessionStatus.running
        ? NotificationContent(
            title: sessionLabel,
            body: 'Agent finished its turn.',
          )
        : null,
    SessionStatus.awaitingInput => NotificationContent(
      title: sessionLabel,
      body: 'Agent needs your input.',
    ),
    SessionStatus.awaitingApproval => NotificationContent(
      title: sessionLabel,
      body: 'Agent needs your approval.',
    ),
    SessionStatus.error => NotificationContent(
      title: sessionLabel,
      body: 'Agent hit an error.',
    ),
    SessionStatus.running => null,
  };
}

/// A session's status plus the label to show in a notification.
class SessionStatusSnapshot {
  const SessionStatusSnapshot({
    required this.sessionId,
    required this.status,
    required this.label,
  });
  final String sessionId;
  final SessionStatus status;
  final String label;
}

/// A notification that should be shown for a given session.
class PendingNotification {
  const PendingNotification({required this.sessionId, required this.content});
  final String sessionId;
  final NotificationContent content;
}

/// Pure diff: given the [previous] status per session and the [current]
/// snapshots, return the notifications that should fire. The caller updates
/// its own status map from [current] afterwards (regardless of foreground).
List<PendingNotification> diffStatusNotifications({
  required Map<String, SessionStatus> previous,
  required List<SessionStatusSnapshot> current,
}) {
  final out = <PendingNotification>[];
  for (final snap in current) {
    final content = notificationFor(
      from: previous[snap.sessionId],
      to: snap.status,
      sessionLabel: snap.label,
    );
    if (content != null) {
      out.add(PendingNotification(sessionId: snap.sessionId, content: content));
    }
  }
  return out;
}
