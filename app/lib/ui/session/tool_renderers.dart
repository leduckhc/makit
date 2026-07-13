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
/// To add support for a new tool, write a [ToolRenderer] subclass and
/// register it in [toolRenderers]. The card view is shown inline in the chat
/// transcript; tapping it opens [detail] full-screen.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../store/models.dart';
import 'line_diff.dart';

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

  /// One-line description for the card subtitle.
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

  /// Full-screen detail view. Default: readable args + result text.
  Widget detail(BuildContext context, ToolCallItem item) {
    return genericToolDetail(context, item);
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
                      renderer.displayName,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontFamilyFallback: kMonoFallback,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (sub != null && sub.isNotEmpty)
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          fontFamilyFallback: kMonoFallback,
                        ),
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

/// Generic detail view for tools without a bespoke renderer. Shows arguments
/// as readable label/value rows (never a raw JSON blob) and the result text,
/// wrapped in the same [ToolDetailScaffold] as every other tool.
Widget genericToolDetail(BuildContext context, ToolCallItem item) {
  final args = item.args;
  final text = extractToolResultText(
    item.deltas.isNotEmpty ? item.deltas.join() : (item.output ?? ''),
  );
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
                ParamRow(e.key, _valueString(e.value)),
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

/// Render a single arg value for display. Scalars show as-is; nested
/// structures fall back to compact JSON so the row stays readable.
String _valueString(dynamic value) {
  if (value == null) return '';
  if (value is String || value is num || value is bool) return value.toString();
  try {
    return jsonEncode(value);
  } catch (_) {
    return value.toString();
  }
}

/// Tool results arrive as one or more concatenated MCP-style envelopes, e.g.
/// `{"content":[{"type":"text","text":"..."}],"details":{}}`. Extract and
/// concatenate the human-readable text. Falls back to the raw string when it
/// isn't in that shape (plain stdout, file contents, etc.).
String extractToolResultText(String raw) {
  final trimmed = raw.trim();
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return raw;
  final buf = StringBuffer();
  var matched = false;
  for (final chunk in _splitJsonValues(trimmed)) {
    dynamic decoded;
    try {
      decoded = jsonDecode(chunk);
    } catch (_) {
      return raw; // Not the envelope shape — show it verbatim.
    }
    if (decoded is Map && decoded['content'] is List) {
      matched = true;
      for (final part in decoded['content'] as List) {
        if (part is Map && part['type'] == 'text' && part['text'] is String) {
          buf.write(part['text'] as String);
        }
      }
    }
  }
  return matched ? buf.toString() : raw;
}

/// Split a string of back-to-back top-level JSON values (e.g. `{...}{...}`)
/// into their individual source substrings, honouring braces/brackets inside
/// strings and escapes.
List<String> _splitJsonValues(String s) {
  final out = <String>[];
  var depth = 0;
  var start = -1;
  var inString = false;
  var escaped = false;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    switch (ch) {
      case '"':
        inString = true;
      case '{':
      case '[':
        if (depth == 0) start = i;
        depth++;
      case '}':
      case ']':
        depth--;
        if (depth == 0 && start >= 0) {
          out.add(s.substring(start, i + 1));
          start = -1;
        }
    }
  }
  return out;
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
  IconData get icon => Icons.menu_book_outlined;
  @override
  String? subtitle(ToolCallItem item) => item.args['path']?.toString();

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
  IconData get icon => Icons.edit_note_outlined;
  @override
  String? subtitle(ToolCallItem item) => item.args['path']?.toString();

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
  IconData get icon => Icons.terminal;
  @override
  String? subtitle(ToolCallItem item) {
    final cmd = item.args['command']?.toString();
    if (cmd == null) return null;
    return cmd.length > 80 ? '${cmd.substring(0, 80)}…' : cmd;
  }

  @override
  Widget detail(BuildContext context, ToolCallItem item) {
    final command = item.args['command']?.toString() ?? '';
    final output = extractToolResultText(
      item.deltas.isNotEmpty ? item.deltas.join() : (item.output ?? ''),
    );
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
  IconData get icon => Icons.search;
  @override
  String? subtitle(ToolCallItem item) {
    final p = item.args['pattern']?.toString();
    final g = item.args['glob']?.toString();
    return [p, if (g != null) 'glob:$g'].whereType<String>().join(' · ');
  }

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
  _AskUserQuestionRenderer('AskUserQuestion'),
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
    final output = extractToolResultText(
      item.deltas.isNotEmpty ? item.deltas.join() : (item.output ?? ''),
    );

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
              children: [for (final line in lines) _DiffLineRow(line: line)],
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

/// One diff line: a coloured full-width row with a gutter prefix. Removed lines
/// use the error container, added lines a green wash, context stays muted.
class _DiffLineRow extends StatelessWidget {
  const _DiffLineRow({required this.line});
  final DiffLine line;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Lighter green text in dark mode so it clears 4.5:1 on the faint wash.
    final addedText = dark ? Colors.green.shade300 : Colors.green.shade800;
    final (
      Color? background,
      Color textColor,
      String prefix,
    ) = switch (line.kind) {
      DiffKind.removed => (
        cs.errorContainer.withValues(alpha: 0.35),
        cs.error,
        '\u2212',
      ),
      DiffKind.added => (Colors.green.withValues(alpha: 0.15), addedText, '+'),
      DiffKind.context => (null, cs.onSurfaceVariant, ' '),
    };
    final style = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: kMonoFallback,
      fontSize: 12,
      color: textColor,
    );
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 14, child: Text(prefix, style: style)),
          Expanded(child: SelectableText(line.text, style: style)),
        ],
      ),
    );
  }
}

/// Renders diff text that already carries its own gutter markers — the `edit`
/// tool's hashline result: a `[path#HASH]` header followed by `+`/`-`/context
/// rows (`+316:…`, `-136:…`, ` 139:…`). Each line gets a full-width colour wash
/// (green added, red removed, muted context, highlighted header) like a git
/// diff. Line numbers stay visible.
class DiffText extends StatelessWidget {
  const DiffText(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final line in lines) _DiffTextLine(line: line)],
    );
  }
}

class _DiffTextLine extends StatelessWidget {
  const _DiffTextLine({required this.line});
  final String line;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Lighter green text in dark mode so it clears 4.5:1 on the faint wash.
    final addedText = dark ? Colors.green.shade300 : Colors.green.shade800;
    final isHeader =
        line.startsWith('[') && line.contains('#') && line.endsWith(']');
    final (Color? background, Color textColor) = isHeader
        ? (cs.surfaceContainerHighest, cs.primary)
        : line.startsWith('+')
        ? (Colors.green.withValues(alpha: 0.15), addedText)
        : line.startsWith('-')
        ? (cs.errorContainer.withValues(alpha: 0.35), cs.error)
        : (null, cs.onSurfaceVariant);
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: SelectableText(
        line.isEmpty ? ' ' : line,
        style: TextStyle(
          fontFamily: 'monospace',
          fontFamilyFallback: kMonoFallback,
          fontSize: 12,
          color: textColor,
          fontWeight: isHeader ? FontWeight.w600 : FontWeight.normal,
        ),
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
  String get displayName => 'Ask the user';
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
