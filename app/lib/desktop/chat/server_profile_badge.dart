/// A small coloured pill naming the server profile this window runs against
/// (e.g. `Work` vs a worktree), shown for **every** profile.
///
/// It used to render nothing for the installed profile, which was right while
/// profiles were invisible plumbing and wrong the moment they became something
/// the user chooses (SPEC-50): a single-profile user sees one calm pill, and a
/// multi-profile user is never left guessing which server a window talks to.
///
/// The colour is derived deterministically from the profile id so the *same*
/// profile always gets the *same* hue: a quick visual cue to tell one window
/// from another at a glance.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../desktop_app.dart' show serverProfileProvider;

/// The title-bar profile badge. Reads [serverProfileProvider].
class ServerProfileBadge extends ConsumerWidget {
  /// Creates the badge.
  const ServerProfileBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(serverProfileProvider);
    final color = hueForProfileId(profile.id);
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
            profile.name,
            style: Theme.of(context).textTheme.labelXs?.copyWith(
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Maps a profile id to a stable, well-spaced hue.
///
/// Top-level so the Profiles list and the switcher menu can colour their rows
/// identically — the colour is part of a profile's identity, not decoration
/// private to the badge.
Color hueForProfileId(String id) {
  var h = 0;
  for (final c in id.codeUnits) {
    h = (h * 31 + c) & 0xffffff;
  }
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.6, 0.55).toColor();
}
