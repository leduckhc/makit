import 'package:flutter/material.dart';

class ChatBubble extends StatelessWidget {
  const ChatBubble._({required this.text, required this.isUser});
  const ChatBubble.user({required String text}) : this._(text: text, isUser: true);
  const ChatBubble.agent({required String text}) : this._(text: text, isUser: false);

  final String text;
  final bool isUser;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = isUser ? cs.primary : cs.surfaceContainerHigh;
    final fg = isUser ? cs.onPrimary : cs.onSurface;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(14),
              topRight: const Radius.circular(14),
              bottomLeft: Radius.circular(isUser ? 14 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 14),
            ),
          ),
          child: SelectableText(
            text,
            style: TextStyle(color: fg),
          ),
        ),
      ),
    );
  }
}
