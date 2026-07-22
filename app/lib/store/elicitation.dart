/// Live `askUserQuestion` elicitations, surfaced **inline** in the transcript
/// (SPEC-25) instead of the modal `AskWizard`.
///
/// This is passive per-session state: [SrvRequestHandler] remains the single
/// `srv.request` socket subscriber and pushes a [PendingAsk] here via [add];
/// the transcript renders it as a trailing row and answers it via [submit].
/// The controller also listens to the connection's `responded` stream so an
/// answer sent from anywhere else (e.g. an actionable notification) clears the
/// inline card in sync.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../notifications/notification_request.dart';
import 'connection.dart';

/// A pending inline question awaiting the user's answer.
class PendingAsk {
  const PendingAsk({
    required this.requestId,
    required this.sessionId,
    required this.questions,
    this.freeText = false,
  });

  /// The `srv.request` envelope id — used as the response correlation id.
  final String requestId;
  final String sessionId;

  /// Normalised wizard form: one `{header?, question, options, multi?,
  /// recommended?}` map per question.
  final List<Map<String, dynamic>> questions;

  /// True once the user chose "type a different answer" — the composer is
  /// re-enabled and its next submit answers this ask (single-question only).
  final bool freeText;

  bool get isSingle => questions.length == 1;

  PendingAsk copyWith({bool? freeText}) => PendingAsk(
    requestId: requestId,
    sessionId: sessionId,
    questions: questions,
    freeText: freeText ?? this.freeText,
  );
}

/// Holds at most one [PendingAsk] per session (the agent asks one at a time).
class ElicitationController extends StateNotifier<Map<String, PendingAsk>> {
  ElicitationController({
    required void Function(String requestId, Map<String, dynamic> body) respond,
    required Stream<String> responded,
  }) : _respond = respond,
       super(const {}) {
    _sub = responded.listen(_onResponded);
  }

  final void Function(String requestId, Map<String, dynamic> body) _respond;
  late final StreamSubscription<String> _sub;

  /// requestId → sessionId, so a `responded` event (which only carries the
  /// requestId) can find and clear the right session's card.
  final Map<String, String> _sessionByRequest = {};

  /// Register a new inline ask (called by the dispatcher).
  void add(PendingAsk ask) {
    _sessionByRequest[ask.requestId] = ask.sessionId;
    state = {...state, ask.sessionId: ask};
  }

  /// Switch the ask into free-text mode (composer answers it). No-op if the
  /// request is gone or is multi-question.
  void enableFreeText(String requestId) {
    final sessionId = _sessionByRequest[requestId];
    final ask = sessionId == null ? null : state[sessionId];
    if (ask == null || ask.requestId != requestId || !ask.isSingle) return;
    state = {...state, sessionId!: ask.copyWith(freeText: true)};
  }

  /// Send the canonical `{indices, answers}` response and clear the card.
  void submit(
    String requestId, {
    required List<int> indices,
    required List<String> answers,
  }) {
    _respond(
      requestId,
      SrvResponse.askUserQuestion(
        indices: indices,
        answers: answers,
        answer: answers.length == 1 ? answers.first : null,
      ),
    );
    _remove(requestId);
  }

  /// Answer with a single free-text string (single-question asks).
  void submitFreeText(String requestId, String text) =>
      submit(requestId, indices: const [-1], answers: [text]);

  /// Cancel the ask (canonical cancelled shape) and clear the card.
  void cancel(String requestId) {
    _respond(requestId, SrvResponse.cancelled('askUserQuestion'));
    _remove(requestId);
  }

  void _onResponded(String requestId) => _remove(requestId);

  void _remove(String requestId) {
    final sessionId = _sessionByRequest.remove(requestId);
    if (sessionId == null) return;
    if (state[sessionId]?.requestId != requestId) return;
    state = {...state}..remove(sessionId);
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final elicitationControllerProvider =
    StateNotifierProvider<ElicitationController, Map<String, PendingAsk>>((
      ref,
    ) {
      final conn = ref.watch(connectionControllerProvider.notifier);
      return ElicitationController(
        respond: conn.respondTo,
        responded: conn.responded,
      );
    });

/// The pending inline ask for [sessionId], or null when none is awaiting.
final pendingAskProvider = Provider.family<PendingAsk?, String>(
  (ref, sessionId) => ref.watch(elicitationControllerProvider)[sessionId],
);
