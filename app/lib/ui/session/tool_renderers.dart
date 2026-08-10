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
import 'tool_summary.dart';

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
  /// (`Run`, `Read`, `Edit`, …), since the full command/path/argument is
  /// already visible in the body. Defaults to [displayName].
  String label(ToolCallItem item) => displayName;

  /// The leading verb of [summaryLine], rendered a weight heavier than the rest
  /// of the collapsed row (see `mockups/tool-one-liner.html` §5). Defaults to
  /// [label] — the two are the same word for every renderer whose summary reads
  /// `<verb> <payload>`; override only where the summary carries a longer
  /// phrase than the verb (`Ask the user`).
  String verb(ToolCallItem item) => label(item);

  /// The verbatim command/argument for the row's hover tooltip, or null when the
  /// collapsed line already says everything (a path is shown in full, a command
  /// list is not). See `mockups/tool-one-liner.html` §4A.
  String? tooltip(ToolCallItem item) => null;

  /// Expanded body sections shown inline when the row is opened. Default:
  /// readable args + result text.
  List<Widget> body(BuildContext context, ToolCallItem item) =>
      genericToolBody(context, item);
}

/// Generic body for tools without a bespoke renderer: short arguments become
/// facts, long ones become captioned payloads, and the result follows.
List<Widget> genericToolBody(BuildContext context, ToolCallItem item) {
  final short = <ToolFact>[];
  final long = <(String, String)>[];
  for (final e in item.args.entries) {
    final value = valueString(e.value);
    if (isFactResult(value)) {
      short.add(ToolFact(e.key, value));
    } else {
      long.add((e.key, value));
    }
  }
  final facts = [...short, ...resultFacts(item)];
  return [
    if (facts.isNotEmpty) ToolFacts(facts),
    for (final (key, value) in long)
      ToolBlock(caption: key, child: ToolCodeBlock(value)),
    ...resultPayload(context, item, caption: long.isEmpty ? null : 'output'),
  ];
}

/// The facts a body ends with: a one-line result (`307 lines`,
/// `No matches found`) belongs in the strip rather than a highlighted panel
/// (see [isFactResult]), and a failure adds its exit code.
List<ToolFact> resultFacts(ToolCallItem item) {
  final text = extractToolResultText(item.resultText);
  final failed = item.ended && (item.exitCode ?? 0) != 0;
  final key = failed ? 'error' : 'result';
  return [
    if (isFactResult(text))
      ToolFact(key, oneLine(text), error: failed)
    else if (text.trim().isEmpty && item.ended)
      ToolFact(
        key,
        item.summary ?? 'exit ${item.exitCode ?? 0}',
        error: failed,
      ),
    if (failed && isFactResult(text))
      ToolFact('exit', '${item.exitCode}', error: true),
  ];
}

/// The result as a payload block, or nothing when [resultFacts] already placed
/// it in the strip.
List<Widget> resultPayload(
  BuildContext context,
  ToolCallItem item, {
  String? caption,
}) {
  final text = extractToolResultText(item.resultText);
  if (text.trim().isEmpty || isFactResult(text)) return const [];
  final failed = item.ended && (item.exitCode ?? 0) != 0;
  return [
    ToolBlock(
      caption: failed ? 'error' : caption,
      error: failed,
      child: ToolCodeBlock(text, language: 'plaintext', error: failed),
    ),
  ];
}

// ---------------------------------------------------------------------------
// Shared body helpers
// ---------------------------------------------------------------------------

/// Collapsed one-liner summary for [item] — the renderer's
/// [ToolRenderer.summaryLine] when registered, otherwise the raw tool name.
///
/// Absolute paths in the result are compacted (see [compactPathsIn]); pass the
/// session's worktree path as [root] so paths inside it render relative.
String toolSummaryLine(ToolCallItem item, {String? root}) => compactPathsIn(
  rendererFor(item)?.summaryLine(item) ?? item.name,
  root: root,
);

/// Short header label for [item] shown when its row is expanded — the
/// renderer's [ToolRenderer.label] when registered, otherwise the raw name.
String toolLabel(ToolCallItem item) =>
    rendererFor(item)?.label(item) ?? item.name;

/// The verb that opens [item]'s collapsed one-liner, for [splitVerb]. Empty for
/// an unregistered tool, whose summary is a bare tool name rather than a verb
/// phrase — nothing to emphasise.
String toolVerb(ToolCallItem item) => rendererFor(item)?.verb(item) ?? '';

/// Hover text for [item]'s collapsed row, or null when the row is not lossy.
String? toolTooltip(ToolCallItem item) => rendererFor(item)?.tooltip(item);

