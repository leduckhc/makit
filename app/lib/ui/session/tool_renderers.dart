/// Tool renderer registry.
///
/// Each entry knows how to render a specific tool name (e.g. `read`, `edit`,
/// `askUserQuestion`). Pick a renderer for an item via [rendererFor]; if no
/// match, the caller falls back to [GenericToolRenderer].
///
/// To add support for a new tool, write a [ToolRenderer] subclass and
/// register it in [toolRenderers]. The card view is shown inline in the chat
/// transcript; tapping it opens [detail] full-screen.
library;

import 'package:flutter/material.dart';

import '../../store/models.dart';

abstract class ToolRenderer {
  const ToolRenderer();

  /// Logical name (matches [ToolCallItem.name]).
  String get name;

  /// One-line description for the card header.
  String? subtitle(ToolCallItem item) => null;

  /// Material icon shown on the card.
  IconData get icon => Icons.terminal;

  /// Whether this renderer should display approve/deny / input controls
  /// inline (otherwise the user just taps through to [detail]).
  bool get inlineInteractive => false;

  /// Inline card. Default: generic title + subtitle. Override for richer
  /// inline UIs (e.g. AskUserQuestion options).
  Widget card(BuildContext context, ToolCallItem item, VoidCallback onTap) {
    return _DefaultCard(renderer: this, item: item, onTap: onTap);
  }

  /// Full-screen detail view. Default: dump args + deltas.
  Widget detail(BuildContext context, ToolCallItem item) {
    return _DefaultDetail(renderer: this, item: item);
  }
}

