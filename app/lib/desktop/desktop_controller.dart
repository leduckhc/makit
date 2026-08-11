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
  /// [serveArgs] supplies the `makit start`/`restart` CLI arguments (bind host
  /// + port) built from the user's [ServerConfig], so every entry point (tray,
  /// bootstrap) honors the configured endpoint. Null → the daemon's own
  /// defaults.
  DesktopController({
    required this.client,
    required this.lifecycle,
    List<String> Function()? serveArgs,
  }) : _serveArgs = serveArgs;

  /// Talks to the running daemon over the control socket.
  final ControlClient client;

  /// Starts/stops/restarts the daemon process via the `makit` CLI.
  final DaemonLifecycle lifecycle;

  final List<String> Function()? _serveArgs;

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

  /// Incremented per [refresh]; only the newest may publish its result.
  int _refreshGeneration = 0;

  Duration _visibleInterval = const Duration(seconds: 3);
  Duration _hiddenInterval = const Duration(seconds: 30);
  bool _windowVisible = true;

  static const _stopped = DaemonSummary(
    state: DaemonState.stopped,
    pairedDevices: 0,
    runningSessions: 0,
  );

  /// Polls the daemon for status + devices + sessions and updates [summary].
  /// A control error means the daemon is not reachable → [DaemonState.stopped].
  ///
  /// Refreshes can overlap — the poll timer does not await the previous tick,
  /// [_act] refreshes after an action, and returning from hidden refreshes at
  /// once — so a slow earlier request could otherwise land after a newer one and
  /// repaint the window with the state it went to sleep with. Results from
  /// anything but the latest request are dropped.
  Future<void> refresh() async {
    final generation = ++_refreshGeneration;
    DaemonSummary summary;
    String? error;
    try {
      final status = await client.status();
      final devices = await client.devicesList();
      final sessions = await client.sessionsList();
      summary = DaemonSummary(
        state: DaemonState.running,
        pid: status.pid,
        pairedDevices: status.pairedDevices,
        runningSessions: status.runningSessions,
        deviceLabels: [for (final d in devices) d.label],
        sessionTitles: [for (final s in sessions) s.title],
      );
    } catch (e) {
      summary = _stopped;
      error = e.toString();
    }
    if (generation != _refreshGeneration) return;
    _summary = summary;
    _lastError = error;
    notifyListeners();
  }

  /// Starts the daemon (`makit start`) on the configured endpoint, then
  /// refreshes.
  Future<DaemonActionResult> start() => _act(
    () => lifecycle.start(serveArgs: _serveArgs?.call() ?? const []),
    transient: DaemonState.starting,
  );

  /// Stops the daemon (`makit stop`), then refreshes.
  Future<DaemonActionResult> stop() => _act(lifecycle.stop);

  /// Restarts the daemon (`makit restart`) on the configured endpoint, then
  /// refreshes.
  Future<DaemonActionResult> restart() => _act(
    () => lifecycle.restart(serveArgs: _serveArgs?.call() ?? const []),
    transient: DaemonState.starting,
  );

  Future<DaemonActionResult> _act(
    Future<DaemonActionResult> Function() action, {
    DaemonState? transient,
  }) async {
    // Serialize lifecycle actions. `start`/`stop`/`restart` share the daemon's
    // PID file and control socket (and `restart` is a `stop` then `start`), so
    // overlapping requests — from mashing Start/Stop/Restart or a reachability
    // change racing a manual action — can remove a freshly written PID file,
    // launch a second daemon, or stop one another action just started. Chaining
    // each action after the previous one makes them strictly sequential.
    final prior = _actionTail;
    final done = Completer<void>();
    _actionTail = done.future;
    if (prior != null) {
      try {
        await prior;
      } catch (_) {
        // A prior action's failure must not cancel the ones queued behind it.
      }
    }
    try {
      if (transient != null) {
        // Counts as newer than any refresh already in flight: an action's
        // `starting`/`stopping` state has to survive until the action's own
        // refresh replaces it, or a poll that left before the button was pressed
        // repaints it as stopped mid-start.
        ++_refreshGeneration;
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
    } finally {
      if (identical(_actionTail, done.future)) _actionTail = null;
      done.complete();
    }
  }

  /// Tail of the serialized lifecycle-action chain, or null when idle.
  Future<void>? _actionTail;

  /// Starts periodic polling: refreshes immediately, then every [interval]
  /// while the window is visible, dropping to [hiddenInterval] while it is not.
  /// Cancels any previous poll. Owned here so the app can stop it cleanly on
  /// quit (no orphaned timer).
  ///
  /// Each refresh is three control RPCs, so at 3s that is ~3600 calls an hour —
  /// wakeups the machine pays for even when nobody is looking at the window.
  /// Polling cannot stop outright while hidden: the tray menu and tooltip read
  /// [summary] (see `desktop_app.dart`), so a stopped poll would show stale
  /// device/session counts to someone who never opens the window.
  void startPolling({
    Duration interval = const Duration(seconds: 3),
    Duration hiddenInterval = const Duration(seconds: 30),
  }) {
    _visibleInterval = interval;
    _hiddenInterval = hiddenInterval;
    unawaited(refresh());
    _restartPoll();
  }

  /// Tells the controller whether the app's window is on screen, so polling can
  /// back off while it is not. Wired from the desktop app's lifecycle observer.
  ///
  /// Coming back refreshes immediately: state gathered up to [_hiddenInterval]
  /// ago must not be what the window paints on return.
  void setWindowVisible(bool visible) {
    if (visible == _windowVisible) return;
    _windowVisible = visible;
    if (_poll == null) return; // not polling; nothing to re-cadence
    _restartPoll();
    if (visible) unawaited(refresh());
  }

  void _restartPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(
      _windowVisible ? _visibleInterval : _hiddenInterval,
      (_) => unawaited(refresh()),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    _poll = null;
    super.dispose();
  }
}