/// A caption above a payload block — a *label*, not a heading: `labelSmall`
/// uppercased in `onSurfaceVariant`, with tracking to carry the caps.
///
/// Only rendered when a body has two or more payloads (a `bash` call's command
/// and its output). A single-payload body has nothing to disambiguate, and the
/// row's own header already names the subject — see
/// `mockups/tool-expanded-body.html` §3/§5.
class ToolCaption extends StatelessWidget {
  const ToolCaption(this.text, {super.key, this.error = false});

  final String text;

  /// Failure is the one thing that earns colour here.
  final bool error;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: kSpace4),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: error ? cs.error : cs.onSurfaceVariant,
          letterSpacing: 0.7,
          height: 1.2,
        ),
      ),
    );
  }
}

/// One short `key value` fact, as used by [ToolFacts]. [error] tones the pair
/// with `colorScheme.error`: a failure is the one thing in this body that earns
/// colour, and it must read the same whether its message landed in the strip
/// (short) or in a payload (long).
class ToolFact {
  const ToolFact(this.key, this.value, {this.error = false});

  final String key;
  final String value;
  final bool error;
}

/// The facts strip: short, structured values — a line count, an exit code, a
/// grep's pattern and glob — laid out as dim `key value` pairs that wrap.
///
/// Deliberately *not* a panel and *not* a table. The old `ParamRow` gave every
/// key a fixed 72 px gutter, which marooned `path` four characters into empty
/// space and wrapped its value at whatever width was left; and wrapping those
/// rows in a container drew a frame around text that needed none.
class ToolFacts extends StatelessWidget {
  const ToolFacts(this.facts, {super.key});

