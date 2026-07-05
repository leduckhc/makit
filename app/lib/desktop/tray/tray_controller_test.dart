// Unit tests for the menubar tray controller. This file lives beside the code
// under test (per SPEC-03 Stream B layout), so it necessarily imports the
// flutter_test dev-dependency from a lib/ path.
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:pino/desktop/tray/tray_controller.dart';
import 'package:pino/desktop/tray/tray_icons.dart';
import 'package:tray_manager/tray_manager.dart';

/// Records every call the [TrayController] makes so tests can assert on
/// behaviour without touching the real (native) tray_manager plugin.
class FakeTrayPlatform implements TrayPlatform {
  final List<String> imagePaths = [];
  final List<bool> templateFlags = [];
  final List<String> tooltips = [];
  final List<Menu> menus = [];
  int destroyCount = 0;

  @override
  Future<void> setImagePath(String path) async => imagePaths.add(path);

  @override
  Future<void> setTemplateImage(bool isTemplate) async =>
      templateFlags.add(isTemplate);

  @override
  Future<void> setTooltip(String tooltip) async => tooltips.add(tooltip);

  @override
  Future<void> setMenu(Menu menu) async => menus.add(menu);

  @override
  Future<void> destroy() async => destroyCount++;

  /// The most recent menu passed to [setMenu].
  Menu get lastMenu => menus.last;
}

/// Flattens all labels in [menu] (including one level of submenu) so tests can
/// assert that a given entry is present.
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

DaemonSummary _running() => const DaemonSummary(
  state: DaemonState.running,
  pid: 1234,
  pairedDevices: 0,
  runningSessions: 0,
);

DaemonSummary _stopped() => const DaemonSummary(
  state: DaemonState.stopped,
  pairedDevices: 0,
  runningSessions: 0,
);

void main() {
  group('TrayController', () {
    late FakeTrayPlatform fake;

    setUp(() => fake = FakeTrayPlatform());

    test('init() sets image, tooltip and menu exactly once', () async {
      final controller = TrayController(
        stateAccessor: _stopped,
        platform: fake,
      );

      await controller.init();

      expect(fake.imagePaths, [TrayIcons.defaultIconPath]);
      expect(fake.tooltips, hasLength(1));
      expect(fake.menus, hasLength(1));
      expect(fake.templateFlags, [true]);
    });

    test('update(running) sets tooltip and includes Stop Server', () async {
      final controller = TrayController(
        stateAccessor: _running,
        platform: fake,
      );

      await controller.update(_running());

      expect(fake.tooltips.last, 'Pino — running');
      expect(_labels(fake.lastMenu), contains('Stop Server'));
      expect(_labels(fake.lastMenu), isNot(contains('Start Server')));
      expect(_labels(fake.lastMenu), contains('Running (pid 1234)'));
    });

    test('update(stopped) sets tooltip and includes Start Server', () async {
      final controller = TrayController(
        stateAccessor: _stopped,
        platform: fake,
      );

      await controller.update(_stopped());

      expect(fake.tooltips.last, 'Pino — stopped');
      expect(_labels(fake.lastMenu), contains('Start Server'));
      expect(_labels(fake.lastMenu), isNot(contains('Stop Server')));
      expect(_labels(fake.lastMenu), contains('Stopped'));
    });

    test('update() with 3 devices creates a Devices (3) submenu', () async {
      final controller = TrayController(
        stateAccessor: _running,
        platform: fake,
      );

      await controller.update(
        const DaemonSummary(
          state: DaemonState.running,
          pid: 1234,
          pairedDevices: 3,
          runningSessions: 0,
          deviceLabels: ['iPhone', 'iPad', 'Pixel'],
        ),
      );

      expect(_labels(fake.lastMenu), contains('Devices (3)'));
      expect(_labels(fake.lastMenu), contains('iPhone'));
      expect(_labels(fake.lastMenu), contains('iPad'));
      expect(_labels(fake.lastMenu), contains('Pixel'));
    });

    test('update() builds a Sessions (N) submenu with titles', () async {
      final controller = TrayController(
        stateAccessor: _running,
        platform: fake,
      );

      await controller.update(
        const DaemonSummary(
          state: DaemonState.running,
          pid: 1234,
          pairedDevices: 0,
          runningSessions: 2,
          sessionTitles: ['build app', 'fix tests'],
        ),
      );

      expect(_labels(fake.lastMenu), contains('Sessions (2)'));
      expect(_labels(fake.lastMenu), contains('build app'));
      expect(_labels(fake.lastMenu), contains('fix tests'));
    });

    test('empty devices/sessions submenus show placeholders', () async {
      final controller = TrayController(
        stateAccessor: _running,
        platform: fake,
      );

      await controller.update(_running());

      final labels = _labels(fake.lastMenu);
      expect(labels, contains('Devices (0)'));
      expect(labels, contains('No devices'));
      expect(labels, contains('Sessions (0)'));
      expect(labels, contains('No sessions'));
    });

    test('menu always contains Dashboard, Pair QR and Quit', () async {
      final controller = TrayController(
        stateAccessor: _running,
        platform: fake,
      );

      await controller.update(_running());

      final labels = _labels(fake.lastMenu);
      expect(labels, contains('Dashboard'));
      expect(labels, contains('Pair QR...'));
      expect(labels, contains('Quit Pino'));
    });

    test('menu callbacks fire when a menu item is clicked', () async {
      var started = false;
      var dashboard = false;
      var qr = false;
      var quit = false;
      final controller = TrayController(
        stateAccessor: _stopped,
        platform: fake,
        onStart: () => started = true,
        onOpenDashboard: () => dashboard = true,
        onOpenQr: () => qr = true,
        onQuit: () => quit = true,
      );

      await controller.update(_stopped());

      MenuItem itemFor(String label) =>
          (fake.lastMenu.items ?? []).firstWhere((i) => i.label == label);

      itemFor('Start Server').onClick!(itemFor('Start Server'));
      itemFor('Dashboard').onClick!(itemFor('Dashboard'));
      itemFor('Pair QR...').onClick!(itemFor('Pair QR...'));
      itemFor('Quit Pino').onClick!(itemFor('Quit Pino'));

      expect(started, isTrue);
      expect(dashboard, isTrue);
      expect(qr, isTrue);
      expect(quit, isTrue);
    });

    test('update() notifies listeners', () async {
      var notified = 0;
      final controller = TrayController(
        stateAccessor: _running,
        platform: fake,
      )..addListener(() => notified++);

      await controller.update(_running());

      expect(notified, 1);
    });

    test('dispose() destroys the tray icon', () async {
      final controller = TrayController(
        stateAccessor: _stopped,
        platform: fake,
      );

      controller.dispose();

      expect(fake.destroyCount, 1);
    });
  });
}
