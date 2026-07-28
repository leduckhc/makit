import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../store/chat_items.dart';
import 'chat_metrics.dart';
import 'media_view.dart';

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
      child: Text(
        _hhmm(ts),
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: cs.outline),
      ),
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
    final cs = Theme.of(context).colorScheme;
    final bubble = cs.surfaceContainerHigh;
    final onBubble = cs.onSurface;
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
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: kSpace10,
              ),
              decoration: BoxDecoration(
                color: bubble,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(kChatRadiusLarge),
                  topRight: Radius.circular(kChatRadiusLarge),
                  bottomLeft: Radius.circular(kChatRadiusLarge),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: SelectableText(text, style: TextStyle(color: onBubble)),
            ),
            _Timestamp(ts: ts, alignRight: true),
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
    // Fill the available (readable-capped) width so the start-aligned content
    // always hugs the left. Without this the Column shrink-wraps to its text,
    // and the desktop pane's centering makes short replies look centered
    // while only long/last replies (which fill the width) appear left-aligned.
    // No horizontal padding here: the surface owns the gutter (see
    // [transcriptRow] / chat_metrics.dart).
    return SizedBox(
      width: double.infinity,
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
                imageBuilder: _mediaImageBuilder,
              ),
            ),
          ),
          _Timestamp(ts: widget.ts, alignRight: false),
        ],
      ),
    );
  }
}

/// Renders markdown images in agent prose.
///
/// `makit-media:<mediaId>` is what the server rewrites the agent's
/// `![](/local/path.png)` into (server/src/media/local.ts ingests the bytes,
/// because the phone has no access to that filesystem) — those load through the
/// pinned media client. `http(s)` keeps flutter_markdown_plus's pre-existing
/// network behaviour; hardening remote images is a separate phase of SPEC-22.
/// Anything else — a `file://` or a raw path that was NOT rewritten (outside
/// the allowed roots, or a still-streaming delta) — is unfetchable from the
/// phone, so it gets a placeholder instead of a red decode error.
Widget _mediaImageBuilder(Uri uri, String? title, String? alt) {
  final label = alt?.isNotEmpty == true ? alt! : (title ?? uri.toString());
  if (uri.scheme == kMediaUriScheme) {
    // `makit-media:<id>` has no authority, so the id lands in `path`.
    final mediaId = uri.path.isNotEmpty ? uri.path : uri.host;
    // Same gate as the event fold: only a real content hash is fetchable, and
    // a malformed one would render a permanent broken image.
    if (!isMediaId(mediaId)) return MediaPlaceholder(label: label);
    return AgentMediaView(
      item: AgentMediaItem(
        seq: 0,
        ts: 0,
        mediaId: mediaId,
        mime: 'image/png',
        alt: alt ?? title,
      ),
    );
  }
  if (uri.scheme == 'http' || uri.scheme == 'https') {
    return Image.network(
      uri.toString(),
      errorBuilder: (_, _, _) => MediaPlaceholder(label: label),
    );
  }
  return MediaPlaceholder(label: label);
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
      padding: const EdgeInsets.symmetric(horizontal: kSpace4, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        code,
        style: preferredStyle?.mono.copyWith(
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
      margin: const EdgeInsets.symmetric(vertical: kSpace6),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF282C34) : const Color(0xFFF0F1F4),
        borderRadius: BorderRadius.circular(kChatRadiusSmall),
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
              textStyle:
                  (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
                      .mono,
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

MarkdownStyleSheet _styleSheet(BuildContext context) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  // Inline `code`: mono font. Background is applied by _CodeBlockBuilder
  // to allow text selection to render on top.
  final mono = theme.textTheme.bodyMedium?.mono;
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
