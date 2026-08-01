/// Mobile's way back to your own messages: a sheet listing them, reached from
/// the session-actions menu (SPEC-34).
///
/// Mobile takes this route rather than one of the five transcript-overlay styles
/// because none of them suits a thumb: they are pointer designs, and a phone has
/// no screen to spend on permanent chrome. (An edge-drag "scrubber" style was
/// built for exactly this and then removed — it asked a thumb to land on one of
/// N markers ~18pt apart, on the edge iOS reserves for swipe-back, under the
/// finger driving it.) A sheet is the platform's own idiom for "pick from a
/// list", costs no permanent screen furniture, and needs no settings to explain
/// it — which is why mobile has no navigator preferences at all.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../app/theme.dart';
import '../../../store/chat_items.dart';
import '../../../store/store.dart';
import 'transcript_jumper.dart';
import 'user_message_indices.dart';

/// Opens the "My messages" sheet for [sessionId].
///
/// Tapping an entry jumps the transcript and dismisses — so the jumper's landing
/// flash is what tells the user where they ended up once the sheet is gone.
Future<void> showMyMessagesSheet({
  required BuildContext context,
  required String sessionId,
  required TranscriptJumper jumper,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => _MyMessagesSheet(
      sessionId: sessionId,
      onPick: (position) {
        Navigator.of(sheetContext).pop();
        // The jumper's own `onFlash` records the landing highlight — doing it
        // here too would double-arm it.
        jumper.jumpToItem(position);
      },
    ),
  );
}

class _MyMessagesSheet extends ConsumerWidget {
  const _MyMessagesSheet({required this.sessionId, required this.onPick});

  final String sessionId;
  final void Function(int position) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(chatItemsProvider(sessionId));
    final positions = userMessagePositions(items);
    final scheme = Theme.of(context).colorScheme;
    final total = positions.length;

    return SafeArea(
      child: ConstrainedBox(
        // Tall enough to be worth opening, short enough to keep the transcript
        // visible behind it.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kSpace16,
                0,
                kSpace16,
                kSpace8,
              ),
              child: Text(
                'My messages',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (total == 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  kSpace16,
                  0,
                  kSpace16,
                  kSpace16,
                ),
                child: Text(
                  "You haven't sent anything in this session yet.",
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: scheme.outline),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: kSpace8),
                  itemCount: total,
                  // Newest first: the thing you just asked is the thing you are
                  // most likely looking for.
                  itemBuilder: (context, i) {
                    final index = total - 1 - i;
                    final position = positions[index];
                    final item = items[position] as UserMessageItem;
                    return Semantics(
                      button: true,
                      label: 'your message ${index + 1} of $total',
                      excludeSemantics: true,
                      onTap: () => onPick(position),
                      child: ListTile(
                        dense: true,
                        leading: Text(
                          '${index + 1}',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: scheme.outline,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                        ),
                        title: Text(
                          item.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Icon(
                          PhosphorIconsLight.arrowUpRight,
                          size: 16,
                          color: scheme.outline,
                        ),
                        onTap: () => onPick(position),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
