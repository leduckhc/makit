/// Pure request→notification mapping, actionId→response mapping, and the
/// notification-payload codec. No Flutter/plugin imports so it stays unit
/// testable and reusable from the (SPEC-07) background isolate.
library;

import 'dart:convert';

/// Canonical `srv.response` body builder — the single source of truth for the
/// shapes the app sends back to the server (SPEC-18 T4). Both the in-app dialog
/// path (`SrvRequestHandler`) and the notification-action path
/// ([responseForAction]) build their responses here so the two can never drift.
///
/// The `kind` field is ALWAYS present: server consumers dispatch on it
/// (`resp.kind === "confirmAction"` / `"askUserQuestion"` / `"input"`), so a
/// response without it falls through and is silently dropped.
abstract final class SrvResponse {
  /// Answer to a `confirmAction` request.
  static Map<String, dynamic> confirmAction({required bool approved}) => {
    'kind': 'confirmAction',
    'approved': approved,
  };

  /// Answer to an `askUserQuestion` request. Consumers read `answers` (label
  /// text) and `indices` (selected option per question); `answer` is the
  /// single-question convenience alias.
  static Map<String, dynamic> askUserQuestion({
    required List<int> indices,
    required List<String> answers,
    String? answer,
  }) => {
    'kind': 'askUserQuestion',
    'indices': indices,
    'answers': answers,
    'answer': ?answer,
  };

  /// Answer to an `input` request carrying the user's [value].
  static Map<String, dynamic> input(String value) => {
    'kind': 'input',
    'value': value,
  };

  /// A cancellation for a request of [kind]. `askUserQuestion` carries empty
  /// `indices`/`answers` so consumers iterating them stay safe; other kinds
  /// carry just the cancelled flag.
  static Map<String, dynamic> cancelled(String kind) => switch (kind) {
    'askUserQuestion' => {
      'kind': 'askUserQuestion',
      'indices': <int>[],
      'answers': <String>[],
      'cancelled': true,
    },
    _ => {'kind': kind, 'cancelled': true},
  };
}

/// Category identifiers registered with the OS notification categories.
const kConfirmCategoryId = 'makit_confirm';
const kQuestionCategoryId = 'makit_question';

/// Action identifiers for the actionable notification buttons.
const kApproveActionId = 'makit_approve';
const kDenyActionId = 'makit_deny';
const kReplyActionId = 'makit_reply';

/// The content + category of a notification derived from a `srv.request`.
class RequestNotification {
  const RequestNotification({
    required this.title,
    required this.body,
    required this.category,
  });

  final String title;
  final String body;
  final String category;
}

/// Map a `srv.request` to actionable-notification content, or null when the
/// request kind has no notification affordance (e.g. free-text `input`).
///
/// [label] is the human-readable session/project label (see
/// `NotificationController.labelFor`); we fall back to `body['title']` then a
/// generic string.
RequestNotification? notificationForRequest({
  required String kind,
  required Map<String, dynamic> body,
  required String label,
}) {
  final title = label.isNotEmpty
      ? label
      : (body['title']?.toString() ?? 'Agent');
  switch (kind) {
    case 'confirmAction':
      final action = body['action']?.toString();
      return RequestNotification(
        title: title,
        body: (action != null && action.isNotEmpty)
            ? action
            : 'Agent needs your approval.',
        category: kConfirmCategoryId,
      );
    case 'askUserQuestion':
      final question = _firstQuestion(body);
      return RequestNotification(
        title: title,
        body: question ?? 'Agent has a question.',
        category: kQuestionCategoryId,
      );
    default:
      return null;
  }
}

/// Extract the first question text from either the single or wizard form.
String? _firstQuestion(Map<String, dynamic> body) {
  final questions = body['questions'];
  if (questions is List) {
    for (final q in questions) {
      if (q is Map && q['question'] is String) return q['question'] as String;
    }
  }
  final single = body['question'];
  return single is String ? single : null;
}

/// Map a tapped notification [actionId] to the `srv.response` body, or null
/// when the action is unknown or does not match the request [kind].
///
/// The `kind` field is REQUIRED in the response: server consumers gate on it
/// (`resp.kind === "confirmAction"` / `"askUserQuestion"`), so omitting it
/// makes the response fall through to the cancelled branch and get silently
/// dropped. This mirrors the dialog path, which always sends `kind`.
///
/// contract: `askUserQuestion` consumers read `answers[]` (label text), never
/// indices — a quick reply therefore maps to a single-element `answers`.
Map<String, dynamic>? responseForAction({
  required String kind,
  required String actionId,
  String? input,
}) {
  switch (actionId) {
    case kApproveActionId:
      if (kind != 'confirmAction') return null;
      return SrvResponse.confirmAction(approved: true);
    case kDenyActionId:
      if (kind != 'confirmAction') return null;
      return SrvResponse.confirmAction(approved: false);
    case kReplyActionId:
      if (kind != 'askUserQuestion') return null;
      final text = input ?? '';
      return SrvResponse.askUserQuestion(
        indices: [-1],
        answers: [text],
        answer: text,
      );
    default:
      return null;
  }
}

/// The routing info decoded from a notification payload.
class NotificationPayload {
  const NotificationPayload({this.sessionId, this.requestId, this.kind});

  final String? sessionId;
  final String? requestId;
  final String? kind;
}

/// Encode the routing info for an actionable notification's payload.
String encodeRequestPayload({
  required String sessionId,
  required String requestId,
  required String kind,
}) => jsonEncode({'sid': sessionId, 'rid': requestId, 'kind': kind});

/// Decode a notification payload. Handles three cases:
///   - JSON object → structured [NotificationPayload]
///   - legacy bare sessionId (non-JSON string) → sessionId-only (keeps the
///     status-tap deep-link routing working)
///   - null/empty/garbage → all-null payload
NotificationPayload parseNotificationPayload(String? raw) {
  if (raw == null || raw.isEmpty) return const NotificationPayload();
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return NotificationPayload(
        sessionId: decoded['sid'] as String?,
        requestId: decoded['rid'] as String?,
        kind: decoded['kind'] as String?,
      );
    }
    // Valid JSON but not an object (e.g. a number/list) → not routable.
    return const NotificationPayload();
  } on FormatException {
    // Legacy bare sessionId payload.
    return NotificationPayload(sessionId: raw);
  }
}
