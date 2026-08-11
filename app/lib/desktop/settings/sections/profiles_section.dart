/// The Profiles settings section (SPEC-50 D7/D8/D9, mockup cards 4 & 5).
///
/// A list of every server profile with its live status, an inline detail view
/// per profile, and a "Stale — source folder is gone" group that only appears
/// when the registry holds orphaned dev profiles. Lifecycle (Start/Stop) and
/// deletion attach to a profile here, never to "the server" (D7): stopping the
/// server this window talks to is self-defeating, but stopping a profile you are
/// not using is an ordinary task.
///
/// The section owns no state the model does not: it reads a [ProfilesController]
/// (itself a thin observable over [ProfileRegistry]) and repaints on its
/// notifications. Colour comes from [hueForProfileId] so a profile's hue is
/// identical here, in the badge and in the switcher.
library;

import 'dart:io' show Platform, Process, ProcessException;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../app/theme.dart';
import '../../../status/status_event.dart';
import '../../../status/status_providers.dart';
import '../../chat/server_profile_badge.dart' show hueForProfileId;
import '../../daemon/profiles_controller.dart';
import '../../daemon/server_profile.dart';
import '../settings_item_anchor.dart';
import 'profile_delete_sheet.dart';
import 'profile_reclaim_sheet.dart';
import 'profiles_format.dart';
import 'profile_switch_sheet.dart';
import 'profiles_providers.dart';

/// The Profiles section body.
class ProfilesSection extends ConsumerStatefulWidget {
  /// Creates the Profiles section body.
  const ProfilesSection({super.key});

  @override
  ConsumerState<ProfilesSection> createState() => _ProfilesSectionState();
}

class _ProfilesSectionState extends ConsumerState<ProfilesSection> {
  /// The id of the profile whose inline detail is expanded, or null.
  String? _expanded;

  @override
  void initState() {
    super.initState();
    // Populate running-state and disk-size for the rows once on mount; the
    // controller notifies when the probes land.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(profilesControllerProvider).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(profilesControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final stale = controller.staleSummary;
        // Stale profiles are represented by the stale group below, so they are
        // deliberately excluded here. Listing them in both places showed each
        // one twice, and on a real machine (27 orphans measured) the dead
        // profiles crowded the live ones off the screen.
        //
        // The one exception is the ACTIVE profile: if it is stale it must stay
        // in the main list, because the reclaim group's deleter refuses the
        // active profile — only the main row's switch-away-&-delete can remove
        // it. `staleSummary` already omits the active profile to match.
        final rows = controller.rows
            .where(
              (r) => !r.stale || r.profile.id == controller.activeProfileId,
            )
            .toList();
        return ListView(
          children: [
            const SettingsSectionHeaderLike(title: 'Profiles'),
            // Anchors so a settings-search hit (profiles.list / .new / .delete)
            // scrolls to and highlights the list rather than merely opening the
            // section. Deletion has no standalone control — it lives in each
            // row's menu — so `profiles.delete` reveals the list it acts on.
            SettingsItemAnchor(
              itemId: 'profiles.delete',
              child: SettingsItemAnchor(
                itemId: 'profiles.list',
                child: _ProfilesGroup(
                  children: [
                    for (final row in rows)
                      _ProfileRow(
                        status: row,
                        activeProfileId: controller.activeProfileId,
                        expanded: _expanded == row.profile.id,
                        onToggle: () => setState(
                          () => _expanded = _expanded == row.profile.id
                              ? null
                              : row.profile.id,
                        ),
                      ),
                    const SettingsItemAnchor(
                      itemId: 'profiles.new',
                      child: _NewProfileRow(),
                    ),
                  ],
                ),
              ),
            ),
            if (stale.rows.isNotEmpty)
              SettingsItemAnchor(
                itemId: 'profiles.reclaim',
                child: _StaleGroup(rows: stale.rows, bytes: stale.bytes),
              ),
          ],
        );
      },
    );
  }
}

/// A local re-implementation of the section header idiom so the file needs no
/// dependency on the (concurrently edited) section_header.dart. Matches its
/// visual contract: UPPERCASE, accent-coloured, letter-spaced.
class SettingsSectionHeaderLike extends StatelessWidget {
  /// Creates a header for [title].
  const SettingsSectionHeaderLike({required this.title, super.key});

  /// The header text; rendered uppercase.
  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: cs.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// A rounded, filled card boxing profile rows (the grouped-list idiom).
class _ProfilesGroup extends StatelessWidget {
  const _ProfilesGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(kRadius12),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// One profile row (mockup card 4) with its inline detail (card 5).
class _ProfileRow extends ConsumerWidget {
  const _ProfileRow({
    required this.status,
    required this.activeProfileId,
    required this.expanded,
    required this.onToggle,
  });

