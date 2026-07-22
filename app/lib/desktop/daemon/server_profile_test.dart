// Unit tests for [ServerProfile] derivation. Co-located with the code under
// test (per SPEC-03 desktop layout).
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/server_profile.dart';
import 'package:makit/desktop/settings/server_config.dart'
    show kDefaultServerPort;

void main() {
  group('ServerProfile.resolve', () {
    const home = '/Users/dev';

    ServerProfile devFrom(String repoRoot) => ServerProfile.resolve(
      executablePath:
          '$repoRoot/app/build/macos/Build/Products/Release/makit.app/Contents/MacOS/makit',
      home: home,
    );

    test(
      'installed app (non dev-build path) → backward-compatible default',
      () {
        final p = ServerProfile.resolve(
          executablePath: '/Applications/makit.app/Contents/MacOS/makit',
          home: home,
        );
        expect(p.isDefault, isTrue);
        expect(p.id, 'default');
        expect(p.label, 'makit');
        expect(p.makitHome, '$home/.makit');
        expect(p.port, kDefaultServerPort);
        expect(p.controlSocketPath, '$home/.makit/control.sock');
        expect(p.prefsPrefix, 'flutter.');
        expect(p.windowTitle, 'Makit');
      },
    );

    test('dev build → isolated home, dev port, namespaced prefs', () {
      final p = devFrom('/Users/dev/Work/makit');
      expect(p.isDefault, isFalse);
      expect(p.label, 'makit');
      expect(p.makitHome, '$home/.makit-dev/${p.id}');
      expect(p.port, inInclusiveRange(7800, 7899));
      expect(p.controlSocketPath, '$home/.makit-dev/${p.id}/control.sock');
      expect(p.prefsPrefix, 'flutter.${p.id}.');
      expect(p.windowTitle, 'Makit — makit');
      expect(p.environment, {'MAKIT_HOME': p.makitHome});
    });

    test('worktree build → label is the worktree folder name', () {
      final p = devFrom('/Users/dev/.worktrees/makit/feature-x');
      expect(p.label, 'feature-x');
      expect(p.windowTitle, 'Makit — feature-x');
    });

    test(
      'derivation is deterministic (stable id/port/home across launches)',
      () {
        final a = devFrom('/Users/dev/.worktrees/makit/feature-x');
        final b = devFrom('/Users/dev/.worktrees/makit/feature-x');
        expect(a.id, b.id);
        expect(a.port, b.port);
        expect(a.makitHome, b.makitHome);
      },
    );

    test('different repos get different homes (no collision)', () {
      final main = devFrom('/Users/dev/Work/makit');
      final wt = devFrom('/Users/dev/.worktrees/makit/feature-x');
      expect(main.id, isNot(wt.id));
      expect(main.makitHome, isNot(wt.makitHome));
    });
  });
}
