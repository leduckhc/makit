/// SPEC-ports-global-view P2a — the session-tile ports glyph (D14).
///
/// A quieter sibling of the worktree row glyph: it renders only for a port
/// whose process tree belongs to *this* session, drops the attention dot (the
/// row already carries attention), and opens the same per-worktree ports
/// surface on tap. App-only — `sessionId` is already on the wire.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../store/ports.dart';
import '../../store/store.dart';
import 'ports_filter.dart';
import 'ports_glyph.dart';
import 'worktree_ports_sheet.dart';

/// The trailing ports glyph for a session tile. Renders nothing unless a port
/// in the latest snapshot is attributed to [sessionId].
class SessionPortsGlyph extends ConsumerWidget {
  const SessionPortsGlyph({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ports = portsForSession(ref.watch(portsProvider), sessionId);
    if (ports.isEmpty) return const SizedBox.shrink();

    // Quiet by design (D14): the row glyph owns attention/unknown, so the tile
    // glyph shows only serving vs exposed — and even the exposed dot is dropped
    // via [PortsGlyph.showBadge] false.
    final state = ports.any((p) => p.reach == PortReach.exposed)
        ? PortsGlyphState.exposed
        : PortsGlyphState.serving;

    final worktreePath = ports.first.worktreePath;
    final branch = worktreePath == null
        ? null
        : ref
              .watch(reposProvider)
              .locateWorktree(worktreePath)
              ?.worktree
              .branch;

    return Padding(
      padding: const EdgeInsets.only(right: kSpace8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: worktreePath == null
            ? null
            : () => showWorktreePortsSheet(
                context,
                worktreePath: worktreePath,
                branch: branch ?? 'detached',
              ),
        child: PortsGlyph(state: state, count: ports.length, showBadge: false),
      ),
    );
  }
}