  final ProfileStatus status;
  final String activeProfileId;
  final bool expanded;
  final VoidCallback onToggle;

  bool get _isActive => status.profile.id == activeProfileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final profile = status.profile;
    final hue = hueForProfileId(profile.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          onTap: onToggle,
          leading: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: hue, shape: BoxShape.circle),
          ),
          title: Row(
            children: [
              Flexible(child: Text(profile.name)),
              if (_isActive) const _Pill(label: 'active'),
              if (profile.kind == ProfileKind.dev)
                const _Pill(label: 'dev build'),
            ],
          ),
          subtitle: Text(
            _tildeHome(profile.home),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                formatProfileBytes(status.diskBytes),
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: kSpace12),
              Icon(
                PhosphorIconsFill.circle,
                size: 10,
                color: status.running ? cs.primary : cs.outline,
              ),
              const SizedBox(width: kSpace6),
              Text(
                status.running ? 'Running' : 'Stopped',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.outline),
              ),
              _ProfileMenu(
                status: status,
                isActive: _isActive,
                onDetail: onToggle,
              ),
            ],
          ),
        ),
        if (expanded) ...[
          const Divider(height: 1),
          _ProfileDetail(status: status, isActive: _isActive),
        ],
      ],
    );
  }
}

/// The overflow (⋯) menu. Delete is **absent** for a protected profile. For the
/// active profile it reads "Switch away & delete…" and runs that flow, because
/// [ProfileDeleter] refuses to delete the profile the window is using (D8).
class _ProfileMenu extends ConsumerWidget {
  const _ProfileMenu({
    required this.status,
    required this.isActive,
    required this.onDetail,
  });

  final ProfileStatus status;
  final bool isActive;
  final VoidCallback onDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = status.profile;
    return PopupMenuButton<String>(
      tooltip: 'Profile actions',
      icon: const Icon(PhosphorIconsLight.dotsThree, size: 20),
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'rename', child: Text('Rename…')),
        // Omitted for the active profile: stopping the daemon this window is
        // connected to would disconnect the UI (the file's own D7 contract),
        // and starting it is meaningless — it is already running.
        if (!isActive)
          PopupMenuItem(
            value: 'toggle',
            child: Text(status.running ? 'Stop' : 'Start'),
          ),
        const PopupMenuItem(value: 'reveal', child: Text('Reveal in Finder')),
        if (!profile.isProtected)
          // The active profile is refused by ProfileDeleter by design (D8), so
          // deleting it means switching away first. That is now one action
          // rather than a dead menu item.
          PopupMenuItem(
            value: 'delete',
            child: Text(isActive ? 'Switch away & delete…' : 'Delete…'),
          ),
      ],
      onSelected: (value) => _onSelected(context, ref, value),
    );
  }

  Future<void> _onSelected(
    BuildContext context,
    WidgetRef ref,
    String value,
  ) async {
    switch (value) {
      case 'rename':
        await promptRenameProfile(context, ref, status.profile);
      case 'toggle':
        await toggleProfileRunning(ref, status);
      case 'reveal':
        await revealInFinder(status.profile.home);
      case 'delete':
        if (!context.mounted) return;
        // ProfileDeleter refuses the ACTIVE profile by design (D8), so deleting
        // the one you are using means switching away first. Offering a menu item
        // that could only ever fail would be worse than offering none.
        if (isActive) {
          await switchAwayAndDelete(context, ref, status.profile);
        } else {
          await showProfileDeleteSheet(context, ref, status);
        }
    }
  }
}

/// The inline detail (mockup card 5): editable name, status + Start/Stop, data
/// path with total size, origin for dev profiles, and a danger zone.
class _ProfileDetail extends ConsumerWidget {
  const _ProfileDetail({required this.status, required this.isActive});

