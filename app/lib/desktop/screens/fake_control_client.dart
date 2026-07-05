/// In-memory [ControlClient] used by widget tests and screen previews.
library;

import 'dart:async';

import '../../control/control_contract.dart';

/// A canned [ControlClient] that returns injected data after a small delay to
/// simulate socket latency.
///
/// Each request method can be made to fail by supplying the matching
/// `throwOn*` flag, which surfaces a [StateError] to exercise the screens'
/// error states. [tailLogs] emits [logLines] at [logInterval] and then
/// completes, or errors when [throwOnTailLogs] is set.
class FakeControlClient implements ControlClient {
  /// Creates a fake client seeded with canned responses.
  FakeControlClient({
    StatusData? status,
    List<DeviceInfo>? devices,
    List<ControlSession>? sessions,
    PairMintData? mint,
    PairCurrentData? current,
    List<LogLine>? logLines,
    this.latency = const Duration(milliseconds: 50),
    this.logInterval = const Duration(milliseconds: 100),
    this.throwOnStatus = false,
    this.throwOnPairMint = false,
    this.throwOnPairCurrent = false,
    this.throwOnDevicesList = false,
    this.throwOnDevicesRevoke = false,
    this.throwOnSessionsList = false,
    this.throwOnServerStop = false,
    this.throwOnTailLogs = false,
  }) : _status = status,
       _devices = devices,
       _sessions = sessions,
       _mint = mint,
       _current = current,
       _logLines = logLines;

  final StatusData? _status;
  List<DeviceInfo>? _devices;
  final List<ControlSession>? _sessions;
  final PairMintData? _mint;
  final PairCurrentData? _current;
  final List<LogLine>? _logLines;

  /// Latency applied before every request/response method resolves.
  final Duration latency;

  /// Delay between emitted log lines in [tailLogs].
  final Duration logInterval;

  /// When set, [status] throws instead of returning.
  final bool throwOnStatus;

  /// When set, [pairMint] throws instead of returning.
  final bool throwOnPairMint;

  /// When set, [pairCurrent] throws instead of returning.
  final bool throwOnPairCurrent;

  /// When set, [devicesList] throws instead of returning.
  final bool throwOnDevicesList;

  /// When set, [devicesRevoke] throws instead of returning.
  final bool throwOnDevicesRevoke;

  /// When set, [sessionsList] throws instead of returning.
  final bool throwOnSessionsList;

  /// When set, [serverStop] throws instead of returning.
  final bool throwOnServerStop;

  /// When set, [tailLogs] errors the stream instead of emitting lines.
  final bool throwOnTailLogs;

  /// Number of times [status] has been invoked (for refresh assertions).
  int statusCalls = 0;

  /// Number of times [pairMint] has been invoked.
  int pairMintCalls = 0;

  /// Number of times [pairCurrent] has been invoked.
  int pairCurrentCalls = 0;

  /// Number of times [devicesList] has been invoked.
  int devicesListCalls = 0;

  /// Ids passed to [devicesRevoke], in call order.
  final List<String> revokedIds = [];

  /// Number of times [sessionsList] has been invoked.
  int sessionsListCalls = 0;

  /// Number of times [serverStop] has been invoked.
  int serverStopCalls = 0;

  @override
  Future<StatusData> status() async {
    statusCalls++;
    await Future<void>.delayed(latency);
    if (throwOnStatus || _status == null) {
      throw StateError('status unavailable');
    }
    return _status;
  }

  @override
  Future<PairMintData> pairMint({int? ttlMs}) async {
    pairMintCalls++;
    await Future<void>.delayed(latency);
    if (throwOnPairMint || _mint == null) {
      throw StateError('pairMint unavailable');
    }
    return _mint;
  }

  @override
  Future<PairCurrentData?> pairCurrent() async {
    pairCurrentCalls++;
    await Future<void>.delayed(latency);
    if (throwOnPairCurrent) {
      throw StateError('pairCurrent unavailable');
    }
    return _current;
  }

  @override
  Future<List<DeviceInfo>> devicesList() async {
    devicesListCalls++;
    await Future<void>.delayed(latency);
    if (throwOnDevicesList) {
      throw StateError('devicesList unavailable');
    }
    return _devices ?? const [];
  }

  @override
  Future<bool> devicesRevoke(String id) async {
    revokedIds.add(id);
    await Future<void>.delayed(latency);
    if (throwOnDevicesRevoke) {
      throw StateError('devicesRevoke failed');
    }
    _devices = (_devices ?? const []).where((d) => d.id != id).toList();
    return true;
  }

  @override
  Future<List<ControlSession>> sessionsList() async {
    sessionsListCalls++;
    await Future<void>.delayed(latency);
    if (throwOnSessionsList) {
      throw StateError('sessionsList unavailable');
    }
    return _sessions ?? const [];
  }

  @override
  Future<void> serverStop() async {
    serverStopCalls++;
    await Future<void>.delayed(latency);
    if (throwOnServerStop) {
      throw StateError('serverStop failed');
    }
  }

  @override
  Stream<LogLine> tailLogs({int? lines, bool follow = false}) {
    // A single cancellable [Timer] chain drives emission so cancelling the
    // subscription (e.g. on widget dispose) leaves no pending timers.
    final controller = StreamController<LogLine>();
    final canned =
        _logLines ??
        const [LogLine('line 1'), LogLine('line 2'), LogLine('line 3')];
    Timer? timer;
    var index = 0;

    void scheduleNext() {
      timer = Timer(logInterval, () {
        if (controller.isClosed) return;
        if (throwOnTailLogs) {
          controller.addError(StateError('connection lost'));
          controller.close();
          return;
        }
        if (index >= canned.length) {
          controller.close();
          return;
        }
        controller.add(canned[index++]);
        scheduleNext();
      });
    }

    controller.onListen = scheduleNext;
    controller.onCancel = () => timer?.cancel();
    return controller.stream;
  }
}
