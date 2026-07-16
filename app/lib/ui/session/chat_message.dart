import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

/// Flutter's `'monospace'` logical family only resolves on Android; on Apple
/// platforms it silently falls back to the default proportional font. Provide
/// real monospace faces so code renders monospaced everywhere.
const String _kMonoFont = 'monospace';
const List<String> _kMonoFallback = [
  'SF Mono',
  'Menlo',
  'Consolas',
  'Roboto Mono',
  'Courier New',
  'monospace',
];

String _hhmm(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  return '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}

/// Small, grey, right- or left-aligned timestamp shown under a message.
class _Timestamp extends StatelessWidget {
  const _Timestamp({required this.ts, required this.alignRight});
  final int ts;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        top: 2,
        left: alignRight ? 0 : 4,
        right: alignRight ? 4 : 0,
      ),
      child: Text(_hhmm(ts), style: TextStyle(fontSize: 11, color: cs.outline)),
    );
  }
}

/// The user's own messages — right-aligned coloured bubble.
class ChatBubble extends StatelessWidget {
  const ChatBubble.user({required this.text, required this.ts, super.key});

  final String text;
  final int ts;

  @override
  Widget build(BuildContext context) {
    // User bubble is neutral grey (design system) — never the green accent.
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bubble = dark ? const Color(0xFF2E2E2E) : const Color(0xFFEBEBEB);
    final onBubble = dark ? const Color(0xFFF5F5F5) : const Color(0xFF1B1B1B);
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: bubble,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: SelectableText(text, style: TextStyle(color: onBubble)),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12, bottom: 4),
              child: _Timestamp(ts: ts, alignRight: true),
            ),
          ],
        ),
      ),
    );
  }
}

/// Assistant output — full-width, no bubble, markdown-rendered.
class AgentMessage extends StatefulWidget {
  const AgentMessage({required this.text, required this.ts, super.key});

  final String text;
  final int ts;

  @override
  State<AgentMessage> createState() => _AgentMessageState();
}

class _AgentMessageState extends State<AgentMessage> {
  // One SelectionArea lets a single drag span every block; the SelectionContainer
  // swaps in a delegate that re-inserts newlines between blocks when copying
  // (the default delegate concatenates block text into one unreadable blob).
  // The delegate holds selection state, so it must outlive rebuilds (streaming
  // updates rebuild this widget as text grows).
  final _MarkdownSelectionDelegate _selectionDelegate =
      _MarkdownSelectionDelegate();

  @override
  void dispose() {
    _selectionDelegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectionArea(
            child: SelectionContainer(
              delegate: _selectionDelegate,
              child: MarkdownBody(
                data: widget.text,
                selectable: false,
                styleSheet: _styleSheet(context),
                onTapLink: _openLink,
                builders: {'code': _CodeBlockBuilder(context)},
              ),
            ),
          ),
          _Timestamp(ts: widget.ts, alignRight: false),
        ],
      ),
    );
  }
}

/// Joins the selected content of markdown blocks with a newline so a
/// multi-block copy is readable. flutter_markdown renders each block
/// (paragraph, list item, heading) and each inline builder widget (our inline
/// `code`) as a separate [Selectable]; the default delegate concatenates them
/// with no separator. We insert `\n` only at real line breaks — detected by
/// comparing the global vertical position of consecutive selected fragments —
/// so inline widgets that sit on the same visual line stay joined without a
/// spurious newline.
class _MarkdownSelectionDelegate extends StaticSelectionContainerDelegate {
  // Fragments overlapping vertically by more than this many logical pixels are
  // treated as the same line (guards against the few-pixel baseline shift that
  // WidgetSpan/inline widgets introduce).
  static const double _sameLineOverlap = 2.0;

