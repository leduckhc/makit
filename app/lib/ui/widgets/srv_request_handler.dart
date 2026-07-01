/// Listens for `srv.request` envelopes from the server and presents the
/// appropriate UI (currently: AskUserQuestion dialog). Mount once at app
/// root so any screen sees the dialog.
///
/// We render against the router's Navigator (`pinoNavigatorKey`) rather
/// than our own `BuildContext`, because this widget sits in
/// `MaterialApp.builder` — above the Navigator created by GoRouter.
library;

import 'dart:async';

// `visibleForTesting` is re-exported by Flutter material.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../store/connection.dart';
import '../../transport/protocol.dart';

class SrvRequestHandler extends ConsumerStatefulWidget {
  const SrvRequestHandler({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<SrvRequestHandler> createState() => _SrvRequestHandlerState();
}

class _SrvRequestHandlerState extends ConsumerState<SrvRequestHandler> {
  StreamSubscription<Envelope>? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _subscribe());
  }

  void _subscribe() {
    _sub?.cancel();
    _sub = ref
        .read(connectionControllerProvider.notifier)
        .srvRequests
        .listen(_dispatch);
  }

  Future<void> _dispatch(Envelope env) async {
    // Use the router's Navigator, not this widget's context — we're above it.
    final navCtx = pinoNavigatorKey.currentContext;
    if (navCtx == null) return;

    final kind = env.body['kind'] as String? ?? 'unknown';

    // Normalise: pi's "askUserQuestion" tool can arrive as either
    //   { question, options, multi?, recommended? }                 (single)
    //   { questions: [{header, question, options, multi?, ...}] }   (wizard)
    // We support both — the wizard form is what the Anthropic-standard
    // schema uses and what pi's LLM training expects.
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
      await _showAskUserQuestion(navCtx, env.id, questions);
      return;
    }

    if (kind == 'confirmAction') {
      await _showConfirmAction(navCtx, env.id, env.body);
      return;
    }

    if (kind == 'input') {
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

  Future<void> _showAskUserQuestion(
    BuildContext ctx,
    String requestId,
    List<Map<String, dynamic>> questions,
  ) async {
    final result = await showDialog<Map<String, dynamic>?>(
      context: ctx,
      barrierDismissible: false,
      builder: (dctx) => _AskWizard(questions: questions),
    );

    if (result == null) {
      // User cancelled — still send a canonical-shaped response so the
      // connector can dispatch back to the agent cleanly.
      _respond(requestId, {
        'kind': 'askUserQuestion',
        'indices': <int>[],
        'answers': <String>[],
        'cancelled': true,
      });
      return;
    }
    // result is already canonical {indices, answers}; just add kind +
    // a convenience `answer` for the single-question form.
    final body = <String, dynamic>{
      'kind': 'askUserQuestion',
      'indices': result['indices'],
      'answers': result['answers'],
    };
    if (questions.length == 1) {
      final answers = result['answers'] as List;
      if (answers.isNotEmpty) body['answer'] = answers.first;
    }
    _respond(requestId, body);
  }

  Future<void> _showConfirmAction(
    BuildContext ctx,
    String requestId,
    Map<String, dynamic> body,
  ) async {
    final approved = await showDialog<bool>(
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
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(dctx).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  body['preview'].toString(),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
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
    _respond(requestId, {
      'kind': 'confirmAction',
      'approved': approved ?? false,
    });
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
    final value = await showDialog<String?>(
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
      _respond(requestId, {'kind': 'input', 'cancelled': true});
    } else {
      _respond(requestId, {'kind': 'input', 'value': value});
    }
  }

  Future<void> _showGeneric(BuildContext ctx, Envelope env) async {
    final controller = TextEditingController();
    final text = await showDialog<String?>(
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
            const SizedBox(height: 12),
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

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A multi-question wizard. One question per page; Next/Submit advances.
/// Returns a list of answers (each answer is either a `String` for
/// single-select or a `List<String>` for multi-select).
class _AskWizard extends StatefulWidget {
  const _AskWizard({required this.questions});
  final List<Map<String, dynamic>> questions;

  @override
  State<_AskWizard> createState() => _AskWizardState();
}

class _AskWizardState extends State<_AskWizard> {
  int _i = 0;
  late final List<Set<int>> _picks = List.generate(
    widget.questions.length,
    (_) => <int>{},
  );

  Map<String, dynamic> get _q => widget.questions[_i];

  List<Map<String, dynamic>> _options() {
    final raw = _q['options'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(Map<String, dynamic>.from)
        .toList();
  }

  bool get _multi => _q['multi'] == true;

  bool get _isLast => _i == widget.questions.length - 1;

  bool get _canAdvance => _picks[_i].isNotEmpty;

  void _toggle(int idx) {
    setState(() {
      if (_multi) {
        _picks[_i].contains(idx) ? _picks[_i].remove(idx) : _picks[_i].add(idx);
      } else {
        _picks[_i]
          ..clear()
          ..add(idx);
      }
    });
  }

  void _next() {
    if (_isLast) {
      // Canonical shape (mirrors AskUserQuestionResponse in uicall.ts):
      //   indices: int[]  — first-picked index per question
      //   answers: string[] — label per question; multi-select joined with " + "
      final indices = <int>[];
      final answers = <String>[];
      for (var qi = 0; qi < widget.questions.length; qi++) {
        final opts =
            (widget.questions[qi]['options'] as List?)
                ?.whereType<Map<dynamic, dynamic>>()
                .map(Map<String, dynamic>.from)
                .toList() ??
            const [];
        final pickedSorted = _picks[qi].toList()..sort();
        final labels = pickedSorted
            .map((i) => opts[i]['label']?.toString() ?? '')
            .toList();
        indices.add(pickedSorted.isEmpty ? -1 : pickedSorted.first);
        answers.add(labels.join(' + '));
      }
      Navigator.of(context).pop({'indices': indices, 'answers': answers});
      return;
    }
    setState(() => _i++);
  }

  void _back() {
    if (_i == 0) return;
    setState(() => _i--);
  }

  @override
  Widget build(BuildContext context) {
    final header = _q['header']?.toString();
    final question = _q['question']?.toString() ?? '?';
    final recommended = (_q['recommended'] as num?)?.toInt();
    final opts = _options();

    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(header ?? 'Question')),
          if (widget.questions.length > 1)
            Text(
              '${_i + 1}/${widget.questions.length}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(question),
              const SizedBox(height: 12),
              for (var i = 0; i < opts.length; i++)
                _OptionTile(
                  label: opts[i]['label']?.toString() ?? '?',
                  description: opts[i]['description']?.toString(),
                  recommended: recommended == i,
                  selected: _picks[_i].contains(i),
                  onTap: () => _toggle(i),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (_i > 0) TextButton(onPressed: _back, child: const Text('Back')),
        FilledButton(
          onPressed: _canAdvance ? _next : null,
          child: Text(_isLast ? 'Submit' : 'Next'),
        ),
      ],
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.description,
    this.recommended = false,
  });

  final String label;
  final String? description;
  final bool recommended;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? cs.primaryContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 18,
                  color: selected ? cs.primary : cs.outline,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            label,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (recommended) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: cs.tertiary.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'Recommended',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: cs.tertiary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (description != null && description!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            description!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Test-only entrypoint to render the wizard with a given question list.
/// Use in widget tests via `showDialog(builder: (_) => debugAskWizardFor(qs))`.
@visibleForTesting
Widget debugAskWizardFor(List<Map<String, dynamic>> questions) =>
    _AskWizard(questions: questions);
