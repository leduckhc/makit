/// Desktop dashboard/tray state machine for the macOS control app (SPEC-03).
///
/// Owns the polled [DaemonSummary] (running/stopped + device & session counts)
/// and the start/stop/restart actions, delegating the socket to a
/// [ControlClient] and process lifecycle to a [DaemonLifecycle]. Kept free of
/// any native (tray/window) calls so it is unit-testable; the app root wires it
/// to the tray and window.
library;

import 'package:flutter/foundation.dart';

import '../control/control_contract.dart';
import 'daemon/daemon_lifecycle.dart';
import 'tray/tray_controller.dart';

/// A [ChangeNotifier] holding daemon state for the desktop UI + tray.
class DesktopController extends ChangeNotifier {
  /// Creates a controller over [client] (control socket) and [lifecycle]
  /// (process start/stop).
  DesktopController({required this.client, required this.lifecycle});

  /// Talks to the running daemon over the control socket.
  final ControlClient client;

  /// Starts/stops/restarts the daemon process via the `pino` CLI.
  final DaemonLifecycle lifecycle;

  DaemonSummary _summary = _stopped;
  String? _lastError;
  bool _cliMissing = false;

  /// The current daemon summary (drives the dashboard header + tray menu).
  DaemonSummary get summary => _summary;

  /// The most recent refresh error, or `null` when the daemon is reachable.
  String? get lastError => _lastError;

  /// Whether the last lifecycle action failed because the `pino` CLI is not
  /// installed (drives the "install the CLI" affordance).
  bool get cliMissing => _cliMissing;

  static const _stopped = DaemonSummary(
    state: DaemonState.stopped,
    pairedDevices: 0,
    runningSessions: 0,
  );

  /// Polls the daemon for status + devices + sessions and updates [summary].
  /// A control error means the daemon is not reachable → [DaemonState.stopped].
  Future<void> refresh() async {
    try {
      final status = await client.status();
      final devices = await client.devicesList();
      final sessions = await client.sessionsList();
      _summary = DaemonSummary(
        state: DaemonState.running,
        pid: status.pid,
        pairedDevices: status.pairedDevices,
        runningSessions: status.runningSessions,
        deviceLabels: [for (final d in devices) d.label],
        sessionTitles: [for (final s in sessions) s.title],
      );
      _lastError = null;
    } catch (e) {
      _summary = _stopped;
      _lastError = e.toString();
    }
    notifyListeners();
  }

  /// Starts the daemon (`pino start`), then refreshes.
  Future<DaemonActionResult> start() =>
      _act(lifecycle.start, transient: DaemonState.starting);

  /// Stops the daemon (`pino stop`), then refreshes.
  Future<DaemonActionResult> stop() => _act(lifecycle.stop);

  /// Restarts the daemon (`pino restart`), then refreshes.
  Future<DaemonActionResult> restart() =>
      _act(lifecycle.restart, transient: DaemonState.starting);

  Future<DaemonActionResult> _act(
    Future<DaemonActionResult> Function() action, {
    DaemonState? transient,
  }) async {
    if (transient != null) {
      _summary = DaemonSummary(
        state: transient,
        pid: _summary.pid,
        pairedDevices: _summary.pairedDevices,
        runningSessions: _summary.runningSessions,
      );
      notifyListeners();
    }
    final result = await action();
    _cliMissing = result.outcome == DaemonActionOutcome.cliNotFound;
    await refresh();
    return result;
  }
}