  final List<ToolFact> facts;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodySmall;
    TextStyle? keyStyle(ToolFact f) => base?.copyWith(
      color: f.error ? cs.error : cs.onSurfaceVariant.withValues(alpha: 0.75),
      height: 1.2,
    );
    TextStyle? valueStyle(ToolFact f) => base?.mono.copyWith(
      color: f.error ? cs.error : cs.onSurfaceVariant,
      height: 1.2,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: kSpace6),
      child: Wrap(
        spacing: kSpace12,
        runSpacing: kSpace4,
        children: [
          for (final fact in facts)
            // A fact is short, but `isFactResult` allows up to 80 characters,
            // which is wider than a 430 pt pane: the value has to be able to
            // shrink and wrap, or the Row overflows (it did, by 147 px).
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: kReadableContentMaxWidth,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(fact.key, style: keyStyle(fact)),
                  const SizedBox(width: kSpace4),
                  // Selectable: an exit code or a match count is the kind of
                  // thing you paste into the next question.
                  Flexible(
                    child: SelectableText(fact.value, style: valueStyle(fact)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The single frame a payload gets: a fill from the app's own ramp, a hairline,
/// a small radius, clipped.
///
/// Defined once and applied by [ToolBlock], so a code payload and a diff payload
/// are framed identically and "one frame per payload" holds by construction
/// rather than by convention. Diffs previously borrowed a frame from the old
/// `ToolSection` container; when that went away they rendered as full-bleed
/// tinted bands next to neatly panelled neighbours.
class ToolPanel extends StatelessWidget {
  const ToolPanel({super.key, required this.child, this.error = false});

  final Widget child;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        // The app's own ramp, not the highlight theme's blue-grey (#282C34 /
        // #F0F1F4): those belong to atom-one-dark and github, and a panel in a
        // foreign neutral was a large part of why this body read as a guest in
        // the transcript.
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(kChatRadiusSmall),
        border: Border.all(
          color: error ? cs.error : cs.outlineVariant,
          width: kChatCodeBorderWidth,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// A payload plus its optional [caption] and the gap that separates it from the
/// next block. The payload is wrapped in exactly one [ToolPanel].
class ToolBlock extends StatelessWidget {
  const ToolBlock({
    super.key,
    required this.child,
    this.caption,
    this.error = false,
  });

  final Widget child;

  /// Omitted for a single-payload body.
  final String? caption;
  final bool error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: kSpace10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (caption != null) ToolCaption(caption!, error: error),
        ToolPanel(error: error, child: child),
      ],
    ),
  );
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

/// The highlight theme with its own panel background stripped.
///
/// [HighlightView] paints `theme['root'].backgroundColor` *inside* whatever
/// container it is given, so colouring [ToolCodeBlock]'s box was not enough:
/// the block still rendered atom-one-dark's `#282C34` (found on the real app,
/// after a widget test asserting the container's colour had already passed).
/// Token colours still highlight the code — only the panel is the app's.
Map<String, TextStyle> _withoutPanel(Map<String, TextStyle> theme) => {
  ...theme,
  'root': (theme['root'] ?? const TextStyle()).copyWith(
    backgroundColor: Colors.transparent,
  ),
};

final Map<String, TextStyle> _codeThemeDark = _withoutPanel(atomOneDarkTheme);
final Map<String, TextStyle> _codeThemeLight = _withoutPanel(githubTheme);

/// A block of code/CLI output rendered with syntax highlighting in a rounded,
/// horizontally-scrollable panel with a copy button — matching the markdown
/// code-block look in `chat_message.dart`. Not text-selectable (HighlightView
/// renders RichText); the copy button covers copy needs.
class ToolCodeBlock extends StatefulWidget {
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
  State<ToolCodeBlock> createState() => _ToolCodeBlockState();
}

class _ToolCodeBlockState extends State<ToolCodeBlock> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final code = widget.code;
    final language = widget.language;
    final error = widget.error;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // On a pointer the copy affordance is hover-revealed, like the row's own
    // disclosure caret; a touch platform has no hover, so it stays put.
    final pointer = switch (Theme.of(context).platform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => true,
      _ => false,
    };
    // The frame belongs to [ToolPanel] (applied by [ToolBlock]); this draws only
    // the code and its copy affordance.
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: HighlightView(
              code.isEmpty ? '(empty)' : code,
              language: language.isEmpty ? 'plaintext' : language,
              theme: dark ? _codeThemeDark : _codeThemeLight,
              padding: const EdgeInsets.fromLTRB(11, 9, 34, 9),
              textStyle:
                  (Theme.of(context).textTheme.bodySmall ?? const TextStyle())
                      .mono
                      .copyWith(color: error ? cs.error : null),
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: AnimatedOpacity(
              opacity: !pointer || _hovered ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: _CopyButton(code: code),
            ),
          ),
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
    // No `path` fact and no caption: the row's header still reads
    // `Read <path>` while expanded, so the body is the file and nothing else.
    final facts = <ToolFact>[
      if (offset != null) ToolFact('offset', '$offset'),
      if (limit != null) ToolFact('limit', '$limit'),
      ...resultFacts(item),
    ];
    return [
      if (facts.isNotEmpty) ToolFacts(facts),
      if (content.trim().isNotEmpty && !isFactResult(content))
        ToolBlock(
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
      'Write ${item.args['path'] ?? '(no path)'}';

  @override
  String label(ToolCallItem item) => 'Write';

  @override
  List<Widget> body(BuildContext context, ToolCallItem item) {
    final path = item.args['path']?.toString() ?? '(no path)';
    final content =
        item.args['content']?.toString() ?? item.args['text']?.toString() ?? '';
    final result = extractToolResultText(item.output ?? item.summary ?? '');
    final facts = <ToolFact>[
      ToolFact('bytes', '${content.length}'),
      if (isFactResult(result)) ToolFact('result', oneLine(result)),
    ];
    return [
      ToolFacts(facts),
      if (content.trim().isNotEmpty)
        ToolBlock(
          child: ToolCodeBlock(content, language: languageForPath(path)),
        ),
      if (result.trim().isNotEmpty && !isFactResult(result))
        ToolBlock(caption: 'result', child: ToolCodeBlock(result)),
    ];
  }
}

class _EditRenderer extends ToolRenderer {
  const _EditRenderer();
  @override
  String get name => 'edit';
  @override
  IconData get icon => PhosphorIconsLight.pencil;

  @override
  String summaryLine(ToolCallItem item) =>
      'Edit ${item.args['path'] ?? '(no path)'}';

  @override
  String label(ToolCallItem item) => 'Edit';

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

    // One diff, not two sections: the agent's own diff output when it sent one
    // (it is already a hashline diff), otherwise the one computed from the
    // before/after text. The shape goes in the strip where it can be read at a
    // glance; the path stays in the row's header.
    final added = lines.where((l) => l.kind == DiffKind.added).length;
    final removed = lines.where((l) => l.kind == DiffKind.removed).length;
    return [
      if (added > 0 || removed > 0)
        ToolFacts([
          ToolFact('added', '+$added'),
          ToolFact('removed', '−$removed'),
        ]),
      if (output.isNotEmpty)
        ToolBlock(child: DiffText(output))
      else if (hasDiff)
        ToolBlock(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final line in lines) DiffLineRow(line: line)],
          ),
        )
      else
        Text(
          'No diff details provided by the agent.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
    ];
  }
}

/// Codex's `apply_patch` (app-server `fileChange`) — a patch that can touch one
/// or more files. Rendered like the edit tool: same pencil icon and "Edited"
/// verb, with each file's unified diff colour-coded in its own section. `args`
/// carries `changes: [{ path, kind, diff }]` (see server `codex-map.ts`).
class _ApplyPatchRenderer extends ToolRenderer {
  const _ApplyPatchRenderer();
  @override
  String get name => 'apply_patch';
  @override
  String get displayName => 'Edit';
  @override
  IconData get icon => PhosphorIconsLight.pencil;

  List<Map<String, dynamic>> _changes(ToolCallItem item) {
    final raw = item.args['changes'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(Map<String, dynamic>.from)
        .toList();
  }

  @override
  String summaryLine(ToolCallItem item) {
    final changes = _changes(item);
    if (changes.length == 1) {
      return 'Edit ${changes.first['path'] ?? '(no path)'}';
    }
    if (changes.isEmpty) return 'Edit';
    return 'Edit ${changes.length} files';
  }

  @override
  String label(ToolCallItem item) => 'Edit';

  @override
  List<Widget> body(BuildContext context, ToolCallItem item) {
    final changes = _changes(item);
    if (changes.isEmpty) return genericToolBody(context, item);
    return [
      for (final change in changes)
        ToolBlock(
          // N files means N payloads, so each one is captioned with its path.
          caption: changes.length == 1
              ? null
              : change['path']?.toString() ?? '(no path)',
          child: (change['diff']?.toString() ?? '').isEmpty
              ? Text(
                  'No diff details provided by the agent.',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              : DiffText(change['diff'].toString()),
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

  /// The commands, not their arguments: `Run grep, gh pr, sed, makit serve`.
  /// The verbatim command is one hover (the row's tooltip) or one tap (the
  /// expanded body) away — see `mockups/tool-one-liner.html` §2/§4.
  ///
  /// A **destructive** call is the exception: `Run rm` hides exactly what the
  /// reader needs (found by QA on the real app), and this is the row the whole
  /// scheme keeps its signal in reserve for — so it shows the full command,
  /// matching its tinted glyph.
  @override
  String summaryLine(ToolCallItem item) {
    final command = item.args['command']?.toString() ?? '';
    final payload = item.risk == ToolRisk.destructive
        ? compactCommand(command)
        : commandNames(command);
    return payload.isEmpty ? 'Run' : 'Run $payload';
  }

  @override
  String label(ToolCallItem item) => 'Run';

  // The names alone cannot say *what* was grepped, so the row hands the whole
  // command back on hover — prologue stripped, everything else verbatim.
  @override
  String? tooltip(ToolCallItem item) {
    final full = compactCommand(item.args['command']?.toString() ?? '');
    return full.isEmpty ? null : full;
  }

  @override
  List<Widget> body(BuildContext context, ToolCallItem item) {
    final command = item.args['command']?.toString() ?? '';
    final output = resultPayload(context, item, caption: 'output');
    final facts = resultFacts(item);
    return [
      if (command.isNotEmpty)
        ToolBlock(
          // Captioned only when the output is a payload too: one block needs no
          // label, and shell text is self-evidently the command (rule 1).
          caption: output.isEmpty ? null : 'command',
          child: ToolCodeBlock(command, language: 'bash'),
        ),
      ...output,
      if (facts.isNotEmpty) ToolFacts(facts),
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
    final pattern = oneLine(item.args['pattern']?.toString() ?? '');
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
    final matches = output.trim().isEmpty
        ? 0
        : output.trim().split('\n').length;
    return [
      ToolFacts([
        if (pattern.isNotEmpty) ToolFact('pattern', pattern),
        if (glob != null) ToolFact('glob', glob),
        if (path != null) ToolFact('path', path),
        if (item.ended) ToolFact('matches', '$matches'),
      ]),
      if (output.trim().isNotEmpty)
        ToolBlock(child: ToolCodeBlock(output, language: 'plaintext')),
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
    return genericToolBody(context, item);
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
  List<Widget> body(BuildContext context, ToolCallItem item) =>
      genericToolBody(context, item);
}

/// Registry. Order does not matter — first matching name wins.
const List<ToolRenderer> toolRenderers = [
  _ReadRenderer(),
  _WriteRenderer(),
  _EditRenderer(),
  _ApplyPatchRenderer(),
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

  // The verb is one word; "the user" is payload, so only "Ask" is emphasised.
  @override
  String verb(ToolCallItem item) => 'Ask';

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
