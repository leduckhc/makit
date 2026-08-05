/// The one place that decides WHERE the pending queue renders (SPEC-38).
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
    // Both placements live in this one mount point (above the composer), so the
    // slot only decides WHICH of them renders.
    final placement = ref.watch(pendingQueuePlacementProvider);
    if (placement != slot) return const SizedBox.shrink();
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
      onPromote: (id) => store.promoteQueuedMessage(sessionId, id),
    );
  }
}
