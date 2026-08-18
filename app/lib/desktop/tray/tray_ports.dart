/// The menubar's ports vocabulary (SPEC-ports-global-view P2c, D15) — pure, so the tray's
/// content is testable without an OS tray.
///
/// D15 is the whole design: the menubar renders the app's **last cached**
/// snapshot and never arms the scanner. That is why this file takes a
/// [PortsSnapshot]` ?` and answers nothing at all for null — before some surface
/// holds a ports watch there is no snapshot, and "no snapshot" is not the same
/// fact as "nothing listening".
library;

import '../../store/ports.dart';
import '../../store/store.dart';
import '../../ui/ports/ports_vocabulary.dart';

/// One menu line per port worth acting on, `:5173 vite · feat/open-ports`.
///
/// Only ports a worktree owns, plus orphans — a machine has dozens of system
/// listeners and the mockup is explicit that they are "noise, not work" (§6).
/// The branch is appended when the repos snapshot knows the worktree; a port
/// owned by a worktree the app has not learned about yet keeps its line and
/// drops the suffix rather than disappearing.
List<String> trayPortLabels(PortsSnapshot? snapshot, ReposState repos) {
  if (snapshot == null) return const [];
  final labels = <String>[];
  final ports =
      snapshot.ports
          .where((p) => p.worktreePath != null || p.orphan != null)
          .toList()
        ..sort((a, b) => a.port.compareTo(b.port));
  for (final port in ports) {
    final suffix = port.orphan != null
        ? portOrphanWord
        : repos.locateWorktree(port.worktreePath)?.worktree.branch;
    final head = ':${port.port} ${portRowToken(port)}';
    labels.add(suffix == null ? head : '$head · $suffix');
  }
  return labels;
}
