/// Inline `askUserQuestion` card (SPEC-25) — rendered as a trailing transcript
/// row instead of the modal `AskWizard`. Single/multi-select, a multi-question
/// stepper, and a "type a different answer" affordance that hands off to the
/// composer (single-question only). Submits the canonical `{indices, answers}`
/// via [ElicitationController].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../store/elicitation.dart';
import 'chat_metrics.dart';

class AskCard extends ConsumerStatefulWidget {
  const AskCard({super.key, required this.ask});
  final PendingAsk ask;

  @override
  ConsumerState<AskCard> createState() => _AskCardState();
}

class _AskCardState extends ConsumerState<AskCard> {
  int _i = 0;
  late List<Set<int>> _picks = List.generate(
    widget.ask.questions.length,
    (_) => <int>{},
  );

  @override
  void didUpdateWidget(AskCard old) {
    super.didUpdateWidget(old);
    // A different request reused this element (rare) — reset local picks.
    if (old.ask.requestId != widget.ask.requestId) {
      _i = 0;
      _picks = List.generate(widget.ask.questions.length, (_) => <int>{});
    }
  }

  Map<String, dynamic> get _q => widget.ask.questions[_i];
  bool get _multi => _q['multi'] == true;
  bool get _isLast => _i == widget.ask.questions.length - 1;
  bool get _canAdvance => _picks[_i].isNotEmpty;

  List<Map<String, dynamic>> _options() {
    final raw = _q['options'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(Map<String, dynamic>.from)
        .toList();
  }

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
    if (!_isLast) {
      setState(() => _i++);
      return;
    }
    // Canonical shape (mirrors AskWizard._next / AskUserQuestionResponse):
    // indices = first-picked index per question; answers = label per question,
    // multi-select joined with " + ".
    final indices = <int>[];
    final answers = <String>[];
    for (var qi = 0; qi < widget.ask.questions.length; qi++) {
      final opts =
          (widget.ask.questions[qi]['options'] as List?)
              ?.whereType<Map<dynamic, dynamic>>()
              .map(Map<String, dynamic>.from)
              .toList() ??
          const [];
      final picked = _picks[qi].toList()..sort();
      indices.add(picked.isEmpty ? -1 : picked.first);
      answers.add(
        picked.map((i) => opts[i]['label']?.toString() ?? '').join(' + '),
      );
    }
    ref
        .read(elicitationControllerProvider.notifier)
        .submit(widget.ask.requestId, indices: indices, answers: answers);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ask = widget.ask;
    final header = _q['header']?.toString();
    final question = _q['question']?.toString() ?? '?';
    final recommended = (_q['recommended'] as num?)?.toInt();
    final opts = _options();
    final total = ask.questions.length;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border.all(color: cs.primary.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(kChatRadiusMedium),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(PhosphorIconsLight.question, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  (header ?? 'Question').toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: cs.primary,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (total > 1)
                Text(
                  '${_i + 1} / $total',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            question,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          if (ask.freeText)
            _FreeTextNote(cs: cs)
          else ...[
            for (var i = 0; i < opts.length; i++)
              _AskOption(
                label: opts[i]['label']?.toString() ?? '?',
                description: opts[i]['description']?.toString(),
                recommended: recommended == i,
                selected: _picks[_i].contains(i),
                multi: _multi,
                onTap: () => _toggle(i),
              ),
            const SizedBox(height: 4),
            _actions(cs),
          ],
        ],
      ),
    );
  }

  Widget _actions(ColorScheme cs) {
    final ask = widget.ask;
    return Row(
      children: [
        if (_i > 0)
          TextButton(
            onPressed: () => setState(() => _i--),
            child: const Text('Back'),
          ),
        // Free-text handoff — single-question asks only (composer answers it).
        if (ask.isSingle)
          TextButton(
            onPressed: () => ref
                .read(elicitationControllerProvider.notifier)
                .enableFreeText(ask.requestId),
            child: const Text('Type a different answer'),
          ),
        const Spacer(),
        FilledButton(
          onPressed: _canAdvance ? _next : null,
          child: Text(_isLast ? 'Submit' : 'Next'),
        ),
      ],
    );
  }
}

/// Shown after "type a different answer" — points the user at the composer.
class _FreeTextNote extends StatelessWidget {
  const _FreeTextNote({required this.cs});
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(PhosphorIconsLight.pencilSimple, size: 15, color: cs.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Type your answer in the message box below.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _AskOption extends StatelessWidget {
  const _AskOption({
    required this.label,
    required this.selected,
    required this.multi,
    required this.onTap,
    this.description,
    this.recommended = false,
  });

  final String label;
  final String? description;
  final bool recommended;
  final bool selected;
  final bool multi;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final box = selected
        ? (multi ? PhosphorIconsFill.checkSquare : PhosphorIconsFill.circle)
        : (multi ? PhosphorIconsLight.square : PhosphorIconsLight.circle);
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Material(
        color: selected ? cs.primaryContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: selected ? cs.primary : Colors.transparent,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(box, size: 18, color: selected ? cs.primary : cs.outline),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              label,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13.5,
                              ),
                            ),
                          ),
                          if (recommended) ...[
                            const SizedBox(width: 7),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: cs.tertiary.withValues(alpha: 0.18),
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