  final ProfileStatus status;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final profile = status.profile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(
            PhosphorIconsFill.circle,
            size: 12,
            color: status.running ? cs.primary : cs.outline,
          ),
          title: Text(status.running ? 'Running' : 'Stopped'),
          subtitle: Text(
            'port ${profile.port}',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          trailing: OutlinedButton.icon(
            // Disabled for the active profile: you never stop the server this
            // window talks to (D7), and it is already running.
            onPressed: isActive
                ? null
                : () => toggleProfileRunning(ref, status),
            icon: Icon(
              status.running
                  ? PhosphorIconsLight.stop
                  : PhosphorIconsLight.play,
              size: 18,
            ),
            label: Text(status.running ? 'Stop' : 'Start'),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          leading: Icon(PhosphorIconsLight.folder, color: cs.outline),
          title: const Text('Data'),
          subtitle: Text(
            '${_tildeHome(profile.home)} · ${formatProfileBytes(status.diskBytes)}',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          trailing: TextButton(
            onPressed: () => revealInFinder(profile.home),
            child: const Text('Reveal'),
          ),
        ),
        if (profile.kind == ProfileKind.dev && profile.origin != null) ...[
          const Divider(height: 1),
          ListTile(
            leading: Icon(PhosphorIconsLight.cube, color: cs.outline),
            title: const Text('Created from'),
            subtitle: Text(
              _tildeHome(profile.origin!),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
        if (!profile.isProtected)
          _DangerZone(status: status, isActive: isActive),
      ],
    );
  }
}

/// The delete row. Present only for a non-protected profile. For the active
/// profile the button reads “Switch away & delete…” and runs that flow (a
/// profile cannot be deleted from under itself), matching the overflow menu.
class _DangerZone extends ConsumerWidget {
  const _DangerZone({required this.status, required this.isActive});

  final ProfileStatus status;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final deleteButton = OutlinedButton(
      style: OutlinedButton.styleFrom(foregroundColor: cs.error),
      onPressed: isActive
          ? () => switchAwayAndDelete(context, ref, status.profile)
          : () => showProfileDeleteSheet(context, ref, status),
      child: Text(isActive ? 'Switch away & delete…' : 'Delete…'),
    );
    return Container(
      color: cs.errorContainer.withValues(alpha: 0.25),
      child: ListTile(
        leading: Icon(PhosphorIconsLight.trash, color: cs.error),
        title: Text('Delete profile', style: TextStyle(color: cs.error)),
        subtitle: const Text(
          'Removes this profile’s server state. Your code is untouched.',
        ),
        trailing: isActive
            ? Tooltip(
                message:
                    'Deleting the active profile switches away from it first, '
                    'because a profile cannot be deleted from under itself.',
                child: deleteButton,
              )
            : deleteButton,
      ),
    );
  }
}

/// A small pill (active / dev build), matching the badge idiom.
class _Pill extends StatelessWidget {
  const _Pill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: kSpace6),
      padding: const EdgeInsets.symmetric(horizontal: kSpace6, vertical: 1),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(kRadius6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelXs?.copyWith(color: cs.outline),
      ),
    );
  }
}

/// The "New profile" action row: prompts for a name and calls `create`.
class _NewProfileRow extends ConsumerWidget {
  const _NewProfileRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(PhosphorIconsLight.plus, color: cs.primary),
      title: Text('New profile', style: TextStyle(color: cs.primary)),
      onTap: () => promptCreateProfile(context, ref),
    );
  }
}

/// The stale-profile group (mockup card 4, lower). Only rendered when something
/// is stale; the count is the headline, the total size the subtext.
class _StaleGroup extends ConsumerWidget {
  const _StaleGroup({required this.rows, required this.bytes});

