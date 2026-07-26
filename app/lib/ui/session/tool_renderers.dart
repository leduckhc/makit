/// Tool renderer registry.
///
/// Each entry knows how to render a specific tool name (e.g. `read`, `edit`,
/// `askUserQuestion`). Pick a renderer for an item via [rendererFor]; if no
/// match, the caller falls back to [genericToolBody].
///
/// The chat transcript renders a collapsed one-liner per tool call (see
/// `ToolCallCard`), reading [ToolRenderer.icon] and [ToolRenderer.summaryLine].
/// Tapping the row expands [ToolRenderer.body] **inline** (there is no longer a
/// full-screen detail page). Tool views use a monospace font since they mostly
/// show arguments, CLI output and file contents.
///
/// To add support for a new tool, write a [ToolRenderer] subclass and register
/// it in [toolRenderers].
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import 'chat_metrics.dart';
import 'diff_view.dart';
import 'line_diff.dart';
import 'tool_result_text.dart';

// Re-export the pure result-text helpers so existing importers of
// `tool_renderers.dart` keep resolving them after the SPEC-19 split.
export 'tool_result_text.dart' show extractToolResultText, valueString;

// Canonical monospace stack lives in `app/theme.dart`; re-exported here so the
// existing tool-view importers keep resolving `kMonoFallback`.
export '../../app/theme.dart'
    show kMonoFallback, kMonoFontFamily, MakitMonoText;

/// Max width for the readable content column. On wide (desktop) windows the
/// transcript, composer and tool body are centered within this width instead of
/// stretching edge-to-edge (which is hard to read and unbalanced).
const double kReadableContentMaxWidth = 760;

abstract class ToolRenderer {
  const ToolRenderer();

  /// Logical name (matches [ToolCallItem.name]).
  String get name;

  /// Human-facing title. Defaults to the (lowercase) tool [name].
  String get displayName => name;

  /// Material icon shown on the collapsed row.
  IconData get icon => PhosphorIconsLight.terminalWindow;

  /// Collapsed one-liner shown in the transcript, e.g. `Ran <cmd>`,
  /// `Edited <path>`, `Read <path>`. Defaults to [displayName].
  String summaryLine(ToolCallItem item) => displayName;

  /// Short header label shown when the row is **expanded** — just the verb
  /// (`Ran`, `Read`, `Edited`, …), since the full command/path/argument is
  /// already visible in the body. Defaults to [displayName].
  String label(ToolCallItem item) => displayName;

  /// Expanded body sections shown inline when the row is opened. Default:
  /// readable args + result text.
  List<Widget> body(BuildContext context, ToolCallItem item) =>
      genericToolBody(context, item);
}

/// Generic body for tools without a bespoke renderer. Shows arguments as
/// readable label/value rows (never a raw JSON blob) and the result text.
List<Widget> genericToolBody(BuildContext context, ToolCallItem item) {
  final args = item.args;
  final text = extractToolResultText(item.resultText);
  final failed = item.ended && (item.exitCode ?? 0) != 0;
  return [
    if (args.isNotEmpty)
      ToolSection(
        title: 'Arguments',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final e in args.entries) ParamRow(e.key, valueString(e.value)),
          ],
        ),
      ),
    if (text.isNotEmpty)
      ToolSection(
        title: failed ? 'Error' : 'Output',
        child: ToolCodeBlock(text, language: 'plaintext', error: failed),
      )
    else if (item.ended)
      ToolSection(
        title: failed ? 'Error' : 'Result',
        child: MonoText(item.summary ?? 'exit ${item.exitCode ?? 0}'),
      ),
  ];
}

// ---------------------------------------------------------------------------
// Shared body helpers
// ---------------------------------------------------------------------------

/// Collapsed one-liner summary for [item] — the renderer's
/// [ToolRenderer.summaryLine] when registered, otherwise the raw tool name.
String toolSummaryLine(ToolCallItem item) =>
    rendererFor(item)?.summaryLine(item) ?? item.name;

/// Short header label for [item] shown when its row is expanded — the
/// renderer's [ToolRenderer.label] when registered, otherwise the raw name.
String toolLabel(ToolCallItem item) =>
    rendererFor(item)?.label(item) ?? item.name;

