/// SPEC-42 P2a — the pure filter + grouping behind the global Ports screen.
///
/// Pure functions and value types only: no widgets, no provider reads, so the
/// screen's visible-set logic is testable without a container (the same split
/// as [portsForWorktree] in `store/ports.dart`). The repo/worktree lookup reads
/// [ReposState] the way `closed_screen.dart` groups by repo.
library;

import '../../store/models.dart';
import '../../store/ports.dart';
import '../../store/store.dart';

/// Ports whose process tree belongs to [sessionId], ascending by port then pid.
/// Pure so it can back both the session-tile glyph and its test without a
/// container (mirrors [portsForWorktree]).
List<PortInfo> portsForSession(PortsSnapshot? snapshot, String sessionId) {
  if (snapshot == null) return const [];
  final list = snapshot.ports.where((p) => p.sessionId == sessionId).toList()
    ..sort((a, b) {
      final byPort = a.port.compareTo(b.port);
      return byPort != 0 ? byPort : a.pid.compareTo(b.pid);
    });
  return list;
}

/// The built-in filters the screen offers (spec §6). *Orphans* keeps only
/// ports carrying a D10 orphan annotation — the listeners whose worktree is
/// gone.
enum PortsFilter { all, thisRepo, mine, exposed, orphans }

/// One worktree's ports within a repo group.
class WorktreePortGroup {
  const WorktreePortGroup({
    required this.worktreePath,
    required this.branch,
    required this.ports,
  });

  final String worktreePath;
  final String branch;
  final List<PortInfo> ports;
}

/// One repo's worktrees (each with its ports), in first-seen order.
class RepoPortGroup {
  const RepoPortGroup({
    required this.repoId,
    required this.repoName,
    required this.worktrees,
  });

  final String repoId;
  final String repoName;
  final List<WorktreePortGroup> worktrees;
}

/// The screen's grouped view: owned ports under repo → worktree, plus the
/// collapsed "other / system" list for everything unowned.
class PortsGrouping {
  const PortsGrouping({required this.repos, required this.systemPorts});

  final List<RepoPortGroup> repos;
  final List<PortInfo> systemPorts;

  bool get isEmpty => repos.isEmpty && systemPorts.isEmpty;
}

/// Applies [filter] to [snapshot]'s ports. A null snapshot yields no ports (the
/// screen shows a waiting/empty state, never a fabricated list). *This repo*
/// keeps only ports owned by a worktree of [repoId]; *Mine* keeps any owned
/// port; *Exposed* keeps only wildcard binds; *All* keeps everything.
List<PortInfo> filterPorts(
  PortsSnapshot? snapshot,
  PortsFilter filter,
  ReposState repos, {
  String? repoId,
}) {
  if (snapshot == null) return const [];
  final ports = snapshot.ports;
  switch (filter) {
    case PortsFilter.all:
      return List.unmodifiable(ports);
    case PortsFilter.mine:
      return ports.where((p) => p.worktreePath != null).toList();
    case PortsFilter.exposed:
      return ports.where((p) => p.reach == PortReach.exposed).toList();
    case PortsFilter.orphans:
      return ports.where((p) => p.orphan != null).toList();
    case PortsFilter.thisRepo:
      if (repoId == null) return const [];
      final paths = {
        for (final w in repos.byId(repoId)?.worktrees ?? const <Worktree>[])
          w.path,
      };
      return ports
          .where(
            (p) => p.worktreePath != null && paths.contains(p.worktreePath),
          )
          .toList();
  }
}

/// Groups [ports] repo → worktree → port in first-seen order. A port whose
/// [PortInfo.worktreePath] matches no active worktree (including unowned ports)
/// collapses into [PortsGrouping.systemPorts].
PortsGrouping groupByRepoWorktree(List<PortInfo> ports, ReposState repos) {
  final repoOrder = <String>[];
  final repoGroups = <String, RepoPortGroup>{};
  final worktreeOrder = <String, List<String>>{};
  final worktreeGroups = <String, Map<String, WorktreePortGroup>>{};
  final systemPorts = <PortInfo>[];

  for (final port in ports) {
    final located = repos.locateWorktree(port.worktreePath);
    if (located == null) {
      systemPorts.add(port);
      continue;
    }
    final repo = located.repo;
    final worktree = located.worktree;
    if (!repoGroups.containsKey(repo.id)) {
      repoOrder.add(repo.id);
      repoGroups[repo.id] = RepoPortGroup(
        repoId: repo.id,
        repoName: repo.name,
        worktrees: [],
      );
      worktreeOrder[repo.id] = [];
      worktreeGroups[repo.id] = {};
    }
    final wtGroups = worktreeGroups[repo.id]!;
    if (!wtGroups.containsKey(worktree.path)) {
      worktreeOrder[repo.id]!.add(worktree.path);
      final group = WorktreePortGroup(
        worktreePath: worktree.path,
        branch: worktree.branch ?? 'detached',
        ports: [],
      );
      wtGroups[worktree.path] = group;
      repoGroups[repo.id]!.worktrees.add(group);
    }
    wtGroups[worktree.path]!.ports.add(port);
  }

  return PortsGrouping(
    repos: [for (final id in repoOrder) repoGroups[id]!],
    systemPorts: systemPorts,
  );
}
