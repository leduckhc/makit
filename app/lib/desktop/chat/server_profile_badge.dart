/// A small colored pill naming the server profile this window runs against
/// (e.g. `main` vs a worktree). Renders nothing for the default (installed)
/// profile — shipped users have a single server and don't need the noise.
///
/// The color is derived deterministically from the profile id so the *same*
/// build always gets the *same* hue: a quick visual cue to tell a `main` window
/// apart from a worktree window at a glance.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop_app.dart' show serverProfileProvider;

/// The title-bar profile badge. Reads [serverProfileProvider].
class ServerProfileBadge extends ConsumerWidget {
  /// Creates the badge.
  const ServerProfileBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(serverProfileProvider);
    if (profile.isDefault) return const SizedBox.shrink();

    final color = _hueFor(profile.id);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
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
          const SizedBox(width: 6),
          Text(
            profile.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  /// Maps a profile id to a stable, well-spaced hue.
  static Color _hueFor(String id) {
    var h = 0;
    for (final c in id.codeUnits) {
      h = (h * 31 + c) & 0xffffff;
    }
    return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.6, 0.55).toColor();
  }
}