/// Titled section used in tool bodies.
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
          Text(title, style: Theme.of(context).textTheme.titleSmall?.mono),
          const SizedBox(height: kSpace6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(kSpace12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(kRadius10),
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}

/// Selectable monospace text — used for short result/summary strings.
class MonoText extends StatelessWidget {
  const MonoText(this.text, {super.key, this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => SelectableText(
    text,
    style: (Theme.of(context).textTheme.bodySmall ?? const TextStyle()).mono
        .copyWith(color: error ? Theme.of(context).colorScheme.error : null),
  );
}

/// A block of code/CLI output rendered with syntax highlighting in a rounded,
/// horizontally-scrollable panel with a copy button — matching the markdown
/// code-block look in `chat_message.dart`. Not text-selectable (HighlightView
/// renders RichText); the copy button covers copy needs.
class ToolCodeBlock extends StatelessWidget {
  const ToolCodeBlock(
    this.code, {
    super.key,
    this.language = 'plaintext',
    this.error = false,
  });

  final String code;
  final String language;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF282C34) : const Color(0xFFF0F1F4),
        borderRadius: BorderRadius.circular(kChatRadiusSmall),
        border: Border.all(color: error ? cs.error : cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: HighlightView(
              code.isEmpty ? '(empty)' : code,
              language: language.isEmpty ? 'plaintext' : language,
              theme: dark ? atomOneDarkTheme : githubTheme,
              padding: const EdgeInsets.fromLTRB(12, 12, 40, 12),
              textStyle:
                  (Theme.of(context).textTheme.bodySmall ?? const TextStyle())
                      .mono
                      .copyWith(color: error ? cs.error : null),
            ),
          ),
          Positioned(top: 2, right: 2, child: _CopyButton(code: code)),
        ],
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.code});
  final String code;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: _copied ? 'Copied' : 'Copy',
      iconSize: 16,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(kSpace4),
      constraints: const BoxConstraints(),
      icon: Icon(
        _copied ? PhosphorIconsLight.check : PhosphorIconsLight.copy,
        color: _copied ? cs.primary : cs.onSurfaceVariant,
      ),
      onPressed: _copy,
    );
  }
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
              style: Theme.of(context).textTheme.bodySmall?.mono.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: Theme.of(context).textTheme.bodySmall?.mono,
            ),
          ),
        ],
      ),
    );
  }
}

/// Map a file path to a highlight.js language name for [ToolCodeBlock]. Small,
/// explicit table; unknown extensions fall back to plaintext.
String languageForPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return 'plaintext';
  return switch (path.substring(dot + 1).toLowerCase()) {
    'dart' => 'dart',
    'ts' || 'tsx' => 'typescript',
    'js' || 'jsx' || 'mjs' || 'cjs' => 'javascript',
    'py' => 'python',
    'json' => 'json',
    'sh' || 'bash' || 'zsh' => 'bash',
    'yaml' || 'yml' => 'yaml',
    'md' || 'markdown' => 'markdown',
    'html' || 'htm' => 'xml',
    'css' => 'css',
    'go' => 'go',
    'rs' => 'rust',
    'java' => 'java',
    'kt' || 'kts' => 'kotlin',
    'swift' => 'swift',
    'c' || 'h' => 'c',
    'cpp' || 'cc' || 'hpp' => 'cpp',
    'sql' => 'sql',
    _ => 'plaintext',
  };
}

/// Collapse a (possibly multi-line) command/label into one whitespace-normalised
/// line for the collapsed summary.
String _oneLine(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

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
  String summaryLine(ToolCallItem item) =>
      'Read ${item.args['path'] ?? '(no path)'}';

  @override
  String label(ToolCallItem item) => 'Read';

  @override
  List<Widget> body(BuildContext context, ToolCallItem item) {
    final path = item.args['path']?.toString() ?? '(no path)';
    final content = extractToolResultText(item.output ?? item.deltas.join());
    final offset = item.args['offset'];
    final limit = item.args['limit'];
    return [
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
        child: ToolCodeBlock(content, language: languageForPath(path)),
      ),
    ];
  }
}

