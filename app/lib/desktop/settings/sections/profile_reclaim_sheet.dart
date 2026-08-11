/// The stale-profile reclaim sheet (SPEC-50 D9, mockup card 7).
///
/// Orphans are **offered, never reaped** (D9): a dev profile whose origin folder
/// is gone is listed with its size, selectable, and deletable in bulk — but a
/// human always presses the button. Auto-deletion is rejected because it would
/// have destroyed transcripts the first time a worktree moved.
///
/// The bulk delete runs [ProfileDeleter] once per selected profile and reports a
/// single combined outcome (count deleted, bytes freed, and any refusals).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../app/theme.dart';
import '../../../status/status_event.dart';
import '../../../status/status_providers.dart';
import '../../daemon/profiles_controller.dart';
import '../../daemon/server_profile.dart';
import 'profiles_format.dart';
import 'profiles_providers.dart';

/// Shows the reclaim sheet over [staleRows], then deletes the chosen profiles.
Future<void> showProfileReclaimSheet(
  BuildContext context,
  WidgetRef ref,
  List<ProfileStatus> staleRows,
) async {
  final statusCenter = ref.status;
  final deleter = ref.read(profileDeleterProvider);
  final controller = ref.read(profilesControllerProvider);

  final chosen = await showDialog<List<ServerProfile>>(
    context: context,
    builder: (_) => _ReclaimDialog(rows: staleRows),
  );
  if (chosen == null || chosen.isEmpty) return;

  var deleted = 0;
  var bytesFreed = 0;
  final refusals = <String>[];
  for (final profile in chosen) {
    final result = await deleter.delete(profile);
    if (result.ok) {
      deleted++;
      bytesFreed += result.bytesFreed;
    } else {
      refusals.add('${profile.name}: ${result.skipped.join(' — ')}');
    }
  }
  await controller.refresh();

  final freed = formatProfileBytes(bytesFreed);
  if (refusals.isEmpty) {
    statusCenter.success(
      'Deleted $deleted stale ${deleted == 1 ? 'profile' : 'profiles'}',
      source: StatusSources.settings,
      detail: 'Freed $freed.',
    );
  } else {
    statusCenter.failure(
      'Deleted $deleted of ${chosen.length} stale profiles',
      source: StatusSources.settings,
      detail: 'Freed $freed. Refused: ${refusals.join('; ')}',
    );
  }
}

/// The checkbox list. Returns the selected profiles from the navigator.
class _ReclaimDialog extends StatefulWidget {
  const _ReclaimDialog({required this.rows});

  final List<ProfileStatus> rows;

  @override
  State<_ReclaimDialog> createState() => _ReclaimDialogState();
}

class _ReclaimDialogState extends State<_ReclaimDialog> {
  late final Set<String> _selected = {
    for (final r in widget.rows) r.profile.id,
  };

  int get _selectedBytes {
    var total = 0;
    for (final r in widget.rows) {
      if (_selected.contains(r.profile.id)) total += r.diskBytes ?? 0;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final count = _selected.length;
    return AlertDialog(
      title: const Text('Stale profiles'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'These dev profiles were created from folders that no longer '
              'exist.',
            ),
            const SizedBox(height: kSpace12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final r in widget.rows)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _selected.contains(r.profile.id),
                        onChanged: (on) => setState(() {
                          if (on ?? false) {
                            _selected.add(r.profile.id);
                          } else {
                            _selected.remove(r.profile.id);
                          }
                        }),
                        title: Text(
                          r.profile.name,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        subtitle: const Text('folder gone'),
                        secondary: Text(
                          formatProfileBytes(r.diskBytes),
                          style: const TextStyle(
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$count ${count == 1 ? 'profile' : 'profiles'} selected',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  formatProfileBytes(_selectedBytes),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(<ServerProfile>[]),
          child: const Text('Keep all'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: cs.error),
          onPressed: count == 0
              ? null
              : () => Navigator.of(context).pop([
                  for (final r in widget.rows)
                    if (_selected.contains(r.profile.id)) r.profile,
                ]),
          icon: const Icon(PhosphorIconsLight.trash, size: 18),
          label: Text('Delete $count ${count == 1 ? 'profile' : 'profiles'}'),
        ),
      ],
    );
  }
}
