/// The pending-queue placement setting (SPEC-36) — shared by both surfaces.
///
/// One control, one blurb, one place to change the copy: desktop mounts it in
/// Settings › Agents & Chat, the phone in its own settings list. There is
/// deliberately no `off` value — a pending message must always be visible
/// somewhere, or it would be waiting to send with no way to see or cancel it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../store/prefs/preference_entries.dart';
import '../../store/prefs/preferences_providers.dart';
import '../composer/pending_queue.dart';

/// A labelled segmented control bound to [pendingQueuePlacementPreference].
class PendingQueuePlacementSetting extends ConsumerWidget {
  /// Creates the placement setting row.
  const PendingQueuePlacementSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placement = ref.watch(pendingQueuePlacementProvider);
    final controller = ref.read(preferencesControllerProvider.notifier);
    return ListTile(
      title: const Text('Messages waiting to send'),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: kSpace4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Where a message you sent while the agent was busy waits. In the '
              'transcript it sits in the conversation and scrolls away with it; '
              'above the composer it stays put. The compact tray trades the '
              'conversation look for a work list — and is the only one that can '
              'stop the current turn to send a waiting message now.',
            ),
            const SizedBox(height: kSpace8),
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<PendingQueuePlacement>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: PendingQueuePlacement.pinned,
                    label: Text('Above the composer'),
                  ),
                  ButtonSegment(
                    value: PendingQueuePlacement.inline,
                    label: Text('In the transcript'),
                  ),
                  ButtonSegment(
                    value: PendingQueuePlacement.tray,
                    label: Text('Compact tray'),
                  ),
                ],
                selected: {placement},
                onSelectionChanged: (picked) => controller.set(
                  pendingQueuePlacementPreference,
                  picked.first,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
