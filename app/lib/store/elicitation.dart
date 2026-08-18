/// Live `askUserQuestion` elicitations, surfaced **inline** in the transcript
/// (SPEC-ask-user-inline-in-chat) instead of the modal `AskWizard`.
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
    this.viaInputText = false,
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

  /// When true, this ask actually arrived as pi-ask-user's multi-select
  /// `ctx.ui.input` fallback (options embedded in the prompt text), so the
  /// answer must go back on the `input` channel as a comma-separated string
  /// rather than the `askUserQuestion` `{indices, answers}` shape.
  final bool viaInputText;

  bool get isSingle => questions.length == 1;

  PendingAsk copyWith({bool? freeText}) => PendingAsk(
    requestId: requestId,
    sessionId: sessionId,
    questions: questions,
    freeText: freeText ?? this.freeText,
    viaInputText: viaInputText,
  );

  /// pi-ask-user's headless multi-select fallback calls `ctx.ui.input` with the
  /// options rendered into the prompt as `"…\n\nOptions (select one or more):\n
  /// 1. Title — desc\n2. …"`, expecting a comma-separated reply. Parse that back
  /// into a structured multi-select ask, or return null when [title] isn't that
  /// shape (an ordinary free-text input).
  static PendingAsk? fromMultiSelectInput({
    required String requestId,
    required String sessionId,
    required String title,
  }) {
    const marker = '\n\nOptions (select one or more):\n';
    final idx = title.indexOf(marker);
    if (idx < 0) return null;
    final prompt = title.substring(0, idx);
    final optionList = title.substring(idx + marker.length);

    var question = prompt;
    String? context;
    const cmarker = '\n\nContext:\n';
    final ci = prompt.indexOf(cmarker);
    if (ci >= 0) {
      question = prompt.substring(0, ci);
      context = prompt.substring(ci + cmarker.length).trim();
    }

    final options = <Map<String, dynamic>>[];
    for (final line in optionList.split('\n')) {
      final m = RegExp(r'^\s*\d+\.\s+(.*)$').firstMatch(line);
      if (m == null) continue;
      final rest = m.group(1)!;
      final dash = rest.indexOf(
        ' \u2014 ',
      ); // " — " separates title/description
      if (dash >= 0) {
        options.add({
          'label': rest.substring(0, dash).trim(),
          'description': rest.substring(dash + 3).trim(),
        });
      } else {
        options.add({'label': rest.trim()});
      }
    }
    if (options.isEmpty) return null;

    return PendingAsk(
      requestId: requestId,
      sessionId: sessionId,
      viaInputText: true,
      questions: [
        {
          'question': question.trim(),
          if (context != null && context.isNotEmpty) 'context': context,
          'multi': true,
          'options': options,
        },
      ],
    );
  }
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

  /// Register a new inline ask (called by the dispatcher). If the session
  /// already had a (different) pending ask, drop its stale request→session
  /// mapping first so it can't leak — one ask per session at a time.
  void add(PendingAsk ask) {
    final prev = state[ask.sessionId];
    if (prev != null && prev.requestId != ask.requestId) {
      _sessionByRequest.remove(prev.requestId);
    }
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

  /// Send the response and clear the card. Multi-select-over-input asks answer
  /// on the `input` channel (comma-separated titles); everything else uses the
  /// canonical `askUserQuestion` `{indices, answers}` shape.
  void submit(
    String requestId, {
    required List<int> indices,
    required List<String> answers,
  }) {
    final ask = _askFor(requestId);
    if (ask != null && ask.viaInputText) {
      final value = answers
          .expand((a) => a.split(' + '))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .join(', ');
      _respond(requestId, SrvResponse.input(value));
    } else {
      _respond(
        requestId,
        SrvResponse.askUserQuestion(
          indices: indices,
          answers: answers,
          answer: answers.length == 1 ? answers.first : null,
        ),
      );
    }
    _remove(requestId);
  }

  PendingAsk? _askFor(String requestId) {
    final sessionId = _sessionByRequest[requestId];
    return sessionId == null ? null : state[sessionId];
  }

  /// Answer with a single free-text string (single-question asks).
  void submitFreeText(String requestId, String text) =>
      submit(requestId, indices: const [-1], answers: [text]);

  /// Cancel the ask (canonical cancelled shape) and clear the card.
  void cancel(String requestId) {
    final ask = _askFor(requestId);
    _respond(
      requestId,
      SrvResponse.cancelled(
        ask?.viaInputText == true ? 'input' : 'askUserQuestion',
      ),
    );
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
