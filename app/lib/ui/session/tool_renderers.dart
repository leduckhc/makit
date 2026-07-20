/// Tool renderer registry.
///
/// Each entry knows how to render a specific tool name (e.g. `read`, `edit`,
/// `askUserQuestion`). Pick a renderer for an item via [rendererFor]; if no
/// match, the caller falls back to [genericToolDetail].
///
/// Every detail view is wrapped in the shared [ToolDetailScaffold] so headers
/// stay consistent: the header shows only the tool's (lowercase) name. Path,
/// command and other arguments live in the body, rendered in the same section
/// style as the output. Tool views use a monospace font since they mostly show
/// arguments, CLI output and file contents.
///
/// The chat transcript renders the collapsed card itself (see `ToolCallCard`),
/// reading only [ToolRenderer.icon] and [toolDisplayName]. Tapping a card opens
/// [ToolRenderer.detail] full-screen. To add support for a new tool, write a
/// [ToolRenderer] subclass and register it in [toolRenderers].
library;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../store/models.dart';
import 'diff_view.dart';
import 'line_diff.dart';
import 'tool_result_text.dart';

// Re-export the pure result-text helpers so existing importers of
// `tool_renderers.dart` keep resolving them after the SPEC-19 split.
export 'tool_result_text.dart' show extractToolResultText, valueString;

/// Monospace font stack for tool views. iOS does not resolve the generic
/// `monospace` family, so we fall back to Menlo (present on all Apple
/// platforms); Android resolves `monospace` directly.
const List<String> kMonoFallback = ['Menlo', 'monospace'];

/// Max width for the readable content column. On wide (desktop) windows the
/// transcript, composer and tool-detail body are centered within this width
/// instead of stretching edge-to-edge (which is hard to read and unbalanced).
const double kReadableContentMaxWidth = 760;

abstract class ToolRenderer {
  const ToolRenderer();

  /// Logical name (matches [ToolCallItem.name]).
  String get name;

  /// Human-facing title shown as the card title and detail-view header.
  /// Defaults to the (lowercase) tool [name] — e.g. `read`, `bash`.
  String get displayName => name;

  /// Material icon shown on the card.
  IconData get icon => PhosphorIconsLight.terminalWindow;

  /// Full-screen detail view. Default: readable args + result text.
  Widget detail(BuildContext context, ToolCallItem item) {
    return genericToolDetail(context, item);
  }
}

/// Generic detail view for tools without a bespoke renderer. Shows arguments
/// as readable label/value rows (never a raw JSON blob) and the result text,
/// wrapped in the same [ToolDetailScaffold] as every other tool.
Widget genericToolDetail(BuildContext context, ToolCallItem item) {
  final args = item.args;
  final text = extractToolResultText(item.resultText);
  final failed = item.ended && (item.exitCode ?? 0) != 0;
  final title = rendererFor(item)?.displayName ?? item.name;
  return ToolDetailScaffold(
    title: title,
    children: [
      if (args.isNotEmpty)
        ToolSection(
          title: 'Arguments',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in args.entries)
                ParamRow(e.key, valueString(e.value)),
            ],
          ),
        ),
      if (text.isNotEmpty)
        ToolSection(
          title: failed ? 'Error' : 'Output',
          child: MonoText(text, error: failed),
        )
      else if (item.ended)
        ToolSection(
          title: failed ? 'Error' : 'Result',
          child: MonoText(item.summary ?? 'exit ${item.exitCode ?? 0}'),
        ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Shared detail-view helpers
// ---------------------------------------------------------------------------

/// Human-facing tool title for [item] — the renderer's [ToolRenderer.displayName]
/// when one is registered, otherwise the raw (lowercase) tool name.
String toolDisplayName(ToolCallItem item) =>
    rendererFor(item)?.displayName ?? item.name;

/// Unified full-screen shell for every tool detail view. The header shows only
/// the tool's [title] (left-aligned) in a monospace font; all arguments and
/// output live in the padded [ListView] body built from [children].
class ToolDetailScaffold extends StatelessWidget {
  const ToolDetailScaffold({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: kMonoFallback,
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kReadableContentMaxWidth),
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: children,
          ),
        ),
      ),
    );
  }
}

/// Titled section used in tool detail pages.
class ToolSection extends StatelessWidget {
  const ToolSection({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontFamily: 'monospace',
              fontFamilyFallback: kMonoFallback,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}

/// Selectable monospace text — used for file content, command output, etc.
class MonoText extends StatelessWidget {
  const MonoText(this.text, {super.key, this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => SelectableText(
    text,
    style: TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: kMonoFallback,
      fontSize: 12.5,
      color: error ? Theme.of(context).colorScheme.error : null,
    ),
  );
}

/// Small label + value row, used to summarise tool parameters.
class ParamRow extends StatelessWidget {
  const ParamRow(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: kMonoFallback,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: kMonoFallback,
                fontSize: 12.5,
              ),
            ),
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
  IconData get icon => PhosphorIconsLight.bookOpen;

  @override
  Widget detail(BuildContext context, ToolCallItem item) {
    final path = item.args['path']?.toString() ?? '(no path)';
    final content = extractToolResultText(item.output ?? item.deltas.join());
    final offset = item.args['offset'];
    final limit = item.args['limit'];
    return ToolDetailScaffold(
      title: displayName,
      children: [
        ToolSection(
          title: 'Arguments',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ParamRow('path', path),
              if (offset != null) ParamRow('offset', '$offset'),
              if (limit != null) ParamRow('limit', '$limit'),
            ],
          ),
        ),
        ToolSection(
          title: 'Content',
          child: MonoText(content.isEmpty ? '(empty)' : content),
        ),
      ],
    );
  }
}

