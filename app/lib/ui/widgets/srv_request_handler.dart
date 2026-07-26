/// Listens for `srv.request` envelopes from the server and presents the
/// appropriate UI (currently: AskUserQuestion dialog). Mount once at app
/// root so any screen sees the dialog.
///
/// We render against the app's Navigator rather than our own `BuildContext`,
/// because this widget sits in `MaterialApp.builder` — above the Navigator.
library;

import 'dart:async';

// `visibleForTesting` is re-exported by Flutter material.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../app/theme.dart';
import '../../notifications/notification_observer.dart';
import '../../notifications/notification_request.dart';
import '../../store/connection.dart';
import '../../store/elicitation.dart';
import '../../store/store.dart';
import '../../transport/protocol.dart';

// Re-export the wizard's test entrypoint so existing importers of
// `srv_request_handler.dart` keep resolving it after the SPEC-19 split.
export 'srv_dialogs/ask_wizard.dart' show debugAskWizardFor;

class SrvRequestHandler extends ConsumerStatefulWidget {
  const SrvRequestHandler({
    super.key,
    required this.child,
    this.navigatorKey,
    this.reminderDelay,
  });
  final Widget child;
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Desktop mode. When set, requests ALWAYS present the in-app dialog
  /// immediately (never diverted to a notification based on foreground
  /// state — the desktop window is the control surface). If the request is
  /// still unanswered after this delay, a system notification is fired as a
  /// reminder. When null (mobile), backgrounded requests are diverted to an
  /// actionable notification instead of the invisible dialog.
  final Duration? reminderDelay;

  @override
  ConsumerState<SrvRequestHandler> createState() => _SrvRequestHandlerState();
}

