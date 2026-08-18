// SPEC-ports-global-view P2a T2 — the pure filter + grouping behind the global Ports screen.
// No widgets, no container: data in, filtered/grouped data out.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/ports/ports_filter.dart';

PortInfo _port({
  required int port,
  String? worktreePath,
  PortReach reach = PortReach.loopback,
  PortOrphan? orphan,
}) => PortInfo(
  key: '$port:0.0.0.0:$port',
  port: port,
  address: reach == PortReach.exposed ? '0.0.0.0' : '127.0.0.1',
  reach: reach,
  pid: port,
  command: 'node vite --port $port',
  worktreePath: worktreePath,
  orphan: orphan,
);

Worktree _wt(String path, String branch) => Worktree(
  id: path,
  path: path,
  branch: branch,
  isPrimary: false,
  insertions: 0,
  deletions: 0,
  filesChanged: 0,
  sessionIds: const [],
);

RepoInfo _repo(String id, String name, List<Worktree> worktrees) => RepoInfo(
  id: id,
  name: name,
  path: '/$name',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: worktrees,
);

final _repos = ReposState([
  _repo('A', 'makit', [
    _wt('/A/feat', 'feat/open-ports'),
    _wt('/A/main', 'main'),
  ]),
  _repo('B', 'chat-ui', [_wt('/B/x', 'access_control')]),
]);

PortsSnapshot _snap(List<PortInfo> ports, {bool scanOk = true}) =>
    PortsSnapshot(ports: ports, scannedAt: 0, scanOk: scanOk);

void main() {
  final owned5173 = _port(port: 5173, worktreePath: '/A/feat');
  final owned9787 = _port(
    port: 9787,
    worktreePath: '/A/feat',
    reach: PortReach.exposed,
  );
  final owned5174 = _port(port: 5174, worktreePath: '/A/main');
  final ownedB = _port(port: 4173, worktreePath: '/B/x');
  final system = _port(port: 22); // no worktreePath
  final snap = _snap([owned5173, owned9787, owned5174, ownedB, system]);

  group('filterPorts', () {
    test('All keeps every port', () {
      expect(filterPorts(snap, PortsFilter.all, _repos), hasLength(5));
    });

    test('This repo keeps only the given repo\'s owned ports', () {
      final got = filterPorts(snap, PortsFilter.thisRepo, _repos, repoId: 'A');
      expect(got.map((p) => p.port), unorderedEquals([5173, 9787, 5174]));
    });

    test('Mine keeps ports with a worktreePath (drops system/unowned)', () {
      final got = filterPorts(snap, PortsFilter.mine, _repos);
      expect(got.contains(system), isFalse);
      expect(got.map((p) => p.port), unorderedEquals([5173, 9787, 5174, 4173]));
    });

    test('Exposed keeps only reach == exposed', () {
      final got = filterPorts(snap, PortsFilter.exposed, _repos);
      expect(got.map((p) => p.port), [9787]);
    });

    test('Orphans keeps only ports carrying an orphan annotation', () {
      final orphan = _port(
        port: 5180,
        worktreePath: null,
        orphan: const PortOrphan(formerBranch: 'feat/gone'),
      );
      final withOrphan = _snap([owned5173, system, orphan]);
      final got = filterPorts(withOrphan, PortsFilter.orphans, _repos);
      expect(got.map((p) => p.port), [5180]);
    });

    test('a null snapshot yields no ports', () {
      expect(filterPorts(null, PortsFilter.all, _repos), isEmpty);
    });
  });

  group('groupByRepoWorktree', () {
    test('groups repo -> worktree -> port in first-seen order', () {
      final grouping = groupByRepoWorktree(
        filterPorts(snap, PortsFilter.mine, _repos),
        _repos,
      );
      expect(grouping.repos.map((r) => r.repoId), ['A', 'B']);
      final a = grouping.repos.first;
      expect(a.repoName, 'makit');
      expect(a.worktrees.map((w) => w.branch), ['feat/open-ports', 'main']);
      expect(a.worktrees.first.ports.map((p) => p.port), [5173, 9787]);
      expect(grouping.systemPorts, isEmpty);
    });

    test('unowned ports collapse into the system group', () {
      final grouping = groupByRepoWorktree(
        filterPorts(snap, PortsFilter.all, _repos),
        _repos,
      );
      expect(grouping.systemPorts.map((p) => p.port), [22]);
      // The owned repos are still grouped.
      expect(grouping.repos.map((r) => r.repoId), ['A', 'B']);
    });
  });
}
