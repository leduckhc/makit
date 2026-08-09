// SPEC-42 P2c T16 — the menubar's Ports submenu (D15).
//
// Lives under `test/` (not beside the code like the older tray suite) because
// `flutter test` does not run tests inside `lib/`, and this behaviour has to be
// covered by CI.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/tray/tray_controller.dart';
import 'package:makit/desktop/tray/tray_ports.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/store/store.dart';
import 'package:tray_manager/tray_manager.dart';

class FakeTrayPlatform implements TrayPlatform {
  final List<String> tooltips = [];
  final List<Menu> menus = [];

  @override
  Future<void> setImagePath(String path) async {}

  @override
  Future<void> setTemplateImage(bool isTemplate) async {}

  @override
  Future<void> setTooltip(String tooltip) async => tooltips.add(tooltip);

  @override
  Future<void> setMenu(Menu menu) async => menus.add(menu);

  @override
  Future<void> destroy() async {}

  Menu get lastMenu => menus.last;
}

/// Every label in [menu], submenu entries included.
List<String> _labels(Menu menu) {
  final out = <String>[];
  for (final item in menu.items ?? const <MenuItem>[]) {
    if (item.label != null) out.add(item.label!);
    for (final sub in item.submenu?.items ?? const <MenuItem>[]) {
      if (sub.label != null) out.add(sub.label!);
    }
  }
  return out;
}

const _running = DaemonSummary(
  state: DaemonState.running,
  pid: 1234,
  pairedDevices: 0,
  runningSessions: 0,
);

PortInfo _port({
  required int port,
  String? worktreePath = '/A/feat',
  PortOrphan? orphan,
  String command = '/opt/node_modules/.bin/vite --port 5173',
}) => PortInfo(
  key: '$port:127.0.0.1:$port',
  port: port,
  address: '127.0.0.1',
  reach: PortReach.loopback,
  pid: port,
  command: command,
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

final _repos = ReposState([
  RepoInfo(
    id: 'A',
    name: 'makit',
    path: '/A',
    pinned: false,
    lastActivityAt: 0,
    isGitRepo: true,
    defaultBranch: 'main',
    currentBranch: 'main',
    worktrees: [_wt('/A/feat', 'feat/open-ports')],
  ),
]);

PortsSnapshot _snap(List<PortInfo> ports) =>
    PortsSnapshot(ports: ports, scannedAt: 3000, scanOk: true);

void main() {
  group('trayPortLabels', () {
    test('a null snapshot yields no labels (never a fabricated empty scan)', () {
      // The scanner is watch-gated: before any surface holds a watch there is
      // no snapshot at all, which is not the same fact as "nothing listening".
      expect(trayPortLabels(null, _repos), isEmpty);
    });

    test('an owned port reads ":port command · branch"', () {
      expect(trayPortLabels(_snap([_port(port: 5173)]), _repos), [
        ':5173 vite · feat/open-ports',
      ]);
    });

    test('an orphan is listed and says so; system noise is dropped', () {
      final labels = trayPortLabels(
        _snap([
          _port(port: 22, worktreePath: null, command: '/usr/sbin/sshd'),
          _port(
            port: 5180,
            worktreePath: null,
            orphan: const PortOrphan(formerBranch: 'gone/branch'),
          ),
          _port(port: 5173),
        ]),
        _repos,
      );
      expect(labels, [':5173 vite · feat/open-ports', ':5180 vite · orphan']);
      expect(
        labels.any((l) => l.contains('sshd')),
        isFalse,
        reason: 'system listeners are noise, not work (mockup §6)',
      );
    });

    test(
      'an owned port whose worktree is unknown still lists, sans branch',
      () {
        // The repos snapshot and the ports snapshot arrive independently, so a
        // port can be owned by a worktree the app has not learned about yet.
        expect(
          trayPortLabels(_snap([_port(port: 5999)]), ReposState(const [])),
          [':5999 vite'],
        );
      },
    );
  });

  group('TrayController ports submenu (D15)', () {
    test(
      'no cached snapshot → a "No ports" submenu, and no scan to arm',
      () async {
        final fake = FakeTrayPlatform();
        final tray = TrayController(
          stateAccessor: () => _running,
          platform: fake,
          isMacOS: true,
        );
        await tray.init();
        final labels = _labels(fake.lastMenu);
        expect(labels, contains('Ports (0)'));
        expect(labels, contains('No ports'));
        expect(fake.tooltips.last, 'Makit — running');
      },
    );

    test(
      'setPorts lists the cached ports and counts them in the label',
      () async {
        final fake = FakeTrayPlatform();
        final tray = TrayController(
          stateAccessor: () => _running,
          platform: fake,
          isMacOS: true,
        );
        await tray.init();
        await tray.setPorts(const [
          ':5173 vite · feat/open-ports',
          ':9787 makit · main',
        ]);

        final labels = _labels(fake.lastMenu);
        expect(labels, contains('Ports (2)'));
        expect(labels, contains(':5173 vite · feat/open-ports'));
        expect(labels, contains(':9787 makit · main'));
        expect(
          fake.tooltips.last,
          'Makit — running · 2 ports',
          reason: 'D15 puts the live count in the tooltip',
        );
      },
    );

    test('offers "Open Ports…" and NO destructive item (kill is P3)', () async {
      final fake = FakeTrayPlatform();
      var opened = 0;
      final tray = TrayController(
        stateAccessor: () => _running,
        platform: fake,
        isMacOS: true,
        onOpenPorts: () => opened++,
      );
      await tray.setPorts(const [':5175 vite · fix/scroll']);

      final labels = _labels(fake.lastMenu);
      expect(labels, contains('Open Ports…'));
      expect(labels.any((l) => l.contains('Kill')), isFalse);

      final item = (fake.lastMenu.items ?? const <MenuItem>[])
          .expand((i) => i.submenu?.items ?? const <MenuItem>[])
          .firstWhere((i) => i.label == 'Open Ports…');
      item.onClick!(item);
      expect(opened, 1);
    });

    test('setPorts on a non-macOS host touches nothing', () async {
      final fake = FakeTrayPlatform();
      final tray = TrayController(
        stateAccessor: () => _running,
        platform: fake,
        isMacOS: false,
      );
      await tray.setPorts(const [':5173 vite']);
      expect(fake.menus, isEmpty);
    });
  });
}
