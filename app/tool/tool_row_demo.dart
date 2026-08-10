// Interactive QA harness for the collapsed transcript row — the tool one-liner
// and the thinking line it must sit flush against. Seeded data, no server.
//
//   cd app && flutter run -d macos      -t tool/tool_row_demo.dart
//   cd app && flutter run -d "iPhone 17" -t tool/tool_row_demo.dart
//
// Every row is the shipped widget rendered through the shipped `chatItemWidget`
// + `transcriptRow`, on the real theme, so gutters, gaps, glyph weights and
// ellipsis behaviour are the product's — not an approximation. The design
// reference is `mockups/tool-one-liner.html`.
//
// Controls (top bar): light/dark, pane width (430 / 560 / full), and a ruler
// that prints each row's measured height so density claims can be checked
// against §6 of the mockup rather than eyeballed.
//
// Not part of the app or the test suite: a harness, kept out of `lib/` so it
// cannot be imported by either.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/session/chat_metrics.dart';
import 'package:makit/ui/session/chat_transcript.dart';
import 'package:makit/ui/session/transcript_expansion.dart';

// ── seeded transcript ────────────────────────────────────────────────────────

int _seq = 0;
final int _t0 = DateTime.now().millisecondsSinceEpoch - 400000;
int _ts(int seconds) => _t0 + seconds * 1000;

ToolCallItem _tool(
  String name,
  Map<String, dynamic> args, {
  String? output,
  bool ended = true,
  int exitCode = 0,
  ToolRisk risk = ToolRisk.risky,
  int startAt = 0,
  int? endAt,
}) => ToolCallItem(
  seq: ++_seq,
  ts: _ts(startAt),
  callId: 'c$_seq',
  name: name,
  args: args,
  output: output,
  ended: ended,
  exitCode: exitCode,
  risk: risk,
  endedTs: ended ? _ts(endAt ?? startAt) : null,
);

/// The rows that matter, in the order a real turn produces them. Commands are
/// verbatim from working on this repo — the point is to see what the summariser
/// does with real input, not with tidy examples.
List<ChatItem> _transcript() {
  _seq = 0;
  return [
    UserMessageItem(
      seq: ++_seq,
      ts: _ts(0),
      text: 'the tool rows are shouting — calm them down',
    ),
    ThinkingItem(
      seq: ++_seq,
      ts: _ts(1),
      text:
          'The risk tint fires on edit/write/bash, so it is on for almost every '
          'row; monochrome loses nothing and buys back the amber for something '
          'that is actually exceptional.',
      lastTs: _ts(5),
    ),
    _tool(
      'read',
      {
        'path':
            '/Users/le/.worktrees/makit/feat-chat-content/app/lib/ui/session/tool_call_card.dart',
      },
      output:
          "import 'package:flutter/material.dart';\n"
          "import 'package:flutter_riverpod/flutter_riverpod.dart';\n"
          '\n'
          'class ToolCallCard extends ConsumerStatefulWidget {\n'
          '  const ToolCallCard({super.key, required this.item});\n',
      risk: ToolRisk.safe,
      startAt: 6,
    ),
    _tool(
      'bash',
      {
        'command':
            'cd /Users/le/.worktrees/makit/feat-chat-content && grep -rn "risk" '
            'server/src/*.ts | head -20',
      },
      output:
          'server/src/pi-sessions.ts:259:function classifyRisk(name: string) {\n'
          'server/src/adapters/acp-map.ts:540:function riskFromKind(kind) {\n'
          'server/src/adapters/codex-map.ts:29:type Risk = "safe" | "risky";',
      startAt: 7,
      endAt: 10,
    ),
    _tool(
      'grep',
      {'pattern': 'kToolRiskyColor'},
      output: 'app/lib/ui/session/chat_metrics.dart:46',
      risk: ToolRisk.safe,
      startAt: 11,
    ),
    _tool('edit', {
      'path': 'app/lib/ui/session/tool_call_card.dart',
      'oldText': 'size: 16,',
      'newText': 'size: kToolGlyph,',
    }, startAt: 12),
    ThinkingItem(
      seq: ++_seq,
      ts: _ts(13),
      text:
          'Sans is about 12% narrower than mono at 13px, so more of the label '
          'survives the ellipsis — compactness in the horizontal axis too.',
      lastTs: _ts(85),
    ),
    _tool(
      'bash',
      {
        'command':
            'cd /Users/le/.worktrees/makit/feat-chat-content/app && '
            '~/flutter/bin/flutter test --no-pub test/tool_call_card_style_test.dart',
      },
      // A one-line result at the very edge of `isFactResult`'s 80-char limit:
      // the widest thing the facts strip will ever be asked to hold, and the
      // case that overflowed a 430 pt pane by 147 px before values could shrink.
      output:
          '00:00 +19: All tests passed! (tool_body_test.dart, 19 assertions ok)',
      startAt: 86,
      endAt: 134,
    ),
    _tool(
      'bash',
      {
        'command':
            "sed -i '' 's/Ran/Run/g' app/lib/ui/session/tool_renderers.dart && "
            'grep -n "Run " app/lib/ui/session/tool_renderers.dart',
      },
      output: 'sed: 1: invalid command code R',
      exitCode: 1,
      startAt: 135,
      endAt: 137,
    ),
    _tool(
      'bash',
      {'command': r'kill $(lsof -t -i:9787) ; sleep 1 ; lsof -t -i:9787'},
      output: '',
      startAt: 138,
    ),
    _tool(
      'bash',
      {'command': 'rm -rf ~/Library/Caches/dev.getmakit.app && rm -rf build'},
      output: '',
      risk: ToolRisk.destructive,
      startAt: 139,
      endAt: 143,
    ),
    _tool('write', {
      'path': 'app/test/tool_call_card_style_test.dart',
      'content': '…',
    }, startAt: 144),
    // The line from the brief, as one command: seven distinct tools.
    _tool(
      'bash',
      {
        'command':
            'cd /Users/le/.worktrees/makit/feat-chat-content && grep -rn "serve" '
            'server/src && gh pr view 154 --json title && sed -i \'\' '
            "'s/7800/7810/' server/src/ports.ts && makit serve --port 7810 & "
            'python3 tool/wait.py | head -3 ; lsof -nP -i:7810',
      },
      ended: false,
      startAt: 145,
    ),
    AgentMessageItem(
      seq: ++_seq,
      ts: _ts(150),
      text: 'Rows are 31px now, one family, and the amber is gone.',
    ),
  ];
}

