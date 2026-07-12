/// Self-pairs the desktop client with the local makit daemon over the
/// privileged control socket — no QR scan needed.
///
/// The desktop process is trusted-local: it already owns the daemon lifecycle
/// via the control socket (`~/.makit/control.sock`). Rather than invent a new
/// "loopback no-auth" mode on the server, it mints a normal pairing token over
/// the control socket ([ControlClient.pairMint]) and completes the same
/// `hello { pair }` handshake every phone uses — but against the loopback WS
/// listener (`127.0.0.1:<port>`), whose TLS cert already lists `127.0.0.1` in
/// its SAN. The server mints and persists a device bearer, so subsequent
/// launches reconnect straight from storage (see `ConnectionController._boot`).
library;

import '../../control/control_contract.dart';
import '../../pairing/pair_info.dart';

/// Completes the `hello { pair }` handshake for [info], persisting the bearer.
///
/// Mirrors `ConnectionController.pairWith`, narrowed to the surface this needs
/// so it can be driven by a fake in tests.
typedef PairWith = Future<void> Function(PairInfo info, {String label});

/// Orchestrates one-time loopback self-pairing for the desktop chat client.
class LoopbackPairing {
  /// Creates a self-pairing orchestrator.
  ///
  /// [isPaired] reports whether a bearer already exists (persisted from a prior
  /// launch); when true, [ensurePaired] does nothing. [label] names this device
  /// in the daemon's device registry.
  LoopbackPairing({
    required ControlClient control,
    required PairWith pairWith,
    required bool Function() isPaired,
    String label = 'Mac',
  })  : _control = control,
        _pairWith = pairWith,
        _isPaired = isPaired,
        _label = label;

  final ControlClient _control;
  final PairWith _pairWith;
  final bool Function() _isPaired;
  final String _label;

  /// Self-pairs over loopback unless already paired.
  ///
  /// Returns `true` when a new pairing was performed, `false` when a bearer was
  /// already present.
  Future<bool> ensurePaired() async {
    if (_isPaired()) return false;
    final status = await _control.status();
    final mint = await _control.pairMint();
    final info = PairInfo(
      host: '127.0.0.1',
      port: status.port,
      fingerprint: status.fingerprint,
      token: mint.token,
    );
    await _pairWith(info, label: _label);
    return true;
  }
}
