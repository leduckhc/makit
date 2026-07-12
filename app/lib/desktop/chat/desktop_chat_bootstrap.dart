/// Orders the two things the desktop chat window needs before it can talk to a
/// harness: (1) the local daemon must be running, and (2) this desktop must be
/// paired with it over loopback.
///
/// Kept separate from the widget so the ordering guard — never attempt pairing
/// if the daemon failed to come up — is unit-testable without a real socket.
library;

/// Sequences daemon startup then loopback self-pairing.
class DesktopChatBootstrap {
  /// Creates a bootstrap.
  ///
  /// [ensureDaemonRunning] starts the daemon if needed and resolves to whether
  /// it is running. [ensurePaired] self-pairs over loopback (a no-op when a
  /// bearer already exists).
  DesktopChatBootstrap({
    required Future<bool> Function() ensureDaemonRunning,
    required Future<void> Function() ensurePaired,
  })  : _ensureDaemonRunning = ensureDaemonRunning,
        _ensurePaired = ensurePaired;

  final Future<bool> Function() _ensureDaemonRunning;
  final Future<void> Function() _ensurePaired;

  /// Runs the sequence. Returns `true` once the daemon is running and pairing
  /// has been ensured; `false` (without pairing) if the daemon never came up.
  Future<bool> run() async {
    final running = await _ensureDaemonRunning();
    if (!running) return false;
    await _ensurePaired();
    return true;
  }
}
