/// The title-bar profile pill — and the switcher it opens.
///
/// Shown for **every** profile. It used to render nothing for the installed one,
/// which was right while profiles were invisible plumbing and wrong the moment
/// they became something the user chooses (SPEC-50): a single-profile user sees
/// one calm pill, and a multi-profile user is never left guessing which server a
/// window is talking to.
///
/// The colour is derived deterministically from the profile id, so the *same*
/// profile always gets the *same* hue — a quick cue for telling two windows apart
/// at a glance.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../status/status_event.dart';
import '../../status/status_providers.dart';
import '../daemon/server_profile.dart';
import '../desktop_app.dart' show serverProfileProvider;
import '../settings/sections/profile_switch_sheet.dart';
import '../settings/sections/profiles_providers.dart';

/// The title-bar profile badge, which opens the profile switcher.
class ServerProfileBadge extends ConsumerWidget {
  /// Creates the badge.
  const ServerProfileBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(serverProfileProvider);
    final color = hueForProfileId(profile.id);
    final controller = ref.watch(switcherProfilesProvider);
    final switcher = ref.watch(profileSwitcherProvider);
    // No profile wiring on this surface: show the label, not a dead menu.
    if (controller == null || switcher == null) {
      return _Pill(name: profile.name, color: color, tappable: false);
    }

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final rows = controller.rows.where((r) => !r.stale).toList();
        return PopupMenuButton<ServerProfile>(
          tooltip: 'Switch profile',
          position: PopupMenuPosition.under,
          // A one-profile user has nothing to switch to; keep the pill as a calm
          // label rather than a menu that opens onto a single dead row.
          enabled: rows.length > 1,
          onSelected: (target) => _switch(context, ref, profile, target),
          itemBuilder: (context) => [
            for (final row in rows)
              PopupMenuItem<ServerProfile>(
                value: row.profile,
                child: _MenuRow(
                  name: row.profile.name,
                  hue: hueForProfileId(row.profile.id),
                  running: row.running,
                  active: row.profile.id == profile.id,
                ),
              ),
          ],
          child: _Pill(
            name: profile.name,
            color: color,
            tappable: rows.length > 1,
          ),
        );
      },
    );
  }

  Future<void> _switch(
    BuildContext context,
    WidgetRef ref,
    ServerProfile from,
    ServerProfile target,
  ) async {
    if (target.id == from.id) return;
    final lifecycle = ref.read(profileLifecycleProvider);
    final switcher = ref.read(profileSwitcherProvider)!;
    // Captured before the awaits: `ref` throws once its widget is unmounted, and
    // the record must outlive the thing reporting to it.
    final status = ref.status;

    final running = await lifecycle.isRunning(target);
    if (!context.mounted) return;
    final ok = await confirmProfileSwitch(
      context,
      from: from,
      to: target,
      targetRunning: running,
    );
    if (!ok) return;

    final failure = await switcher(target);
    if (failure == null) {
      status.success(
        'Switched to ${target.name}',
        source: StatusSources.settings,
      );
    } else {
      status.failure(
        'Could not switch to ${target.name}',
        source: StatusSources.settings,
        detail: failure,
      );
    }
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.name,
    required this.color,
    required this.tappable,
  });

  final String name;
  final Color color;
  final bool tappable;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace8,
        vertical: kSpace2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(kRadius8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: kSpace6),
          Text(
            name,
            style: Theme.of(context).textTheme.labelXs?.copyWith(
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          if (tappable) ...[
            const SizedBox(width: kSpace2),
            Icon(Icons.expand_more, size: 12, color: color),
          ],
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.name,
    required this.hue,
    required this.running,
    required this.active,
  });

  final String name;
  final Color hue;
  final bool running;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: hue, shape: BoxShape.circle),
        ),
        const SizedBox(width: kSpace8),
        Expanded(
          child: Text(
            name,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
        if (!running)
          Text(
            'stopped',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        if (active)
          Padding(
            padding: const EdgeInsets.only(left: kSpace6),
            child: Icon(Icons.check, size: 14, color: cs.primary),
          ),
      ],
    );
  }
}

/// Maps a profile id to a stable, well-spaced hue.
///
/// Top-level so the Profiles list, the switcher menu and the switch sheet all
/// colour a profile identically — the colour is part of its identity, not
/// decoration private to the badge.
Color hueForProfileId(String id) {
  var h = 0;
  for (final c in id.codeUnits) {
    h = (h * 31 + c) & 0xffffff;
  }
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.6, 0.55).toColor();
}
