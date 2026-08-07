// Unit tests for the desktop controller (dashboard/tray state machine).
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/control/control_contract.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';
import 'package:makit/desktop/desktop_controller.dart';
import 'package:makit/desktop/tray/tray_controller.dart';

/// A control client whose responses (or failure) the test drives.
/// A client whose `status()` parks on a completer the test controls, so two
/// refreshes can be finished out of order deterministically.
class _GatedControlClient implements ControlClient {
  final List<Completer<void>> gates = [];
  int pairedDevices = 0;

  @override
  Future<StatusData> status() async {
    // Captured at call time: the payload each refresh carries is the state as of
    // when it asked, which is the whole point of the ordering test.
    final asked = pairedDevices;
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    return StatusData(
      pid: 42,
      uptimeMs: 0,
      host: 'h',
      port: 7788,
      fingerprint: 'f',
      advertiseHost: 'h',
      pairedDevices: asked,
      runningSessions: 0,
      version: 'v',
    );
  }

  @override
  Future<List<DeviceInfo>> devicesList() async => const [];

  @override
  Future<List<ControlSession>> sessionsList() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _FakeControlClient implements ControlClient {
  bool up = true;
  List<DeviceInfo> devices = const [];
  List<ControlSession> sessions = const [];
  int pairedDevices = 0;
  int runningSessions = 0;
  int statusCalls = 0;

  Never _down() => throw const ControlException('not connected');

  @override
  Future<StatusData> status() async {
    statusCalls++;
    return up
        ? StatusData(
            pid: 42,
            uptimeMs: 0,
            host: 'h',
            port: 7788,
            fingerprint: 'f',
            advertiseHost: 'h',
            pairedDevices: pairedDevices,
            runningSessions: runningSessions,
            version: 'v',
          )
        : _down();
  }

  @override
  Future<List<DeviceInfo>> devicesList() async => up ? devices : _down();

  @override
  Future<List<ControlSession>> sessionsList() async => up ? sessions : _down();

  @override
  Future<bool> devicesRevoke(String id) async => up ? true : _down();
  @override
  Future<PairCurrentData?> pairCurrent() async => up ? null : _down();
  @override
  Future<PairMintData> pairMint({int? ttlMs}) async => up
      ? const PairMintData(url: 'u', token: 't', expiresAt: 0, fingerprint: 'f')
      : _down();
  @override
  Future<void> serverStop() async => up ? null : _down();
  @override
  Stream<LogLine> tailLogs({int? lines, bool follow = false}) =>
      const Stream.empty();
}

DeviceInfo _device(String label) => DeviceInfo(
  id: label,
  label: label,
  pairedAt: 0,
  lastSeenAt: 0,
  connected: true,
);

/// A lifecycle whose CLI resolves to a stub that returns [exitCode], or is
/// missing when [found] is false.
DaemonLifecycle _lifecycle({
  bool found = true,
  int exitCode = 0,
  List<List<String>>? calls,
}) => DaemonLifecycle(
  resolver: MakitCliResolver(
    candidatePaths: found ? ['/x/makit'] : const [],
    exists: (_) => found,
    shellLookup: () async => null,
  ),
  run: (exe, args) async {
    calls?.add([exe, ...args]);
    return ProcessResult(0, exitCode, '', 'err');
  },
);

void main() {
  group('DesktopController', () {
    test('starts in the stopped state before any refresh', () {
      final c = DesktopController(
        client: _FakeControlClient(),
        lifecycle: _lifecycle(),
      );
      expect(c.summary.state, DaemonState.stopped);
    });

    test(
      'refresh reflects a running daemon with devices and sessions',
      () async {
        final client = _FakeControlClient()
          ..pairedDevices = 2
          ..runningSessions = 1
          ..devices = [_device('phone-a'), _device('phone-b')];
        final c = DesktopController(client: client, lifecycle: _lifecycle());

        await c.refresh();

        expect(c.summary.state, DaemonState.running);
        expect(c.summary.pid, 42);
        expect(c.summary.pairedDevices, 2);
        expect(c.summary.deviceLabels, ['phone-a', 'phone-b']);
        expect(c.lastError, isNull);
      },
    );

    test(
      'refresh drops to stopped and records the error when the daemon is down',
      () async {
        final client = _FakeControlClient()..up = false;
        final c = DesktopController(client: client, lifecycle: _lifecycle());

        await c.refresh();

        expect(c.summary.state, DaemonState.stopped);
        expect(c.lastError, isNotNull);
      },
    );

    test('start runs the CLI then refreshes into running', () async {
      final calls = <List<String>>[];
      final client = _FakeControlClient()..up = true;
      final c = DesktopController(
        client: client,
        lifecycle: _lifecycle(calls: calls),
      );

      final result = await c.start();

      expect(result.outcome, DaemonActionOutcome.started);
      expect(calls.single, ['/x/makit', 'start']);
      expect(c.summary.state, DaemonState.running);
      expect(c.cliMissing, isFalse);
    });

    test('start flags cliMissing when the CLI cannot be found', () async {
      final c = DesktopController(
        client: _FakeControlClient()..up = false,
        lifecycle: _lifecycle(found: false),
      );

      final result = await c.start();

      expect(result.outcome, DaemonActionOutcome.cliNotFound);
      expect(c.cliMissing, isTrue);
    });

    test('stop runs `makit stop`', () async {
      final calls = <List<String>>[];
      final c = DesktopController(
        client: _FakeControlClient()..up = false,
        lifecycle: _lifecycle(calls: calls),
      );

      await c.stop();

      expect(calls.single, ['/x/makit', 'stop']);
    });

    test('notifies listeners on refresh', () async {
      var notes = 0;
      final c = DesktopController(
        client: _FakeControlClient(),
        lifecycle: _lifecycle(),
      )..addListener(() => notes++);

      await c.refresh();

      expect(notes, greaterThan(0));
    });

    test('startPolling refreshes on the interval; dispose stops it', () {
      fakeAsync((async) {
        final client = _FakeControlClient();
        final c = DesktopController(client: client, lifecycle: _lifecycle());

        c.startPolling(interval: const Duration(seconds: 5));
        async.flushMicrotasks(); // immediate refresh
        expect(client.statusCalls, 1);

        async.elapse(const Duration(seconds: 12)); // +2 ticks
        expect(client.statusCalls, 3);

        c.dispose();
        async.elapse(const Duration(seconds: 30)); // no more ticks
        expect(client.statusCalls, 3);
      });
    });

    // Battery: the window is often hidden for hours while sessions run. Polling
    // at the visible cadence then is pure wakeup cost — but it cannot stop
    // outright, because the tray menu/tooltip reads the same summary while the
    // window is gone (desktop_app.dart wires tray.update to this controller).
    test('polling backs off while the window is hidden', () {
      fakeAsync((async) {
        final client = _FakeControlClient();
        final c = DesktopController(client: client, lifecycle: _lifecycle());

        c.startPolling(
          interval: const Duration(seconds: 3),
          hiddenInterval: const Duration(seconds: 30),
        );
        async.flushMicrotasks(); // immediate refresh
        expect(client.statusCalls, 1);

        c.setWindowVisible(false);
        async.elapse(const Duration(seconds: 9)); // 3 visible ticks would fire
        expect(
          client.statusCalls,
          1,
          reason: 'hidden must not poll at the visible cadence',
        );

        async.elapse(const Duration(seconds: 21)); // 30s since hiding
        expect(
          client.statusCalls,
          2,
          reason: 'the tray still needs eventually-fresh state',
        );

        c.dispose();
      });
    });

    test('becoming visible refreshes at once and restores the cadence', () {
      fakeAsync((async) {
        final client = _FakeControlClient();
        final c = DesktopController(client: client, lifecycle: _lifecycle());

        c.startPolling(
          interval: const Duration(seconds: 3),
          hiddenInterval: const Duration(seconds: 30),
        );
        async.flushMicrotasks();
        c.setWindowVisible(false);
        async.elapse(const Duration(seconds: 5));
        expect(client.statusCalls, 1);

        // Whatever is on screen the moment the window comes back must not be
        // up to hiddenInterval stale.
        c.setWindowVisible(true);
        async.flushMicrotasks();
        expect(client.statusCalls, 2);

        async.elapse(const Duration(seconds: 3));
        expect(client.statusCalls, 3, reason: 'fast cadence resumed');

        c.dispose();
      });
    });

    // Coming back from hidden fires a refresh while a hidden-cadence refresh may
    // still be in flight. If the older one lands last it would repaint the
    // window with the state it went to sleep with.
    test('a slower earlier refresh cannot overwrite a newer one', () async {
      final client = _GatedControlClient();
      final c = DesktopController(client: client, lifecycle: _lifecycle());

      client.pairedDevices = 1;
      final first = c.refresh(); // the "hidden" refresh
      await pumpEventQueue();
      client.pairedDevices = 2;
      final second = c.refresh(); // the "just became visible" refresh
      await pumpEventQueue();
      expect(client.gates.length, 2, reason: 'both refreshes are in flight');

      // Finish the newer one first, then let the older one land.
      client.gates[1].complete();
      await second;
      expect(c.summary.pairedDevices, 2);

      client.gates[0].complete();
      await first;
      expect(
        c.summary.pairedDevices,
        2,
        reason: 'the stale result must be discarded, not applied',
      );

      c.dispose();
    });

    // Same class as the ordering test above: an action sets a transient state
    // (`starting`) and only refreshes once the CLI returns, so a poll that was
    // already in flight would otherwise land in between and repaint the button
    // as stopped mid-start.
    test(
      'a refresh in flight cannot erase the transient action state',
      () async {
        final client = _GatedControlClient();
        final actionGate = Completer<void>();
        final c = DesktopController(
          client: client,
          lifecycle: DaemonLifecycle(
            resolver: MakitCliResolver(
              candidatePaths: const ['/x/makit'],
              exists: (_) => true,
              shellLookup: () async => null,
            ),
            run: (exe, args) async {
              await actionGate.future;
              return ProcessResult(0, 0, '', '');
            },
          ),
        );

        final polling = c.refresh(); // in flight, parked on its gate
        await pumpEventQueue();

        final action = c.start(); // sets `starting`, then awaits the CLI
        await pumpEventQueue();
        expect(c.summary.state, DaemonState.starting);

        client.gates[0].complete(); // the older poll comes back now
        await polling;
        expect(
          c.summary.state,
          DaemonState.starting,
          reason: 'a poll from before the action must not erase its state',
        );

        actionGate.complete();
        await pumpEventQueue();
        client.gates.last.complete(); // the action's own post-run refresh
        await action;
        expect(c.summary.state, DaemonState.running);

        c.dispose();
      },
    );

    test('a repeated visibility signal neither re-polls nor stacks timers', () {
      fakeAsync((async) {
        final client = _FakeControlClient();
        final c = DesktopController(client: client, lifecycle: _lifecycle());

        c.startPolling(interval: const Duration(seconds: 3));
        async.flushMicrotasks();
        c.setWindowVisible(true); // already visible: no-op
        c.setWindowVisible(true);
        async.flushMicrotasks();
        expect(client.statusCalls, 1);

        async.elapse(const Duration(seconds: 3));
        expect(client.statusCalls, 2, reason: 'one timer, one tick');

        c.dispose();
      });
    });
  });
}
