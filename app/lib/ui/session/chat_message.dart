import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart' show kPinoBrandBlue;

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
              decoration: const BoxDecoration(
                color: kPinoBrandBlue,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(14),
                  topRight: Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: SelectableText(
                text,
                style: const TextStyle(color: Colors.white),
              ),
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
class AgentMessage extends StatelessWidget {
  const AgentMessage({required this.text, required this.ts, super.key});

  final String text;
  final int ts;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarkdownBody(
            data: text,
            selectable: true,
            styleSheet: _styleSheet(context),
            onTapLink: _openLink,
            builders: {'code': _CodeBlockBuilder(context)},
          ),
          _Timestamp(ts: ts, alignRight: false),
        ],
      ),
    );
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
/// Inline `code` returns null → falls back to the stylesheet's inline style.
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
    if (!isBlock) return null; // inline code
    return _CodeBlock(code: code, language: language);
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
        color: dark ? const Color(0xFF282C34) : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
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
              textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13),
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
  final mono = theme.textTheme.bodyMedium?.copyWith(
    fontFamily: 'monospace',
    fontSize: 13,
  );
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: theme.textTheme.bodyMedium,
    code: mono?.copyWith(backgroundColor: cs.surfaceContainerHighest),
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