  @override
  SelectedContent? getSelectedContent() {
    final StringBuffer buffer = StringBuffer();
    var wroteAny = false;
    Rect? prev;
    for (final Selectable selectable in selectables) {
      final SelectedContent? content = selectable.getSelectedContent();
      if (content == null || content.plainText.isEmpty) continue;

      final List<Rect> rects = selectable.value.selectionRects;
      Rect? firstGlobal;
      Rect? lastGlobal;
      if (rects.isNotEmpty) {
        final Matrix4 transform = selectable.getTransformTo(null);
        firstGlobal = MatrixUtils.transformRect(transform, rects.first);
        lastGlobal = MatrixUtils.transformRect(transform, rects.last);
      }

      if (wroteAny) {
        final bool sameLine =
            prev != null &&
            firstGlobal != null &&
            firstGlobal.top < prev.bottom - _sameLineOverlap &&
            firstGlobal.bottom > prev.top + _sameLineOverlap;
        if (!sameLine) buffer.write('\n');
      }
      buffer.write(content.plainText);
      wroteAny = true;
      prev = lastGlobal ?? prev;
    }
    if (!wroteAny) return null;
    return SelectedContent(plainText: buffer.toString());
  }
}

Future<void> _openLink(String text, String? href, String title) async {
  if (href == null || href.isEmpty) return;
  final uri = Uri.tryParse(href);
  if (uri == null) return;
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// Renders fenced code blocks with syntax highlighting + a copy button.
/// Inline `code` returns a Container with background (not TextStyle.backgroundColor)
/// so text selection highlight renders on top.
class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder(this.context);
  final BuildContext context;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final className = element.attributes['class'];
    var language = '';
    if (className != null && className.startsWith('language-')) {
      language = className.substring('language-'.length);
    }
    var code = element.textContent;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    final isBlock = className != null || code.contains('\n');

    if (isBlock) {
      return _CodeBlock(code: code, language: language);
    }

    // Inline code - wrap in Container with background for proper selection rendering
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF33363E) : const Color(0xFFEBECF0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        code,
        style: preferredStyle?.copyWith(
          fontFamily: _kMonoFont,
          fontFamilyFallback: _kMonoFallback,
          fontSize: 13,
          backgroundColor: Colors.transparent,
        ),
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code, required this.language});
  final String code;
  final String language;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF282C34) : const Color(0xFFF0F1F4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: HighlightView(
              code,
              language: language.isEmpty ? 'plaintext' : language,
              theme: dark ? atomOneDarkTheme : githubTheme,
              padding: const EdgeInsets.fromLTRB(12, 12, 40, 12),
              textStyle: const TextStyle(
                fontFamily: _kMonoFont,
                fontFamilyFallback: _kMonoFallback,
                fontSize: 13,
              ),
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
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(),
      icon: Icon(
        _copied ? Icons.check : Icons.copy,
        color: _copied ? Colors.green : cs.onSurfaceVariant,
      ),
      onPressed: _copy,
    );
  }
}

MarkdownStyleSheet _styleSheet(BuildContext context) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  // Inline `code`: mono font. Background is applied by _CodeBlockBuilder
  // to allow text selection to render on top.
  final mono = theme.textTheme.bodyMedium?.copyWith(
    fontFamily: _kMonoFont,
    fontFamilyFallback: _kMonoFallback,
    fontSize: 13,
  );
  // LLMs love emitting h1/h2/h3 headers; render them all as plain bold text at
  // the normal body size instead of oversized headings.
  final heading = theme.textTheme.bodyMedium?.copyWith(
    fontWeight: FontWeight.w700,
  );
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: theme.textTheme.bodyMedium,
    code: mono,
    h1: heading,
    h2: heading,
    h3: heading,
    h4: heading,
    h5: heading,
    h6: heading,
    blockquoteDecoration: BoxDecoration(
      color: cs.surfaceContainerHigh,
      border: Border(left: BorderSide(color: cs.primary, width: 3)),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
    a: TextStyle(color: cs.primary, decoration: TextDecoration.underline),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: cs.outlineVariant)),
    ),
  );
}
