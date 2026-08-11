/// The profile delete confirmation sheet (SPEC-50 D8, mockup card 6).
///
/// The most important widget in the Profiles section: it enumerates **what will
/// be deleted** and, just as prominently, **what will be kept**. The kept half
/// is what makes the destructive button usable — the word "delete" next to a
/// path that sits beside a worktree reads as "deletes my branch", and one line
/// removes that fear.
///
/// The confirm wires to [ProfileDeleter], then reflects its
/// [ProfileDeletionResult] honestly: on refusal it surfaces the reason from
/// `skipped`; on success it reports the bytes freed **and** the stores that were
/// skipped (for example the secure-store file on a platform that has none),
/// never hiding them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../app/theme.dart';
import '../../../status/status_event.dart';
import '../../../status/status_providers.dart';
import '../../daemon/profiles_controller.dart';
import 'profiles_format.dart';
import 'profiles_providers.dart';

/// Shows the delete sheet for [status], then performs and reports the deletion.
///
/// Returns once the flow settles. Captures `ref.status` before the first await
/// (`ref` throws once unmounted) and repaints the list via
/// [ProfilesController.refresh] after a successful delete, because the deleter
/// removes the registry entry directly and the controller must be told to
/// re-read.
Future<void> showProfileDeleteSheet(
  BuildContext context,
  WidgetRef ref,
  ProfileStatus status,
) async {
  final statusCenter = ref.status;
  final deleter = ref.read(profileDeleterProvider);
  final controller = ref.read(profilesControllerProvider);
  final profile = status.profile;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => _ProfileDeleteDialog(
      name: profile.name,
      prefsKeyPrefix: profile.prefsKeyPrefix,
      diskBytes: status.diskBytes,
      running: status.running,
    ),
  );
  if (confirmed != true) return;

  // `ProfileDeleter.delete` is best-effort and reports store failures in its
  // result, but an unexpected throw must still surface an outcome rather than
  // vanish into an unhandled async gap that leaves the list stale.
  try {
    final result = await deleter.delete(profile);
    if (result.ok) {
      await controller.refresh();
      final freed = formatProfileBytes(result.bytesFreed);
      final skipped = result.skipped.isEmpty
          ? null
          : 'Freed $freed. Not purged: ${result.skipped.join(' — ')}';
      statusCenter.success(
        'Deleted ${profile.name}',
        source: StatusSources.settings,
        detail: skipped ?? 'Freed $freed.',
      );
    } else {
      statusCenter.failure(
        'Could not delete ${profile.name}',
        source: StatusSources.settings,
        detail: result.skipped.join(' — '),
      );
    }
  } catch (error) {
    await controller.refresh();
    statusCenter.failure(
      'Could not delete ${profile.name}',
      source: StatusSources.settings,
      detail: error.toString(),
    );
  }
}

/// The sheet body. Pure UI: it returns `true` from the navigator only when the
/// user confirms, and knows nothing about the deleter.
class _ProfileDeleteDialog extends StatelessWidget {
  const _ProfileDeleteDialog({
    required this.name,
    required this.prefsKeyPrefix,
    required this.diskBytes,
    required this.running,
  });

  final String name;
  final String prefsKeyPrefix;
  final int? diskBytes;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('Delete “$name”?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('This removes makit’s state for this profile only.'),
              const SizedBox(height: kSpace16),
              _SectionLabel(
                label: 'Will be deleted',
                trailing: formatProfileBytes(diskBytes),
                color: cs.error,
              ),
              const _DeletedItem('makit.db', 'sessions & transcripts'),
              const _DeletedItem('media/', 'ingested images'),
              const _DeletedItem('devices.json', 'paired devices'),
              const _DeletedItem('projects.json', 'projects'),
              const _DeletedItem(
                'server.crt / .key',
                'this profile’s TLS identity',
              ),
              const _DeletedItem('keychain / secure store', 'pairing bearer'),
              // Genuinely deleted now: prefs are scoped by key prefix, so the
              // deleter can purge another profile's keys (the sheet used to carry
              // a caveat here, from when the global setPrefix made them
              // unreachable).
              _DeletedItem('prefs', 'flutter.$prefsKeyPrefix* keys'),
              const _DeletedItem('profiles.json', 'registry entry'),
              const SizedBox(height: kSpace16),
              _SectionLabel(label: 'Will be kept', color: cs.primary),
              const _KeptItem(
                'your code',
                'worktrees and repos are never touched',
              ),
              const _KeptItem(
                'other profiles',
                'every other profile is unaffected',
              ),
              if (running) ...[
                const SizedBox(height: kSpace12),
                Text(
                  'The daemon is running and will be stopped before removal.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: cs.outline),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: cs.error),
          onPressed: () => Navigator.of(context).pop(true),
          icon: const Icon(PhosphorIconsLight.trash, size: 18),
          label: const Text('Delete profile'),
        ),
      ],
    );
  }
}

/// A "Will be deleted" / "Will be kept" heading, optionally with a trailing size.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.label,
    required this.color,
    this.trailing,
  });

  final String label;
  final Color color;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: color,
      fontWeight: FontWeight.w700,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: kSpace8),
      child: Row(
        children: [
          Expanded(child: Text(label.toUpperCase(), style: style)),
          if (trailing != null)
            Text(
              trailing!,
              style: style?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}

class _DeletedItem extends StatelessWidget {
  const _DeletedItem(this.key_, this.detail);

  final String key_;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kSpace2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              key_,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            ),
          ),
          Expanded(
            child: Text(
              detail,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.outline),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeptItem extends StatelessWidget {
  const _KeptItem(this.key_, this.detail);

  final String key_;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kSpace2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(PhosphorIconsLight.check, size: 15, color: cs.primary),
          const SizedBox(width: kSpace8),
          SizedBox(
            width: 110,
            child: Text(
              key_,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
            ),
          ),
          Expanded(
            child: Text(
              detail,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.outline),
            ),
          ),
        ],
      ),
    );
  }
}
