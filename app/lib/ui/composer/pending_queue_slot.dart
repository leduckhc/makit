/// The one place that decides HOW the pending queue renders (SPEC-37/38).
///
/// There is exactly ONE mount point — above the composer — since SPEC-37 removed
/// the in-transcript placement. So this widget takes no slot argument: it reads
/// the preference and builds the presentation it names, and the two surfaces
/// (mobile session screen, desktop chat pane) mount it once each.
///
/// It used to take a `slot` and compare it against the preference. That let the
/// tests mount a combination of slots the app does not have — they stayed green
/// while the tray never rendered in the running app, because the composer only
/// ever mounted the `pinned` slot. A parameter that can disagree with reality is
/// a parameter worth deleting.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/prefs/preferences_providers.dart';
import '../../store/store.dart';
import 'pending_queue.dart';
import 'pending_queue_tray.dart';

/// Renders this session's pending messages in the presentation the user chose,
/// or nothing when the queue is empty.
class PendingQueueSlot extends ConsumerWidget {
  /// Creates the queue mount point.
  const PendingQueueSlot({super.key, required this.sessionId});

  /// The session whose queue this shows.
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queued = ref.watch(queuedMessagesProvider(sessionId));
    if (queued.isEmpty) return const SizedBox.shrink();

    final placement = ref.watch(pendingQueuePlacementProvider);
    final commands = ref.watch(commandsProvider(sessionId));
    final store = ref.read(storeControllerProvider.notifier);

    void edit(String id, String text) =>
        store.updateQueuedMessage(sessionId, id, text);
    void reorder(List<String> ids) =>
        store.reorderQueuedMessages(sessionId, ids);
    void cancel(String id) => store.cancelQueuedMessage(sessionId, id);
    void promote(String id) => store.promoteQueuedMessage(sessionId, id);

    return switch (placement) {
      PendingQueuePlacement.tray => PendingQueueTray(
        queued: queued,
        commands: commands,
        onEdit: edit,
        onReorder: reorder,
        onCancel: cancel,
        onPromote: promote,
      ),
      PendingQueuePlacement.pinned => PendingQueue(
        queued: queued,
        commands: commands,
        onEdit: edit,
        onReorder: reorder,
        onCancel: cancel,
        onPromote: promote,
      ),
    };
  }
}
