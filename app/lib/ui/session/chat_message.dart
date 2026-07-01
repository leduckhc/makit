import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

/// The user's own messages — right-aligned coloured bubble.
class ChatBubble extends StatelessWidget {
  const ChatBubble.user({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: cs.primary,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(14),
              topRight: Radius.circular(14),
              bottomLeft: Radius.circular(14),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: SelectableText(text, style: TextStyle(color: cs.onPrimary)),
        ),
      ),
    );
  }
}

/// Assistant output — full-width, no bubble, markdown-rendered.
class AgentMessage extends StatelessWidget {
  const AgentMessage({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: MarkdownBody(
        data: text,
        selectable: true,
        styleSheet: _styleSheet(context),
      ),
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
    code: mono?.copyWith(
      backgroundColor: cs.surfaceContainerHighest,
    ),
    codeblockDecoration: BoxDecoration(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    codeblockPadding: const EdgeInsets.all(12),
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
