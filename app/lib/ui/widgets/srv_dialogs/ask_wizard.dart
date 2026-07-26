/// AskUserQuestion wizard dialog + option tile. Extracted from
/// `srv_request_handler.dart` (SPEC-19). Pure move — no behaviour change.
library;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../app/theme.dart';

/// A multi-question wizard. One question per page; Next/Submit advances.
/// Returns a canonical `{indices, answers}` map (see AskUserQuestionResponse
/// in uicall.ts), or null when cancelled.
class AskWizard extends StatefulWidget {
  const AskWizard({super.key, required this.questions});
  final List<Map<String, dynamic>> questions;

  @override
  State<AskWizard> createState() => _AskWizardState();
}

class _AskWizardState extends State<AskWizard> {
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
              const SizedBox(height: kSpace12),
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
        borderRadius: BorderRadius.circular(kRadius8),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadius8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(kSpace10),
            child: Row(
              children: [
                Icon(
                  selected
                      ? PhosphorIconsLight.checkSquare
                      : PhosphorIconsLight.square,
                  size: 18,
                  color: selected ? cs.primary : cs.outline,
                ),
                const SizedBox(width: kSpace8),
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
                            const SizedBox(width: kSpace6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: kSpace6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: cs.tertiary.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(kRadius6),
                              ),
                              child: Text(
                                'Recommended',
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: cs.tertiary),
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
    AskWizard(questions: questions);