// ── harness ──────────────────────────────────────────────────────────────────

void main() => runApp(const ProviderScope(child: _DemoApp()));

class _DemoApp extends ConsumerStatefulWidget {
  const _DemoApp();
  @override
  ConsumerState<_DemoApp> createState() => _DemoAppState();
}

/// `flutter run -t tool/tool_row_demo.dart --dart-define=unfold=true` opens with
/// every row already expanded. Synthesized clicks do not reliably reach a
/// background window, and the expanded body needs grading from a screenshot.
const bool kStartUnfolded = bool.fromEnvironment('unfold');

class _DemoAppState extends ConsumerState<_DemoApp> {
  bool _dark = true;
  double? _width = 430;
  bool _ruler = false;
  bool _unfolded = false;
  final List<ChatItem> _items = _transcript();

  @override
  void initState() {
    super.initState();
    if (kStartUnfolded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _toggleAll(ref));
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // Both themes + an explicit mode: `theme:` alone is at the mercy of the
      // host's system appearance, which made the first QA pass silently grade
      // the light theme.
      theme: makitLightTheme,
      darkTheme: makitDarkTheme,
      themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
      home: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Consumer(builder: (context, ref, _) => _controls(context, ref)),
              const Divider(height: 1),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: _width,
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      children: [
                        for (var i = 0; i < _items.length; i++)
                          _RowProbe(
                            enabled: _ruler,
                            label: _items[i].runtimeType.toString(),
                            child: transcriptRow(
                              chatItemWidget('demo', _items[i], position: i),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Unfold/refold every row at once — the expanded body is the thing under
  /// review, and synthesized clicks do not reliably reach a background window.
  void _toggleAll(WidgetRef ref) {
    final notifier = ref.read(expandedTranscriptRowsProvider.notifier);
    for (final item in _items) {
      notifier.toggle(transcriptRowExpansionKey('demo', item));
    }
    setState(() => _unfolded = !_unfolded);
  }

  Widget _controls(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'tool one-liner · '
          '${Theme.of(context).brightness.name} · '
          '${_width?.toStringAsFixed(0) ?? 'full'}pt',
        ),
        _chip(context, 'dark', _dark, () => setState(() => _dark = !_dark)),
        _chip(
          context,
          '430',
          _width == 430,
          () => setState(() => _width = 430),
        ),
        _chip(
          context,
          '560',
          _width == 560,
          () => setState(() => _width = 560),
        ),
        _chip(
          context,
          'full',
          _width == null,
          () => setState(() => _width = null),
        ),
        _chip(context, 'ruler', _ruler, () => setState(() => _ruler = !_ruler)),
        _chip(context, 'unfold', _unfolded, () => _toggleAll(ref)),
      ],
    ),
  );

  /// Takes the context explicitly: the State's own `context` sits ABOVE
  /// `MaterialApp`, so `Theme.of` there resolves the stock Material theme rather
  /// than the app's. That is why these chips rendered in Material purple while
  /// the transcript below them was correctly makit-green.
  Widget _chip(
    BuildContext context,
    String label,
    bool on,
    VoidCallback onTap,
  ) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(kRadius8),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadius8),
        border: Border.all(
          color: on
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outlineVariant,
        ),
        color: on
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
            : null,
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelMedium),
    ),
  );
}

/// Draws the measured pitch of one transcript row (its full box, gaps included)
/// so §6's 31 px claim can be read off the screen instead of trusted.
class _RowProbe extends StatefulWidget {
  const _RowProbe({
    required this.child,
    required this.enabled,
    required this.label,
  });
  final Widget child;
  final bool enabled;
  final String label;

  @override
  State<_RowProbe> createState() => _RowProbeState();
}

class _RowProbeState extends State<_RowProbe> {
  final GlobalKey _key = GlobalKey();
  double? _height;
  bool _measuring = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return KeyedSubtree(key: _key, child: widget.child);
    // Guarded: build can run several times in one frame, and each unguarded
    // registration re-measures the same box.
    if (!_measuring) {
      _measuring = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _measuring = false;
        // The ruler can be switched off in the same frame, taking this State
        // with it — setState on an unmounted State throws.
        if (!mounted) return;
        final box = _key.currentContext?.findRenderObject();
        if (box is RenderBox && box.hasSize && _height != box.size.height) {
          setState(() => _height = box.size.height);
        }
      });
    }
    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: cs.primary.withValues(alpha: 0.35)),
          ),
          child: KeyedSubtree(key: _key, child: widget.child),
        ),
        // The label rides with the number: `ToolCallItem 31.0px` is readable at
        // a glance, a bare `31.0px` next to eleven other rows is not.
        Positioned(
          right: 2,
          top: 0,
          child: Text(
            _height == null
                ? ''
                : '${widget.label} ${_height!.toStringAsFixed(1)}px',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: cs.primary),
          ),
        ),
      ],
    );
  }
}
