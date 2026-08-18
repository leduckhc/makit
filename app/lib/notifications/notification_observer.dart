import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../status/status_event.dart';
import '../status/status_providers.dart';
import '../store/models.dart';
import '../store/store.dart';
import 'notification_policy.dart';
import 'notification_service.dart';

/// Singleton notification service.
final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService(),
);

/// Wires session status changes → local notifications. Only fires while the
/// app is backgrounded (foreground = the user already sees the UI).
///
/// Read this provider once at boot to activate it (see main.dart).
final notificationControllerProvider = Provider<NotificationController>((ref) {
  final c = NotificationController(ref);
  ref.onDispose(c.dispose);
  return c;
});

class NotificationController with WidgetsBindingObserver {
  NotificationController(this._ref) {
    WidgetsBinding.instance.addObserver(this);
    // fireImmediately seeds `_last` with current statuses without notifying
    // (the app is in the foreground at boot), so we don't fire a burst on
    // launch or reconnect snapshots.
    _sub = _ref.listen<SessionsState>(
      sessionsProvider,
      (_, next) => _onSessions(next),
      fireImmediately: true,
    );
  }

  final Ref _ref;
  final Map<String, SessionStatus> _last = {};
  ProviderSubscription<SessionsState>? _sub;
  bool _foreground = true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` (a transient system overlay: control center, app switcher,
    // call banner) still counts as foreground — the user is effectively in-app,
    // so a status notification would be redundant. This mirrors
    // `SrvRequestHandler`'s foreground semantics.
    _foreground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
  }

  void _onSessions(SessionsState sessions) {
    final projects = _ref.read(projectsProvider).projects;
    String labelFor(Session s) {
      final match = projects.where((p) => p.id == s.projectId);
      return match.isEmpty ? s.title : match.first.name;
    }

    final snapshots = [
      for (final s in sessions.sessions)
        SessionStatusSnapshot(
          sessionId: s.id,
          status: s.status,
          label: labelFor(s),
        ),
    ];

    final pending = diffStatusNotifications(
      previous: _last,
      current: snapshots,
    );

    // Update the baseline regardless of foreground, so a later background
    // transition doesn't replay an already-seen change.
    for (final snap in snapshots) {
      _last[snap.sessionId] = snap.status;
    }

    if (pending.isEmpty) return;

    // The record gets every one of these, foreground or not: an OS notification
    // is a tap on the shoulder that vanishes, and "which of my sessions wanted
    // something, and when?" had no answer anywhere in the product (SPEC-status-and-activity D7).
    // Silent, because a session you are watching already shows its own status —
    // the history is the part that was missing, not the interruption.
    final status = _ref.status;
    for (final p in pending) {
      status.post(
        _severityFor(p.status),
        p.content.body,
        source: StatusSources.agent,
        detail: p.content.title,
        sessionId: p.sessionId,
        silent: true,
      );
    }

    if (_foreground) return;
    final service = _ref.read(notificationServiceProvider);
    for (final p in pending) {
      service.show(
        id: p.sessionId.hashCode,
        title: p.content.title,
        body: p.content.body,
        payload: p.sessionId,
      );
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.close();
  }
}

/// The same judgement the notification prose makes, as a severity: an error is a
/// failure, "it wants something from you" is a warning, a finished turn is a
/// success. `running` never reaches here (`notificationFor` returns null).
StatusSeverity _severityFor(SessionStatus status) => switch (status) {
  SessionStatus.error => StatusSeverity.failure,
  SessionStatus.awaitingInput ||
  SessionStatus.awaitingApproval => StatusSeverity.warning,
  SessionStatus.idle || SessionStatus.exited => StatusSeverity.success,
  SessionStatus.running => StatusSeverity.info,
};