  final List<ProfileStatus> rows;
  final int bytes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final count = rows.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeaderLike(title: 'Stale — source folder is gone'),
        _ProfilesGroup(
          children: [
            ListTile(
              leading: Icon(PhosphorIconsLight.warning, color: cs.error),
              title: Text(
                '$count orphaned dev ${count == 1 ? 'profile' : 'profiles'}',
              ),
              subtitle: Text(
                'Their worktrees no longer exist. ${formatProfileBytes(bytes)}.',
              ),
              trailing: OutlinedButton(
                onPressed: () => showProfileReclaimSheet(context, ref, rows),
                child: const Text('Review…'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Prompts for a new profile name and creates it, reporting the outcome.
Future<void> promptCreateProfile(BuildContext context, WidgetRef ref) async {
  final statusCenter = ref.status;
  final controller = ref.read(profilesControllerProvider);
  final name = await _promptForName(context, title: 'New profile');
  if (name == null) return;
  final created = await controller.create(name);
  if (created == null) {
    statusCenter.failure(
      'Could not create profile',
      source: StatusSources.settings,
      detail: 'A profile needs a non-blank name.',
    );
  } else {
    statusCenter.success(
      'Created ${created.name}',
      source: StatusSources.settings,
    );
  }
}

/// Prompts for a new name and renames [profile], reporting the outcome.
Future<void> promptRenameProfile(
  BuildContext context,
  WidgetRef ref,
  ServerProfile profile,
) async {
  final statusCenter = ref.status;
  final controller = ref.read(profilesControllerProvider);
  final name = await _promptForName(
    context,
    title: 'Rename profile',
    initial: profile.name,
  );
  if (name == null) return;
  if (!controller.rename(profile.id, name)) {
    statusCenter.failure(
      'Could not rename profile',
      source: StatusSources.settings,
      detail: 'A profile needs a non-blank name.',
    );
  }
}

/// Starts or stops [status]'s daemon and reports the outcome, updating the row.
Future<void> toggleProfileRunning(WidgetRef ref, ProfileStatus status) async {
  final statusCenter = ref.status;
  final controller = ref.read(profilesControllerProvider);
  final lifecycle = ref.read(profileLifecycleProvider);
  final profile = status.profile;
  final result = status.running
      ? await lifecycle.stop(profile)
      : await lifecycle.start(profile);
  if (result.ok) {
    controller.noteRunning(profile.id, running: !status.running);
    statusCenter.success(
      status.running ? 'Stopped ${profile.name}' : 'Started ${profile.name}',
      source: StatusSources.settings,
    );
  } else {
    statusCenter.failure(
      status.running
          ? 'Could not stop ${profile.name}'
          : 'Could not start ${profile.name}',
      source: StatusSources.settings,
      detail: result.message,
    );
  }
}

/// Opens [home] in the macOS Finder, best effort. A no-op off macOS, and it
/// swallows a spawn failure rather than surfacing an error for a convenience.
Future<void> revealInFinder(String home) async {
  if (!Platform.isMacOS) return;
  try {
    await Process.run('open', [home]);
  } on ProcessException {
    // Best effort: revealing a folder is not worth an error banner.
  }
}

/// A minimal single-field name prompt. Returns the trimmed name, or null on
/// cancel / blank.
Future<String?> _promptForName(
  BuildContext context, {
  required String title,
  String? initial,
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (context) => _NamePromptDialog(title: title, initial: initial),
  );
  if (result == null || result.isEmpty) return null;
  return result;
}

/// The name prompt body. Owns its [TextEditingController] so it is disposed only
/// after the dialog's exit animation, never while the field is still rebuilding.
class _NamePromptDialog extends StatefulWidget {
  const _NamePromptDialog({required this.title, this.initial});

  final String title;
  final String? initial;

  @override
  State<_NamePromptDialog> createState() => _NamePromptDialogState();
}

class _NamePromptDialogState extends State<_NamePromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Name',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

/// Abbreviates a leading `$HOME` to `~`, matching the mockup's `~/.makit`.
String _tildeHome(String path) {
  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty && path.startsWith(home)) {
    return '~${path.substring(home.length)}';
  }
  return path;
}

/// Switches away from [victim] and then deletes it.
///
/// `ProfileDeleter` refuses the active profile (SPEC-50 D8) — a profile cannot be
/// deleted from under the window using it — so this picks another profile, hands
/// the window over, and lets the host delete the old one from the *new* runtime,
/// where it is no longer active. Both steps are confirmed: the switch sheet
/// first, then the delete sheet's own consequences are folded into it, because
/// two modal sheets in a row for one intent is worse UX than one honest one.
Future<void> switchAwayAndDelete(
  BuildContext context,
  WidgetRef ref,
  ServerProfile victim,
) async {
  final controller = ref.read(profilesControllerProvider);
  final switcher = ref.read(profileSwitcherProvider);
  final status = ref.status;

  if (switcher == null) {
    status.failure(
      'Cannot delete the active profile',
      source: StatusSources.settings,
      detail: 'Profile switching is not available on this surface.',
    );
    return;
  }

  // Prefer the protected/installed profile as the place to land: it always
  // exists and can never itself be deleted.
  final candidates =
      controller.rows
          .where((r) => r.profile.id != victim.id && !r.stale)
          .toList()
        // A total order: protected profiles first, then stable by name. A
        // comparator returning -1 for `isProtected` on both sides breaks the
        // contract and leaves the order unspecified.
        ..sort((a, b) {
          final byProtected = (a.profile.isProtected ? 0 : 1).compareTo(
            b.profile.isProtected ? 0 : 1,
          );
          if (byProtected != 0) return byProtected;
          return a.profile.name.toLowerCase().compareTo(
            b.profile.name.toLowerCase(),
          );
        });
  if (candidates.isEmpty) {
    status.failure(
      'Cannot delete the only profile',
      source: StatusSources.settings,
      detail: 'Create another profile first, then switch to it.',
    );
    return;
  }
  final target = candidates.first.profile;

  final ok = await confirmSwitchAwayAndDelete(
    context,
    victim: victim,
    target: target,
  );
  if (!ok) return;

  final result = await switcher(target, deleteAfter: victim);
  if (result.switchFailure != null) {
    // The switch itself failed, so nothing changed and the victim is untouched.
    status.failure(
      'Could not switch to ${target.name}',
      source: StatusSources.settings,
      detail: result.switchFailure,
    );
  } else if (result.deleteFailure != null) {
    // The switch succeeded; only the delete failed — report that honestly rather
    // than claiming the whole operation failed.
    status.failure(
      'Switched to ${target.name}, but could not delete ${victim.name}',
      source: StatusSources.settings,
      detail: result.deleteFailure,
    );
  } else {
    status.success(
      'Deleted ${victim.name} and switched to ${target.name}',
      source: StatusSources.settings,
    );
  }
}
