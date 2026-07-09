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
            port: 8787,
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
  });
}
