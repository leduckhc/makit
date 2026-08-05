/// The one place that decides WHERE the pending queue renders (SPEC-36).
///
/// Both surfaces mount this twice — once in the composer column, once in the
/// transcript's trailer row — passing which [slot] that instance is. Exactly one
/// of them renders, so the placement rule lives here instead of being duplicated
/// across four call sites (mobile + desktop × two slots) where it could drift.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/prefs/preferences_providers.dart';
import '../../store/store.dart';
import 'pending_queue.dart';
import 'pending_queue_tray.dart';

/// Whether the inline (in-transcript) queue has anything to show for [sessionId].
///
/// The transcript needs this *before* it builds rows: the trailer row occupies
/// index 0 of the reversed list, and `transcriptChildIndexFinder` shifts every
/// other index by it (SPEC-21/34). An inline queue must therefore be counted in
/// `hasTrailer`, or the trailer would vanish the moment the agent goes idle with
/// messages still pending.
final inlineQueueVisibleProvider = Provider.family<bool, String>((
  ref,
  sessionId,
) {
  if (ref.watch(pendingQueuePlacementProvider) !=
      PendingQueuePlacement.inline) {
    return false;
  }
  return ref.watch(queuedMessagesProvider(sessionId)).isNotEmpty;
});

/// Renders the session's pending queue when the user's placement preference
/// matches this instance's [slot]; builds nothing otherwise.
class PendingQueueSlot extends ConsumerWidget {
  /// Creates a placement-gated queue slot.
  const PendingQueueSlot({
    super.key,
    required this.sessionId,
    required this.slot,
  });

  /// The session whose queue this slot would show.
  final String sessionId;

  /// Which placement this mount point represents.
  final PendingQueuePlacement slot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Compare mount points, not placements: `tray` renders in the `pinned`
    // slot, so a slot must ask "does the chosen placement live HERE", not "is it
    // literally me".
    final placement = ref.watch(pendingQueuePlacementProvider);
    if (placement.mountPoint != slot) return const SizedBox.shrink();
    final queued = ref.watch(queuedMessagesProvider(sessionId));
    if (queued.isEmpty) return const SizedBox.shrink();

    final store = ref.read(storeControllerProvider.notifier);
    if (placement == PendingQueuePlacement.tray) {
      return PendingQueueTray(
        queued: queued,
        commands: ref.watch(commandsProvider(sessionId)),
        onEdit: (id, text) => store.updateQueuedMessage(sessionId, id, text),
        onReorder: (ids) => store.reorderQueuedMessages(sessionId, ids),
        onCancel: (id) => store.cancelQueuedMessage(sessionId, id),
        onPromote: (id) => store.promoteQueuedMessage(sessionId, id),
      );
    }
    return PendingQueue(
      queued: queued,
      commands: ref.watch(commandsProvider(sessionId)),
      onEdit: (id, text) => store.updateQueuedMessage(sessionId, id, text),
      onReorder: (ids) => store.reorderQueuedMessages(sessionId, ids),
      onCancel: (id) => store.cancelQueuedMessage(sessionId, id),
    );
  }
}