class _SrvRequestHandlerState extends ConsumerState<SrvRequestHandler>
    with WidgetsBindingObserver {
  StreamSubscription<Envelope>? _sub;
  StreamSubscription<String>? _respondedSub;
  bool _foreground = true;

  /// Backgrounded requests for which we fired a notification. Kept so that if
  /// the user resumes the app without acting on the notification, we can still
  /// present the dialog (the `srvRequests` stream has no replay). Soft-capped
  /// so a long backgrounded session can't grow it without bound (mirrors the
  /// SPEC-07 status-notification queue); oldest entries are evicted first.
  final Map<String, Envelope> _pendingBackground = {};
  static const _kMaxPendingBackground = 50;

  /// Desktop reminder timers, keyed by request id. Fires a system notification
  /// when a dialog has been open (unanswered) for [SrvRequestHandler.reminderDelay];
  /// cancelled when the request is answered or the widget disposes.
  final Map<String, Timer> _reminderTimers = {};

  /// Dialog contexts keyed by request id, so an answer from a notification can
  /// remove that request's exact route without disturbing another open dialog.
  final Map<String, BuildContext> _activeDialogContexts = {};
  final Map<String, Object> _activeDialogTokens = {};

  /// Salted so request-notification ids can't collide with the status
  /// notifications keyed on `sessionId.hashCode`.
  int _notificationId(String requestId) =>
      (requestId.hashCode ^ 0x52455148).toUnsigned(31);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _subscribe());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` (e.g. transient system overlay) still counts as foreground so
    // an in-flight request isn't diverted to a notification the user can see
    // the app behind. A true background→foreground transition drains any
    // queued fallback dialogs.
    final wasForeground = _foreground;
    _foreground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (!wasForeground && _foreground) _drainPendingBackground();
  }

  /// Present any still-pending backgrounded requests as dialogs on resume.
  ///
  /// Approve/Deny/Reply are FOREGROUND notification actions: tapping one
  /// resumes the app, and the action callback (→ `respondTo` → `responded`)
  /// can land slightly AFTER `resumed`. We therefore delay the drain briefly
  /// and re-check `_pendingBackground` before presenting, so a request already
  /// answered from the notification is not double-prompted.
  void _drainPendingBackground() {
    if (_pendingBackground.isEmpty) return;
    final queued = List<Envelope>.from(_pendingBackground.values);
    Future.delayed(const Duration(milliseconds: 400), () async {
      for (final env in queued) {
        if (!mounted) return;
        if (!_pendingBackground.containsKey(env.id)) continue;
        _pendingBackground.remove(env.id);
        await _presentDialog(env);
      }
    });
  }

  void _subscribe() {
    _sub?.cancel();
    final controller = ref.read(connectionControllerProvider.notifier);
    _sub = controller.srvRequests.listen(_dispatch);
    _respondedSub?.cancel();
    _respondedSub = controller.responded.listen(_onResponded);
  }

  void _onResponded(String id) {
    _pendingBackground.remove(id);
    _reminderTimers.remove(id)?.cancel();
    _activeDialogTokens.remove(id);
    final dialogContext = _activeDialogContexts.remove(id);
    if (dialogContext == null || !dialogContext.mounted) return;
    final route = ModalRoute.of(dialogContext);
    if (route != null && route.isActive) {
      Navigator.of(dialogContext).removeRoute(route);
    }
  }

  Future<T?> _showTrackedDialog<T>({
    required String requestId,
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) async {
    final dialogToken = Object();
    final result = await showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (dctx) {
        _activeDialogContexts[requestId] = dctx;
        _activeDialogTokens[requestId] = dialogToken;
        return builder(dctx);
      },
    );
    if (identical(_activeDialogTokens[requestId], dialogToken)) {
      _activeDialogTokens.remove(requestId);
      _activeDialogContexts.remove(requestId);
    }
    return result;
  }

  /// Fire a system notification once a still-unanswered request has been
  /// on-screen for [SrvRequestHandler.reminderDelay] (desktop only).
  void _scheduleReminder(Envelope env, String kind) {
    final sessionId = env.body['sessionId'] as String? ?? '';
    _reminderTimers.remove(env.id)?.cancel();
    _reminderTimers[env.id] = Timer(widget.reminderDelay!, () async {
      _reminderTimers.remove(env.id);
      if (!mounted) return;
      final notif = notificationForRequest(
        kind: kind,
        body: env.body,
        label: _labelFor(sessionId),
      );
      if (notif == null) return;
      await ref
          .read(notificationServiceProvider)
          .show(
            id: _notificationId(env.id),
            title: notif.title,
            body: notif.body,
            category: notif.category,
            payload: encodeRequestPayload(
              sessionId: sessionId,
              requestId: env.id,
              kind: kind,
            ),
          );
    });
  }

  Future<void> _dispatch(Envelope env) async {
    final kind = env.body['kind'] as String? ?? 'unknown';

    // Desktop: always present the dialog now; if it goes unanswered for
    // `reminderDelay`, nudge with a system notification (the tap routes back
    // through respondTo, and the in-app dialog stays answerable meanwhile).
    if (widget.reminderDelay != null) {
      _scheduleReminder(env, kind);
      await _presentDialog(env);
      return;
    }

    // Backgrounded: if this request kind has an actionable-notification
    // affordance, fire the notification and skip the (invisible) dialog. The
    // user resolves it from the lock screen; the tap routes back through
    // `respondTo` (see main.dart onAction).
    if (!_foreground) {
      final sessionId = env.body['sessionId'] as String? ?? '';
      final notif = notificationForRequest(
        kind: kind,
        body: env.body,
        label: _labelFor(sessionId),
      );
      if (notif != null) {
        final shown = await ref
            .read(notificationServiceProvider)
            .show(
              id: _notificationId(env.id),
              title: notif.title,
              body: notif.body,
              category: notif.category,
              payload: encodeRequestPayload(
                sessionId: sessionId,
                requestId: env.id,
                kind: kind,
              ),
            );
        // Shown: keep it so a resume-without-action still surfaces a dialog.
        // Not shown (no permission / dismissed / platform throw): fall through
        // to present the dialog now, so the request stays answerable.
        if (shown) {
          if (_pendingBackground.length >= _kMaxPendingBackground) {
            _pendingBackground.remove(_pendingBackground.keys.first);
          }
          _pendingBackground[env.id] = env;
          return;
        }
      }
    }

    await _presentDialog(env);
  }

  Future<void> _presentDialog(Envelope env) async {
    final kind = env.body['kind'] as String? ?? 'unknown';

    // askUserQuestion renders inline (SPEC-25) — it needs no Navigator, so
    // handle it before the navigator-context guard below.
    if (kind == 'askUserQuestion') {
      final questions = _normaliseQuestions(env.body);
      if (questions.isEmpty) {
        _respond(env.id, {
          'kind': 'askUserQuestion',
          'indices': <int>[],
          'answers': <String>[],
          'error': 'no questions',
        });
        return;
      }
      // The desktop reminder timer (scheduled in _dispatch) and _onResponded
      // cleanup still apply; the store answers via the connection's respondTo.
      ref
          .read(elicitationControllerProvider.notifier)
          .add(
            PendingAsk(
              requestId: env.id,
              sessionId: env.body['sessionId'] as String? ?? '',
              questions: questions,
            ),
          );
      return;
    }

    // Use the app's Navigator, not this widget's context — we're above it.
    final navCtx = (widget.navigatorKey ?? makitNavigatorKey).currentContext;
    if (navCtx == null) return;

    if (kind == 'confirmAction') {
      await _showConfirmAction(navCtx, env.id, env.body);
      return;
    }

    if (kind == 'input') {
      // pi-ask-user's multi-select fallback arrives as ctx.ui.input with the
      // options embedded in the prompt. Render it inline as a multi-select
      // card instead of a modal; ordinary free-text input stays modal.
      final ms = PendingAsk.fromMultiSelectInput(
        requestId: env.id,
        sessionId: env.body['sessionId'] as String? ?? '',
        title: env.body['title']?.toString() ?? '',
      );
      if (ms != null) {
        ref.read(elicitationControllerProvider.notifier).add(ms);
        return;
      }
      await _showInput(navCtx, env.id, env.body);
      return;
    }

    await _showGeneric(navCtx, env);
  }

  List<Map<String, dynamic>> _normaliseQuestions(Map<String, dynamic> body) {
    final raw = body['questions'];
    if (raw is List) {
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map(Map<String, dynamic>.from)
          .toList();
    }
    // Single-question form — wrap as one-element wizard.
    if (body['question'] is String) {
      return [
        {
          'header': body['header'],
          'question': body['question'],
          'options': body['options'],
          'multi': body['multi'],
          'recommended': body['recommended'],
        },
      ];
    }
    return const [];
  }

  Future<void> _showConfirmAction(
    BuildContext ctx,
    String requestId,
    Map<String, dynamic> body,
  ) async {
    final approved = await _showTrackedDialog<bool>(
      requestId: requestId,
      context: ctx,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        title: Text(body['title']?.toString() ?? 'Confirm'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body['message']?.toString() ?? ''),
            if (body['preview'] != null) ...[
              const SizedBox(height: kSpace8),
              Container(
                padding: const EdgeInsets.all(kSpace8),
                decoration: BoxDecoration(
                  color: Theme.of(dctx).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(kRadius6),
                ),
                child: SelectableText(
                  body['preview'].toString(),
                  style: Theme.of(dctx).textTheme.bodySmall?.mono,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Deny'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    _respond(requestId, SrvResponse.confirmAction(approved: approved ?? false));
  }

  /// Free-text input (maps pi's ctx.ui.input / ctx.ui.editor via the PiAdapter
  /// UI interceptor). Responds with the canonical `input` shape.
  Future<void> _showInput(
    BuildContext ctx,
    String requestId,
    Map<String, dynamic> body,
  ) async {
    final controller = TextEditingController(
      text: body['prefill']?.toString() ?? '',
    );
    final multiline = body['multiline'] == true;
    final value = await _showTrackedDialog<String?>(
      requestId: requestId,
      context: ctx,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        title: Text(body['title']?.toString() ?? 'Input'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: multiline ? 3 : 1,
          maxLines: multiline ? 8 : 1,
          decoration: InputDecoration(
            hintText: body['placeholder']?.toString(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, controller.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (value == null) {
      _respond(requestId, SrvResponse.cancelled('input'));
    } else {
      _respond(requestId, SrvResponse.input(value));
    }
  }

  Future<void> _showGeneric(BuildContext ctx, Envelope env) async {
    final controller = TextEditingController();
    final text = await _showTrackedDialog<String?>(
      requestId: env.id,
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: Text(env.body['title']?.toString() ?? 'Server request'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              env.body['message']?.toString() ??
                  env.body['kind']?.toString() ??
                  '',
            ),
            const SizedBox(height: kSpace12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Your answer'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, controller.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (text == null) {
      _respond(env.id, {'ok': false, 'cancelled': true});
    } else {
      _respond(env.id, {'ok': true, 'text': text});
    }
  }

  void _respond(String id, Map<String, dynamic> body) {
    ref.read(connectionControllerProvider.notifier).respondTo(id, body);
  }

  /// Human-readable label for a session (project name), mirroring
  /// `NotificationController.labelFor`. Falls back to the session title.
  String _labelFor(String sessionId) {
    if (sessionId.isEmpty) return '';
    final sessions = ref.read(sessionsProvider).sessions;
    final match = sessions.where((s) => s.id == sessionId);
    if (match.isEmpty) return '';
    final session = match.first;
    final projects = ref.read(projectsProvider).projects;
    final proj = projects.where((p) => p.id == session.projectId);
    return proj.isEmpty ? session.title : proj.first.name;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _respondedSub?.cancel();
    for (final t in _reminderTimers.values) {
      t.cancel();
    }
    _reminderTimers.clear();
    _activeDialogContexts.clear();
    _activeDialogTokens.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
