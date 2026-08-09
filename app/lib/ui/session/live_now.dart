/// The live-tick seam for session-timing counters (SPEC-47 D5/D14/D21).
///
/// A running tool call, a streaming thought and the working indicator all need
/// a number that advances once a second. They must NOT each own a
/// `Timer.periodic`, and they must NOT wrap a duration label in [PulseBuilder]
/// (which rebuilds 20×/second — `kPulseInterval`, `pulse.dart` — to emit
/// identical text 19 of those times). Instead every counter watches one
/// [ServerNowTicker]: one timer for the whole app (the shared [PulseClock]),
/// one rebuild per displayed second.
///
/// The elapsed value is computed from timestamps at build time
/// (`serverNow - startTs`) and accumulates nothing, so a row scrolled off the
/// viewport pauses harmlessly and renders the right number on its next build.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/store.dart';
import '../widgets/pulse.dart';

/// The normal live cadence: one tick per whole second (D14 — the smallest unit
/// any label shows is `1s`, so sub-second rebuilds would produce identical
/// text).
const Duration kLiveTickCadence = Duration(seconds: 1);

/// The reduced-motion cadence (D21): under `MediaQuery.disableAnimations` a
/// per-second number is itself visual motion, so the tick coarsens to ~5 s. The
/// exact figure still lands on the finished row.
const Duration kLiveTickReducedMotionCadence = Duration(seconds: 5);

/// A [ValueNotifier] whose value is "server-now" in ms, resampled from the
/// shared [PulseClock] but notifying **only when the [cadence] bucket changes**
/// (SPEC-47 D5). Live counters watch it and compute `serverNow - startTs`.
///
/// [nowMs] is the server clock (device wall clock + the store's server offset,
/// D15); it is injected so widget tests can drive an exact value rather than
/// asserting a label against a real wall clock. [clock] defaults to the shared
/// app clock; tests pass their own [Listenable].
class ServerNowTicker extends ValueNotifier<int> {
  ServerNowTicker({
    required int Function() nowMs,
    Listenable? clock,
    Duration cadence = kLiveTickCadence,
  }) : _nowMs = nowMs,
       _clock = clock ?? PulseClock.instance,
       _cadenceMs = cadence.inMilliseconds,
       super(nowMs()) {
    _lastQuantum = value ~/ _cadenceMs;
    _clock.addListener(_onTick);
  }

  final int Function() _nowMs;
  final Listenable _clock;
  final int _cadenceMs;
  late int _lastQuantum;

  void _onTick() {
    final now = _nowMs();
    final quantum = now ~/ _cadenceMs;
    if (quantum != _lastQuantum) {
      _lastQuantum = quantum;
      value = now;
    }
  }

  @override
  void dispose() {
    _clock.removeListener(_onTick);
    super.dispose();
  }
}

/// The app-wide live clock at a given cadence in **seconds** (SPEC-47 D5). A
/// family so a reduced-motion consumer can ask for the coarse 5 s tick (D21)
/// from the same seam. Widget tests override this with a controllable notifier
/// rather than asserting a label against a real wall clock.
final liveNowProvider = Provider.family<ValueListenable<int>, int>((
  ref,
  cadenceSeconds,
) {
  final store = ref.read(storeControllerProvider.notifier);
  final ticker = ServerNowTicker(
    nowMs: store.serverNowMs,
    cadence: Duration(seconds: cadenceSeconds),
  );
  ref.onDispose(ticker.dispose);
  return ticker;
});

/// The live-now listenable for [context], honouring reduced motion (D21).
ValueListenable<int> liveNowFor(WidgetRef ref, BuildContext context) {
  final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
  return ref.watch(
    liveNowProvider(
      reduced
          ? kLiveTickReducedMotionCadence.inSeconds
          : kLiveTickCadence.inSeconds,
    ),
  );
}