class _WriteRenderer extends ToolRenderer {
  const _WriteRenderer();
  @override
  String get name => 'write';
  @override
  IconData get icon => PhosphorIconsLight.notePencil;

  @override
  Widget detail(BuildContext context, ToolCallItem item) {
    final path = item.args['path']?.toString() ?? '(no path)';
    final content =
        item.args['content']?.toString() ?? item.args['text']?.toString() ?? '';
    final result = extractToolResultText(item.output ?? item.summary ?? '');
    return ToolDetailScaffold(
      title: displayName,
      children: [
        ToolSection(title: 'Arguments', child: ParamRow('path', path)),
        ToolSection(
          title: 'Content written',
          child: MonoText(content.isEmpty ? '(empty)' : content),
        ),
        if (result.isNotEmpty)
          ToolSection(title: 'Result', child: MonoText(result)),
      ],
    );
  }
}

class _EditRenderer extends ToolRenderer {
  const _EditRenderer();
  @override
  String get name => 'edit';
  @override
  IconData get icon => PhosphorIconsLight.gitDiff;

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
  IconData get icon => PhosphorIconsLight.terminalWindow;

  @override
  Widget detail(BuildContext context, ToolCallItem item) {
    final command = item.args['command']?.toString() ?? '';
    final output = extractToolResultText(item.resultText);
    final failed = item.ended && (item.exitCode ?? 0) != 0;
    return ToolDetailScaffold(
      title: displayName,
      children: [
        if (command.isNotEmpty)
          ToolSection(title: 'Command', child: MonoText(command)),
        if (output.isNotEmpty)
          ToolSection(
            title: failed ? 'Error' : 'Output',
            child: MonoText(output, error: failed),
          )
        else if (item.ended)
          ToolSection(
            title: failed ? 'Error' : 'Result',
            child: MonoText(item.summary ?? 'exit ${item.exitCode ?? 0}'),
          ),
      ],
    );
  }
}

class _GrepRenderer extends ToolRenderer {
  const _GrepRenderer();
  @override
  String get name => 'grep';
  @override
  IconData get icon => PhosphorIconsLight.magnifyingGlass;

  @override
  Widget detail(BuildContext context, ToolCallItem item) {
    final pattern = item.args['pattern']?.toString() ?? '';
    final glob = item.args['glob']?.toString();
    final path = item.args['path']?.toString();
    final output = extractToolResultText(item.output ?? item.deltas.join());
    return ToolDetailScaffold(
      title: displayName,
      children: [
        ToolSection(
          title: 'Search',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (pattern.isNotEmpty) ParamRow('pattern', pattern),
              if (glob != null) ParamRow('glob', glob),
              if (path != null) ParamRow('path', path),
            ],
          ),
        ),
        if (output.isNotEmpty)
          ToolSection(title: 'Results', child: MonoText(output))
        else if (item.ended)
          ToolSection(
            title: 'Results',
            child: MonoText(item.summary ?? 'No matches found'),
          ),
      ],
    );
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
];

/// Pick a renderer for [item] by name (case-insensitive so `Read`/`read` and
/// `Edit`/`edit` from different agents match). Returns null if no renderer is
/// registered — caller should fall back to [genericToolDetail].
ToolRenderer? rendererFor(ToolCallItem item) {
  for (final r in toolRenderers) {
    if (r.name == item.name) return r;
  }
  final lower = item.name.toLowerCase();
  for (final r in toolRenderers) {
    if (r.name.toLowerCase() == lower) return r;
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

  /// Read the "before" text from whichever key the agent used. Different
  /// agents name these differently (edit/StrReplace tools commonly use
  /// `old_string`/`new_string`; others `oldText`/`newText` or `old`/`new`).
  static String _pick(Map<String, dynamic> args, List<String> keys) {
    for (final k in keys) {
      final v = args[k];
      if (v != null) return v.toString();
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final path = item.args['path']?.toString();
    final oldText = _pick(item.args, const [
      'oldText',
      'old_string',
      'oldString',
      'old_str',
      'old',
    ]);
    final newText = _pick(item.args, const [
      'newText',
      'new_string',
      'newString',
      'new_str',
      'new',
    ]);
    final lines = computeLineDiff(oldText, newText);
    final hasDiff = oldText.isNotEmpty || newText.isNotEmpty;
    final output = extractToolResultText(item.resultText);

    return ToolDetailScaffold(
      title: 'edit',
      children: [
        if (path != null && path.isNotEmpty)
          ToolSection(title: 'Arguments', child: ParamRow('path', path)),
        if (hasDiff)
          ToolSection(
            title: 'Changes',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final line in lines) DiffLineRow(line: line)],
            ),
          ),
        // The edit tool's result is itself a diff (hashline `+`/`-`/context
        // rows under a `[path#HASH]` header) — render it colour-coded.
        if (output.isNotEmpty)
          ToolSection(title: 'Diff', child: DiffText(output))
        else if (!hasDiff)
          ToolSection(
            title: 'Changes',
            child: Text(
              'No diff details provided by the agent.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
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
  String get displayName => 'Ask the user';
  @override
  IconData get icon => PhosphorIconsLight.question;

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
  Widget detail(BuildContext context, ToolCallItem item) {
    final cs = Theme.of(context).colorScheme;
    final questions = _questions(item);
    return Scaffold(
      appBar: AppBar(centerTitle: false, title: const Text('Ask the user')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: questions.length,
        separatorBuilder: (_, _) => const SizedBox(height: 20),
        itemBuilder: (context, qi) {
          final q = questions[qi];
          final chosen = _chosen(item, qi).toSet();
          final options =
              (q['options'] as List?)
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
            chosen ? PhosphorIconsFill.checkCircle : PhosphorIconsLight.circle,
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