class _WriteRenderer extends ToolRenderer {
  const _WriteRenderer();
  @override
  String get name => 'write';
  @override
  IconData get icon => PhosphorIconsLight.notePencil;

  @override
  String summaryLine(ToolCallItem item) =>
      'Wrote ${item.args['path'] ?? '(no path)'}';

  @override
  String label(ToolCallItem item) => 'Wrote';

  @override
  List<Widget> body(BuildContext context, ToolCallItem item) {
    final path = item.args['path']?.toString() ?? '(no path)';
    final content =
        item.args['content']?.toString() ?? item.args['text']?.toString() ?? '';
    final result = extractToolResultText(item.output ?? item.summary ?? '');
    return [
      ToolSection(title: 'Arguments', child: ParamRow('path', path)),
      ToolSection(
        title: 'Content written',
        child: ToolCodeBlock(content, language: languageForPath(path)),
      ),
      if (result.isNotEmpty)
        ToolSection(title: 'Result', child: MonoText(result)),
    ];
  }
}

class _EditRenderer extends ToolRenderer {
  const _EditRenderer();
  @override
  String get name => 'edit';
  @override
  IconData get icon => PhosphorIconsLight.gitDiff;

  @override
  String summaryLine(ToolCallItem item) =>
      'Edited ${item.args['path'] ?? '(no path)'}';

  @override
  String label(ToolCallItem item) => 'Edited';

  /// Read the "before"/"after" text from whichever key the agent used.
  /// Different agents name these differently (edit/StrReplace tools commonly
  /// use `old_string`/`new_string`; others `oldText`/`newText` or `old`/`new`).
  static String _pick(Map<String, dynamic> args, List<String> keys) {
    for (final k in keys) {
      final v = args[k];
      if (v != null) return v.toString();
    }
    return '';
  }

  @override
  List<Widget> body(BuildContext context, ToolCallItem item) {
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

    return [
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
      // The edit tool's result is itself a diff (hashline `+`/`-`/context rows
      // under a `[path#HASH]` header) — render it colour-coded.
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
    ];
  }
}

class _BashRenderer extends ToolRenderer {
  const _BashRenderer();
  @override
  String get name => 'bash';
  @override
  IconData get icon => PhosphorIconsLight.terminalWindow;

  @override
  String summaryLine(ToolCallItem item) {
    final cmd = _oneLine(item.args['command']?.toString() ?? '');
    return cmd.isEmpty ? 'Ran' : 'Ran $cmd';
  }

  @override
  String label(ToolCallItem item) => 'Ran';

  @override
  List<Widget> body(BuildContext context, ToolCallItem item) {
    final command = item.args['command']?.toString() ?? '';
    final output = extractToolResultText(item.resultText);
    final failed = item.ended && (item.exitCode ?? 0) != 0;
    return [
      if (command.isNotEmpty)
        ToolSection(
          title: 'Command',
          child: ToolCodeBlock(command, language: 'bash'),
        ),
      if (output.isNotEmpty)
        ToolSection(
          title: failed ? 'Error' : 'Output',
          child: ToolCodeBlock(output, language: 'plaintext', error: failed),
        )
      else if (item.ended)
        ToolSection(
          title: failed ? 'Error' : 'Result',
          child: MonoText(item.summary ?? 'exit ${item.exitCode ?? 0}'),
        ),
    ];
  }
}

class _GrepRenderer extends ToolRenderer {
  const _GrepRenderer();
  @override
  String get name => 'grep';
  @override
  IconData get icon => PhosphorIconsLight.magnifyingGlass;

  @override
  String summaryLine(ToolCallItem item) {
    final pattern = _oneLine(item.args['pattern']?.toString() ?? '');
    return pattern.isEmpty ? 'Grep' : 'Grep $pattern';
  }

  @override
  String label(ToolCallItem item) => 'Grep';