class _DefaultCard extends StatelessWidget {
  const _DefaultCard({
    required this.renderer,
    required this.item,
    required this.onTap,
  });
  final ToolRenderer renderer;
  final ToolCallItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sub = renderer.subtitle(item);
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Icon(renderer.icon, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      renderer.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (sub != null && sub.isNotEmpty)
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              if (!item.ended)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (item.exitCode != null && item.exitCode != 0)
                Icon(Icons.error_outline, size: 18, color: cs.error),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _DefaultDetail extends StatelessWidget {
  const _DefaultDetail({required this.renderer, required this.item});
  final ToolRenderer renderer;
  final ToolCallItem item;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(renderer.name)),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
            'Arguments',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          SelectableText(
            item.args.toString(),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(height: 16),
          const Text('Output', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Builder(
            builder: (context) {
              // Streaming tools (e.g. bash) accumulate deltas; one-shot tools
              // (read, grep, …) carry the full text in output.
              final text = item.deltas.isNotEmpty
                  ? item.deltas.join()
                  : (item.output ?? '');
              final failed = item.ended && (item.exitCode ?? 0) != 0;
              return SelectableText(
                text.isEmpty ? '(no output)' : text,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: failed ? Theme.of(context).colorScheme.error : null,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Built-in renderers
// ---------------------------------------------------------------------------

class _ReadRenderer extends ToolRenderer {
  const _ReadRenderer();
  @override
  String get name => 'read';
  @override
  IconData get icon => Icons.menu_book_outlined;
  @override
  String? subtitle(ToolCallItem item) => item.args['path']?.toString();
}

class _WriteRenderer extends ToolRenderer {
  const _WriteRenderer();
  @override
  String get name => 'write';
  @override
  IconData get icon => Icons.edit_note_outlined;
  @override
  String? subtitle(ToolCallItem item) => item.args['path']?.toString();
}

class _EditRenderer extends ToolRenderer {
  const _EditRenderer();
  @override
  String get name => 'edit';
  @override
  IconData get icon => Icons.difference_outlined;
  @override
  String? subtitle(ToolCallItem item) => item.args['path']?.toString();

  @override
  Widget detail(BuildContext context, ToolCallItem item) {
    return _EditDiffView(item: item);
  }
}

class _BashRenderer extends ToolRenderer {
  const _BashRenderer();
  @override
  String get name => 'bash';
  @override
  IconData get icon => Icons.attach_money;
  @override
  String? subtitle(ToolCallItem item) {
    final cmd = item.args['command']?.toString();
    if (cmd == null) return null;
    return cmd.length > 80 ? '${cmd.substring(0, 80)}…' : cmd;
  }
}

class _GrepRenderer extends ToolRenderer {
  const _GrepRenderer();
  @override
  String get name => 'grep';
  @override
  IconData get icon => Icons.search;
  @override
  String? subtitle(ToolCallItem item) {
    final p = item.args['pattern']?.toString();
    final g = item.args['glob']?.toString();
    return [p, if (g != null) 'glob:$g'].whereType<String>().join(' · ');
  }
}

/// Registry. Order does not matter — first matching name wins.
const List<ToolRenderer> toolRenderers = [
  _ReadRenderer(),
  _WriteRenderer(),
  _EditRenderer(),
  _BashRenderer(),
  _GrepRenderer(),
  _AskUserQuestionRenderer('askUserQuestion'),
  _AskUserQuestionRenderer('AskUserQuestion'),
];

/// Pick a renderer for [item] by exact name match. Returns null if no renderer
/// is registered — caller should fall back to a generic card.
ToolRenderer? rendererFor(ToolCallItem item) {
  for (final r in toolRenderers) {
    if (r.name == item.name) return r;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Edit diff viewer — extracted because it's noticeably bigger than the
// generic detail page.
// ---------------------------------------------------------------------------

class _EditDiffView extends StatelessWidget {
  const _EditDiffView({required this.item});
  final ToolCallItem item;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final path = item.args['path']?.toString() ?? '(no path)';
    final oldText =
        item.args['oldText']?.toString() ?? item.args['old']?.toString() ?? '';
    final newText =
        item.args['newText']?.toString() ?? item.args['new']?.toString() ?? '';

    return Scaffold(
      appBar: AppBar(title: Text(path, overflow: TextOverflow.ellipsis)),
      body: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          Container(
            decoration: BoxDecoration(
              color: cs.errorContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '− Removed',
                  style: TextStyle(
                    color: cs.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  oldText,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '+ Added',
                  style: TextStyle(
                    color: Colors.green,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  newText,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
            ),
          ),
          if (item.deltas.isNotEmpty || (item.output?.isNotEmpty ?? false)) ...[
            const SizedBox(height: 16),
            const Text('Output', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            SelectableText(
              item.deltas.isNotEmpty ? item.deltas.join() : item.output!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// AskUserQuestion — renders each question with its chosen answer highlighted,
// instead of the raw "Q:/A:" text + args JSON. Uses the structured `details`
// ({indices, answers}) forwarded from the tool result when available.
// ---------------------------------------------------------------------------

class _AskUserQuestionRenderer extends ToolRenderer {
  const _AskUserQuestionRenderer(this._name);
  final String _name;
  @override
  String get name => _name;
  @override
  IconData get icon => Icons.quiz_outlined;

  List<Map<String, dynamic>> _questions(ToolCallItem item) {
    final raw = item.args['questions'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(Map<String, dynamic>.from)
        .toList();
  }

  /// Chosen answer labels for question [i]. Multi-select answers arrive joined
  /// with " + " (see the wizard), so split them back out.
  List<String> _chosen(ToolCallItem item, int i) {
    final answers = (item.details?['answers'] as List?)?.cast<dynamic>();
    if (answers == null || i >= answers.length) return const [];
    return answers[i].toString().split(' + ').map((s) => s.trim()).toList();
  }

  @override
  String? subtitle(ToolCallItem item) {
    final answers = (item.details?['answers'] as List?)?.cast<dynamic>();
    if (answers != null && answers.isNotEmpty) {
      return answers.map((a) => a.toString()).join(' · ');
    }
    final qs = _questions(item);
    return qs.isEmpty ? null : qs.first['question']?.toString();
  }

  @override
  Widget detail(BuildContext context, ToolCallItem item) {
    final cs = Theme.of(context).colorScheme;
    final questions = _questions(item);
    return Scaffold(
      appBar: AppBar(title: const Text('Ask the user')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: questions.length,
        separatorBuilder: (_, _) => const SizedBox(height: 20),
        itemBuilder: (context, qi) {
          final q = questions[qi];
          final chosen = _chosen(item, qi).toSet();
          final options = (q['options'] as List?)
                  ?.whereType<Map<dynamic, dynamic>>()
                  .map(Map<String, dynamic>.from)
                  .toList() ??
              const [];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (q['header'] != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    q['header'].toString().toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: cs.primary,
                          letterSpacing: 0.5,
                        ),
                  ),
                ),
              Text(
                q['question']?.toString() ?? '',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              for (final opt in options)
                _AnswerOption(
                  label: opt['label']?.toString() ?? '',
                  description: opt['description']?.toString(),
                  chosen: chosen.contains(opt['label']?.toString()),
                ),
              // Free-text / "Other" answers won't match an option — show them too.
              for (final ans in chosen)
                if (!options.any((o) => o['label']?.toString() == ans))
                  _AnswerOption(label: ans, description: null, chosen: true),
            ],
          );
        },
      ),
    );
  }
}

class _AnswerOption extends StatelessWidget {
  const _AnswerOption({
    required this.label,
    required this.chosen,
    this.description,
  });
  final String label;
  final String? description;
  final bool chosen;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: chosen ? cs.primaryContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: chosen ? Border.all(color: cs.primary) : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            chosen ? Icons.check_circle : Icons.circle_outlined,
            size: 18,
            color: chosen ? cs.primary : cs.outline,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: chosen ? FontWeight.w700 : FontWeight.w500,
                  ),
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
    );
  }
}
