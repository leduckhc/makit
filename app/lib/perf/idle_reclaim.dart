/// Shed idle cost when the app parks or the OS reports memory pressure.
///
/// A maximized window on a high-resolution panel re-rasterizes a large surface
/// every frame, so an app that keeps ticking while hidden wastes CPU and holds
/// memory it can rebuild. This observer does two safe, reversible things:
///
/// * It pauses the shared [PulseClock] when the window is not visible, so a
///   hidden window schedules no periodic frames.
/// * It trims Flutter's image cache on OS memory pressure and on park, so freed
///   decode buffers return to the allocator.
///
/// It never drops the live-image set while the window is visible, because that
/// would force on-screen images to reload. See [CacheTrimmer].
library;

import 'package:flutter/widgets.dart';

import '../ui/widgets/pulse.dart';

/// Drop cached images. When [clearLive] is true, also drop the live set, which
/// forces on-screen images to reload — only safe while the window is hidden.
typedef CacheTrimmer = void Function({required bool clearLive});

void _defaultTrim({required bool clearLive}) {
  final cache = PaintingBinding.instance.imageCache;
  // Evict images no widget currently shows. On-screen images stay, because
  // their live streams keep them out of this sweep.
  cache.clear();
  // Only when hidden: nothing is on screen, so the live set is safe to drop.
  if (clearLive) cache.clearLiveImages();
}

/// Pause the pulse and trim caches when the app parks or is pressured.
///
/// Construct it, then call [install] once at startup. Call [dispose] to stop.
/// Both collaborators are injected so tests drive them without the framework.
class IdleReclaimObserver with WidgetsBindingObserver {
  /// Creates an observer over [clock] and [trim].
  ///
  /// [clock] defaults to the shared [PulseClock.instance]; [trim] defaults to
  /// trimming Flutter's image cache.
  IdleReclaimObserver({PulseClock? clock, CacheTrimmer? trim})
    : _clock = clock ?? PulseClock.instance,
      _trim = trim ?? _defaultTrim;

  final PulseClock _clock;
  final CacheTrimmer _trim;

  /// Start observing lifecycle and memory-pressure signals.
  ///
  /// It adopts the state the app is ALREADY in. `addObserver` never replays the
  /// current lifecycle state, so an observer installed into a hidden or paused
  /// app would hear nothing until the next change, and leave the 20 Hz pulse
  /// running while the window was parked.
  void install() {
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    final state = binding.lifecycleState;
    if (state != null) didChangeAppLifecycleState(state);
  }

  /// Stop observing.
  void dispose() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` is a transient overlay (control center, app switcher), still on
    // screen. This matches the foreground definition the rest of the app uses.
    final visible =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _clock.setVisible(visible);
    // On park, nothing is on screen, so drop the live set too.
    if (!visible) _trim(clearLive: true);
  }

  @override
  void didHaveMemoryPressure() {
    // Pressure can arrive while visible, so keep on-screen images.
    _trim(clearLive: false);
  }
}

/// Install the idle-reclaim observer and return a disposer.
///
/// Call it once at startup, before the platform branch, so both the desktop and
/// mobile roots reclaim idle cost.
void Function() installIdleReclaim({PulseClock? clock, CacheTrimmer? trim}) {
  final observer = IdleReclaimObserver(clock: clock, trim: trim);
  observer.install();
  return observer.dispose;
}