  @override
  List<Widget> body(BuildContext context, ToolCallItem item) {
    final pattern = item.args['pattern']?.toString() ?? '';
    final glob = item.args['glob']?.toString();
    final path = item.args['path']?.toString();
    final output = extractToolResultText(item.output ?? item.deltas.join());
    return [
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
        ToolSection(
          title: 'Results',
          child: ToolCodeBlock(output, language: 'plaintext'),
        )
      else if (item.ended)
        ToolSection(
          title: 'Results',
          child: MonoText(item.summary ?? 'No matches found'),
        ),
    ];
  }
}

class _MemoryRenderer extends ToolRenderer {
  const _MemoryRenderer();
  @override
  String get name => 'memory';
  @override
  IconData get icon => PhosphorIconsLight.brain;

  @override
  String summaryLine(ToolCallItem item) {
    final action = item.args['action']?.toString();
    return action == null || action.isEmpty ? 'Memory' : 'Memory $action';
  }

  @override
  String label(ToolCallItem item) => 'Memory';

  @override
  List<Widget> body(BuildContext context, ToolCallItem item) {
    final args = item.args;
    final result = extractToolResultText(item.resultText);
    return [
      if (args.isNotEmpty)
        ToolSection(
          title: 'Input',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in args.entries)
                ParamRow(e.key, valueString(e.value)),
            ],
          ),
        ),
      if (result.isNotEmpty)
        ToolSection(title: 'Result', child: MonoText(result)),
    ];
  }
}

class _SkillRenderer extends ToolRenderer {
  const _SkillRenderer();
  @override
  String get name => 'skill';
  @override
  IconData get icon => PhosphorIconsLight.graduationCap;

  @override
  String summaryLine(ToolCallItem item) {
    final name =
        item.args['name']?.toString() ?? item.args['skill_id']?.toString();
    return name == null || name.isEmpty ? 'Skill' : 'Skill $name';
  }

  @override
  String label(ToolCallItem item) => 'Skill';

  @override
  List<Widget> body(BuildContext context, ToolCallItem item) {
    final args = item.args;
    final result = extractToolResultText(item.resultText);
    return [
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
      if (result.isNotEmpty)
        ToolSection(title: 'Description', child: MonoText(result)),
    ];
  }
}

/// Registry. Order does not matter — first matching name wins.
const List<ToolRenderer> toolRenderers = [
  _ReadRenderer(),
  _WriteRenderer(),
  _EditRenderer(),
  _BashRenderer(),
  _GrepRenderer(),
  _MemoryRenderer(),
  _SkillRenderer(),
  _AskUserQuestionRenderer('askUserQuestion'),
];

/// Pick a renderer for [item] by name (case-insensitive so `Read`/`read` and
/// `Edit`/`edit` from different agents match). Returns null if no renderer is
/// registered — caller should fall back to [genericToolBody].
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

  @override
  String summaryLine(ToolCallItem item) => 'Ask the user';

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
  List<Widget> body(BuildContext context, ToolCallItem item) {
    final cs = Theme.of(context).colorScheme;
    final questions = _questions(item);
    return [
      for (var qi = 0; qi < questions.length; qi++)
        Builder(
          builder: (context) {
            final q = questions[qi];
            final chosen = _chosen(item, qi).toSet();
            final options =
                (q['options'] as List?)
                    ?.whereType<Map<dynamic, dynamic>>()
                    .map(Map<String, dynamic>.from)
                    .toList() ??
                const [];
            return Padding(
              padding: EdgeInsets.only(
                bottom: qi == questions.length - 1 ? 0 : 20,
              ),
              child: Column(
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
                  const SizedBox(height: kSpace10),
                  for (final opt in options)
                    _AnswerOption(
                      label: opt['label']?.toString() ?? '',
                      description: opt['description']?.toString(),
                      chosen: chosen.contains(opt['label']?.toString()),
                    ),
                  // Free-text / "Other" answers won't match an option — show them.
                  for (final ans in chosen)
                    if (!options.any((o) => o['label']?.toString() == ans))
                      _AnswerOption(
                        label: ans,
                        description: null,
                        chosen: true,
                      ),
                ],
              ),
            );
          },
        ),
    ];
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
      padding: const EdgeInsets.all(kSpace10),
      decoration: BoxDecoration(
        color: chosen ? cs.primaryContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(kRadius8),
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
          const SizedBox(width: kSpace8),
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
