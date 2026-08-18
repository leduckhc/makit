/// Control-socket contract consumed by the SPEC-desktop-control-app desktop screens.
///
/// The desktop UI depends on the abstract [ControlClient], while the concrete
/// socket implementation and tests share the wire DTOs from `control_types.dart`
/// so the UI contract cannot drift from the daemon protocol.
library;

import 'control_types.dart';

export 'control_types.dart'
    show
        ControlException,
        ControlSession,
        DeviceInfo,
        LogLine,
        PairCurrentData,
        PairMintData,
        StatusData;

/// Abstract control-plane client used by the desktop screens.
///
/// Every method maps to a control-socket verb. Implementations must surface
/// transport failures as thrown exceptions for request/response methods or as
/// stream errors for [tailLogs].
abstract class ControlClient {
  /// Fetches a one-shot snapshot of daemon status.
  Future<StatusData> status();

  /// Mints a fresh pairing token, optionally overriding its lifetime in
  /// milliseconds via [ttlMs].
  Future<PairMintData> pairMint({int? ttlMs});

  /// Returns the currently-active pairing token, or `null` when none is live.
  Future<PairCurrentData?> pairCurrent();

  /// Lists every device currently paired with the daemon.
  Future<List<DeviceInfo>> devicesList();

  /// Revokes the device with [id]. Resolves to `true` when a device was
  /// actually removed.
  Future<bool> devicesRevoke(String id);

  /// Lists sessions known to the daemon.
  Future<List<ControlSession>> sessionsList();

  /// Requests a graceful daemon shutdown.
  Future<void> serverStop();

  /// Tails the daemon log.
  ///
  /// [lines] bounds the initial backfill; [follow] keeps the stream open for
  /// live lines until the subscription is cancelled.
  Stream<LogLine> tailLogs({int? lines, bool follow = false});
}
