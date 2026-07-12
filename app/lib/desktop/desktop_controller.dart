/// Desktop dashboard/tray state machine for the macOS control app (SPEC-03).
///
/// Owns the polled [DaemonSummary] (running/stopped + device & session counts)
/// and the start/stop/restart actions, delegating the socket to a
/// [ControlClient] and process lifecycle to a [DaemonLifecycle]. Kept free of
/// any native (tray/window) calls so it is unit-testable; the app root wires it
/// to the tray and window.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../control/control_contract.dart';
import 'daemon/daemon_lifecycle.dart';
import 'tray/tray_controller.dart';

/// A [ChangeNotifier] holding daemon state for the desktop UI + tray.
class DesktopController extends ChangeNotifier {
  /// Creates a controller over [client] (control socket) and [lifecycle]
  /// (process start/stop).
  ///
  /// [serveDefaults] supplies the host/port `start`/`restart` bind to when no
  /// explicit values are given, so every entry point (tray, bootstrap) honors
  /// the user's configured endpoint. Null → the daemon's own defaults.
  DesktopController({
    required this.client,
    required this.lifecycle,
    ({String host, int port}) Function()? serveDefaults,
  }) : _serveDefaults = serveDefaults;

  /// Talks to the running daemon over the control socket.
  final ControlClient client;

  /// Starts/stops/restarts the daemon process via the `makit` CLI.
  final DaemonLifecycle lifecycle;

  final ({String host, int port}) Function()? _serveDefaults;

  DaemonSummary _summary = _stopped;
  String? _lastError;
  bool _cliMissing = false;
  Timer? _poll;

  /// The current daemon summary (drives the dashboard header + tray menu).
  DaemonSummary get summary => _summary;

  /// The most recent refresh error, or `null` when the daemon is reachable.
  String? get lastError => _lastError;

  /// Whether the last lifecycle action failed because the `makit` CLI is not
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

  /// Starts the daemon (`makit start`) on the configured endpoint, then
  /// refreshes.
  Future<DaemonActionResult> start() {
    final d = _serveDefaults?.call();
    return _act(
      () => lifecycle.start(host: d?.host, port: d?.port),
      transient: DaemonState.starting,
    );
  }

  /// Stops the daemon (`makit stop`), then refreshes.
  Future<DaemonActionResult> stop() => _act(lifecycle.stop);

  /// Restarts the daemon (`makit restart`) on the configured endpoint, then
  /// refreshes.
  Future<DaemonActionResult> restart() {
    final d = _serveDefaults?.call();
    return _act(
      () => lifecycle.restart(host: d?.host, port: d?.port),
      transient: DaemonState.starting,
    );
  }

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

  /// Starts periodic polling: refreshes immediately, then every [interval].
  /// Cancels any previous poll. Owned here so the app can stop it cleanly on
  /// quit (no orphaned timer).
  void startPolling({Duration interval = const Duration(seconds: 3)}) {
    _poll?.cancel();
    unawaited(refresh());
    _poll = Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _poll = null;
    super.dispose();
  }
}
